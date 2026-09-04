import Darwin
import Foundation
import XCTest
@testable import UsageButlerInfrastructure

final class CLIExecutableLocatorTests: XCTestCase {
    func testExplicitOverrideWinsOverEarlierValidPATHCandidate() throws {
        let explicit = fileURL("/selected/custom-codex")
        let pathCandidate = fileURL("/first/bin/codex")
        let fileSystem = FixtureCLIFileSystem(inspections: [
            explicit.path: executableInspection(resolvedPath: "/resolved/custom-codex"),
            pathCandidate.path: executableInspection(resolvedPath: "/resolved/path-codex")
        ])

        let result = try CLIExecutableLocator(fileSystem: fileSystem).locate(
            executableName: "codex",
            explicitUserFileURL: explicit,
            pathEntries: ["/first/bin"]
        )

        XCTAssertEqual(result.source, .explicitUserSelection)
        XCTAssertEqual(result.resolvedFileURL, fileURL("/resolved/custom-codex"))
        XCTAssertTrue(result.resolvedFileURL.isFileURL)
        XCTAssertTrue((result.resolvedFileURL.path as NSString).isAbsolutePath)
        var diagnosticDump = ""
        dump(result, to: &diagnosticDump)
        XCTAssertFalse(diagnosticDump.contains("/resolved/custom-codex"))
    }

    func testInvalidExplicitOverrideFailsClosedWithoutPATHFallback() throws {
        let explicit = fileURL("/selected/missing-codex")
        let fallback = fileURL("/valid/bin/codex")
        let fileSystem = FixtureCLIFileSystem(inspections: [
            explicit.path: inspection(path: explicit.path, state: .missing),
            fallback.path: executableInspection(resolvedPath: fallback.path)
        ])

        XCTAssertThrowsError(
            try CLIExecutableLocator(fileSystem: fileSystem).locate(
                executableName: "codex",
                explicitUserFileURL: explicit,
                pathEntries: ["/valid/bin"]
            )
        ) { error in
            XCTAssertEqual(
                error as? CLIExecutableLocatorError,
                .explicitOverrideRejected(.missing)
            )
        }
    }

    func testExplicitOverrideRejectionsAreTypedAndContainNoPathValues() throws {
        let secretPath = "/Users/private-account/bin/provider-secret"
        let explicit = fileURL(secretPath)
        let cases: [(CLIExecutableFileInspection, CLIExecutableCandidateRejection)] = [
            (inspection(path: secretPath, state: .missing), .missing),
            (inspection(path: secretPath, state: .nonRegularFile), .notRegularFile),
            (
                inspection(path: secretPath, state: .regularFile, isExecutable: false),
                .notExecutable
            ),
            (inspection(path: secretPath, state: .inaccessible), .inaccessible),
            (
                CLIExecutableFileInspection(
                    resolvedFileURL: URL(string: "relative/provider-secret")!,
                    entryState: .regularFile,
                    isExecutable: true
                ),
                .invalidResolvedFileURL
            )
        ]

        for (inspection, rejection) in cases {
            let locator = CLIExecutableLocator(
                fileSystem: FixtureCLIFileSystem(inspections: [secretPath: inspection])
            )
            XCTAssertThrowsError(
                try locator.locate(
                    executableName: "provider",
                    explicitUserFileURL: explicit,
                    pathEntries: []
                )
            ) { error in
                XCTAssertEqual(
                    error as? CLIExecutableLocatorError,
                    .explicitOverrideRejected(rejection)
                )
                XCTAssertFalse(String(describing: error).contains(secretPath))
                XCTAssertFalse(String(reflecting: error).contains(secretPath))
            }
        }

        XCTAssertThrowsError(
            try CLIExecutableLocator(fileSystem: FixtureCLIFileSystem()).locate(
                executableName: "provider",
                explicitUserFileURL: URL(string: "file:relative/provider")!,
                pathEntries: ["/valid/bin"]
            )
        ) { error in
            XCTAssertEqual(
                error as? CLIExecutableLocatorError,
                .explicitOverrideRejected(.absoluteLocalFileURLRequired)
            )
        }
    }

