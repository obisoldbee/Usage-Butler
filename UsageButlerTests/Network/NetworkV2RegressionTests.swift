import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

final class NetworkV2RegressionTests: XCTestCase {
    func testMixedCadenceDoesNotReinterpretOldHistory() {
        let times = stride(from: 0, through: 50, by: 5).map(Double.init) + (51...110).map(Double.init)
        let samples = times.map { t in NetworkRateSample(
            captureSessionID: .init(rawValue: "source"), counterEpoch: .init(rawValue: 1),
            sampledAt: Date(timeIntervalSince1970: t), sampledMonotonic: .init(nanoseconds: UInt64(t * 1e9)),
            uploadBytesPerSecond: 10, downloadBytesPerSecond: 1_000, samplingInterval: t <= 50 ? 5 : 1
        ) }
        let projection = NetworkChartProjector.project(samples, interface: "en0",
            now: Date(timeIntervalSince1970: 111), window: 200, contract: .init())
        XCTAssertEqual(projection.segmentCount, 2, "old 5-second history must remain continuous when 1-second points become the majority")
    }

    func testDownloadResetDoesNotRelabelUploadStart() {
        let session = CaptureSessionID(rawValue: "reset")
        var aggregator = NetworkAggregator(sessionID: session)
        for (index, bytes) in [(1_000, 1_000), (6_000, 9_000), (6_000, 100)].enumerated() {
            let at = Date(timeIntervalSince1970: Double(index + 1))
            let mono = MonotonicInstant(nanoseconds: UInt64(index + 1) * 1_000_000_000)
            let source = InterfaceCounters(name: "en0", kind: .physical,
                counters: .init(bytes: .init(upload: UInt64(bytes.0), download: UInt64(bytes.1)),
                                semantics: .cumulativeSinceEpoch, epoch: .init(rawValue: 1)),
                asOf: at, monotonicAsOf: mono)
            aggregator.apply(.init(envelope: .init(sessionID: session, sequence: UInt64(index + 1),
                occurredAt: at, monotonicOccurredAt: mono), payload: .interfaceCounters(source)))
        }
        let total = aggregator.snapshot(asOf: Date(timeIntervalSince1970: 3), monotonicAsOf: .init(nanoseconds: 3_000_000_000), collectionState: .active).interfaces["en0"]?.sessionTotal
        XCTAssertEqual(total?.bytes.upload, 5_000)
        XCTAssertEqual(total?.upload.since, Date(timeIntervalSince1970: 1))
    }
}
