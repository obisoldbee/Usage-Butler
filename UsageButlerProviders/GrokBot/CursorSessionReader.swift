import Foundation
import Darwin
import SQLite3

/// The only supported source. No browser scan, Keychain, database copy or token refresh.
public protocol CursorSessionReading: Sendable {
    func load() async throws -> CursorReadOnlySession?
}

public enum GrokBotReadError: Error, Equatable, Sendable {
    case consentRequired, noSession, invalidSession, expiredSession, unsafeFile, databaseUnavailable
    case identityMismatch, unsupportedEndpoint, redirect, responseTooLarge, schema, quotaUnavailable, http(Int)
}

public struct CursorReadOnlySession: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "[redacted Cursor session]" }
    public var debugDescription: String { description }
    // Deliberately not Codable or CustomStringConvertible.
    let token: String
    let subject: String
    let expiresAt: Date

    public init(token: String, now: Date) throws {
        guard token.utf8.count <= 32_768,
              token.utf8.allSatisfy({ (45...46).contains($0) || (48...57).contains($0) || (65...90).contains($0) || $0 == 95 || (97...122).contains($0) }) else {
            throw GrokBotReadError.invalidSession
        }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { throw GrokBotReadError.invalidSession }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String,
              let rawExpiration = json["exp"] as? NSNumber,
              CFGetTypeID(rawExpiration) != CFBooleanGetTypeID(),
              rawExpiration.doubleValue.isFinite, rawExpiration.doubleValue > 0,
              let subject = Self.normalizedSubject(sub) else { throw GrokBotReadError.invalidSession }
        let expiration = Date(timeIntervalSince1970: rawExpiration.doubleValue)
        guard expiration > now else { throw GrokBotReadError.expiredSession }
        self.token = token; self.subject = subject; self.expiresAt = expiration
    }

    static func normalizedSubject(_ sub: String) -> String? {
        let parts = sub.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count <= 2, let last = parts.last, !last.isEmpty, last.utf8.count <= 256,
              last.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }) else { return nil }
        return String(last)
    }
    var cookie: String { "WorkosCursorSessionToken=\(subject)%3A%3A\(token)" }
}

public struct CursorSQLiteSessionReader: CursorSessionReading {
    public static let relativePath = "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    private let home: URL
    private let now: @Sendable () -> Date
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home; self.now = now
    }
    public func load() async throws -> CursorReadOnlySession? {
        try Task.checkCancellation()
        let database = home.appendingPathComponent(Self.relativePath)
        var path = home
        for component in [""] + Self.relativePath.components(separatedBy: "/") {
            if !component.isEmpty { path.appendPathComponent(component) }
            var status = stat()
            if lstat(path.path, &status) != 0 {
                if errno == ENOENT { return nil }
                throw GrokBotReadError.unsafeFile
            }
            let isDB = path == database
            guard status.st_uid == getuid(), status.st_mode & 0o022 == 0,
                  status.st_mode & S_IFMT == (isDB ? S_IFREG : S_IFDIR),
                  !isDB || (status.st_size > 0 && status.st_size <= 128 * 1024 * 1024) else {
                throw GrokBotReadError.unsafeFile
            }
        }
        // In WAL mode, SQLite must use the current sidecars. Never fall back to immutable.
        let header = try FileHandle(forReadingFrom: database)
        let bytes = try header.read(upToCount: 20) ?? Data()
        try header.close()
        if bytes.count >= 20 && (bytes[18] == 2 || bytes[19] == 2) {
            for suffix in ["-wal", "-shm"] {
                var status = stat()
                guard lstat(database.path + suffix, &status) == 0,
                      status.st_mode & S_IFMT == S_IFREG, status.st_uid == getuid(), status.st_mode & 0o022 == 0 else {
                    throw GrokBotReadError.databaseUnavailable
                }
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw GrokBotReadError.databaseUnavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 65_536)
        sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 1024)
        let deadline = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        deadline.initialize(to: DispatchTime.now().uptimeNanoseconds + 250_000_000)
        defer { sqlite3_progress_handler(db, 0, nil, nil); deadline.deinitialize(count: 1); deadline.deallocate() }
        sqlite3_progress_handler(db, 1000, { pointer in
            guard let pointer else { return 1 }
            return DispatchTime.now().uptimeNanoseconds > pointer.assumingMemoryBound(to: UInt64.self).pointee ? 1 : 0
        }, deadline)
        var statement: OpaquePointer?
        // Fixed key, bounded output. A view or malformed DB cannot extend the query budget.
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw GrokBotReadError.databaseUnavailable
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw GrokBotReadError.databaseUnavailable }
        let type = sqlite3_column_type(statement, 0)
        guard type == SQLITE_TEXT || type == SQLITE_BLOB else { throw GrokBotReadError.invalidSession }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, count <= 65_536, let pointer = sqlite3_column_blob(statement, 0) else { throw GrokBotReadError.invalidSession }
        let value = Data(bytes: pointer, count: count)
        let utf16 = count.isMultiple(of: 2) && stride(from: 1, to: count, by: 2).allSatisfy { value[$0] == 0 }
        guard let token = String(data: value, encoding: utf16 ? .utf16LittleEndian : .utf8), !token.contains("\0") else {
            throw GrokBotReadError.invalidSession
        }
        try Task.checkCancellation()
        return try CursorReadOnlySession(token: token, now: now())
    }
}
