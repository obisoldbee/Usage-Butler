import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain
@testable import UsageButlerInfrastructure

final class ProviderDiagnosticJournalTests: XCTestCase {
    private func directory() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("diagnostic-test-\(UUID().uuidString)", isDirectory: true)
    }

    func testFailureSurvivesRestartThenRecordsOneRecovery() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let store = ProviderDiagnosticJournal(directory: directory)
        await store.record(.init(providerID: .miniMax, stage: .quota, reason: .unsupportedStatus, timestamp: now,
            retryAt: now.addingTimeInterval(60), retryGate: .backoff, automaticRetry: true, model: "general", window: "current", values: ["current_interval_status": 2]))
        let reopened = ProviderDiagnosticJournal(directory: directory)
        await reopened.record(.init(providerID: .miniMax, stage: .recovery, reason: .recovered, timestamp: now.addingTimeInterval(1)))
        await reopened.record(.init(providerID: .miniMax, stage: .recovery, reason: .recovered, timestamp: now.addingTimeInterval(2)))
        let saved = await reopened.snapshot(now: now.addingTimeInterval(3))
        XCTAssertEqual(saved.state, .ready)
        XCTAssertEqual(saved.events.map(\.reason), [.unsupportedStatus, .recovered])
        XCTAssertEqual(saved.events.first?.retryGate, .backoff)
        XCTAssertEqual(saved.events.first?.automaticRetry, true)
        XCTAssertNotNil(saved.events.first?.retryAt)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(ProviderDiagnosticJournal.fileName).path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRetentionBoundsPersistAndAgeOutOnRead() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(); let store = ProviderDiagnosticJournal(directory: directory)
        for i in 0..<205 {
            await store.record(.init(providerID: .ark, stage: .runtime, reason: .providerFailure, timestamp: now.addingTimeInterval(Double(i))))
        }
        let snapshot = await store.snapshot(now: now.addingTimeInterval(205))
        XCTAssertEqual(snapshot.events.count, 200)
        let aged = await store.snapshot(now: now.addingTimeInterval(8 * 86400))
        XCTAssertEqual(aged.events.count, 0)
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(ProviderDiagnosticJournal.fileName))) as? [Any]
        XCTAssertEqual(decoded?.count, 0)
    }

    func testUnknownStringsAndNonfiniteNumbersCannotEnterEvidence() throws {
        let event = ProviderDiagnosticEvent(providerID: .miniMax, stage: .quota, reason: .unsupportedModel,
            cliVersion: "secret@example.com", executableSHA256: "/Users/private/token",
            fieldPath: "$.model_remains.Index 0.private@example.com", model: "private@example.com", window: "secret",
            values: ["token": 42, "current_interval_status": 2, "current_interval_remaining_percent": .infinity])
        let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(text.contains("private")); XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("token"))
        XCTAssertEqual(event.values, ["current_interval_status": 2])
        XCTAssertEqual(event.model, "unknown")
        XCTAssertEqual(event.fieldPath, "$.model_remains.row.unknown.unknown")
    }

    func testSymlinkDestinationIsRejectedWithoutOverwritingTarget() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(ProviderDiagnosticJournal.fileName), withDestinationURL: target)
        let store = ProviderDiagnosticJournal(directory: directory)
        await store.record(.init(providerID: .miniMax, stage: .json, reason: .invalidJSON))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.state, .unavailable)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }
}
