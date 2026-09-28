import XCTest
import UsageButlerDomain
import UsageButlerCore
@testable import UsageButlerUI

final class HistoryCurvePresentationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let plot = CGRect(x: 54, y: 12, width: 400, height: 110)
    private var range: HistoryRange { .init(start: start, end: start.addingTimeInterval(3_600)) }
    private func bucket(_ minute: Int, seconds: Double = 60, upload: UInt64? = 120, download: UInt64? = 600,
                        observed: UInt64 = 60_000_000, quality: HistoryQuality = []) -> HistoryCurveBucket {
        var totals = HistoryTotals(); totals.upload = upload; totals.download = download
        totals.uploadObservedMicroseconds = observed; totals.downloadObservedMicroseconds = observed
        totals.uploadSamples = upload == nil ? 0 : 6; totals.downloadSamples = download == nil ? 0 : 6
        totals.peakUpload = 20; totals.peakDownload = 100; totals.quality = quality
        return .init(id: minute, start: start.addingTimeInterval(Double(minute) * 60),
            end: start.addingTimeInterval(Double(minute) * 60 + seconds), totals: totals, segments: 1)
    }

    func testFirstTapUsesActualPositionInEitherDirectionWithoutHover() throws {
        for direction in [HistoryChartDirection.upload, .download] {
            for (x, seconds) in [(54.0, 0.0), (254.0, 1_800.0), (453.0, 3_591.0)] {
                var state = HistoryCurveInteraction()
                state.tap(at: .init(x: x, y: 70), plot: plot, range: range, direction: direction)
                XCTAssertEqual(try XCTUnwrap(state.inspected).timeIntervalSince(start), seconds, accuracy: 0.000001)
                XCTAssertEqual(state.focused, direction); XCTAssertTrue(state.pinned)
            }
        }
    }

    func testSecondTapRepositionsAndTransfersFocusEvenWhilePinned() {
        var state = HistoryCurveInteraction()
        state.tap(at: .init(x: 254, y: 70), plot: plot, range: range, direction: .upload)
        state.hover(at: .init(x: 453, y: 70), plot: plot, range: range)
        XCTAssertEqual(state.inspected, start.addingTimeInterval(1_800))
        state.tap(at: .init(x: 54, y: 70), plot: plot, range: range, direction: .download)
        XCTAssertEqual(state.inspected, start); XCTAssertEqual(state.focused, .download)
    }

    func testAxisOutsideAndNonfiniteCoordinatesNeverClampToEndpoints() {
        for p in [CGPoint(x: 53, y: 70), .init(x: 454, y: 70), .init(x: 200, y: 11),
                  .init(x: 200, y: 123), .init(x: CGFloat.infinity, y: 70)] {
            var state = HistoryCurveInteraction()
            state.tap(at: .init(x: 254, y: 70), plot: plot, range: range, direction: .upload)
            state.tap(at: p, plot: plot, range: range, direction: .download)
            XCTAssertNil(state.inspected); XCTAssertNil(state.focused); XCTAssertFalse(state.pinned)
            state.hover(at: p, plot: plot, range: range); XCTAssertNil(state.inspected)
        }
        XCTAssertNil(HistoryCurveInteraction.time(at: .zero, plot: .zero, range: range))
    }

    func testGapSelectionIsKeptWithoutFallingBackToLastBucket() {
        let buckets = [bucket(0), bucket(59)]
        var state = HistoryCurveInteraction()
        state.tap(at: .init(x: 254, y: 70), plot: plot, range: range, direction: .upload)
        XCTAssertEqual(state.inspected, start.addingTimeInterval(1_800))
        XCTAssertNil(HistoryCurvePresentation.bucket(at: state.inspected, in: buckets))
        state.step(1, buckets: buckets); XCTAssertEqual(state.inspected, buckets.last?.start)
        state.tap(at: .init(x: 254, y: 70), plot: plot, range: range, direction: .download)
        state.step(-1, buckets: buckets); XCTAssertEqual(state.inspected, buckets.first?.start)
    }

    func testKeyboardBoundsAndEscapeResetLeaveNoOldSelection() {
        let buckets = [bucket(0), bucket(1)]
        var state = HistoryCurveInteraction(); state.focused = .upload
        state.step(1, buckets: buckets); XCTAssertEqual(state.inspected, buckets[0].start)
        state.step(-1, buckets: buckets); XCTAssertEqual(state.inspected, buckets[0].start)
        state.step(1, buckets: buckets); state.step(1, buckets: buckets)
        XCTAssertEqual(state.inspected, buckets[1].start)
        state.reset(); state.step(1, buckets: buckets)
        XCTAssertNil(state.inspected); XCTAssertNil(state.focused); XCTAssertFalse(state.pinned)
        state.focused = .download; state.step(-1, buckets: [])
        XCTAssertNil(state.inspected)
    }

    func testHoverLeavingPlotClearsOnlyUnpinnedSelection() {
        var state = HistoryCurveInteraction()
        state.hover(at: .init(x: 254, y: 70), plot: plot, range: range)
        XCTAssertNotNil(state.inspected)
        state.hover(at: nil, plot: plot, range: range); XCTAssertNil(state.inspected)
        state.tap(at: .init(x: 254, y: 70), plot: plot, range: range, direction: .upload)
        state.hover(at: nil, plot: plot, range: range); XCTAssertNotNil(state.inspected)
    }

    func testBothDirectionsKeepAveragePeakBytesAndObservationSeparate() {
        var point = bucket(0, upload: 10_000_000, download: 1_000_000, observed: 2_500_000)
        point.totals.peakUpload = 9_000_000; point.totals.peakDownload = 800_000
        XCTAssertEqual(HistoryCurvePresentation.average(point, upload: true), 4_000_000)
        XCTAssertEqual(HistoryCurvePresentation.average(point, upload: false), 400_000)
        XCTAssertEqual(HistoryCurvePresentation.peak(point.totals, upload: true), 9_000_000)
        XCTAssertEqual(HistoryCurvePresentation.observedBytes(point.totals, upload: true), 10_000_000)
        XCTAssertEqual(HistoryCurvePresentation.observedSeconds(point, upload: true), 2.5)
        XCTAssertTrue(HistoryCurvePresentation.isPartial(point, upload: true))
    }

    func testKnownZeroAndMissingDirectionRemainDifferent() {
        var point = bucket(0, upload: 0, download: nil)
        point.totals.downloadObservedMicroseconds = 0
        XCTAssertEqual(HistoryCurvePresentation.average(point, upload: true), 0)
        XCTAssertEqual(HistoryCurvePresentation.observedBytes(point.totals, upload: true), 0)
        XCTAssertTrue(HistoryCurvePresentation.observation(point, upload: true).contains("已观察为零"))
        XCTAssertNil(HistoryCurvePresentation.average(point, upload: false))
        XCTAssertNil(HistoryCurvePresentation.peak(point.totals, upload: false))
        XCTAssertNil(HistoryCurvePresentation.observedBytes(point.totals, upload: false))
        XCTAssertEqual(HistoryCurvePresentation.observation(point, upload: false), "无可用记录")
        XCTAssertNil(HistoryCurvePresentation.observedBytes(.init(), upload: true))
    }

    func testMinuteBoundaryAloneDoesNotMeanMissingSamples() {
        let full = bucket(0, quality: .minuteBoundary)
        XCTAssertFalse(HistoryCurvePresentation.isPartial(full, upload: true))
        XCTAssertEqual(HistoryCurvePresentation.observation(full, upload: true), "已记录")
        XCTAssertTrue(HistoryCurvePresentation.isPartial(bucket(0, observed: 59_000_000, quality: .minuteBoundary), upload: true))
        XCTAssertTrue(HistoryCurvePresentation.isPartial(bucket(0, quality: [.minuteBoundary, .sourcePartial]), upload: true))
        XCTAssertTrue(HistoryCurvePresentation.isPartial(bucket(0, quality: [.minuteBoundary, .capacity]), upload: true))
        let asymmetric = bucket(0, quality: .downloadGap)
        XCTAssertFalse(HistoryCurvePresentation.isPartial(asymmetric, upload: true))
        XCTAssertTrue(HistoryCurvePresentation.isPartial(asymmetric, upload: false))
    }

    func testAllRangesKeepAbsoluteTimelineAndPrehistoryGap() throws {
        for duration: Double in [3_600, 86_400, 7 * 86_400, 14 * 86_400] {
            let selected = HistoryRange(start: start, end: start.addingTimeInterval(duration))
            let actualStart = start.addingTimeInterval(duration * 0.75)
            let gap = try XCTUnwrap(HistoryCurvePresentation.leadingUnrecorded(range: selected, first: actualStart))
            XCTAssertEqual(gap.start, selected.start); XCTAssertEqual(gap.end, actualStart)
            XCTAssertEqual(HistoryCurveInteraction.time(at: .init(x: 254, y: 70), plot: plot, range: selected), start.addingTimeInterval(duration / 2))
            XCTAssertEqual(NetworkChartCoordinates.ticks, [0, 0.5, 1])
        }
        XCTAssertNil(HistoryCurvePresentation.leadingUnrecorded(range: range, first: nil))
        XCTAssertNil(HistoryCurvePresentation.leadingUnrecorded(range: range, first: start))
    }

    func testMergedBucketShowsItsRealIntervalRatherThanOneMinute() {
        let point = bucket(1, seconds: 3_360, observed: 90_000_000)
        XCTAssertEqual(HistoryCurvePresentation.span(point), "56 分钟")
        XCTAssertTrue(HistoryCurvePresentation.granularity([point]).contains("56 分钟"))
        XCTAssertEqual(HistoryCurvePresentation.bucket(at: point.end.addingTimeInterval(-1), in: [point]), point)
        XCTAssertNil(HistoryCurvePresentation.bucket(at: point.end, in: [point]))
    }
}
