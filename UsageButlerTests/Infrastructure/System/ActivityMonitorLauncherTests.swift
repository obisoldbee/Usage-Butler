import AppKit
import XCTest
@testable import UsageButlerInfrastructure

@MainActor
final class ActivityMonitorLauncherTests: XCTestCase {
    private let bundleIdentifier = "com.apple.ActivityMonitor"

    func testRunningApplicationIsExplicitlyActivatedAndNotOpened() async throws {
        let runningApplication = FakeRunningApplication(activationResult: true)
        let workspace = FakeActivityMonitorWorkspace(
            runningApplication: runningApplication
        )

        try await ActivityMonitorLauncher(workspace: workspace).openActivityMonitor()

        XCTAssertEqual(workspace.runningApplicationLookups, [bundleIdentifier])
        XCTAssertTrue(workspace.applicationURLLookups.isEmpty)
        XCTAssertTrue(workspace.openRequests.isEmpty)
        let options = try XCTUnwrap(runningApplication.activationOptions.first)
        XCTAssertEqual(options, ActivityMonitorActivationOptions.current)
        XCTAssertEqual(runningApplication.activationOptions.count, 1)
    }

    func testMacOS13ActivationOptionsRaiseAllWindowsAndIgnoreCurrentActiveApp() {
        let options = ActivityMonitorActivationOptions.options(
            forMacOSMajorVersion: 13
        )

        XCTAssertEqual(
            options.rawValue,
            NSApplication.ActivationOptions.activateAllWindows.rawValue | (1 << 1)
        )
    }

    func testMacOS14AndLaterActivationOptionsUseOnlyRaiseAllWindows() {
        for majorVersion in [14, 15, 27] {
            XCTAssertEqual(
                ActivityMonitorActivationOptions.options(
                    forMacOSMajorVersion: majorVersion
                ),
                [.activateAllWindows]
            )
        }
    }

    func testRunningApplicationActivationFailureIsTypedAndDoesNotColdLaunch() async {
        let runningApplication = FakeRunningApplication(activationResult: false)
        let workspace = FakeActivityMonitorWorkspace(
            runningApplication: runningApplication,
            applicationURL: fixtureApplicationURL
        )

        do {
            try await ActivityMonitorLauncher(workspace: workspace).openActivityMonitor()
            XCTFail("Expected activation failure")
        } catch {
            XCTAssertEqual(error as? ActivityMonitorLaunchError, .launchFailed)
        }

        XCTAssertEqual(runningApplication.activationOptions.count, 1)
        XCTAssertTrue(workspace.applicationURLLookups.isEmpty)
        XCTAssertTrue(workspace.openRequests.isEmpty)
    }

    func testNotRunningApplicationUsesActivatingOpenConfiguration() async throws {
        let workspace = FakeActivityMonitorWorkspace(
            applicationURL: fixtureApplicationURL
        )

        try await ActivityMonitorLauncher(workspace: workspace).openActivityMonitor()

        XCTAssertEqual(workspace.runningApplicationLookups, [bundleIdentifier])
        XCTAssertEqual(workspace.applicationURLLookups, [bundleIdentifier])
        XCTAssertEqual(workspace.openRequests.count, 1)
        let request = try XCTUnwrap(workspace.openRequests.first)
        XCTAssertEqual(request.applicationURL, fixtureApplicationURL)
        XCTAssertTrue(request.activates)
        XCTAssertFalse(request.createsNewApplicationInstance)
        XCTAssertTrue(request.allowsRunningApplicationSubstitution)
        XCTAssertFalse(request.addsToRecentItems)
        XCTAssertFalse(request.promptsUserIfNeeded)
    }

    func testNotRunningAndMissingApplicationIsTypedNotFound() async {
        let workspace = FakeActivityMonitorWorkspace()

        do {
            try await ActivityMonitorLauncher(workspace: workspace).openActivityMonitor()
            XCTFail("Expected missing application failure")
        } catch {
            XCTAssertEqual(error as? ActivityMonitorLaunchError, .applicationNotFound)
        }

        XCTAssertEqual(workspace.applicationURLLookups, [bundleIdentifier])
        XCTAssertTrue(workspace.openRequests.isEmpty)
    }

    func testColdLaunchFailureIsTypedLaunchFailed() async {
        let workspace = FakeActivityMonitorWorkspace(
            applicationURL: fixtureApplicationURL,
            openError: FakeOpenError.failed
        )

        do {
            try await ActivityMonitorLauncher(workspace: workspace).openActivityMonitor()
            XCTFail("Expected cold-launch failure")
        } catch {
            XCTAssertEqual(error as? ActivityMonitorLaunchError, .launchFailed)
        }

        XCTAssertEqual(workspace.openRequests.count, 1)
    }

    private var fixtureApplicationURL: URL {
        URL(
            fileURLWithPath: "/Applications/Utilities/Activity Monitor.app",
            isDirectory: true
        )
    }
}

@MainActor
private final class FakeRunningApplication: ActivityMonitorRunningApplicationActivating {
    private let activationResult: Bool
    private(set) var activationOptions: [NSApplication.ActivationOptions] = []

    init(activationResult: Bool) {
        self.activationResult = activationResult
    }

    func activate(options: NSApplication.ActivationOptions) -> Bool {
        activationOptions.append(options)
        return activationResult
    }
}

@MainActor
private final class FakeActivityMonitorWorkspace: ActivityMonitorWorkspaceClient {
    struct OpenRequest {
        let applicationURL: URL
        let activates: Bool
        let createsNewApplicationInstance: Bool
        let allowsRunningApplicationSubstitution: Bool
        let addsToRecentItems: Bool
        let promptsUserIfNeeded: Bool
    }

    private let stubbedRunningApplication:
        (any ActivityMonitorRunningApplicationActivating)?
    private let stubbedApplicationURL: URL?
    private let openError: (any Error)?

    private(set) var runningApplicationLookups: [String] = []
    private(set) var applicationURLLookups: [String] = []
    private(set) var openRequests: [OpenRequest] = []

    init(
        runningApplication: (any ActivityMonitorRunningApplicationActivating)? = nil,
        applicationURL: URL? = nil,
        openError: (any Error)? = nil
    ) {
        stubbedRunningApplication = runningApplication
        stubbedApplicationURL = applicationURL
        self.openError = openError
    }

    func runningApplication(
        withBundleIdentifier bundleIdentifier: String
    ) -> (any ActivityMonitorRunningApplicationActivating)? {
        runningApplicationLookups.append(bundleIdentifier)
        return stubbedRunningApplication
    }

    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        applicationURLLookups.append(bundleIdentifier)
        return stubbedApplicationURL
    }

    func openApplication(
        at applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async throws {
        openRequests.append(
            OpenRequest(
                applicationURL: applicationURL,
                activates: configuration.activates,
                createsNewApplicationInstance: configuration.createsNewApplicationInstance,
                allowsRunningApplicationSubstitution:
                    configuration.allowsRunningApplicationSubstitution,
                addsToRecentItems: configuration.addsToRecentItems,
                promptsUserIfNeeded: configuration.promptsUserIfNeeded
            )
        )
        if let openError {
            throw openError
        }
    }
}

private enum FakeOpenError: Error {
    case failed
}
