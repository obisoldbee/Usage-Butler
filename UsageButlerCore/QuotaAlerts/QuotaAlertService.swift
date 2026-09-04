import Foundation
import OSLog
import UsageButlerDomain

/// One delivery channel (system notification, Feishu CLI message) with the
/// fixed identifier used in telemetry so outcomes stay attributable.
public struct QuotaAlertChannel: Sendable {
    public let id: String
    public let notifier: any QuotaAlertNotifier

    public init(id: String, notifier: any QuotaAlertNotifier) {
        self.id = id
        self.notifier = notifier
    }
}

/// Evaluates every committed provider snapshot for quota exhaustion and reset
/// edges, then dispatches aggregated payloads across all channels.
///
/// Channels succeed or fail independently; a failed channel is logged with
/// its typed failure code and never suppresses the other channels.
public actor QuotaAlertService {
    public enum Telemetry {
        public static let subsystem = "io.github.obisoldbee.UsageButler"
        public static let category = "QuotaAlerts"
    }

    private let channels: [QuotaAlertChannel]
    private let markerStore: any QuotaAlertMarkerStore
    private let isAlertsEnabled: @Sendable () -> Bool
    private let logger = Logger(
        subsystem: Telemetry.subsystem,
        category: Telemetry.category
    )
    private var markers: [String: String]?
    private var markerLoadTask: Task<[String: String], Never>?
    private var markerSaveTask: Task<Void, Never>?
    private var lastEvaluatedFetchedAt: [ProviderID: Date] = [:]
    private var isStopped = false

    public init(
        channels: [QuotaAlertChannel],
        markerStore: any QuotaAlertMarkerStore,
        isAlertsEnabled: @escaping @Sendable () -> Bool
    ) {
        self.channels = channels
        self.markerStore = markerStore
        self.isAlertsEnabled = isAlertsEnabled
    }

    /// Lets every channel perform startup work (e.g. notification
    /// authorization) before the first snapshot arrives.
    public func prepare() async {
        guard !isStopped else { return }
        let channels = self.channels
        await withTaskGroup(of: Void.self) { group in
            for channel in channels {
                group.addTask {
                    await channel.notifier.prepare()
                }
            }
        }
    }

    public func shutdown() {
        guard !isStopped else { return }
        isStopped = true
        markerLoadTask?.cancel()
        markerLoadTask = nil
        markers = nil
        lastEvaluatedFetchedAt = [:]
    }

    /// Feeds one provider projection into the alert pipeline. Snapshots are
    /// deduplicated by `lastGood.fetchedAt`, so gate-only or failure-only
    /// re-projections never re-evaluate the same data.
    public func receive(_ projection: ProviderProjection) async {
        guard !isStopped, projection.isEnabled else { return }
        guard let snapshot = projection.state.lastGood else { return }

        let providerID = snapshot.providerID
        guard lastEvaluatedFetchedAt[providerID] != snapshot.fetchedAt else {
            return
        }
        lastEvaluatedFetchedAt[providerID] = snapshot.fetchedAt

        // Startup rule: a fresh exhaustion still alerts when it has no marker.
        // The OpenAI weekly reset detector separately treats its first valid
        // sample as a baseline, never as proof that a transition just happened.
        if markers == nil {
            let loadTask = markerLoadTask ?? Task { [markerStore] in
                await markerStore.loadMarkers()
            }
            markerLoadTask = loadTask
            let loadedMarkers = await loadTask.value
            guard !isStopped else { return }
            // Another waiter may already have published and advanced the map
            // while this receive was suspended. Never replace that state.
            if markers == nil {
                markers = loadedMarkers
                markerLoadTask = nil
            }
        }
        guard !isStopped, var currentMarkers = markers else { return }

        let statuses = QuotaExhaustionEvaluator.statuses(in: snapshot)
        let outcome = QuotaExhaustionTracker.consume(
            statuses: statuses,
            into: &currentMarkers
        )
        let observedResets = OpenAIWeeklyResetTracker.consume(
            data: snapshot,
            into: &currentMarkers
        )
        if currentMarkers != markers {
            markers = currentMarkers
            // Publish before awaiting, then serialize saves: the store's own
            // actor may suspend inside saveMarkers and complete writes out of
            // order. Each accepted map must persist after its predecessor.
            let previousSave = markerSaveTask
            let saveTask = Task { [markerStore, currentMarkers] in
                await previousSave?.value
                await markerStore.saveMarkers(currentMarkers)
            }
            markerSaveTask = saveTask
            await saveTask.value
        }
        guard !isStopped else { return }

        var payloads: [(kind: String, payload: QuotaAlertPayload)] = []
        if !outcome.freshExhaustions.isEmpty {
            payloads.append(
                (
                    "exhaustion",
                    Self.payload(providerID: providerID, findings: outcome.freshExhaustions)
                )
            )
        }
        let observedResetKeys = Set(observedResets.map(\.metricKey))
        let resetStatuses = outcome.recoveries.filter {
            !observedResetKeys.contains($0.metricKey)
        } + observedResets
        if !resetStatuses.isEmpty {
            payloads.append(
                (
                    observedResets.isEmpty ? "recovery" : "reset_observed",
                    Self.recoveryPayload(providerID: providerID, statuses: resetStatuses)
                )
            )
        }
        guard !payloads.isEmpty, isAlertsEnabled() else { return }

        for entry in payloads {
            guard !isStopped else { return }
            logger.info(
                "quota_alert_dispatch kind=\(entry.kind, privacy: .public) provider=\(providerID.rawValue, privacy: .public) findings=\(entry.payload.bodyLines.count)"
            )
            await dispatch(entry.payload)
        }
    }

    private func dispatch(_ payload: QuotaAlertPayload) async {
        let logger = self.logger
        let channels = self.channels
        await withTaskGroup(of: Void.self) { group in
            for channel in channels {
                group.addTask {
                    switch await channel.notifier.send(payload) {
                    case .success:
                        logger.info(
                            "quota_alert_delivery channel=\(channel.id, privacy: .public) outcome=delivered"
                        )
                    case let .failure(failure):
                        let code = failure.code.rawValue
                        let diagnostic = failure.diagnosticCode
                        logger.error(
                            "quota_alert_delivery channel=\(channel.id, privacy: .public) outcome=failed code=\(code, privacy: .public) diagnostic=\(diagnostic, privacy: .public)"
                        )
                    }
                }
            }
        }
    }

    private static func payload(
        providerID: ProviderID,
        findings: [QuotaExhaustionFinding]
    ) -> QuotaAlertPayload {
        let providerName = providerDisplayName(providerID)
        let bodyLines = findings.map { finding in
            var scope = finding.productLabel
            if let windowLabel = finding.windowLabel {
                scope += " · \(windowLabel)"
            }
            var line = "\(providerName) · \(scope)：\(finding.usageSummary)"
            if let resetAt = finding.resetAt {
                line += "（\(resetAt.formatted(date: .abbreviated, time: .shortened)) 重置）"
            }
            return line
        }
        return QuotaAlertPayload(title: "额度已用完", bodyLines: bodyLines)
    }

    /// The reset alert: a quota entered a new usable cycle, either after prior
    /// exhaustion or through direct OpenAI weekly reset evidence. Windowed
    /// metrics say 已重置; balances and entitlements say 已恢复.
    private static func recoveryPayload(
        providerID: ProviderID,
        statuses: [QuotaMetricStatus]
    ) -> QuotaAlertPayload {
        let providerName = providerDisplayName(providerID)
        let bodyLines = statuses.map { status in
            var scope = status.productLabel
            if let windowLabel = status.windowLabel {
                scope += " · \(windowLabel)"
            }
            let verb = status.windowLabel == nil ? "已恢复" : "已重置"
            var line = "\(providerName) · \(scope)：\(verb)，\(status.usageSummary)"
            if let resetAt = status.resetAt, status.windowLabel != nil {
                line += "（\(resetAt.formatted(date: .abbreviated, time: .shortened)) 重置）"
            }
            return line
        }
        return QuotaAlertPayload(title: "额度已重置", bodyLines: bodyLines)
    }

    /// Core cannot import the UI layer, so the provider display names are
    /// mirrored here from `ProviderPresentation.displayName`.
    private static func providerDisplayName(_ providerID: ProviderID) -> String {
        switch providerID {
        case .openAI: "OpenAI"
        case .miniMax: "MiniMax"
        case .ark: "火山方舟"
        }
    }
}
