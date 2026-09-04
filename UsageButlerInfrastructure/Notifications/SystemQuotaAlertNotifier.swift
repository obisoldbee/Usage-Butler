import Foundation
import OSLog
import UsageButlerCore
import UsageButlerDomain
import UserNotifications

/// Delivers quota-exhaustion alerts as macOS user notifications.
///
/// Authorization is requested once during `prepare()`; a denied
/// authorization never blocks the alert pipeline - `send()` reports a typed
/// `.permissionDenied` failure that the service logs independently of other
/// channels.
///
/// Not covered by unit tests: `UNUserNotificationCenter` requires a running
/// application context, so its behavior is verified on the real app instead.
public actor SystemQuotaAlertNotifier: QuotaAlertNotifier {
    private let logger = Logger(
        subsystem: QuotaAlertService.Telemetry.subsystem,
        category: QuotaAlertService.Telemetry.category
    )

    public init() {}

    public func prepare() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(
                options: [.alert, .sound]
            )) ?? false
            if granted {
                logger.info("system_notification_authorization outcome=granted")
            } else {
                logger.info("system_notification_authorization outcome=denied")
            }
        case .authorized:
            logger.info("system_notification_authorization outcome=already_authorized")
        case .provisional:
            logger.info("system_notification_authorization outcome=already_provisional")
        case .ephemeral:
            logger.info("system_notification_authorization outcome=already_ephemeral")
        default:
            logger.info("system_notification_authorization outcome=denied")
        }
    }

    public func send(_ payload: QuotaAlertPayload) async -> Result<Void, ProviderFailure> {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            // Late authorization attempt; prepare() usually settles this at
            // startup, but the service can also run without it.
            let granted = (try? await center.requestAuthorization(
                options: [.alert, .sound]
            )) ?? false
            guard granted else {
                return .failure(Self.authorizationDenied)
            }
        default:
            return .failure(Self.authorizationDenied)
        }

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.bodyLines.joined(separator: "\n")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "quota-alert-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return .success(())
        } catch {
            return .failure(Self.deliveryFailed)
        }
    }

    private static let authorizationDenied = ProviderFailure(
        code: .permissionDenied,
        retryClass: .afterRecovery,
        userMessageKey: "quota.alert.system_notification.authorization_denied",
        diagnosticCode: "quotaAlert.systemNotification.authorization_denied",
        recovery: nil
    )

    private static let deliveryFailed = ProviderFailure(
        code: .processFailed,
        retryClass: .backoff,
        userMessageKey: "quota.alert.system_notification.delivery_failed",
        diagnosticCode: "quotaAlert.systemNotification.add_failed",
        recovery: .retry
    )
}
