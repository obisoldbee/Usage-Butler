import Darwin
import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain
@testable import UsageButlerInfrastructure

final class MemoryHistoryDiskStoreTests: XCTestCase {
    private let referenceTimestamp = Date(timeIntervalSince1970: 1_786_400_000)
    private let components = ["UsageButlerTests", "MemoryHistory", "v1"]

    func testRoundTripPersistsOnlyMinimalSchemaAndValidTwoHourWindow() async throws {
        let support = try TemporaryMemoryHistorySupport()
        let store = try makeStore(in: support)
        let boundary = point(
            offset: -MemorySampleHistory.twoHourRetention,
            ratio: nil,
            pressure: .unknown
        )
        let replaced = point(offset: -3_600, ratio: 0.4, pressure: .warning)
        let replacement = point(offset: -3_600, ratio: 0.6, pressure: .critical)
        let latest = point(
            offset: 0,
            ratio: 0.9,
            pressureRatio: 0.35,
            pressure: .normal
        )

        let result = await store.save(
            [
                point(offset: -7_200.001, ratio: 0.1),
                latest,
                boundary,
                replaced,
                replacement,
                point(offset: 1, ratio: 1)
            ],
            referenceTimestamp: referenceTimestamp
        )
        XCTAssertEqual(result, .success(persistedPointCount: 3))

        let loaded = try unwrapHit(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(loaded, [boundary, replacement, latest])

        let file = historyFile(in: support)
        let data = try Data(contentsOf: file)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["schema", "version", "points"])
        XCTAssertEqual(
            object["schema"] as? String,
            MemoryHistoryEnvelopeDTO.schemaIdentifier
        )
        XCTAssertEqual(
            object["version"] as? Int,
            MemoryHistoryEnvelopeDTO.formatVersion
        )
        let persisted = try XCTUnwrap(object["points"] as? [[String: Any]])
        XCTAssertEqual(persisted.count, 3)
        for persistedPoint in persisted {
            XCTAssertTrue(Set(persistedPoint.keys).isSubset(of: [
                "timestamp", "ratio", "pressureRatio", "pressure"
            ]))
            XCTAssertNotNil(persistedPoint["timestamp"])
            XCTAssertNotNil(persistedPoint["pressure"])
        }
        XCTAssertEqual(persisted.filter { $0["ratio"] == nil }.count, 1)
        XCTAssertEqual(
            persisted.compactMap { $0["pressureRatio"] as? Double },
            [0.35]
        )

        let contents = String(decoding: data, as: UTF8.self)
        for forbidden in [
            "providerID", "identity", "account", "path", "/Users/",
            "diagnostic", "failure", "executable"
        ] {
            XCTAssertFalse(contents.contains(forbidden))
        }
    }

