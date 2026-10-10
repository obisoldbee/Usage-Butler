import XCTest
import UsageButlerDomain
import UsageButlerCore
@testable import UsageButlerUI

@MainActor final class ApplicationNoteStoreTests: XCTestCase {
    private func identity(_ key: String = "desktop", name: String = "ChatGPT") -> ProcessNetworkApplicationIdentity {
        .init(key: key, name: name, bundleID: "com.example.\(key)", installationPath: "/Applications/\(key).app", evidence: .executableBundle)
    }
    func testSameNameHasIndependentNotesAndNameChangesKeepNote() {
        let store = ApplicationNoteStore(), desktop = identity(), cli = identity("cli")
        XCTAssertTrue(store.save("桌面聊天", for: desktop))
        XCTAssertEqual(store.displayName(for: desktop), "桌面聊天")
        XCTAssertEqual(store.displayName(for: cli), "ChatGPT")
        XCTAssertEqual(store.displayName(for: identity(name: "New Name")), "桌面聊天")
        XCTAssertTrue(store.save("命令行", for: cli))
        XCTAssertEqual(store.displayName(for: desktop), "桌面聊天")
        XCTAssertEqual(store.displayName(for: cli), "命令行")
    }
    func testPersistsTrimsClearsAndPreservesOtherPreferences() throws {
        let suite = "UsageButlerNotesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "network.backgroundHistory.enabled")
        let first = ApplicationNoteStore(defaults: defaults)
        XCTAssertTrue(first.save("  桌面聊天  ", for: identity()))
        let restarted = ApplicationNoteStore(defaults: defaults)
        XCTAssertEqual(restarted.note(for: identity()), "桌面聊天")
        XCTAssertTrue(restarted.save(" \n ", for: identity()))
        XCTAssertNil(ApplicationNoteStore(defaults: defaults).note(for: identity()))
        XCTAssertTrue(defaults.bool(forKey: "network.backgroundHistory.enabled"))
    }
    func testInvalidInputLeavesSavedValueUntouched() {
        let store = ApplicationNoteStore(), app = identity()
        XCTAssertTrue(store.save(String(repeating: "界", count: 60), for: app))
        let valid = store.notes
        for text in [String(repeating: "界", count: 61), "one\ntwo", "a\tb", "x\u{2028}y"] {
            XCTAssertFalse(store.save(text, for: app)); XCTAssertEqual(store.notes, valid)
        }
        XCTAssertFalse(store.save("remark", for: identity("")))
        XCTAssertEqual(store.notes, valid)
    }
    func testOriginalIdentityAndHistoryExportRemainIdentical() throws {
        let store = ApplicationNoteStore(), app = identity()
        let encoded = try JSONEncoder().encode(app)
        let range = HistoryRange(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        let totals = HistoryMinute(upload: 123, download: 456, durationNanoseconds: 1_000_000_000, firstMillisecond: 0, lastMillisecond: 1000).totals
        let result = HistoryQueryResult(range: range, applications: [.init(id: 1, identity: app, totals: totals)], totalApplications: 1, page: 0,
                                       curve: [], days: [], events: [], coverage: .init())
        let exported = try NetworkHistoryExport.encode(result, now: range.end)
        XCTAssertTrue(store.save("私人备注", for: app))
        let decoded = try JSONDecoder().decode(ProcessNetworkApplicationIdentity.self, from: encoded)
        XCTAssertEqual(app, decoded)
        XCTAssertEqual(try NetworkHistoryExport.encode(result, now: range.end), exported)
        XCTAssertEqual(app.name, "ChatGPT")
    }
    func testLiveAndHistoryShareOneStoreWithoutTouchingQueryOrSelection() {
        let store = ApplicationNoteStore()
        let live = ProcessNetworkViewModel(applicationNotes: store)
        let history = BackgroundNetworkViewModel(applicationNotes: store)
        history.search = "ChatGPT"; live.search = "ChatGPT"
        XCTAssertTrue(live.applicationNotes.save("桌面", for: identity()))
        XCTAssertEqual(history.applicationNotes.note(for: identity()), "桌面")
        XCTAssertEqual(history.search, "ChatGPT"); XCTAssertEqual(live.search, "ChatGPT")
        XCTAssertNil(history.selectedApplication); XCTAssertNil(live.selected)
    }
}
