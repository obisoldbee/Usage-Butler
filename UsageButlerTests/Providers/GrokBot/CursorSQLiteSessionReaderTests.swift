import Foundation
import Darwin
import SQLite3
import XCTest
@testable import UsageButlerProviders

@MainActor final class CursorSQLiteSessionReaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_022_400)
    private var homes: [URL] = []
    override func tearDownWithError() throws { for home in homes { try FileManager.default.removeItem(at: home) }; homes = [] }
    private func fixture(value: Data, blob: Bool = false) throws -> (URL, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ub-grok-synthetic-" + UUID().uuidString).resolvingSymlinksInPath()
        homes.append(home)
        let dbURL = home.appendingPathComponent(CursorSQLiteSessionReader.relativePath)
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath:home.path)
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value); INSERT INTO ItemTable VALUES ('unrelated-secret', 'DO_NOT_READ');", nil, nil, nil), SQLITE_OK)
        var stmt: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', ?)", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        value.withUnsafeBytes { bytes in
            if blob { sqlite3_bind_blob(stmt, 1, bytes.baseAddress, Int32(value.count), transient) }
            else { sqlite3_bind_text(stmt, 1, bytes.baseAddress?.assumingMemoryBound(to:CChar.self), Int32(value.count), transient) }
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: dbURL.path)
        return (home, dbURL)
    }
    private func token() -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["sub":"auth0|user_SQLITE_FAKE", "exp":now.addingTimeInterval(3600).timeIntervalSince1970])
        return "e30." + payload.base64EncodedString().replacingOccurrences(of:"+", with:"-").replacingOccurrences(of:"/", with:"_").replacingOccurrences(of:"=", with:"") + ".FAKE"
    }
    private func reader(_ home: URL) -> CursorSQLiteSessionReader { let date = now; return .init(home:home, now:{ date }) }
    func testTEXTIsReadOnlySingleKeyAndCreatesNoJournalOrSidecars() async throws {
        let (home, url) = try fixture(value:Data(token().utf8))
        let before = try Data(contentsOf:url)
        let session = try await reader(home).load()
        XCTAssertEqual(session?.subject,"user_SQLITE_FAKE")
        XCTAssertEqual(try Data(contentsOf:url),before)
        for suffix in ["-journal","-wal","-shm"] { XCTAssertFalse(FileManager.default.fileExists(atPath:url.path+suffix)) }
    }
    func testUTF8BLOBAndUTF16LEBLOBAreDecodedWithoutNullTruncation() async throws {
        for value in [Data(token().utf8), token().data(using:.utf16LittleEndian)!] {
            let (home,_) = try fixture(value:value,blob:true)
            let session = try await reader(home).load(); XCTAssertEqual(session?.subject,"user_SQLITE_FAKE")
        }
    }
    func testInvalidBlobAndOverlargeTokenFailClosed() async throws {
        for value in [Data([255,255,255]),Data("not-a-jwt".utf8),Data(repeating:65,count:65_537)] {
            let (home,_) = try fixture(value:value,blob:true)
            do { _ = try await reader(home).load(); XCTFail("Invalid source must fail") } catch {}
        }
    }
    func testSymlinkDatabaseIsRejected() async throws {
        let (home,url) = try fixture(value:Data(token().utf8)); let moved = url.deletingLastPathComponent().appendingPathComponent("original")
        try FileManager.default.moveItem(at:url,to:moved); try FileManager.default.createSymbolicLink(at:url,withDestinationURL:moved)
        do { _ = try await reader(home).load(); XCTFail("Symlink must fail") } catch { XCTAssertEqual(error as? GrokBotReadError,.unsafeFile) }
    }
    func testWorldWritableDatabaseIsRejectedWithoutChangingPermissions() async throws {
        let (home,url) = try fixture(value:Data(token().utf8)); try FileManager.default.setAttributes([.posixPermissions:0o666],ofItemAtPath:url.path)
        do { _ = try await reader(home).load(); XCTFail("Unsafe mode must fail") } catch { XCTAssertEqual(error as? GrokBotReadError,.unsafeFile) }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as! NSNumber).intValue,0o666)
    }
    func testActiveWALIsObservedWithoutImmutableFallback() async throws {
        let (home,url) = try fixture(value:Data(token().utf8))
        var db:OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path,&db),SQLITE_OK); defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db,"PRAGMA journal_mode=WAL; UPDATE ItemTable SET value=value WHERE key='cursorAuth/accessToken';",nil,nil,nil),SQLITE_OK)
        let session = try await reader(home).load(); XCTAssertEqual(session?.subject,"user_SQLITE_FAKE")
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path+"-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path+"-shm"))
    }
    func testExclusiveLockReturnsSafeFailureAndKeepsDatabase() async throws {
        let (home,url) = try fixture(value:Data(token().utf8))
        var db:OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path,&db),SQLITE_OK); defer { sqlite3_exec(db,"ROLLBACK",nil,nil,nil);sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db,"BEGIN EXCLUSIVE",nil,nil,nil),SQLITE_OK)
        do { _ = try await reader(home).load(); XCTFail("Locked source must fail") } catch { XCTAssertEqual(error as? GrokBotReadError,.databaseUnavailable) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
    }
}
