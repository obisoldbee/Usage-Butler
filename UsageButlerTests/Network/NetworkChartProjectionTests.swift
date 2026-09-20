import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

/// Deterministic guards for the trend projection. Every case here encodes one
/// artifact the user actually saw: upload and download joined into one line,
/// long diagonals across holes, and points that looked live but were replays.
final class NetworkChartProjectionTests: XCTestCase {
    private let baseWall = Date(timeIntervalSince1970: 1_700_000_000)
    private let session = CaptureSessionID(rawValue: "s-1")

    private func sample(
        seconds: TimeInterval,
        upload: Double?,
        download: Double?,
        session: CaptureSessionID? = nil,
        epoch: UInt64 = 0
    ) -> NetworkRateSample {
        NetworkRateSample(
            captureSessionID: session ?? self.session,
            counterEpoch: CounterEpoch(rawValue: epoch),
            sampledAt: baseWall.addingTimeInterval(seconds),
            sampledMonotonic: MonotonicInstant(nanoseconds: UInt64(seconds * 1_000_000_000)),
            uploadBytesPerSecond: upload,
            downloadBytesPerSecond: download
        )
    }

    private func project(
        _ samples: [NetworkRateSample],
        now: TimeInterval,
        window: TimeInterval = 60,
        contract: NetworkChartSamplingContract = NetworkChartSamplingContract(),
        maxPointsPerSegment: Int = 140
    ) -> NetworkChartProjection {
        NetworkChartProjector.project(
            samples,
            interface: "en0",
            now: baseWall.addingTimeInterval(now),
            window: window,
            contract: contract,
            maxPointsPerSegment: maxPointsPerSegment
        )
    }

    private func seriesKeys(_ points: [NetworkChartPoint]) -> Set<String> {
        Set(points.map(\.seriesKey))
    }

    // MARK: - Direction isolation

    func testUploadAndDownloadNeverShareASeries() {
        let samples = stride(from: 0.0, through: 10.0, by: 1.0).map {
            sample(seconds: $0, upload: $0 * 100, download: 500)
        }
        let projection = project(samples, now: 10)
        let uploadKeys = seriesKeys(projection.points(.upload))
        let downloadKeys = seriesKeys(projection.points(.download))

        XCTAssertFalse(uploadKeys.isEmpty)
        XCTAssertFalse(downloadKeys.isEmpty)
        XCTAssertTrue(uploadKeys.isDisjoint(with: downloadKeys), "directions must never join")
        XCTAssertEqual(projection.segmentCount, 2, "one continuous run per direction")
    }

    func testColorsAreDrivenByDirectionNotByEmissionOrder() {
        let samples = [
            sample(seconds: 0, upload: 900, download: 10),
            sample(seconds: 1, upload: 100, download: 20)
        ]
        let projection = project(samples, now: 1)
        for point in projection.points {
            let expected = point.direction == .upload ? "upload" : "download"
            XCTAssertEqual(point.direction.scaleKey, expected)
            XCTAssertTrue(point.seriesKey.contains("|\(expected)|"), "series key must encode direction")
        }
    }

    /// The original defect: two runs emitted in sequence with no `series`
    /// identity produced one edge from the upload's last point to the
    /// download's first point. A shared key would re-enable exactly that.
    func testNoEdgeCanCrossBetweenDirectionsEvenWithIdenticalTimes() {
        let samples = [
            sample(seconds: 1, upload: 800, download: nil),
            sample(seconds: 2, upload: 40, download: 600)
        ]
        let projection = project(samples, now: 2)
        // upload: one run over t1,t2. download: one run containing only t2.
        XCTAssertEqual(seriesKeys(projection.points).count, 2, "directions must not share a line")
        XCTAssertTrue(Set(projection.points.map(\.seriesKey)).allSatisfy { key in
            projection.points.filter { $0.seriesKey == key }.allSatisfy { $0.direction.scaleKey == key.components(separatedBy: "|")[3] }
        }, "every point in a series belongs to one direction")
    }

    // MARK: - Time ordering within a series

    func testEverySeriesIsStrictlyTimeOrdered() {
        var samples: [NetworkRateSample] = []
        for tick in stride(from: 0.0, through: 30.0, by: 1.0) {
            samples.append(sample(seconds: tick, upload: tick.truncatingRemainder(dividingBy: 3) * 100, download: 200))
        }
        let projection = project(samples, now: 30)
        let grouped = Dictionary(grouping: projection.points, by: \.seriesKey)
        XCTAssertGreaterThan(grouped.count, 1)
        for (_, points) in grouped {
            let times = points.map(\.at)
            XCTAssertEqual(times, times.sorted(by: { $0 < $1 }))
            for index in 1..<points.count {
                XCTAssertLessThan(points[index - 1].at, points[index].at, "no time reversal inside a series")
            }
        }
    }

