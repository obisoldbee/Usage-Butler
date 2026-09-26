import AppKit
import CoreFoundation
import Darwin
import Foundation
import UsageButlerDomain
import UsageButlerInfrastructure

@main
enum NetworkAgentMain {
    @MainActor static func main() {
        umask(0o077)
        // Command-line helpers have no independent app bundle. Resolve the
        // containing signed application from this verified executable path.
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 else { exit(78) }
        let executable = URL(fileURLWithPath: String(cString: path))
        let root = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let bundle = Bundle(url: root), let name = try? BackgroundNetworkLocation.serviceName(bundle: bundle),
              let requirement = try? HistoryCodeIdentity.requirement(for: root) else { exit(0) }
        let engine: BackgroundNetworkEngine?
        var startupFailure: String?
        do { engine = try .init(directory: BackgroundNetworkLocation.directory(bundle: bundle)) }
        catch { engine = nil; startupFailure = (error as? NetworkHistoryError)?.code ?? "history.startup-failed" }
        let finish: @Sendable () -> Void = {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exit(0) }
        }
        guard let server = try? HistoryXPCServer(name: name, peerRequirement: requirement,
                engine: engine, startupFailure: startupFailure, stopped: finish) else { exit(0) }
        let notifications = NSWorkspace.shared.notificationCenter
        let sleep = notifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { await engine?.suspend() }
        }
        let wake = notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { await engine?.resume() }
        }
        let logout = notifications.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            Task { await engine?.shutdown(disable: false); finish() }
        }
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        for source in [termination, interrupt] {
            source.setEventHandler { Task { await engine?.shutdown(disable: false); finish() } }
            source.resume()
        }
        server.start(); Task { await engine?.start() }
        // NSApplication would register this embedded tool with the containing
        // app's LaunchServices identity, preventing ordinary open from starting
        // the GUI after it quits. A main-thread CFRunLoop services the XPC,
        // dispatch and workspace callbacks without creating an application.
        withExtendedLifetime((server, termination, interrupt, sleep, wake, logout)) { CFRunLoopRun() }
    }
}
