import AppKit
import Foundation
import UsageButlerCore

public enum ActivityMonitorLaunchError: Error, Equatable {
    case applicationNotFound
    case launchFailed
}

@MainActor
public final class ActivityMonitorLauncher: ActivityMonitorLaunching {
    private static let bundleIdentifier = "com.apple.ActivityMonitor"

    private let workspace: any ActivityMonitorWorkspaceClient

    public convenience init(workspace: NSWorkspace = .shared) {
        self.init(workspace: NSWorkspaceActivityMonitorClient(workspace: workspace))
    }

    init(workspace: any ActivityMonitorWorkspaceClient) {
        self.workspace = workspace
    }

    public func openActivityMonitor() async throws {
        if let runningApplication = workspace.runningApplication(
            withBundleIdentifier: Self.bundleIdentifier
        ) {
            guard runningApplication.activate(
                options: ActivityMonitorActivationOptions.current
            ) else {
                throw ActivityMonitorLaunchError.launchFailed
            }
            return
        }

        guard let applicationURL = workspace.urlForApplication(
            withBundleIdentifier: Self.bundleIdentifier
        ) else {
            throw ActivityMonitorLaunchError.applicationNotFound
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false

        do {
            try await workspace.openApplication(
                at: applicationURL,
                configuration: configuration
            )
        } catch {
            throw ActivityMonitorLaunchError.launchFailed
        }
    }
}

enum ActivityMonitorActivationOptions {
    private static let legacyActivateIgnoringOtherAppsRawValue: UInt = 1 << 1

    static var current: NSApplication.ActivationOptions {
        options(
            forMacOSMajorVersion:
                ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }

    static func options(
        forMacOSMajorVersion majorVersion: Int
    ) -> NSApplication.ActivationOptions {
        var options: NSApplication.ActivationOptions = [.activateAllWindows]
        if majorVersion < 14 {
            // AppKit defines the legacy activateIgnoringOtherApps option as bit 1.
            // Constructing it by raw value avoids referencing the SDK-deprecated symbol.
            options.insert(
                NSApplication.ActivationOptions(
                    rawValue: legacyActivateIgnoringOtherAppsRawValue
                )
            )
        }
        return options
    }
}

@MainActor
protocol ActivityMonitorRunningApplicationActivating: AnyObject {
    func activate(options: NSApplication.ActivationOptions) -> Bool
}

@MainActor
protocol ActivityMonitorWorkspaceClient: AnyObject {
    func runningApplication(
        withBundleIdentifier bundleIdentifier: String
    ) -> (any ActivityMonitorRunningApplicationActivating)?

    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL?

    func openApplication(
        at applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async throws
}

@MainActor
private final class NSWorkspaceActivityMonitorClient: ActivityMonitorWorkspaceClient {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace) {
        self.workspace = workspace
    }

    func runningApplication(
        withBundleIdentifier bundleIdentifier: String
    ) -> (any ActivityMonitorRunningApplicationActivating)? {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else {
            return nil
        }

        return NSRunningActivityMonitorApplication(application: application)
    }

    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func openApplication(
        at applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async throws {
        try await workspace.openApplication(
            at: applicationURL,
            configuration: configuration
        )
    }
}

@MainActor
private final class NSRunningActivityMonitorApplication:
    ActivityMonitorRunningApplicationActivating
{
    private let application: NSRunningApplication

    init(application: NSRunningApplication) {
        self.application = application
    }

    func activate(options: NSApplication.ActivationOptions) -> Bool {
        application.activate(options: options)
    }
}