    func testVersionOneHistoryLoadsWithoutManufacturingPressureRatio() async throws {
        let support = try TemporaryMemoryHistorySupport()
        let store = try makeStore(in: support)
        let file = historyFile(in: support)
        _ = await store.load(referenceTimestamp: referenceTimestamp)

        let legacy = Data("""
        {"schema":"usage-butler.memory-history","version":1,"points":[{"timestamp":1786400000,"ratio":0.9,"pressure":"normal"}]}
        """.utf8)
        try writeRaw(legacy, to: file)

        let loaded = try unwrapHit(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].estimatedUsedRatio, 0.9)
        XCTAssertNil(loaded[0].pressureRatio)
    }

    func testStartupLoadReturnsOnlyTheReferenceTimeWindow() async throws {
        let support = try TemporaryMemoryHistorySupport()
        let store = try makeStore(in: support)
        let savedReference = referenceTimestamp.addingTimeInterval(3_600)
        let persisted = [
            point(offset: -3_600, ratio: 0.1),
            point(offset: 0, ratio: 0.2),
            point(offset: 1_800, ratio: nil, pressure: .warning),
            point(offset: 3_600, ratio: 0.4, pressure: .critical)
        ]
        let result = await store.save(
            persisted,
            referenceTimestamp: savedReference
        )
        XCTAssertEqual(result, .success(persistedPointCount: 4))

        var loaded = try unwrapHit(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(loaded, Array(persisted.prefix(2)))

        loaded = try unwrapHit(
            await store.load(
                referenceTimestamp: referenceTimestamp.addingTimeInterval(5_000)
            )
        )
        XCTAssertEqual(loaded, Array(persisted.dropFirst()))
    }

    func testMissCreatesPrivateDirectoriesAndSaveCreatesPrivateFile() async throws {
        let support = try TemporaryMemoryHistorySupport()
        let store = try makeStore(in: support)

        let loadResult = await store.load(referenceTimestamp: referenceTimestamp)
        XCTAssertEqual(loadResult, .miss)

        var current = support.root
        for component in components {
            current.appendPathComponent(component, isDirectory: true)
            XCTAssertEqual(try permissions(of: current), mode_t(0o700))
        }

        let saveResult = await store.save(
            [point(offset: 0, ratio: 0.5)],
            referenceTimestamp: referenceTimestamp
        )
        XCTAssertEqual(saveResult, .success(persistedPointCount: 1))
        XCTAssertEqual(try permissions(of: historyFile(in: support)), mode_t(0o600))
    }

    func testCorruptUnknownSchemaUnknownVersionAndExtraFieldsAreTyped() async throws {
        let support = try TemporaryMemoryHistorySupport()
        let store = try makeStore(in: support)
        let file = historyFile(in: support)
        _ = await store.load(referenceTimestamp: referenceTimestamp)

        try writeRaw(Data("{".utf8), to: file)
        var failure = try unwrapFailure(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(failure, .corrupt)

        _ = await store.save(
            [point(offset: 0, ratio: 0.5)],
            referenceTimestamp: referenceTimestamp
        )
        try mutateEnvelope(at: file, key: "schema", value: "future.history")
        failure = try unwrapFailure(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(failure, .unsupportedSchema)

        _ = await store.save(
            [point(offset: 0, ratio: 0.5)],
            referenceTimestamp: referenceTimestamp
        )
        try mutateEnvelope(at: file, key: "version", value: 99)
        failure = try unwrapFailure(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(failure, .unsupportedVersion)

        _ = await store.save(
            [point(offset: 0, ratio: 0.5)],
            referenceTimestamp: referenceTimestamp
        )
        try mutateEnvelope(at: file, key: "diagnostic", value: "must-not-load")
        failure = try unwrapFailure(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(failure, .corrupt)

        _ = await store.save(
            [point(offset: 0, ratio: 0.5)],
            referenceTimestamp: referenceTimestamp
        )
        try mutateFirstPoint(at: file, key: "identity", value: "must-not-load")
        failure = try unwrapFailure(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(failure, .corrupt)
    }

    func testInvalidPointValuesAndOversizedFileAreTyped() async throws {
        let support = try TemporaryMemoryHistorySupport()
        let store = try makeStore(in: support, maximumFileBytes: 1_024)
        let file = historyFile(in: support)

        _ = await store.save(
            [point(offset: 0, ratio: 0.5)],
            referenceTimestamp: referenceTimestamp
        )
        try mutateFirstPoint(at: file, key: "ratio", value: 1.1)
        var failure = try unwrapFailure(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(failure, .corrupt)

        _ = await store.save(
            [point(offset: 0, ratio: 0.5)],
            referenceTimestamp: referenceTimestamp
        )
        try mutateFirstPoint(at: file, key: "pressure", value: "red")
        failure = try unwrapFailure(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(failure, .corrupt)

        try writeRaw(Data(repeating: 0x41, count: 1_025), to: file)
        failure = try unwrapFailure(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(failure, .oversized)
    }

    func testSymlinkAndFIFOAreDistinctFailuresWithoutFollowingOrBlocking() async throws {
        let support = try TemporaryMemoryHistorySupport()
        let store = try makeStore(in: support)
        let file = historyFile(in: support)
        _ = await store.load(referenceTimestamp: referenceTimestamp)

        let external = support.root.appendingPathComponent(
            "outside.json",
            isDirectory: false
        )
        let sentinel = Data("outside-sentinel".utf8)
        try writeRaw(sentinel, to: external)
        try FileManager.default.createSymbolicLink(
            at: file,
            withDestinationURL: external
        )

        var loadFailure = try unwrapFailure(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(loadFailure, .symbolicLink)
        var writeFailure = try unwrapFailure(
            await store.save(
                [point(offset: 0, ratio: 0.5)],
                referenceTimestamp: referenceTimestamp
            )
        )
        XCTAssertEqual(writeFailure, .symbolicLink)
        XCTAssertEqual(try Data(contentsOf: external), sentinel)

        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(
            file.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) },
            0
        )
        loadFailure = try unwrapFailure(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(loadFailure, .nonRegularFile)
        writeFailure = try unwrapFailure(
            await store.save(
                [point(offset: 0, ratio: 0.5)],
                referenceTimestamp: referenceTimestamp
            )
        )
        XCTAssertEqual(writeFailure, .nonRegularFile)
    }

    func testUnsafeFileAndDirectoryModesAreTyped() async throws {
        let support = try TemporaryMemoryHistorySupport()
        let store = try makeStore(in: support)
        _ = await store.save(
            [point(offset: 0, ratio: 0.5)],
            referenceTimestamp: referenceTimestamp
        )
        let file = historyFile(in: support)

        XCTAssertEqual(Darwin.chmod(file.path, mode_t(0o644)), 0)
        var failure = try unwrapFailure(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(failure, .unsafeFileMode)
        let writeFailure = try unwrapFailure(
            await store.save(
                [point(offset: 0, ratio: 0.6)],
                referenceTimestamp: referenceTimestamp
            )
        )
        XCTAssertEqual(writeFailure, .unsafeFileMode)

        XCTAssertEqual(Darwin.chmod(file.path, mode_t(0o600)), 0)
        XCTAssertEqual(Darwin.chmod(historyDirectory(in: support).path, mode_t(0o755)), 0)
        failure = try unwrapFailure(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(failure, .unsafeDirectoryMode)
    }

    func testBaseAndIntermediateDirectorySymlinksAreRejected() async throws {
        let support = try TemporaryMemoryHistorySupport()
        let target = support.root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: mode_t(0o700)]
        )
        let baseLink = support.root.appendingPathComponent("base-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: baseLink,
            withDestinationURL: target
        )
        let baseLinkConfiguration = try MemoryHistoryDiskStoreConfiguration(
            applicationSupportDirectory: baseLink,
            versionedRelativeDirectory: components
        )
        let baseLinkStore = MemoryHistoryDiskStore(
            configuration: baseLinkConfiguration
        )
        var failure = try unwrapFailure(
            await baseLinkStore.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(failure, .unsafeBaseDirectory)

        let intermediateTarget = support.root.appendingPathComponent(
            "intermediate-target",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: intermediateTarget,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: mode_t(0o700)]
        )
        let firstComponent = support.root.appendingPathComponent(
            components[0],
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: firstComponent,
            withDestinationURL: intermediateTarget
        )
        let intermediateStore = try makeStore(in: support)
        failure = try unwrapFailure(
            await intermediateStore.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(failure, .unsafeDirectoryEntry)
    }

    func testAtomicReplacementChangesInodeAndLeavesNoTemporaryEntries() async throws {
        let support = try TemporaryMemoryHistorySupport()
        let store = try makeStore(in: support)
        let file = historyFile(in: support)

        var result = await store.save(
            [point(offset: 0, ratio: 0.2)],
            referenceTimestamp: referenceTimestamp
        )
        XCTAssertEqual(result, .success(persistedPointCount: 1))
        let firstInode = try inode(of: file)

        result = await store.save(
            [point(offset: 0, ratio: 0.8, pressure: .critical)],
            referenceTimestamp: referenceTimestamp
        )
        XCTAssertEqual(result, .success(persistedPointCount: 1))
        let secondInode = try inode(of: file)

        XCTAssertNotEqual(firstInode, secondInode)
        let loaded = try unwrapHit(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(loaded, [
            point(offset: 0, ratio: 0.8, pressure: .critical)
        ])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: historyDirectory(in: support).path
            ),
            [MemoryHistoryDiskStore.fileName]
        )
    }

    func testOversizedSavePreservesPriorEntryAndLeavesNoTemporaryEntries() async throws {
        let support = try TemporaryMemoryHistorySupport()
        let store = try makeStore(in: support, maximumFileBytes: 1_024)
        let original = [point(offset: 0, ratio: 0.25)]
        var result = await store.save(
            original,
            referenceTimestamp: referenceTimestamp
        )
        XCTAssertEqual(result, .success(persistedPointCount: 1))

        let oversized = (0..<100).map { index in
            point(offset: -Double(index), ratio: Double(index) / 100)
        }
        result = await store.save(
            oversized,
            referenceTimestamp: referenceTimestamp
        )
        XCTAssertEqual(result, .failure(.oversized))
        let loaded = try unwrapHit(
            await store.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: historyDirectory(in: support).path
            ),
            [MemoryHistoryDiskStore.fileName]
        )
    }

    func testShutdownIsIdempotentAndPermanentlySealsLoadAndSave() async throws {
        let support = try TemporaryMemoryHistorySupport()
        let store = try makeStore(in: support)
        let original = [point(offset: 0, ratio: 0.25)]
        _ = await store.save(
            original,
            referenceTimestamp: referenceTimestamp
        )

        await store.shutdown()
        await store.shutdown()

        let loadResult = await store.load(referenceTimestamp: referenceTimestamp)
        XCTAssertEqual(loadResult, .failure(.shutdown))
        let writeResult = await store.save(
            [point(offset: 0, ratio: 0.75)],
            referenceTimestamp: referenceTimestamp
        )
        XCTAssertEqual(writeResult, .failure(.shutdown))

        let replacement = try makeStore(in: support)
        let loaded = try unwrapHit(
            await replacement.load(referenceTimestamp: referenceTimestamp)
        )
        XCTAssertEqual(loaded, original)
    }

    func testConfigurationRejectsUnsafeUnversionedOversizedAndOverlongValues() throws {
        let support = try TemporaryMemoryHistorySupport()

        XCTAssertThrowsError(
            try MemoryHistoryDiskStoreConfiguration(
                applicationSupportDirectory: URL(string: "https://example.test")!,
                versionedRelativeDirectory: components
            )
        )
        XCTAssertThrowsError(
            try MemoryHistoryDiskStoreConfiguration(
                applicationSupportDirectory: support.root,
                versionedRelativeDirectory: ["UsageButler", "../escape", "v1"]
            )
        )
        XCTAssertThrowsError(
            try MemoryHistoryDiskStoreConfiguration(
                applicationSupportDirectory: support.root,
                versionedRelativeDirectory: ["UsageButler", "history"]
            )
        )
        XCTAssertThrowsError(
            try MemoryHistoryDiskStoreConfiguration(
                applicationSupportDirectory: support.root,
                versionedRelativeDirectory: ["UsageButler", "v1"],
                maximumFileBytes: MemoryHistoryDiskStoreConfiguration
                    .hardMaximumFileBytes + 1
            )
        )
        XCTAssertThrowsError(
            try MemoryHistoryDiskStoreConfiguration(
                applicationSupportDirectory: support.root,
                versionedRelativeDirectory: ["UsageButler", "v1"],
                retention: MemorySampleHistory.twoHourRetention + 1
            )
        )
    }

    func testInvalidReferenceTimestampReturnsTypedFailureWithoutWriting() async throws {
        let support = try TemporaryMemoryHistorySupport()
        let store = try makeStore(in: support)
        let invalid = Date(timeIntervalSince1970: .nan)

        let loadResult = await store.load(referenceTimestamp: invalid)
        XCTAssertEqual(loadResult, .failure(.invalidInput))
        let writeResult = await store.save(
            [point(offset: 0, ratio: 0.5)],
            referenceTimestamp: invalid
        )
        XCTAssertEqual(writeResult, .failure(.invalidInput))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: historyDirectory(in: support).path
        ))
    }

    private func makeStore(
        in support: TemporaryMemoryHistorySupport,
        maximumFileBytes: Int = MemoryHistoryDiskStoreConfiguration
            .hardMaximumFileBytes
    ) throws -> MemoryHistoryDiskStore {
        let configuration = try MemoryHistoryDiskStoreConfiguration(
            applicationSupportDirectory: support.root,
            versionedRelativeDirectory: components,
            maximumFileBytes: maximumFileBytes
        )
        return MemoryHistoryDiskStore(configuration: configuration)
    }

    private func point(
        offset: TimeInterval,
        ratio: Double?,
        pressureRatio: Double? = nil,
        pressure: MemoryPressureState = .normal
    ) -> MemoryHistoryPoint {
        MemoryHistoryPoint(
            timestamp: referenceTimestamp.addingTimeInterval(offset),
            estimatedUsedRatio: ratio,
            pressureRatio: pressureRatio,
            pressure: pressure
        )
    }

    private func historyDirectory(in support: TemporaryMemoryHistorySupport) -> URL {
        components.reduce(support.root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    private func historyFile(in support: TemporaryMemoryHistorySupport) -> URL {
        historyDirectory(in: support).appendingPathComponent(
            MemoryHistoryDiskStore.fileName,
            isDirectory: false
        )
    }

    private func unwrapHit(
        _ result: MemoryHistoryStoreLoadResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [MemoryHistoryPoint] {
        guard case let .hit(points) = result else {
            XCTFail("Expected history hit, got \(result)", file: file, line: line)
            throw MemoryHistoryTestFailure.unexpectedResult
        }
        return points
    }

    private func unwrapFailure(
        _ result: MemoryHistoryStoreLoadResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> MemoryHistoryStoreFailure {
        guard case let .failure(failure) = result else {
            XCTFail("Expected history failure, got \(result)", file: file, line: line)
            throw MemoryHistoryTestFailure.unexpectedResult
        }
        return failure
    }

    private func unwrapFailure(
        _ result: MemoryHistoryStoreWriteResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> MemoryHistoryStoreFailure {
        guard case let .failure(failure) = result else {
            XCTFail("Expected history failure, got \(result)", file: file, line: line)
            throw MemoryHistoryTestFailure.unexpectedResult
        }
        return failure
    }

    private func writeRaw(_ data: Data, to file: URL) throws {
        try data.write(to: file)
        guard Darwin.chmod(file.path, mode_t(0o600)) == 0 else {
            throw MemoryHistoryPOSIXFailure(errorNumber: errno)
        }
    }

    private func mutateEnvelope(at file: URL, key: String, value: Any) throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: file)
            ) as? [String: Any]
        )
        object[key] = value
        try writeRaw(
            try JSONSerialization.data(withJSONObject: object),
            to: file
        )
    }

    private func mutateFirstPoint(at file: URL, key: String, value: Any) throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: file)
            ) as? [String: Any]
        )
        var points = try XCTUnwrap(object["points"] as? [[String: Any]])
        var first = try XCTUnwrap(points.first)
        first[key] = value
        points[0] = first
        object["points"] = points
        try writeRaw(
            try JSONSerialization.data(withJSONObject: object),
            to: file
        )
    }

    private func permissions(of url: URL) throws -> mode_t {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw MemoryHistoryPOSIXFailure(errorNumber: errno)
        }
        return status.st_mode & mode_t(0o7777)
    }

    private func inode(of url: URL) throws -> ino_t {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw MemoryHistoryPOSIXFailure(errorNumber: errno)
        }
        return status.st_ino
    }
}

private final class TemporaryMemoryHistorySupport: @unchecked Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-butler-memory-history-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: mode_t(0o700)]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum MemoryHistoryTestFailure: Error {
    case unexpectedResult
}

private struct MemoryHistoryPOSIXFailure: Error {
    let errorNumber: Int32
}
