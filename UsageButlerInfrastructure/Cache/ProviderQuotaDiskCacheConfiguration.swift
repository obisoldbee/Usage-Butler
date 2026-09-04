import Foundation

public enum ProviderQuotaDiskCacheConfigurationError: Error, Equatable, Sendable {
    case applicationSupportDirectoryMustBeAbsoluteFileURL
    case invalidRelativeDirectoryComponent
    case relativeDirectoryMustEndInVersionComponent
    case invalidMaximumFileBytes
}

/// The composition root supplies both the Application Support base and the versioned
/// relative directory. The cache never discovers or persists a user-home path itself.
public struct ProviderQuotaDiskCacheConfiguration: Equatable, Sendable {
    public static let hardMaximumFileBytes = 1_048_576

    public let applicationSupportDirectory: URL
    public let versionedRelativeDirectory: [String]
    public let maximumFileBytes: Int

    public init(
        applicationSupportDirectory: URL,
        versionedRelativeDirectory: [String],
        maximumFileBytes: Int = ProviderQuotaDiskCacheConfiguration.hardMaximumFileBytes
    ) throws {
        guard applicationSupportDirectory.isFileURL,
              applicationSupportDirectory.path.hasPrefix("/") else {
            throw ProviderQuotaDiskCacheConfigurationError
                .applicationSupportDirectoryMustBeAbsoluteFileURL
        }
        guard !versionedRelativeDirectory.isEmpty,
              versionedRelativeDirectory.allSatisfy(Self.isSafeRelativeComponent) else {
            throw ProviderQuotaDiskCacheConfigurationError.invalidRelativeDirectoryComponent
        }
        guard Self.isVersionComponent(versionedRelativeDirectory.last!) else {
            throw ProviderQuotaDiskCacheConfigurationError
                .relativeDirectoryMustEndInVersionComponent
        }
        guard (1...Self.hardMaximumFileBytes).contains(maximumFileBytes) else {
            throw ProviderQuotaDiskCacheConfigurationError.invalidMaximumFileBytes
        }

        self.applicationSupportDirectory = applicationSupportDirectory
        self.versionedRelativeDirectory = versionedRelativeDirectory
        self.maximumFileBytes = maximumFileBytes
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
