import Darwin
import Foundation

public enum CLIExecutableFileEntryState: Equatable, Sendable {
    case missing
    case regularFile
    case nonRegularFile
    case inaccessible
}

/// Metadata-only inspection result for one executable candidate.
///
/// A symlink is permitted as an input selector, but `resolvedFileURL` must identify its
/// standardized target. The locator accepts the result only when that target is a regular file
/// and is executable by the current process. No candidate contents are read.
public struct CLIExecutableFileInspection: Equatable, Sendable {
    public let resolvedFileURL: URL
    public let entryState: CLIExecutableFileEntryState
    public let isExecutable: Bool

    public init(
        resolvedFileURL: URL,
        entryState: CLIExecutableFileEntryState,
        isExecutable: Bool
    ) {
        self.resolvedFileURL = resolvedFileURL
        self.entryState = entryState
        self.isExecutable = isExecutable
    }
}

public protocol CLIExecutableFileSystemChecking: Sendable {
    func inspectExecutableCandidate(at candidateURL: URL) -> CLIExecutableFileInspection
}

/// The production metadata checker. It standardizes and resolves symlinks before checking the
/// resolved target's file type and executable permission. It never opens or reads file contents.
public struct FoundationCLIExecutableFileSystem: CLIExecutableFileSystemChecking {
    public init() {}

    public func inspectExecutableCandidate(at candidateURL: URL) -> CLIExecutableFileInspection {
        let localCandidate = URL(
            fileURLWithPath: candidateURL.path,
            isDirectory: false
        ).standardizedFileURL
        let resolvedURL = localCandidate.resolvingSymlinksInPath().standardizedFileURL

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return CLIExecutableFileInspection(
                    resolvedFileURL: resolvedURL,
                    entryState: .nonRegularFile,
                    isExecutable: false
                )
            }
            return CLIExecutableFileInspection(
                resolvedFileURL: resolvedURL,
                entryState: .regularFile,
                isExecutable: FileManager.default.isExecutableFile(atPath: resolvedURL.path)
            )
        } catch {
            return CLIExecutableFileInspection(
                resolvedFileURL: resolvedURL,
                entryState: Self.isMissing(error) ? .missing : .inaccessible,
                isExecutable: false
            )
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(ENOENT) || nsError.code == Int(ENOTDIR)
        }
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError
                || nsError.code == NSFileReadNoSuchFileError
        }
        return false
    }
}

public enum CLIExecutableLocationSource: Equatable, Sendable {
    case explicitUserSelection
    case searchPath
}

/// A resolved executable identity suitable for a shell-free `Process.executableURL`.
///
/// `description` deliberately omits the path so ordinary diagnostics cannot accidentally expose
/// a user-selected home path. Callers use `resolvedFileURL` only at the execution boundary.
public struct ResolvedCLIExecutable: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let resolvedFileURL: URL
    public let source: CLIExecutableLocationSource

    init(resolvedFileURL: URL, source: CLIExecutableLocationSource) {
        self.resolvedFileURL = resolvedFileURL
        self.source = source
    }

    public var description: String {
        "ResolvedCLIExecutable(source: \(source))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["source": source])
    }
}

public enum CLIExecutableCandidateRejection: Error, Equatable, Sendable {
    case absoluteLocalFileURLRequired
    case missing
    case notRegularFile
    case notExecutable
    case inaccessible
    case invalidResolvedFileURL

    public var diagnosticCode: String {
        switch self {
        case .absoluteLocalFileURLRequired:
            "cli.locator.override.absolute_local_file_url_required"
        case .missing:
            "cli.locator.override.missing"
        case .notRegularFile:
            "cli.locator.override.not_regular_file"
        case .notExecutable:
            "cli.locator.override.not_executable"
        case .inaccessible:
            "cli.locator.override.inaccessible"
        case .invalidResolvedFileURL:
            "cli.locator.override.invalid_resolved_file_url"
        }
    }
}

public enum CLIExecutableLocatorError: Error, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    case invalidExecutableName
    case explicitOverrideRejected(CLIExecutableCandidateRejection)
    case executableNotFound

    public var diagnosticCode: String {
        switch self {
        case .invalidExecutableName:
            "cli.locator.executable_name.invalid"
        case let .explicitOverrideRejected(rejection):
            rejection.diagnosticCode
        case .executableNotFound:
            "cli.locator.executable_not_found"
        }
    }

    public var description: String { diagnosticCode }
    public var debugDescription: String { diagnosticCode }
}

