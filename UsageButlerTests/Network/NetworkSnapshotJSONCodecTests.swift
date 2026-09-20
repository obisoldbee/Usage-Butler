import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

final class NetworkSnapshotJSONCodecTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let appKey = "b:com.example.app|s:sig|t:team"

    // MARK: - Builders

    private func makeApp(upload: UInt64?, download: UInt64?, includeRate: Bool = true) -> AppNetworkCounters {
        AppNetworkCounters(
            identity: AppIdentity(
                bundleID: "com.example.app",
                signingIdentity: "sig",
                teamID: "team",
                version: "1.2.3",
                displayName: "Example"
            ),
            counters: NetworkByteCounters(
                bytes: DirectionalBytes(upload: upload, download: download),
                semantics: .cumulativeSinceEpoch,
                epoch: CounterEpoch(rawValue: 7)
            ),
            activeConnectionCount: 3,
            rate: includeRate
                ? NetworkRate(uploadBytesPerSecond: 1.5, downloadBytesPerSecond: nil, asOf: base, window: .seconds(2))
                : nil,
            lastActivity: base
        )
    }

    private func makeFullSnapshot() -> NetworkSnapshot {
        NetworkSnapshot(
            sessionID: CaptureSessionID(rawValue: "s-1"),
            appliedSequence: 42,
            asOf: base,
            monotonicAsOf: MonotonicInstant(nanoseconds: 5_000),
            collectionState: .partial(reason: "nettop degraded"),
            coverage: NetworkCoverage(
                identity: .full,
                bytes: .partial(reason: "one interface missing"),
                targets: .unavailable(reason: "no hostname source"),
                protocols: .full,
                lostEventCount: 2,
                counterResetCount: 1,
                truncatedCollections: ["apps"],
                hasLiveSample: true
            ),
            capabilities: NetworkCapabilities(
                observe: true,
                blockNewConnections: false,
                terminateExistingConnections: false,
                ask: false,
                allowlist: false,
                history: true,
                export: true,
                blockers: [.signingOrProfileMissing, .notYetImplemented]
            ),
            interfaces: [
                "en0": InterfaceCounters(
                    name: "en0",
                    kind: .physical,
                    counters: NetworkByteCounters(
                        bytes: DirectionalBytes(upload: 100, download: 200),
                        semantics: .cumulativeSinceEpoch,
                        epoch: CounterEpoch(rawValue: 0)
                    ),
                    asOf: base,
                    monotonicAsOf: MonotonicInstant(nanoseconds: 1_000)
                )
            ],
            apps: [appKey: makeApp(upload: 9_007_199_254_740_993, download: 0)],
            interfaceRates: [
                "en0": NetworkRate(uploadBytesPerSecond: 10, downloadBytesPerSecond: 20, asOf: base, window: .seconds(1))
            ]
        )
    }

    private func makeMinimalSnapshot(
        state: NetworkCollectionState = .stopped,
        appliedSequence: UInt64 = 0
    ) -> NetworkSnapshot {
        NetworkSnapshot(
            sessionID: CaptureSessionID(rawValue: "s-empty"),
            appliedSequence: appliedSequence,
            asOf: base,
            monotonicAsOf: MonotonicInstant(nanoseconds: 0),
            collectionState: state,
            coverage: NetworkCoverage(
                identity: .unavailable(reason: "off"),
                bytes: .unavailable(reason: "off"),
                targets: .unavailable(reason: "off"),
                protocols: .unavailable(reason: "off"),
                lostEventCount: 0,
                counterResetCount: 0,
                truncatedCollections: [],
                hasLiveSample: false
            ),
            capabilities: .unavailable,
            interfaces: [:],
            apps: [:],
            interfaceRates: [:]
        )
    }

    private func mutateJSON(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            file: file,
            line: line
        )
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func assertFailure(
        _ expected: NetworkSnapshotCodecFailure,
        _ data: Data,
        sizeLimit: Int = NetworkSnapshotJSONCodec.defaultSizeLimit,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try NetworkSnapshotJSONCodec.decode(data, sizeLimit: sizeLimit), file: file, line: line) { error in
            XCTAssertEqual(error as? NetworkSnapshotCodecFailure, expected, file: file, line: line)
        }
    }

    // MARK: - Round trip

    func testRoundTripPreservesAllFields() throws {
        let snapshot = makeFullSnapshot()
        let decoded = try NetworkSnapshotJSONCodec.decode(NetworkSnapshotJSONCodec.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }

    func testEmptySnapshotRoundTrips() throws {
        let snapshot = makeMinimalSnapshot()
        XCTAssertEqual(try NetworkSnapshotJSONCodec.decode(NetworkSnapshotJSONCodec.encode(snapshot)), snapshot)
    }

    func testDisconnectedStateRoundTrips() throws {
        let snapshot = makeMinimalSnapshot(state: .disconnected(since: base), appliedSequence: 9)
        let decoded = try NetworkSnapshotJSONCodec.decode(NetworkSnapshotJSONCodec.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.collectionState, .disconnected(since: base))
    }

    func testEncodingIsDeterministic() throws {
        let snapshot = makeFullSnapshot()
        XCTAssertEqual(
            try NetworkSnapshotJSONCodec.encode(snapshot),
            try NetworkSnapshotJSONCodec.encode(snapshot)
        )
    }

    // MARK: - UInt64 decimal-string contract

    func testCountersAboveDoublePrecisionStayExact() throws {
        // 2^53 + 1 is not representable as a Double; a JSON-number encoding
        // would silently truncate it, so the contract requires a string.
        let data = try NetworkSnapshotJSONCodec.encode(makeFullSnapshot())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"9007199254740993\""))
        let decoded = try NetworkSnapshotJSONCodec.decode(data)
        XCTAssertEqual(decoded.apps[appKey]?.counters.bytes.upload, 9_007_199_254_740_993)

        let maxed = makeMinimalSnapshot(appliedSequence: .max)
        let maxedData = try NetworkSnapshotJSONCodec.encode(maxed)
        XCTAssertTrue(String(decoding: maxedData, as: UTF8.self).contains("\"18446744073709551615\""))
        XCTAssertEqual(try NetworkSnapshotJSONCodec.decode(maxedData).appliedSequence, .max)
    }

    func testMeasuredZeroNeverDecodesAsUnknown() throws {
        var snapshot = makeFullSnapshot()
        snapshot = NetworkSnapshot(
            sessionID: snapshot.sessionID,
            appliedSequence: snapshot.appliedSequence,
            asOf: snapshot.asOf,
            monotonicAsOf: snapshot.monotonicAsOf,
            collectionState: snapshot.collectionState,
            coverage: snapshot.coverage,
            capabilities: snapshot.capabilities,
            interfaces: snapshot.interfaces,
            apps: [appKey: makeApp(upload: 0, download: nil, includeRate: false)],
            interfaceRates: snapshot.interfaceRates
        )
        let decoded = try NetworkSnapshotJSONCodec.decode(NetworkSnapshotJSONCodec.encode(snapshot))
        let app = try XCTUnwrap(decoded.apps[appKey])
        XCTAssertEqual(app.counters.bytes.upload, 0)
        XCTAssertNil(app.counters.bytes.download)
        XCTAssertNil(app.counters.bytes.total)
        XCTAssertNil(app.rate)
    }

    // MARK: - Forward compatibility

    func testUnknownKeysAreTolerated() throws {
        let snapshot = makeFullSnapshot()
        let mutated = try mutateJSON(NetworkSnapshotJSONCodec.encode(snapshot)) { object in
            object["futureTopLevel"] = "ignored"
            var coverage = object["coverage"] as? [String: Any] ?? [:]
            coverage["futureNested"] = 42
            object["coverage"] = coverage
        }
        XCTAssertEqual(try NetworkSnapshotJSONCodec.decode(mutated), snapshot)
    }

    // MARK: - Hard failures

    func testWrongSchemaIsRejected() throws {
        let data = try mutateJSON(NetworkSnapshotJSONCodec.encode(makeMinimalSnapshot())) { object in
            object["schema"] = "usagebutler.other"
        }
        assertFailure(.unsupportedSchema, data)
    }

    func testWrongVersionIsRejected() throws {
        let encoded = try NetworkSnapshotJSONCodec.encode(makeMinimalSnapshot())
        let v2 = try mutateJSON(encoded) { $0["version"] = 2 }
        assertFailure(.unsupportedVersion(2), v2)
        let v0 = try mutateJSON(encoded) { $0["version"] = 0 }
        assertFailure(.unsupportedVersion(0), v0)
    }

    func testCorruptPayloadsAreRejected() throws {
        assertFailure(.corrupt, Data("{ not json".utf8))
        // Valid JSON missing required fields is a decode failure, not a crash.
        assertFailure(.corrupt, Data("{\"schema\":\"usagebutler.network.snapshot\"}".utf8))
    }

    func testOversizedPayloadIsRejectedAtExactBoundary() throws {
        let data = try NetworkSnapshotJSONCodec.encode(makeMinimalSnapshot())
        assertFailure(.oversized(limit: data.count - 1), data, sizeLimit: data.count - 1)
        // Exact-size payloads still decode: the limit is inclusive.
        XCTAssertEqual(
            try NetworkSnapshotJSONCodec.decode(data, sizeLimit: data.count),
            makeMinimalSnapshot()
        )
    }

    func testUnknownEnumValuesAreRejected() throws {
        let encoded = try NetworkSnapshotJSONCodec.encode(makeFullSnapshot())
        let badState = try mutateJSON(encoded) { $0["collectionState"] = ["type": "teleporting"] }
        assertFailure(.invalidValue(field: "collectionState.type"), badState)

        let badBlocker = try mutateJSON(encoded) { object in
            var capabilities = object["capabilities"] as? [String: Any] ?? [:]
            capabilities["blockers"] = ["alien"]
            object["capabilities"] = capabilities
        }
        assertFailure(.invalidValue(field: "capabilities.blockers"), badBlocker)

        let badSemantics = try mutateJSON(encoded) { object in
            var apps = object["apps"] as? [String: Any] ?? [:]
            var app = apps[appKey] as? [String: Any] ?? [:]
            var counters = app["counters"] as? [String: Any] ?? [:]
            counters["semantics"] = "sometimes"
            app["counters"] = counters
            apps[appKey] = app
            object["apps"] = apps
        }
        assertFailure(.invalidValue(field: "counters.semantics"), badSemantics)
    }

    func testMalformedCounterStringsAreRejected() throws {
        let encoded = try NetworkSnapshotJSONCodec.encode(makeFullSnapshot())
        for bad in ["12x", "-5", "1.5"] {
            let mutated = try mutateJSON(encoded) { object in
                var apps = object["apps"] as? [String: Any] ?? [:]
                var app = apps[appKey] as? [String: Any] ?? [:]
                var counters = app["counters"] as? [String: Any] ?? [:]
                counters["upload"] = bad
                app["counters"] = counters
                apps[appKey] = app
                object["apps"] = apps
            }
            assertFailure(.invalidValue(field: "counters.upload"), mutated)
        }
    }

    func testNegativeAndNonFiniteRatesAreRejected() throws {
        let encoded = try NetworkSnapshotJSONCodec.encode(makeFullSnapshot())
        let negative = try mutateJSON(encoded) { object in
            var apps = object["apps"] as? [String: Any] ?? [:]
            var app = apps[appKey] as? [String: Any] ?? [:]
            var rate = app["rate"] as? [String: Any] ?? [:]
            rate["uploadBytesPerSecond"] = -1
            app["rate"] = rate
            apps[appKey] = app
            object["apps"] = apps
        }
        assertFailure(.invalidValue(field: "rate.bytesPerSecond"), negative)

        // JSONSerialization refuses to *write* non-finite Doubles, and its
        // parser rejects overflowing exponents outright — 1e999 never reaches
        // the value checks, failing closed as .corrupt.
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("\"uploadBytesPerSecond\":1.5"))
        let nonFinite = Data(text.replacingOccurrences(
            of: "\"uploadBytesPerSecond\":1.5",
            with: "\"uploadBytesPerSecond\":1e999"
        ).utf8)
        assertFailure(.corrupt, nonFinite)
    }

    func testNonPositiveRateWindowIsRejected() throws {
        let encoded = try NetworkSnapshotJSONCodec.encode(makeFullSnapshot())
        for bad in ["0", "-100"] {
            let mutated = try mutateJSON(encoded) { object in
                var apps = object["apps"] as? [String: Any] ?? [:]
                var app = apps[appKey] as? [String: Any] ?? [:]
                var rate = app["rate"] as? [String: Any] ?? [:]
                rate["windowNanoseconds"] = bad
                app["rate"] = rate
                apps[appKey] = app
                object["apps"] = apps
            }
            assertFailure(.invalidValue(field: "rate.windowNanoseconds"), mutated)
        }
    }

    func testPartialStateWithoutReasonIsRejected() throws {
        let encoded = try NetworkSnapshotJSONCodec.encode(makeFullSnapshot())
        let mutated = try mutateJSON(encoded) { $0["collectionState"] = ["type": "partial"] }
        assertFailure(.invalidValue(field: "collectionState.reason"), mutated)
    }
}
