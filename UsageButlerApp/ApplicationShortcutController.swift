import AppKit
import Carbon.HIToolbox
import UsageButlerCore

@MainActor
protocol ApplicationHotkeyRegistering: AnyObject {
    func installHandler(_ route: @escaping (UInt32, UInt32) -> Bool) -> OSStatus
    func register(_ shortcut: GlobalShortcut, signature: UInt32, id: UInt32) -> OSStatus
    func unregister(id: UInt32) -> OSStatus
    func removeHandler() -> OSStatus
}

/// Two independent registrations; changing the recorded panel shortcut never
/// rewrites preferences or silently borrows the settings route.
@MainActor
final class ApplicationShortcutController {
    static let signature: UInt32 = 0x5542_686B // Existing "UBhk" namespace.
    static let panelID: UInt32 = 1
    static let settingsID: UInt32 = 2
    static let settingsShortcut = GlobalShortcut(keyCode: UInt32(kVK_ANSI_Comma), modifiers: [.command, .shift])

    private let registrar: any ApplicationHotkeyRegistering
    private let onPanel: () -> Void
    private let onSettings: () -> Void
    private let report: (String?, String?) -> Void
    private var handlerInstalled = false
    private var activePanel: GlobalShortcut?
    private var settingsRegistered = false
    private(set) var panelIssue: String?
    private(set) var settingsIssue: String?

    init(registrar: any ApplicationHotkeyRegistering, onPanel: @escaping () -> Void,
         onSettings: @escaping () -> Void, report: @escaping (String?, String?) -> Void) {
        self.registrar = registrar; self.onPanel = onPanel; self.onSettings = onSettings; self.report = report
    }

    func start(panelShortcut: GlobalShortcut?) {
        guard !handlerInstalled else { return }
        let status = registrar.installHandler { [weak self] signature, id in
            self?.route(signature: signature, id: id) ?? false
        }
        guard status == noErr else {
            panelIssue = "全局热键事件处理器不可用（OSStatus \(status)）。"
            settingsIssue = panelIssue; publish(); return
        }
        handlerInstalled = true
        applyPanelShortcut(panelShortcut)
    }

    func applyPanelShortcut(_ shortcut: GlobalShortcut?) {
        guard handlerInstalled else { start(panelShortcut: shortcut); return }
        let conflicts = shortcut?.keyCode == Self.settingsShortcut.keyCode
            && shortcut?.carbonModifiers == Self.settingsShortcut.carbonModifiers
        panelIssue = nil
        if activePanel != shortcut {
            if activePanel != nil {
                let status = registrar.unregister(id: Self.panelID)
                guard status == noErr else {
                    panelIssue = "面板快捷键更新失败，旧注册仍保留（注销 OSStatus \(status)）。"
                    publish(); return
                }
                activePanel = nil
            }
            if conflicts, settingsRegistered {
                let status = registrar.unregister(id: Self.settingsID)
                guard status == noErr else {
                    panelIssue = "面板快捷键未生效：无法释放设置热键（OSStatus \(status)）。"
                    publish(); return
                }
                settingsRegistered = false
            }
            if let shortcut {
                let status = registrar.register(shortcut, signature: Self.signature, id: Self.panelID)
                if status == noErr { activePanel = shortcut }
                else { panelIssue = "面板快捷键未注册，可能已被占用（OSStatus \(status)）；保存的配置未更改。" }
            }
        }
        if conflicts {
            settingsIssue = "打开设置 ⌘⇧, 与面板快捷键冲突；面板配置不会自动更改，请检查配置和注册状态。"
        } else if !settingsRegistered {
            let status = registrar.register(Self.settingsShortcut, signature: Self.signature, id: Self.settingsID)
            settingsRegistered = status == noErr
            settingsIssue = status == noErr ? nil : "打开设置 ⌘⇧, 未注册，可能已被其它软件占用（OSStatus \(status)）。"
        } else { settingsIssue = nil }
        publish()
    }

    @discardableResult
    func route(signature: UInt32, id: UInt32) -> Bool {
        guard handlerInstalled, signature == Self.signature else { return false }
        switch id {
        case Self.panelID where activePanel != nil: onPanel(); return true
        case Self.settingsID where settingsRegistered: onSettings(); return true
        default: return false
        }
    }

    func stop() {
        if activePanel != nil {
            let status = registrar.unregister(id: Self.panelID)
            if status == noErr { activePanel = nil }
            else { panelIssue = "面板热键注销失败（OSStatus \(status)）。" }
        }
        if settingsRegistered {
            let status = registrar.unregister(id: Self.settingsID)
            if status == noErr { settingsRegistered = false }
            else { settingsIssue = "设置热键注销失败（OSStatus \(status)）。" }
        }
        if handlerInstalled, activePanel == nil, !settingsRegistered {
            let status = registrar.removeHandler()
            if status == noErr { handlerInstalled = false }
            else { settingsIssue = "热键事件处理器注销失败（OSStatus \(status)）。" }
        }
        publish()
    }

    private func publish() { report(panelIssue, settingsIssue) }
}

@MainActor
final class CarbonApplicationHotkeys: ApplicationHotkeyRegistering {
    private var handler: EventHandlerRef?
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var route: ((UInt32, UInt32) -> Bool)?

    func installHandler(_ route: @escaping (UInt32, UInt32) -> Bool) -> OSStatus {
        guard handler == nil else { self.route = route; return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            // Application-event Carbon callbacks run on the AppKit main loop.
            return MainActor.assumeIsolated {
                let owner = Unmanaged<CarbonApplicationHotkeys>.fromOpaque(userData).takeUnretainedValue()
                return CarbonApplicationHotkeys.dispatch(event) { owner.route?($0, $1) ?? false }
            }
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status == noErr { self.route = route }
        return status
    }

    /// Also exercised with locally-created Carbon events; tests never install a
    /// system handler or post events into the user's session.
    static func dispatch(_ event: EventRef, route: (UInt32, UInt32) -> Bool) -> OSStatus {
        guard GetEventClass(event) == OSType(kEventClassKeyboard),
              GetEventKind(event) == UInt32(kEventHotKeyPressed) else { return OSStatus(eventNotHandledErr) }
        var hotkey = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
        guard status == noErr else { return status }
        return route(hotkey.signature, hotkey.id) ? noErr : OSStatus(eventNotHandledErr)
    }

    func register(_ shortcut: GlobalShortcut, signature: UInt32, id: UInt32) -> OSStatus {
        guard references[id] == nil else { return OSStatus(eventHotKeyExistsErr) }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
            EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return status }
        guard let ref else { return OSStatus(paramErr) }
        references[id] = ref
        return noErr
    }

    func unregister(id: UInt32) -> OSStatus {
        guard let ref = references[id] else { return noErr }
        let status = UnregisterEventHotKey(ref)
        if status == noErr { references[id] = nil }
        return status
    }

    func removeHandler() -> OSStatus {
        guard let handler else { return noErr }
        let status = RemoveEventHandler(handler)
        if status == noErr { self.handler = nil; route = nil }
        return status
    }
}
