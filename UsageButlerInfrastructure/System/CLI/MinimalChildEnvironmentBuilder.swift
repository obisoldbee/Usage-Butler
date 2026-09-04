import Foundation

public struct CLILocaleEnvironment: Equatable, Sendable {
    public let lang: String?
    public let lcAll: String?
    public let lcCType: String?

    public init(lang: String?, lcAll: String?, lcCType: String?) {
        self.lang = lang
        self.lcAll = lcAll
        self.lcCType = lcCType
    }

    public static let utf8 = CLILocaleEnvironment(
        lang: "en_US.UTF-8",
        lcAll: nil,
        lcCType: "UTF-8"
    )
}

/// A child environment whose ordinary textual representations expose keys, never values.
public struct MinimalChildEnvironment: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    private let storage: [String: String]

    init(storage: [String: String]) {
        self.storage = storage
    }

    /// The explicit handoff to `Process.environment` / `ChildProcessRequest.environment`.
    public var variables: [String: String] { storage }

    public var description: String {
        let keys = storage.keys.sorted().joined(separator: ",")
        return "MinimalChildEnvironment(keys: [\(keys)])"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["keys": storage.keys.sorted()])
    }
}

public enum MinimalChildEnvironmentError: Error, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    case homeDirectoryMustBeAbsoluteLocalFileURL
    case invalidLocaleValue
    case proxyEnvironmentNotAllowlisted
    case invalidProxyValue

    public var diagnosticCode: String {
        switch self {
        case .homeDirectoryMustBeAbsoluteLocalFileURL:
            "cli.environment.home.absolute_local_file_url_required"
        case .invalidLocaleValue:
            "cli.environment.locale.invalid"
        case .proxyEnvironmentNotAllowlisted:
            "cli.environment.proxy.not_allowlisted"
        case .invalidProxyValue:
            "cli.environment.proxy.invalid_value"
        }
    }

    public var description: String { diagnosticCode }
    public var debugDescription: String { diagnosticCode }
}

/// Builds a complete replacement child environment. It never reads or merges the parent process
/// environment. Proxy variables appear only when the caller passes the exact allowlisted key.
public struct MinimalChildEnvironmentBuilder: Sendable {
    public static let allowedProxyKeys: Set<String> = [
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "no_proxy"
    ]

    public init() {}

    public func build(
        pathEntries: [String],
        homeDirectoryURL: URL?,
        locale: CLILocaleEnvironment = .utf8,
        explicitProxyEnvironment: [String: String] = [:]
    ) throws -> MinimalChildEnvironment {
        var environment: [String: String] = [:]

        let normalizedPath = CLIPathEntryPolicy.normalizedAbsoluteDirectories(pathEntries)
        if !normalizedPath.isEmpty {
            environment["PATH"] = normalizedPath.joined(separator: ":")
        }

        if let homeDirectoryURL {
            guard CLIFileURLPolicy.isAbsoluteLocalFileURL(homeDirectoryURL) else {
                throw MinimalChildEnvironmentError.homeDirectoryMustBeAbsoluteLocalFileURL
            }
            environment["HOME"] = homeDirectoryURL.standardizedFileURL.path
        }

        let localeValues: [(String, String?)] = [
            ("LANG", locale.lang),
            ("LC_ALL", locale.lcAll),
            ("LC_CTYPE", locale.lcCType)
        ]
        for (key, value) in localeValues {
            guard let value else { continue }
            guard !value.utf8.contains(0) else {
                throw MinimalChildEnvironmentError.invalidLocaleValue
            }
            environment[key] = value
        }

        guard explicitProxyEnvironment.keys.allSatisfy({ key in
            Self.allowedProxyKeys.contains(key)
                && !key.contains("=")
                && !key.utf8.contains(0)
        }) else {
            throw MinimalChildEnvironmentError.proxyEnvironmentNotAllowlisted
        }
        guard explicitProxyEnvironment.values.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw MinimalChildEnvironmentError.invalidProxyValue
        }
        for (key, value) in explicitProxyEnvironment {
            environment[key] = value
        }

        return MinimalChildEnvironment(storage: environment)
    }
}