    func testWallClockRollbackCannotReverseAPath() {
        let samples = [
            sample(seconds: 10, upload: 100, download: 100),
            sample(seconds: 3, upload: 200, download: 200),   // wall jumps backwards
            sample(seconds: 12, upload: 300, download: 300)
        ]
        let projection = project(samples, now: 12)
        for points in Dictionary(grouping: projection.points, by: \.seriesKey).values {
            XCTAssertEqual(points, points.sorted { $0.at < $1.at })
        }
        XCTAssertFalse(projection.points.contains { $0.at == baseWall.addingTimeInterval(3) && $0.value == 200 })
    }

    // MARK: - Gaps

    func testBothDirectionGapBreaksBothLinesAndLeavesVisiblePoint() {
        let samples = [
            sample(seconds: 1, upload: 100, download: 100),
            sample(seconds: 2, upload: 200, download: 200),
            sample(seconds: 3, upload: nil, download: nil),   // hole
            sample(seconds: 4, upload: 400, download: 400)
        ]
        let projection = project(samples, now: 4)
        XCTAssertEqual(projection.segmentCount, 4, "2 upload + 2 download segments")
        let uploadKeys = seriesKeys(projection.points(.upload))
        XCTAssertEqual(uploadKeys.count, 2)
        XCTAssertTrue(projection.points.contains { $0.at == baseWall.addingTimeInterval(4) })
    }

    /// A missing upload must not punch a hole in download.
    func testSingleDirectionGapKeepsOtherDirectionContinuous() {
        let samples = [
            sample(seconds: 1, upload: 100, download: 100),
            sample(seconds: 2, upload: nil, download: 200),
            sample(seconds: 3, upload: 300, download: 300)
        ]
        let projection = project(samples, now: 3)
        XCTAssertEqual(projection.points(.download).count, 3)
        XCTAssertEqual(seriesKeys(projection.points(.download)).count, 1, "download stays one line")
        XCTAssertEqual(seriesKeys(projection.points(.upload)).count, 2)
    }

    func testLoneSampleStaysVisible() {
        let samples = [
            sample(seconds: 1, upload: 100, download: 100),
            sample(seconds: 2, upload: nil, download: 200),
            sample(seconds: 3, upload: nil, download: 300),
            sample(seconds: 4, upload: 900, download: 400)
        ]
        let projection = project(samples, now: 4)
        // Upload is unknown at t2 and t3, so both surviving upload readings
        // stand alone and must each be drawn as a visible dot.
        let isolated = projection.points.filter(\.isIsolated)
        XCTAssertEqual(isolated.map(\.value), [100, 900])
        XCTAssertEqual(projection.isolatedPointCount, 2)
    }

    func testLongSilenceBreaksTheLine() {
        let samples = [
            sample(seconds: 1, upload: 100, download: 100),
            sample(seconds: 2, upload: 200, download: 200),
            sample(seconds: 30, upload: 300, download: 300),
            sample(seconds: 31, upload: 400, download: 400)
        ]
        let projection = project(samples, now: 31, contract: NetworkChartSamplingContract(nominalSampleInterval: 1))
        XCTAssertEqual(seriesKeys(projection.points(.upload)).count, 2)
        XCTAssertGreaterThan(projection.gapThreshold, 1)
    }

    /// Hidden-panel publication is throttled; ordinary 5 s spacing must not be
    /// reported as a hole in the observation.
    func testSlowCadenceDoesNotShatterTheTrend() {
        let samples = stride(from: 0.0, through: 60.0, by: 5.0).map {
            sample(seconds: $0, upload: 100, download: 100)
        }
        let projection = project(samples, now: 60, window: 120)
        XCTAssertEqual(projection.segmentCount, 2, "one line per direction")
        XCTAssertEqual(seriesKeys(projection.points(.upload)).count, 1)
    }

    // MARK: - Session / epoch boundaries

    func testSessionChangeStartsNewSeries() {
        let samples = [
            sample(seconds: 1, upload: 100, download: 100),
            sample(seconds: 2, upload: 200, download: 200, session: CaptureSessionID(rawValue: "s-2"))
        ]
        let projection = project(samples, now: 2)
        XCTAssertEqual(seriesKeys(projection.points(.upload)).count, 2)
    }

