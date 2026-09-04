import Foundation

public enum MemoryHistoryStoreFailure: Error, Equatable, Sendable {
    case invalidInput
    case unsafeBaseDirectory
    case unsafeDirectoryEntry
    case unsafeDirectoryMode
    case symbolicLink
    case nonRegularFile
    case unsafeFileMode
    case oversized
    case corrupt
    case unsupportedSchema
    case unsupportedVersion
    case io
    case shutdown
}

public enum MemoryHistoryStoreLoadResult: Equatable, Sendable {
    case hit([MemoryHistoryPoint])
    case miss
    case failure(MemoryHistoryStoreFailure)
}

public enum MemoryHistoryStoreWriteResult: Equatable, Sendable {
    case success(persistedPointCount: Int)
    case failure(MemoryHistoryStoreFailure)
}

public protocol MemoryHistoryStore: Actor {
    func load(
        referenceTimestamp: Date
    ) async -> MemoryHistoryStoreLoadResult

    func save(
        _ points: [MemoryHistoryPoint],
        referenceTimestamp: Date
    ) async -> MemoryHistoryStoreWriteResult

    func shutdown() async
}
