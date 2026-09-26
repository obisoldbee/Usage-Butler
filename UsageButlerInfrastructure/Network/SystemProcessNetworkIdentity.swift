import CryptoKit
import Darwin
import Foundation
import UsageButlerDomain

/// Public process metadata only. Executable containment, never process names
/// or parent PIDs, associates a helper with its enclosing application.
public struct SystemProcessNetworkIdentity: Sendable {
    private struct Cached: Sendable { let identity: ProcessNetworkApplicationIdentity; let used: UInt64; let created: UInt64 }
    private var bundles: [String: Cached] = [:]
    private var tick: UInt64 = 0
    public static let cacheLimit = 512
    public init() {}
    public var cachedIdentityCount: Int { bundles.count }
    public mutating func resolve(pid: Int32, name: String, frameStartedAt: Date) -> ProcessNetworkIdentity {
        var before = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, size)
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        var after = proc_bsdinfo()
        let checked = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, size)
        let started = Double(before.pbi_start_tvsec) + Double(before.pbi_start_tvusec) / 1e6
        guard read == size, checked == size, before.pbi_start_tvsec > 0,
              before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec,
              started <= frameStartedAt.timeIntervalSince1970, count > 0 else {
            return .init(pid: pid, instanceID: nil, name: name, executablePath: nil,
                application: .init(key: "unknown-\(pid)", name: name, evidence: .unknown))
        }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let token = "\(pid):\(before.pbi_start_tvsec):\(before.pbi_start_tvusec):\(Self.digest(canonical))"
        let app = application(for: canonical, fallback: name)
        return .init(pid: pid, instanceID: token, name: name, executablePath: canonical, application: app)
    }
    /// Public for deterministic containment tests; cache is bounded and expires
    /// after 60 seconds so replacement metadata is not retained indefinitely.
    public mutating func application(for executable: String, fallback: String) -> ProcessNetworkApplicationIdentity {
        tick &+= 1
        let now = DispatchTime.now().uptimeNanoseconds
        if let cached = bundles[executable], now >= cached.created, now - cached.created < 60_000_000_000 {
            bundles[executable] = .init(identity: cached.identity, used: tick, created: cached.created)
            return cached.identity
        }
        let url = URL(fileURLWithPath: executable).standardizedFileURL
        let components = url.pathComponents
        let appIndexes = components.indices.filter { components[$0].hasSuffix(".app") }
        var resolved: ProcessNetworkApplicationIdentity?
        // The outer bundle must contain Contents and an actual executable
        // or nested helper bundle. A directory merely ending in .app is not evidence.
        for index in appIndexes {
            guard index + 2 < components.count, components[index + 1] == "Contents" else { continue }
            let root = NSString.path(withComponents: Array(components.prefix(index + 1)))
            let infoURL = URL(fileURLWithPath: root).appendingPathComponent("Contents/Info.plist")
            guard let infoSize = try? infoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  infoSize <= 1_048_576,
                  let data = try? Data(contentsOf: infoURL), data.count <= 1_048_576,
                  let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let bundleID = values["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
                  let main = values["CFBundleExecutable"] as? String, !main.isEmpty,
                  FileManager.default.isExecutableFile(atPath: root + "/Contents/MacOS/" + main) else { continue }
            let mainPath = root + "/Contents/MacOS/" + main
            let nested = executable != mainPath
            // Helpers must be in the bundle's structural executable locations.
            let tail = Array(components.dropFirst(index + 2))
            guard !nested || ["MacOS", "Frameworks", "Helpers", "XPCServices", "Library", "PlugIns"].contains(tail.first ?? "") else { continue }
            let display = values["CFBundleDisplayName"] as? String ?? values["CFBundleName"] as? String ?? URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent
            resolved = .init(key: Self.digest(root + "\u{0}" + bundleID), name: String(display.prefix(256)),
                             bundleID: String(bundleID.prefix(512)), installationPath: root,
                             evidence: nested ? .nestedBundle : .executableBundle)
            break
        }
        let identity = resolved ?? .init(key: Self.digest(executable), name: String(fallback.prefix(256)),
                                         installationPath: nil, evidence: .executable)
        if bundles.count >= Self.cacheLimit, bundles[executable] == nil,
           let victim = bundles.min(by: { $0.value.used < $1.value.used })?.key { bundles.removeValue(forKey: victim) }
        bundles[executable] = .init(identity: identity, used: tick, created: now)
        return identity
    }
    private static func digest(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}