    func testPATHUsesOnlyNormalizedAbsoluteEntriesInCallerOrder() throws {
        let first = fileURL("/first/bin/provider")
        let second = fileURL("/second/bin/provider")
        let fileSystem = FixtureCLIFileSystem(inspections: [
            first.path: inspection(path: first.path, state: .regularFile, isExecutable: false),
            second.path: executableInspection(resolvedPath: "/resolved/second-provider")
        ])

        let result = try CLIExecutableLocator(fileSystem: fileSystem).locate(
            executableName: "provider",
            pathEntries: [
                "",
                "relative/bin",
                "/first/./bin",
                "/first/bin/",
                "/ignored:entry",
                "/second/bin",
                "/third/bin"
            ]
        )

        XCTAssertEqual(result.source, .searchPath)
        XCTAssertEqual(result.resolvedFileURL, fileURL("/resolved/second-provider"))
    }

    func testPATHSkipsMissingNonRegularAndNonExecutableCandidates() {
        let fileSystem = FixtureCLIFileSystem(inspections: [
            "/missing/bin/provider": inspection(
                path: "/missing/bin/provider",
                state: .missing
            ),
            "/directory/bin/provider": inspection(
                path: "/directory/bin/provider",
                state: .nonRegularFile
            ),
            "/nonexec/bin/provider": inspection(
                path: "/nonexec/bin/provider",
                state: .regularFile,
                isExecutable: false
            )
        ])

        XCTAssertThrowsError(
            try CLIExecutableLocator(fileSystem: fileSystem).locate(
                executableName: "provider",
                pathEntries: ["/missing/bin", "/directory/bin", "/nonexec/bin"]
            )
        ) { error in
            XCTAssertEqual(error as? CLIExecutableLocatorError, .executableNotFound)
        }
    }

    func testInvalidExecutableNamesNeverBecomePaths() {
        for name in ["", ".", "..", "../provider", "nested/provider", "bad\0name"] {
            XCTAssertThrowsError(
                try CLIExecutableLocator(fileSystem: FixtureCLIFileSystem()).locate(
                    executableName: name,
                    pathEntries: ["/valid/bin"]
                )
            ) { error in
                XCTAssertEqual(error as? CLIExecutableLocatorError, .invalidExecutableName)
            }
        }
    }

    func testFoundationCheckerAcceptsSymlinkOnlyAfterResolvingExecutableRegularTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "UsageButler-CLIExecutableLocatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("resolved-provider", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
        XCTAssertEqual(Darwin.chmod(target.path, mode_t(0o700)), 0)
        let link = root.appendingPathComponent("provider", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = try CLIExecutableLocator().locate(
            executableName: "provider",
            explicitUserFileURL: link,
            pathEntries: []
        )

        XCTAssertEqual(
            result.resolvedFileURL,
            target.resolvingSymlinksInPath().standardizedFileURL
        )
        XCTAssertNotEqual(result.resolvedFileURL, link.standardizedFileURL)

        XCTAssertEqual(Darwin.chmod(target.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(
            try CLIExecutableLocator().locate(
                executableName: "provider",
                explicitUserFileURL: link,
                pathEntries: []
            )
        ) { error in
            XCTAssertEqual(
                error as? CLIExecutableLocatorError,
                .explicitOverrideRejected(.notExecutable)
            )
        }
    }
}

private struct FixtureCLIFileSystem: CLIExecutableFileSystemChecking {
    let inspections: [String: CLIExecutableFileInspection]

    init(inspections: [String: CLIExecutableFileInspection] = [:]) {
        self.inspections = inspections
    }

    func inspectExecutableCandidate(at candidateURL: URL) -> CLIExecutableFileInspection {
        inspections[candidateURL.standardizedFileURL.path]
            ?? inspection(path: candidateURL.path, state: .missing)
    }
}

private func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
}

private func inspection(
    path: String,
    state: CLIExecutableFileEntryState,
    isExecutable: Bool = false
) -> CLIExecutableFileInspection {
    CLIExecutableFileInspection(
        resolvedFileURL: fileURL(path),
        entryState: state,
        isExecutable: isExecutable
    )
}

private func executableInspection(resolvedPath: String) -> CLIExecutableFileInspection {
    inspection(path: resolvedPath, state: .regularFile, isExecutable: true)
}