    func testEpochChangeStartsNewSeries() {
        let samples = [
            sample(seconds: 1, upload: 100, download: 100, epoch: 4),
            sample(seconds: 2, upload: 200, download: 200, epoch: 5)
        ]
        let projection = project(samples, now: 2)
        let keys = seriesKeys(projection.points(.upload))
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(keys.contains { $0.contains("|4|") })
        XCTAssertTrue(keys.contains { $0.contains("|5|") })
    }

    func testInterfaceNameIsPartOfEverySeriesKey() {
        let samples = [sample(seconds: 1, upload: 100, download: 100)]
        let projection = NetworkChartProjector.project(
            samples,
            interface: "utun5",
            now: baseWall.addingTimeInterval(1),
            window: 60,
            contract: NetworkChartSamplingContract()
        )
        XCTAssertTrue(projection.points.allSatisfy { $0.seriesKey.hasPrefix("utun5|") })
    }

    /// Series identity is anchored on the segment's own start, so a refresh
    /// that changes how many segments exist cannot relabel surviving ones.
    func testAppendingALaterSampleDoesNotRelabelTheExistingSegment() {
        let short = stride(from: 0.0, through: 20.0, by: 1.0).map {
            sample(seconds: $0, upload: $0 * 10, download: 50)
        }
        var long = short
        long.append(sample(seconds: 21, upload: 210, download: 50))
        let before = seriesKeys(project(short, now: 20, window: 60).points(.upload))
        let after = seriesKeys(project(long, now: 21, window: 60).points(.upload))
        XCTAssertEqual(before, after, "segment identity must anchor on its start, not on how many points it has")
    }

    // MARK: - Window and empty history

    func testNothingIsPlottedBeforeTheRealStart() {
        let samples = stride(from: 20.0, through: 40.0, by: 1.0).map {
            sample(seconds: $0, upload: 100, download: 100)
        }
        let projection = project(samples, now: 40, window: 60)
        XCTAssertEqual(projection.points(.upload).count, 21)
        let earlier = project(samples, now: 25, window: 60)
        XCTAssertEqual(earlier.points(.upload).count, 6, "no zero-filled history before the first sample")
    }

    func testPointsOutsideWindowAreExcludedFromBothEnds() {
        let samples = stride(from: 0.0, through: 100.0, by: 1.0).map {
            sample(seconds: $0, upload: 100, download: 100)
        }
        let projection = project(samples, now: 100, window: 10)
        XCTAssertEqual(projection.points(.upload).count, 10)
        XCTAssertTrue(projection.points.allSatisfy { $0.at > baseWall.addingTimeInterval(90) })
    }

    func testEmptyInputProducesEmptyProjection() {
        let projection = project([], now: 10)
        XCTAssertTrue(projection.points.isEmpty)
        XCTAssertEqual(projection.segmentCount, 0)
        XCTAssertEqual(projection.isolatedPointCount, 0)
    }

    // MARK: - Downsampling fidelity

    func testThinningKeepsEndpointsPeakAndValley() {
        var samples: [NetworkRateSample] = []
        for tick in 0..<1_000 {
            let value = tick == 500 ? 9_000.0 : (tick == 700 ? 1.0 : Double(tick))
            samples.append(sample(seconds: Double(tick), upload: value, download: 10))
        }
        let projection = project(samples, now: 999, window: 1_000, maxPointsPerSegment: 40)
        let upload = projection.points(.upload).map(\.value)
        XCTAssertLessThan(upload.count, 200, "must actually thin")
        XCTAssertGreaterThanOrEqual(projection.thinnedSegmentCount, 1)
        XCTAssertEqual(upload.max(), 9_000, "peak survives thinning")
        XCTAssertTrue(upload.contains(1), "valley survives thinning")
        XCTAssertEqual(upload.first, 0, "segment start survives thinning")
        XCTAssertEqual(upload.last, 999, "segment end survives thinning")
    }

    func testThinningNeverInventsAnUnknownValue() {
        let samples = stride(from: 0.0, through: 300.0, by: 1.0).map {
            sample(seconds: $0, upload: $0 < 150 ? $0 : nil, download: 10)
        }
        let projection = project(samples, now: 300, window: 301, maxPointsPerSegment: 20)
        XCTAssertTrue(projection.points(.upload).allSatisfy { $0.value >= 0 && $0.value < 150 })
        let download = projection.points(.download)
        XCTAssertLessThan(download.count, 301, "long continuous run must be thinned")
        XCTAssertFalse(download.isEmpty)
        XCTAssertTrue(download.allSatisfy { $0.value == 10 }, "thinning must not invent values")
    }
}
