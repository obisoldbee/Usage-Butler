import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

/// Measures production pure Swift stages in this test process. These numbers
/// are NOT SwiftUI layout/draw/present or input-to-screen frame times.
final class NetworkChartPerformanceTests: XCTestCase {
    func testTwoHourProjectionCacheHoverAndRangeWorkloads() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var results: [[String: Any]] = []
        var checksum = 0
        for workload in ["dense-7200", "gapped-7200"] {
            let samples = NetworkRateHistoryBuffer.identifyingContinuity((0..<7200).map { i in
                let gap = workload == "gapped-7200" && i % 97 < 4
                return NetworkRateSample(captureSessionID: .init(rawValue: "performance"), counterEpoch: .init(rawValue: UInt64(i / 1800)),
                    sampledAt: base.addingTimeInterval(Double(i)), sampledMonotonic: .init(nanoseconds: UInt64(i) * 1_000_000_000),
                    uploadBytesPerSecond: gap ? nil : Double((i * 71) % 1703),
                    downloadBytesPerSecond: gap ? nil : Double((i * 113) % 17009), interfaceName: "en0", samplingInterval: 1)
            })
            func measure(_ stage: String, count: Int, operation: (Int) -> Int) {
                var timings: [Double] = []
                timings.reserveCapacity(count)
                for i in 0..<count {
                    let begin = DispatchTime.now().uptimeNanoseconds
                    checksum &+= operation(i)
                    timings.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6)
                }
                let sorted = timings.sorted()
                func quantile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(ceil(p * Double(sorted.count))) - 1)] }
                results.append(["workload": workload, "stage": stage, "sampleCount": count,
                    "unit": "ms", "p50": quantile(0.50), "p95": quantile(0.95), "p99": quantile(0.99),
                    "max": sorted.last!, "rawMilliseconds": timings])
            }
            let now = base.addingTimeInterval(7200)
            measure("project", count: 120) { i in
                NetworkChartProjector.project(samples, interface: "en0", now: now.addingTimeInterval(Double(i % 10)),
                    window: 7200, contract: .init()).points.count
            }
            var cache = NetworkChartProjectionCache()
            let frame = cache.frame(samples: samples, revision: 1, interface: "en0", now: now, window: 7200)
            measure("cached-frame", count: 1000) { _ in
                cache.frame(samples: samples, revision: 1, interface: "en0", now: now, window: 7200).projection.points.count
            }
            XCTAssertEqual(cache.buildCount, 1)
            measure("cursor-lookup", count: 2000) { i in
                frame.inspection.sample(at: base.addingTimeInterval(Double((i * 17) % 7200))) == nil ? 0 : 1
            }
            let windows: [Double] = [60, 600, 1800, 3600, 7200]
            measure("range-switch-frame", count: 150) { i in
                cache.frame(samples: samples, revision: 1, interface: "en0", now: now, window: windows[i % 5]).projection.points.count
            }
            measure("moving-window-frame", count: 120) { i in
                cache.frame(samples: samples, revision: 1, interface: "en0", now: now.addingTimeInterval(Double(i)), window: 7200).samples.count
            }
            var up = NetworkChartAxis(), down = NetworkChartAxis()
            measure("dual-axis-update", count: 1000) { i in
                up.update(peak: frame.uploadPeak ?? 0, monotonicNow: Double(i))
                down.update(peak: frame.downloadPeak ?? 0, monotonicNow: Double(i))
                return Int(up.upperBound + down.upperBound)
            }
        }
        XCTAssertGreaterThan(checksum, 0)
        let receipt: [String: Any] = ["method": "DispatchTime monotonic nanoseconds; synchronous production Swift stages in Debug XCTest; no warmup discarded", "sourcePointsPerWorkload": 7200,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "processorCount": ProcessInfo.processInfo.processorCount,
            "build": "0.3.3 (6) Debug", "results": results,
            "unmeasured": ["SwiftUI body", "system layout", "system draw", "present", "input-to-screen", "two-hour real-time soak"]]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print("NETWORK_PERFORMANCE_JSON=" + String(decoding: data, as: UTF8.self))
    }
}