/// Resolves a provider CLI without invoking a shell, `which`, the CLI itself, or any network API.
public struct CLIExecutableLocator: Sendable {
    private let fileSystem: any CLIExecutableFileSystemChecking

    public init(
        fileSystem: any CLIExecutableFileSystemChecking = FoundationCLIExecutableFileSystem()
    ) {
        self.fileSystem = fileSystem
    }

    public func locate(
        executableName: String,
        explicitUserFileURL: URL? = nil,
        pathEntries: [String]
    ) throws -> ResolvedCLIExecutable {
        guard CLIPathEntryPolicy.isValidExecutableName(executableName) else {
            throw CLIExecutableLocatorError.invalidExecutableName
        }

        if let explicitUserFileURL {
            guard CLIFileURLPolicy.isAbsoluteLocalFileURL(explicitUserFileURL) else {
                throw CLIExecutableLocatorError.explicitOverrideRejected(
                    .absoluteLocalFileURLRequired
                )
            }
            let inspection = fileSystem.inspectExecutableCandidate(
                at: explicitUserFileURL.standardizedFileURL
            )
            switch resolvedExecutable(
                from: inspection,
                source: .explicitUserSelection
            ) {
            case let .success(executable):
                return executable
            case let .failure(rejection):
                // Explicit user intent is fail-closed. Never fall back to PATH after rejection.
                throw CLIExecutableLocatorError.explicitOverrideRejected(rejection)
            }
        }

        for directoryPath in CLIPathEntryPolicy.normalizedAbsoluteDirectories(pathEntries) {
            let candidateURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
                .appendingPathComponent(executableName, isDirectory: false)
            let inspection = fileSystem.inspectExecutableCandidate(at: candidateURL)
            if case let .success(executable) = resolvedExecutable(
                from: inspection,
                source: .searchPath
            ) {
                return executable
            }
        }

        throw CLIExecutableLocatorError.executableNotFound
    }

    private func resolvedExecutable(
        from inspection: CLIExecutableFileInspection,
        source: CLIExecutableLocationSource
    ) -> Result<ResolvedCLIExecutable, CLIExecutableCandidateRejection> {
        let resolvedURL = inspection.resolvedFileURL.standardizedFileURL
        guard CLIFileURLPolicy.isAbsoluteLocalFileURL(resolvedURL) else {
            return .failure(.invalidResolvedFileURL)
        }

        switch inspection.entryState {
        case .missing:
            return .failure(.missing)
        case .nonRegularFile:
            return .failure(.notRegularFile)
        case .inaccessible:
            return .failure(.inaccessible)
        case .regularFile where !inspection.isExecutable:
            return .failure(.notExecutable)
        case .regularFile:
            return .success(
                ResolvedCLIExecutable(resolvedFileURL: resolvedURL, source: source)
            )
        }
    }
}

enum CLIFileURLPolicy {
    static func isAbsoluteLocalFileURL(_ url: URL) -> Bool {
        let path = url.path
        return url.isFileURL
            && url.host == nil
            && !path.isEmpty
            && (path as NSString).isAbsolutePath
            && !path.utf8.contains(0)
    }
}

enum CLIPathEntryPolicy {
    /// PATH never gains implicit current-directory behavior: empty and relative entries are
    /// ignored. Absolute entries are standardized and deduplicated by first occurrence.
    /// Entries containing NUL or `:` are ignored because they cannot be represented safely in a
    /// colon-delimited child PATH.
    static func normalizedAbsoluteDirectories(_ entries: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []

        for entry in entries {
            guard
                !entry.isEmpty,
                !entry.contains(":"),
                !entry.utf8.contains(0),
                (entry as NSString).isAbsolutePath
            else {
                continue
            }

            let path = URL(fileURLWithPath: entry, isDirectory: true)
                .standardizedFileURL.path
            guard
                !path.isEmpty,
                !path.contains(":"),
                !path.utf8.contains(0),
                (path as NSString).isAbsolutePath,
                seen.insert(path).inserted
            else {
                continue
            }
            normalized.append(path)
        }

        return normalized
    }

    static func isValidExecutableName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.utf8.contains(0)
    }
}
