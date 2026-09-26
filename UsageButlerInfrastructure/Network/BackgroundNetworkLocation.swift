import Darwin
import Foundation

public enum BackgroundNetworkLocation {
    public static let plistName = "io.github.obisoldbee.UsageButler.network-agent.plist"
    public static func directory(bundle: Bundle) throws -> URL {
        guard let identifier = bundle.bundleIdentifier, identifier.count <= 160,
              identifier.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }) else {
            throw NetworkHistoryError.unsafePath
        }
        #if DEBUG
        if identifier.hasPrefix("io.github.obisoldbee.UsageButler.Validation.") {
            // Foundation keeps the /tmp alias even after resolving symlinks.
            // Canonicalize only the signed bundle's parent with realpath; the
            // data directory itself still undergoes the store's no-link checks.
            guard let parent = realpath(bundle.bundleURL.deletingLastPathComponent().path, nil) else {
                throw NetworkHistoryError.unsafePath
            }
            defer { free(parent) }
            return URL(fileURLWithPath: String(cString: parent), isDirectory: true)
                .appendingPathComponent("HistoryValidationData", isDirectory: true)
        }
        #endif
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("NetworkHistory", isDirectory: true)
    }
    public static func serviceName(bundle: Bundle) throws -> String {
        guard let value = bundle.object(forInfoDictionaryKey: "UsageButlerAgentServiceName") as? String,
              value.hasPrefix(bundle.bundleIdentifier ?? "!invalid"), value.count <= 180,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }) else {
            throw NetworkHistoryError.invalidRequest
        }
        return value
    }
}
