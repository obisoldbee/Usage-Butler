import Foundation
import OSLog
import UsageButlerCore

/// Notice-level local unified log. Only lifecycle transitions are recorded;
/// retention is managed by macOS, not an application history guarantee.
public enum ProcessNetworkLifecycleLog {
    private static let logger = Logger(subsystem: "io.github.obisoldbee.UsageButler", category: "ProcessNetworkLifecycle")
    public static func record(_ event: ProcessNetworkLifecycleEvent) {
        let payload = String(decoding: event.encoded(), as: UTF8.self)
        logger.notice("\(payload, privacy: .public)")
    }
}
