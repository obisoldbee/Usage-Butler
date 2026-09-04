import Foundation
import UsageButlerCore
import UsageButlerDomain
import XCTest
@testable import UsageButlerProviders

/// Real controller, Ark adapter and expiry reader; only the CLI process and
/// its private temporary identity store are fixtures. Never touches user auth.
final class ArkReauthorizationFlowTests: XCTestCase {
    func testWarningCanReauthorizeBeforeExpiryAndReadNewDeadline() async throws {
        try await exerciseLogin(extendsSession: true)
    }

    func testNonzeroPostCallbackRecoveryUsesOneFreshAuthenticationProbe() async throws {
        try await exerciseLogin(extendsSession: true, loginExitCode: 1)
    }

    func testSuccessfulCLIExitAloneDoesNotClearWarning() async throws {
        try await exerciseLogin(extendsSession: false)
    }

    func testExternalLoginIsObservedByNormalQuotaRefresh() async throws {
        let now = ControllerFixture.fixedDate
        let process = try ArkReauthorizationProcess(now: now, extendsSession: true)
        defer { try? FileManager.default.removeItem(at: process.home) }
        let controller = try makeController(process: process, now: now)
        _ = await controller.send(.start)
        guard case .warning = await controller.projection().state.authentication else {
            return XCTFail("fixture must start inside the warning window")
        }

        try await process.replaceExpiration(now.addingTimeInterval(172_800))
        _ = await controller.send(.refresh(.manual(scope: .provider)))
        let refreshed = await controller.projection().state
        guard case let .healthy(evidence) = refreshed.authentication else {
            return XCTFail("normal quota refresh must observe an external login")
        }
        XCTAssertEqual(evidence.expiresAt, now.addingTimeInterval(172_800))
        let commands = await process.commands()
        XCTAssertFalse(commands.contains(["auth", "login", "volc-sso"]))
        _ = await controller.send(.shutdown)
    }

    private func exerciseLogin(
        extendsSession: Bool,
        loginExitCode: Int32 = 0
    ) async throws {
        let now = ControllerFixture.fixedDate
        let process = try ArkReauthorizationProcess(
            now: now,
            extendsSession: extendsSession,
            loginExitCode: loginExitCode
        )
        defer { try? FileManager.default.removeItem(at: process.home) }
        let controller = try makeController(process: process, now: now)
        _ = await controller.send(.start)
        let before = await controller.projection().state
        XCTAssertEqual(before.connection, .connected(observedAt: now))
        guard case .warning = before.authentication else {
            return XCTFail("login must be available while the session still works")
        }
        _ = await controller.send(.login)
        let after = await controller.projection().state
        XCTAssertEqual(after.connection, .connected(observedAt: now))
        guard case .fresh = after.freshness else { return XCTFail("must verify quota after login") }
        if extendsSession {
            guard case let .healthy(evidence) = after.authentication else {
                return XCTFail("must use the replacement session deadline")
            }
            XCTAssertEqual(evidence.expiresAt, now.addingTimeInterval(172_800))
            XCTAssertEqual(LoginRecoveryVerifier.classify(after), .verifiedFresh)
        } else {
            guard case let .warning(evidence) = after.authentication else {
                return XCTFail("process exit alone must not manufacture renewed auth")
            }
            XCTAssertEqual(evidence.expiresAt, now.addingTimeInterval(3_600))
            XCTAssertEqual(
                LoginRecoveryVerifier.classify(after),
                .authorizationNotRenewed
            )
        }
        let commands = await process.commands()
        XCTAssertEqual(commands.filter { $0 == ["auth", "login", "volc-sso"] }.count, 1)
        let loginIndex = try XCTUnwrap(commands.firstIndex(of: ["auth", "login", "volc-sso"]))
        let commandsAfterLogin = commands.dropFirst(loginIndex + 1)
        XCTAssertEqual(
            commandsAfterLogin.filter { $0 == ["auth", "status", "--format", "json"] }.count,
            1
        )
        XCTAssertTrue(commandsAfterLogin.contains(["usage", "plan", "--format", "json"]))
        _ = await controller.send(.shutdown)
    }

    private func makeController(process: ArkReauthorizationProcess, now: Date) throws -> ProviderController {
        let executable = URL(fileURLWithPath: "/fixture/bin/arkcli")
        let reader = ArkAuthenticationStatusReader(
            processClient: process, executableURL: executable,
            sessionExpiryReader: ArkSessionExpiryReader(homeDirectory: process.home), now: { now }
        )
        let adapter = ArkProviderAdapter(
            processClient: process, authenticationStatusReader: reader,
            executableURL: executable, now: { now }
        )
        let clock = TestClock(wallTime: now)
        return try ProviderController(
            initialState: ProviderBootstrap.initialState(id: .ark, capabilities: adapter.capabilities, now: now),
            initiallyEnabled: true, adapter: adapter, cache: FakeProviderQuotaCache(),
            clock: clock, scheduler: RefreshScheduler(clock: clock)
        )
    }
}

private actor ArkReauthorizationProcess: ChildProcessClient {
    nonisolated let home: URL
    private let now: Date
    private let extendsSession: Bool
    private let loginExitCode: Int32
    private var requests: [[String]] = []

    init(now: Date, extendsSession: Bool, loginExitCode: Int32 = 0) throws {
        self.now = now
        self.extendsSession = extendsSession
        self.loginExitCode = loginExitCode
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent(".arkcli/identities/volc-123")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"trn":"test-owner","source":"arkcli"}"#.utf8)
            .write(to: directory.appendingPathComponent("metadata.json"))
        try Self.writeExpiration(now.addingTimeInterval(3_600), home: home)
    }

    func run(_ request: ChildProcessRequest) async -> Result<ChildProcessOutput, ProviderFailure> {
        requests.append(request.arguments)
        let json: String
        let exitCode: Int32
        switch request.arguments {
        case ["auth", "status", "--format", "json"]:
            json = #"{"control_plane_auth":{"status":"ok"},"active_profile":{"owner_trn":"test-owner"},"volc_sso":{"identity":{"account_id":"123","trn":"test-owner"}}}"#
            exitCode = 0
        case ["usage", "plan", "--format", "json"]:
            json = #"{"items":[{"product":"agent-plan","subscribed":false,"periods":[]},{"product":"coding-plan","subscribed":false,"periods":[]}]}"#
            exitCode = 0
        case ["auth", "login", "volc-sso"]:
            if extendsSession {
                do { try replaceExpiration(now.addingTimeInterval(172_800)) }
                catch { return .failure(ControllerFixture.failure(retryClass: .never)) }
            }
            json = "{}"
            exitCode = loginExitCode
        default:
            return .failure(ControllerFixture.failure(retryClass: .never))
        }
        return .success(ChildProcessOutput(
            termination: .exited(code: exitCode),
            standardOutput: Data(json.utf8),
            redactedStandardError: Data()
        ))
    }

    func commands() -> [[String]] { requests }
    func shutdown() async {}
    func replaceExpiration(_ date: Date) throws { try Self.writeExpiration(date, home: home) }

    private static func writeExpiration(_ date: Date, home: URL) throws {
        let payload = try JSONSerialization.data(withJSONObject: ["exp": date.timeIntervalSince1970])
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        try JSONSerialization.data(withJSONObject: ["refresh_token": "e30.\(payload).signature"])
            .write(to: home.appendingPathComponent(".arkcli/identities/volc-123/token.json"), options: .atomic)
    }
}
