import Darwin
import Foundation

/// Used only by the leased background owner. A crash must not allow a new
/// source to overlap an old orphan. Receipts identify PID + kernel start time,
/// uid, executable and original parent; names alone never authorize a signal.
public final class NettopChildSupervisor: @unchecked Sendable {
    private struct Identity: Codable, Equatable {
        let pid: Int32
        let seconds: UInt64
        let microseconds: UInt64
        let executable: String
        let uid: UInt32
    }
    private struct Receipt: Codable {
        let owner: Identity
        let child: Identity
    }
    private let file: URL
    public init(directory: URL) { file = directory.appendingPathComponent("nettop-owner.json") }
    private static func identity(_ pid: Int32) -> Identity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return .init(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec,
                     executable: String(cString: path), uid: info.pbi_uid)
    }
    private func read() throws -> Receipt? {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size <= 4096 else { throw NetworkHistoryError.unsafePath }
        guard let value = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: file)) else { throw NetworkHistoryError.corrupt }
        return value
    }
    /// Call after acquiring the sole writer lease, before creating a source.
    public func recover() throws {
        guard let receipt = try read() else { return }
        guard receipt.child.executable == "/usr/bin/nettop", receipt.child.uid == getuid(), receipt.owner.uid == getuid() else {
            throw NetworkHistoryError.unsafePath
        }
        guard Self.identity(receipt.child.pid) == receipt.child else {
            try FileManager.default.removeItem(at: file); return
        }
        guard Self.identity(receipt.owner.pid) != receipt.owner else { throw NetworkHistoryError.alreadyRunning }
        // Recheck immediately before every signal. The same-user trust boundary
        // does not claim protection from forged private files by this user.
        if Self.identity(receipt.child.pid) == receipt.child { kill(receipt.child.pid, SIGTERM) }
        for _ in 0..<50 {
            if Self.identity(receipt.child.pid) != receipt.child { break }; usleep(10_000)
        }
        if Self.identity(receipt.child.pid) == receipt.child { kill(receipt.child.pid, SIGKILL) }
        for _ in 0..<100 {
            if Self.identity(receipt.child.pid) != receipt.child { break }; usleep(10_000)
        }
        guard Self.identity(receipt.child.pid) != receipt.child else { throw NetworkHistoryError.alreadyRunning }
        try FileManager.default.removeItem(at: file)
    }
    func started(_ pid: Int32) throws {
        guard let owner = Self.identity(getpid()), let child = Self.identity(pid), child.executable == "/usr/bin/nettop",
              child.uid == getuid() else { throw NetworkHistoryError.unsafePath }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_ppid == UInt32(getpid()) else { throw NetworkHistoryError.unsafePath }
        let data = try JSONEncoder().encode(Receipt(owner: owner, child: child))
        try data.write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else { throw NetworkHistoryError.unsafePath }
    }
    func reaped(_ pid: Int32) {
        guard let receipt = try? read(), receipt.child.pid == pid,
              Self.identity(pid) != receipt.child else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
