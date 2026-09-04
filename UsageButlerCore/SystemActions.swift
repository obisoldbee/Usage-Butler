import Foundation

@MainActor
public protocol ActivityMonitorLaunching: AnyObject {
    func openActivityMonitor() async throws
}

public enum ActivityMonitorActionState: Equatable, Sendable {
    case idle
    case opening
    case notFound
    case launchFailed
}
