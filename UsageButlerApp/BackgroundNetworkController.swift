import AppKit
import CryptoKit
import Darwin
import ServiceManagement
import UsageButlerCore
import UsageButlerDomain
import UsageButlerInfrastructure
import UsageButlerUI

@MainActor
protocol BackgroundNetworkRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}
extension SMAppService: BackgroundNetworkRegistration {}

/// UI-side lifecycle and bounded read client. It never owns a collector,
/// writer, migration, checkpoint, or fallback nettop process.
@MainActor
final class BackgroundNetworkController {
    static let preference = "network.backgroundHistory.enabled"
    private let model: BackgroundNetworkViewModel
    private let process: ProcessNetworkViewModel
    private let defaults: UserDefaults
    private let service: any BackgroundNetworkRegistration
    private let client: any BackgroundNetworkClient
    private let replyValidator: (@MainActor (BackgroundNetworkStatus?) throws -> Void)?
    private let offlineQuery: UsageButlerInfrastructure.NetworkHistoryQuery
    private let executable: URL
    private let executableSHA256: String
    private let binding: String
    private let historyWindow: NetworkHistoryWindowController
    private var poll: Task<Void, Never>?
    private var change: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var disconnected = false
    private var stopConfirmed = false
    private var visible = false
    convenience init(model: BackgroundNetworkViewModel, process: ProcessNetworkViewModel, defaults: UserDefaults, bundle: Bundle = .main) throws {
        let directory = try BackgroundNetworkLocation.directory(bundle: bundle)
        let executable = bundle.bundleURL.appendingPathComponent("Contents/MacOS/UsageButlerNetworkAgent")
        let peerRequirement = try HistoryCodeIdentity.requirement(for: executable)
        let binding = try HistoryCodeIdentity.requirement(for: bundle.bundleURL) + "|" + peerRequirement
        let client = try HistoryXPCClient(serviceName: BackgroundNetworkLocation.serviceName(bundle: bundle), peerRequirement: peerRequirement)
        let bytes = try Data(contentsOf: executable, options: .mappedIfSafe)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        self.init(model: model, process: process, defaults: defaults,
            service: SMAppService.agent(plistName: BackgroundNetworkLocation.plistName), client: client,
            databaseURL: directory.appendingPathComponent("history-v1.sqlite"), executable: executable,
            executableSHA256: hash, binding: binding)
    }
    // Same controller and revision paths in unhosted tests; no real SM, bundle
    // signature, process, preferences domain or installed database is touched.
    init(model: BackgroundNetworkViewModel, process: ProcessNetworkViewModel, defaults: UserDefaults,
         service: any BackgroundNetworkRegistration, client: any BackgroundNetworkClient,
         databaseURL: URL, executable: URL, executableSHA256: String, binding: String,
         replyValidator: (@MainActor (BackgroundNetworkStatus?) throws -> Void)? = nil) {
        self.model = model; self.process = process; self.defaults = defaults
        self.service = service; self.client = client; self.executable = executable
        self.executableSHA256 = executableSHA256; self.binding = binding; self.replyValidator = replyValidator
        historyWindow = .init(model: model)
        offlineQuery = .init(databaseURL: databaseURL)
        if let data = defaults.data(forKey: "network.backgroundHistory.uploadRule"),
           let rule = try? JSONDecoder().decode(HistoryUploadRule.self, from: data), rule.isValid { model.configuredRule = rule }
        model.onEnabled = { [weak self] value in await self?.setEnabled(value) }
        model.onOpenApproval = { SMAppService.openSystemSettingsLoginItems() }
        model.onOpenHistory = { [weak self] in self?.historyWindow.show() }
        model.onRefreshService = { [weak self] in
            guard let self else { return }
            if model.desired { await setEnabled(true) } else { await fetch() }
        }
        model.onRule = { [weak self] rule in
            guard let self else { throw BackgroundNetworkWire.Failure.disconnected }
            guard rule.isValid else { throw BackgroundNetworkWire.Failure.invalidRequest }
            defaults.set(try JSONEncoder().encode(rule), forKey: "network.backgroundHistory.uploadRule")
            model.configuredRule = rule
            guard service.status == .enabled else { return }
            var request = BackgroundNetworkRequest(.updateRule); request.rule = rule
            let token = revision
            let response = try await client.request(request)
            guard token == revision, !disconnected else { return }
            if let status = response.status { model.status = status }
        }
        model.onQuery = { [weak self] range, app, page, kind in
            guard let self else { throw BackgroundNetworkWire.Failure.disconnected }
            return try await query(range, applicationID: app, page: page, kind: kind)
        }
        process.onLongHistory = { [weak self] key, seconds in
            guard let self else { throw BackgroundNetworkWire.Failure.disconnected }
            return try await query(.recent(days: seconds / 86_400), applicationID: nil, applicationKey: key, page: 0, kind: nil)
        }
    }
    func start(initiallyEnabled: Bool) async {
        let desired = defaults.object(forKey: Self.preference) == nil ? initiallyEnabled : defaults.bool(forKey: Self.preference)
        await setEnabled(desired)
        guard !disconnected else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }; await fetch()
                do { try await Task.sleep(for: .seconds(visible ? 1 : 5)) } catch { return }
            }
        }
    }
    func setEnabled(_ enabled: Bool) async {
        guard !disconnected else { return }
        revision &+= 1; let token = revision
        stopConfirmed = false
        defaults.set(enabled, forKey: Self.preference); model.desired = enabled; model.changing = true
        let previous = change
        let next = Task { [weak self] in
            await previous?.value
            guard let self, token == revision, !disconnected else { return }
            await reconcile(enabled, token: token)
        }
        change = next; await next.value
    }
    private func reconcile(_ enabled: Bool, token: UInt64) async {
        do {
            model.serviceIssue = nil
            if enabled {
                if service.status == .enabled || service.status == .notFound,
                   let oldBinding = defaults.string(forKey: "network.backgroundHistory.registeredCode"), oldBinding != binding {
                    // An ad-hoc old helper correctly rejects the new App cdhash.
                    // SM unregister is still the authoritative owned-service stop.
                    _ = try? await client.request(.init(.stop))
                    try await service.unregister(); await client.disconnect()
                    guard token == revision, !disconnected else { return }
                }
                if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                }
                guard token == revision, !disconnected else { return }
                readRegistration()
                guard service.status == .enabled else { model.changing = false; return }
                // Re-register changed embedded code only after the old helper
                // has flushed, exited, and async unregister has completed.
                let old = try await client.request(.init(.status))
                guard token == revision, !disconnected else { return }
                if let status = old.status, status.executableSHA256 != executableSHA256 {
                    _ = try await client.request(.init(.stop))
                    try await service.unregister(); await client.disconnect()
                    guard token == revision, !disconnected else { return }
                    try service.register()
                }
                guard token == revision, !disconnected else { return }
                let response = try await client.request(.init(.enable))
                guard token == revision, !disconnected else { return }
                try validate(response.status)
                // Registration alone does not prove launch or authenticated IPC.
                // Keep the previous binding after a failed replacement so an
                // explicit refresh can retry the standard unregister flow.
                defaults.set(binding, forKey: "network.backgroundHistory.registeredCode")
                model.status = response.status
                if response.status?.rule != model.configuredRule {
                    var ruleRequest = BackgroundNetworkRequest(.updateRule); ruleRequest.rule = model.configuredRule
                    let configured = try await client.request(ruleRequest)
                    guard token == revision, !disconnected else { return }; model.status = configured.status
                }
            } else {
                if service.status == .notRegistered { stopConfirmed = true }
                else {
                    do {
                        let response = try await client.request(.init(.stop))
                        guard token == revision, !disconnected else { return }
                        try validate(response.status)
                        guard response.status?.sourceState == .stopped else { throw BackgroundNetworkWire.Failure.invalidResponse }
                        stopConfirmed = true
                    } catch {
                        guard token == revision, !disconnected else { return }
                        model.serviceIssue = "history.graceful-stop-unconfirmed"
                    }
                    try await service.unregister()
                    guard token == revision, !disconnected else { return }
                    stopConfirmed = true
                }
                await client.disconnect()
                guard token == revision, !disconnected else { return }
                model.status = nil; process.markBackgroundUnavailable(stopped: stopConfirmed)
            }
        } catch {
            guard token == revision, !disconnected else { return }
            model.serviceIssue = Self.errorCode(error)
            process.markBackgroundUnavailable(stopped: !enabled && stopConfirmed)
        }
        guard token == revision, !disconnected else { return }
        readRegistration(); model.changing = false
    }
    private func readRegistration() {
        model.registration = switch service.status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }
    private func validate(_ status: BackgroundNetworkStatus?) throws {
        if let replyValidator { try replyValidator(status); return }
        guard let status, status.version == BackgroundNetworkWire.version, status.executableSHA256 == executableSHA256 else {
            throw BackgroundNetworkWire.Failure.remote("history.helper-version-mismatch")
        }
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(status.pid, &bytes, UInt32(bytes.count)) > 0,
              String(cString: bytes) == executable.path else { throw BackgroundNetworkWire.Failure.remote("history.helper-identity-mismatch") }
    }
    func fetch() async {
        guard !disconnected, !model.changing else { return }
        let token = revision; readRegistration()
        if !model.desired, stopConfirmed { process.markBackgroundUnavailable(stopped: true); return }
        guard service.status == .enabled else { process.markBackgroundUnavailable(stopped: false); return }
        var request = BackgroundNetworkRequest(.snapshot); request.selectedKey = process.selected
        do {
            let response = try await client.request(request)
            guard token == revision, !disconnected, !model.changing else { return }
            try validate(response.status); model.status = response.status; model.serviceIssue = nil
            if let snapshot = response.snapshot { process.apply(snapshot) }
        } catch {
            guard token == revision, !disconnected, !model.changing else { return }
            model.serviceIssue = Self.errorCode(error); process.markBackgroundUnavailable(stopped: false)
        }
    }
    func updatePolicy(_ policy: NetworkPublishPolicy) {
        visible = policy.minimumInterval <= .seconds(1); process.setLongHistoryVisible(visible)
    }
    func refresh() async {
        guard service.status == .enabled else { return }
        _ = try? await client.request(.init(.refresh)); await fetch()
    }
    func disconnect() async {
        disconnected = true; revision &+= 1; poll?.cancel(); poll = nil
        historyWindow.close()
        process.setLongHistoryVisible(false)
        // Intentionally no stop / unregister: ordinary App exit leaves the
        // independent collector running with its existing durable preference.
        await client.disconnect()
    }
    private func query(_ range: HistoryRange, applicationID: Int64?, applicationKey: String? = nil, page: Int, kind: String?) async throws -> HistoryQueryResult {
        if service.status != .enabled {
            return try await offlineQuery.query(range: range, applicationID: applicationID, applicationKey: applicationKey, page: page, eventKind: kind)
        }
        var request = BackgroundNetworkRequest(.query); request.range = range; request.applicationID = applicationID
        request.selectedKey = applicationKey
        request.page = page; request.eventKind = kind
        let response = try await client.request(request)
        guard let history = response.history else { throw BackgroundNetworkWire.Failure.invalidResponse }; return history
    }
    private static func errorCode(_ error: Error) -> String {
        if let error = error as? NetworkHistoryError { return error.code }
        if case let BackgroundNetworkWire.Failure.remote(code) = error { return code }
        let ns = error as NSError
        if ns.domain == "SMAppServiceErrorDomain" { return "history.registration.\(ns.code)" }
        return "history.service-unavailable"
    }
}
