import Darwin
import Foundation
import SQLite3

public enum NetworkHistoryError: Error, Equatable, Sendable {
    case alreadyRunning, unsafePath, closed, invalidRequest, unsupportedSchema, corrupt, capacity, queryBusy, queryTimedOut
    case sqlite(Int32)
    public var code: String {
        switch self {
        case .alreadyRunning: "history.already-running"
        case .unsafePath: "history.unsafe-path"
        case .closed: "history.closed"
        case .invalidRequest: "history.invalid-request"
        case .unsupportedSchema: "history.unsupported-schema"
        case .corrupt: "history.corrupt"
        case .capacity: "history.capacity"
        case .queryBusy: "history.query-busy"
        case .queryTimedOut: "history.query-timeout"
        case let .sqlite(code): "history.sqlite.\(code)"
        }
    }
}

/// Sole writer lifetime lease, acquired before opening SQLite or starting a
/// source. Data is private to the current user; this is not a tamper-proof log.
final class HistoryFileLease: @unchecked Sendable {
    private var descriptor: Int32 = -1
    init(directory: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw NetworkHistoryError.unsafePath
        }
        guard chmod(directory.path, 0o700) == 0 else { throw NetworkHistoryError.unsafePath }
        let path = directory.appendingPathComponent("writer.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NetworkHistoryError.unsafePath }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else {
            Darwin.close(fd); throw NetworkHistoryError.unsafePath
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw NetworkHistoryError.alreadyRunning }
        _ = fchmod(fd, 0o600); descriptor = fd
    }
    func release() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { release() }
}

/// Confined to one actor/queue. Read-only instances never migrate or checkpoint.
final class HistoryDatabase: @unchecked Sendable {
    private(set) var handle: OpaquePointer?
    let path: URL
    let readOnly: Bool
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(path: URL, readOnly: Bool = false, pageLimit: Int = 126_976) throws {
        self.path = path; self.readOnly = readOnly
        var info = stat()
        guard lstat(path.deletingLastPathComponent().path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw NetworkHistoryError.unsafePath }
        for suffix in ["-wal", "-shm"] {
            if lstat(path.path + suffix, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
                    throw NetworkHistoryError.unsafePath
                }
            }
        }
        if lstat(path.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
                throw NetworkHistoryError.unsafePath
            }
        } else if !readOnly {
            let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NetworkHistoryError.unsafePath }; Darwin.close(fd)
        }
        if !readOnly { guard chmod(path.path, 0o600) == 0 else { throw NetworkHistoryError.unsafePath } }
        var connection: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
        let code = sqlite3_open_v2(path.path, &connection, flags, nil)
        guard code == SQLITE_OK else { sqlite3_close(connection); throw NetworkHistoryError.sqlite(code) }
        handle = connection
        sqlite3_busy_timeout(connection, 200)
        try execute("PRAGMA mmap_size=0; PRAGMA cache_size=-2048; PRAGMA temp_store=FILE; PRAGMA trusted_schema=OFF;")
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA cache_spill=OFF; PRAGMA wal_autocheckpoint=1024; PRAGMA journal_size_limit=8388608; PRAGMA max_page_count=\(max(32, pageLimit));")
        } else { try execute("PRAGMA query_only=ON;") }
    }
    func close() { if let handle { sqlite3_close_v2(handle); self.handle = nil } }
    deinit { close() }
    func execute(_ sql: String) throws {
        guard let handle else { throw NetworkHistoryError.closed }
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw NetworkHistoryError.sqlite(code) }
    }
    func statement(_ sql: String) throws -> HistoryStatement {
        guard let handle else { throw NetworkHistoryError.closed }
        return try .init(database: handle, sql: sql)
    }
    func scalar(_ sql: String) throws -> Int64 {
        let statement = try statement(sql)
        guard try statement.next() else { return 0 }; return statement.integer(0)
    }
    /// Spill is disabled: uncommitted pages stay in the explicitly bounded
    /// cache. Reserve twice the allocated page-cache bytes for WAL frames and
    /// headers before COMMIT; a pinned reader cannot grow WAL past the budget.
    func ensureWriteBudget() throws {
        guard let handle, !readOnly else { throw NetworkHistoryError.closed }
        var bytes: Int32 = 0, peak: Int32 = 0
        guard sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_USED, &bytes, &peak, 0) == SQLITE_OK,
              bytes >= 0, bytes <= 4 * 1_048_576 else { throw NetworkHistoryError.capacity }
        let size = sizes, reserve = Int64(bytes) * 2 + 4096
        let pages = try scalar("PRAGMA page_count"), pageSize = try scalar("PRAGMA page_size")
        guard size.wal + reserve <= 16 * 1_048_576,
              max(size.database, pages * pageSize) + size.wal + reserve <= 512 * 1_048_576 else {
            throw NetworkHistoryError.capacity
        }
    }
    @discardableResult func checkpoint(allowBusy: Bool = false) throws -> Bool {
        guard !readOnly, let handle else { throw NetworkHistoryError.closed }
        let code = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        if allowBusy, code == SQLITE_BUSY || code == SQLITE_LOCKED { return false }
        guard code == SQLITE_OK else { throw NetworkHistoryError.sqlite(code) }
        return true
    }
    var sizes: (database: Int64, wal: Int64) {
        func size(_ path: String) -> Int64 { var s = stat(); return lstat(path, &s) == 0 ? s.st_size : 0 }
        return (size(path.path), size(path.path + "-wal"))
    }
    func protectSidecars() throws {
        for suffix in ["-wal", "-shm"] {
            var info = stat(); let path = path.path + suffix
            if lstat(path, &info) != 0 { continue }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  chmod(path, 0o600) == 0 else { throw NetworkHistoryError.unsafePath }
        }
    }
}

final class HistoryStatement {
    private(set) var handle: OpaquePointer?
    init(database: OpaquePointer, sql: String) throws {
        let code = sqlite3_prepare_v2(database, sql, -1, &handle, nil)
        guard code == SQLITE_OK else { sqlite3_finalize(handle); throw NetworkHistoryError.sqlite(code) }
    }
    deinit { sqlite3_finalize(handle) }
    func bind(_ index: Int32, _ value: Int64) { sqlite3_bind_int64(handle, index, value) }
    func bind(_ index: Int32, _ value: Double) { sqlite3_bind_double(handle, index, value) }
    func bind(_ index: Int32, _ value: String) { sqlite3_bind_text(handle, index, value, -1, HistoryDatabase.transient) }
    func bind(_ index: Int32, _ value: Data) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), HistoryDatabase.transient) }
    }
    func next() throws -> Bool {
        let code = sqlite3_step(handle)
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        throw NetworkHistoryError.sqlite(code)
    }
    func run() throws { guard try !next() else { throw NetworkHistoryError.corrupt } }
    func reset() { sqlite3_reset(handle); sqlite3_clear_bindings(handle) }
    func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(handle, index) }
    func double(_ index: Int32) -> Double { sqlite3_column_double(handle, index) }
    func text(_ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(handle, index) else { return "" }; return String(cString: bytes)
    }
    func data(_ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(handle, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, index)))
    }
}
