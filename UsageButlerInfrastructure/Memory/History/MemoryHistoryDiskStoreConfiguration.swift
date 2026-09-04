import Foundation
import UsageButlerCore

public enum MemoryHistoryDiskStoreConfigurationError: Error, Equatable, Sendable {
    case applicationSupportDirectoryMustBeAbsoluteFileURL
    case invalidRelativeDirectoryComponent
    case relativeDirectoryMustEndInVersionComponent
    case invalidMaximumFileBytes
    case invalidRetention
}

/// The composition root supplies an existing base directory and a versioned,
/// relative location. The path itself is never part of the persisted payload.
public struct MemoryHistoryDiskStoreConfiguration: Equatable, Sendable {
    public static let hardMaximumFileBytes = 1_048_576
    public static let hardMaximumRetention = MemorySampleHistory.twoHourRetention

    public let applicationSupportDirectory: URL
    public let versionedRelativeDirectory: [String]
    public let maximumFileBytes: Int
    public let retention: TimeInterval

    public init(
        applicationSupportDirectory: URL,
        versionedRelativeDirectory: [String],
        maximumFileBytes: Int = MemoryHistoryDiskStoreConfiguration
            .hardMaximumFileBytes,
        retention: TimeInterval = MemoryHistoryDiskStoreConfiguration
            .hardMaximumRetention
    ) throws {
        guard applicationSupportDirectory.isFileURL,
              applicationSupportDirectory.path.hasPrefix("/") else {
            throw MemoryHistoryDiskStoreConfigurationError
                .applicationSupportDirectoryMustBeAbsoluteFileURL
        }
        guard !versionedRelativeDirectory.isEmpty,
              versionedRelativeDirectory.allSatisfy(Self.isSafeRelativeComponent) else {
            throw MemoryHistoryDiskStoreConfigurationError
                .invalidRelativeDirectoryComponent
        }
        guard Self.isVersionComponent(versionedRelativeDirectory.last!) else {
            throw MemoryHistoryDiskStoreConfigurationError
                .relativeDirectoryMustEndInVersionComponent
        }
        guard (1...Self.hardMaximumFileBytes).contains(maximumFileBytes) else {
            throw MemoryHistoryDiskStoreConfigurationError.invalidMaximumFileBytes
        }
        guard retention.isFinite,
              retention > 0,
              retention <= Self.hardMaximumRetention else {
            throw MemoryHistoryDiskStoreConfigurationError.invalidRetention
        }

        self.applicationSupportDirectory = applicationSupportDirectory
        self.versionedRelativeDirectory = versionedRelativeDirectory
        self.maximumFileBytes = maximumFileBytes
        self.retention = retention
    }

    private static func isSafeRelativeComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.contains("\0")
    }

    private static func isVersionComponent(_ component: String) -> Bool {
        guard component.first == "v", component.count > 1 else { return false }
        return component.dropFirst().allSatisfy(\.isNumber)
    }
}
