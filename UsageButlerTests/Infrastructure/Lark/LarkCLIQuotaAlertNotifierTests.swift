import XCTest
import UsageButlerCore
import UsageButlerDomain
import UsageButlerInfrastructure

final class LarkCLIQuotaAlertNotifierTests: XCTestCase {
    private actor FakeLarkProcessClient: ChildProcessClient {
        private(set) var requests: [ChildProcessRequest] = []
        private let result: Result<ChildProcessOutput, ProviderFailure>

        init(result: Result<ChildProcessOutput, ProviderFailure>) {
            self.result = result
        }

        func run(_ request: ChildProcessRequest) async -> Result<ChildProcessOutput, ProviderFailure> {
            requests.append(request)
            return result
        }

        func shutdown() async {}
    }

    private let payload = QuotaAlertPayload(
        title: "额度已用完",
        bodyLines: ["火山方舟 · prod-1：已用 100%"]
    )

    private var expectedText: String {
        "额度已用完\n火山方舟 · prod-1：已用 100%\n-- 额度管家 Usage-Butler"
    }

    private func successOutput(_ stdout: String) -> Result<ChildProcessOutput, ProviderFailure> {
        .success(
            ChildProcessOutput(
                termination: .exited(code: 0),
                standardOutput: Data(stdout.utf8),
                redactedStandardError: Data()
            )
        )
    }

    private func makeNotifier(
        result: Result<ChildProcessOutput, ProviderFailure>,
        baseEnvironment: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/tester"
        ],
        chatID: String = "oc_test_chat"
    ) async -> (LarkCLIQuotaAlertNotifier, FakeLarkProcessClient) {
        let client = FakeLarkProcessClient(result: result)
        guard let notifier = LarkCLIQuotaAlertNotifier(
            processClient: client,
            executableURL: URL(fileURLWithPath: "/fake/lark-cli"),
            baseEnvironment: baseEnvironment,
            chatID: chatID
        ) else {
            preconditionFailure("Test chat ID must be valid")
        }
        return (notifier, client)
    }

    private func makeStatusReader(
        result: Result<ChildProcessOutput, ProviderFailure>,
        baseEnvironment: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/tester"
        ],
        isDestinationConfigured: Bool = true
    ) async -> (LarkCLIQuotaAlertStatusReader, FakeLarkProcessClient) {
        let client = FakeLarkProcessClient(result: result)
        let reader = LarkCLIQuotaAlertStatusReader(
            processClient: client,
            executableURL: URL(fileURLWithPath: "/fake/lark-cli"),
            baseEnvironment: baseEnvironment,
            isDestinationConfigured: isDestinationConfigured
        )
        return (reader, client)
    }

    func testRequestMatchesCLIContract() async throws {
        let (notifier, client) = await makeNotifier(result: successOutput(#"{"ok":true}"#))

        let sendResult = await notifier.send(payload)
        guard case .success = sendResult else {
            XCTFail("exit 0 with ok:true must succeed, got: \(sendResult)")
            return
        }

        let requests = await client.requests
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.executableURL, URL(fileURLWithPath: "/fake/lark-cli"))
        XCTAssertEqual(
            request.arguments,
            [
                "im", "+messages-send",
                "--as", "bot",
                "--chat-id", "oc_test_chat",
                "--text", expectedText,
                "--format", "json"
            ]
        )
        XCTAssertEqual(
            request.environment,
            [
                "PATH": "/usr/bin:/bin",
                "HOME": "/Users/tester",
                "LARKSUITE_CLI_NO_UPDATE_NOTIFIER": "1",
                "LARKSUITE_CLI_NO_SKILLS_NOTIFIER": "1"
            ]
        )
        XCTAssertNil(request.standardInput)
        XCTAssertEqual(request.limits.timeout, .seconds(20))
        XCTAssertEqual(request.limits.standardOutputByteLimit, 64 * 1024)
        XCTAssertEqual(request.limits.standardErrorByteLimit, 16 * 1024)
        XCTAssertEqual(request.limits.lineLimit, 400)
    }

    func testExitZeroWithOkTrueSucceeds() async {
        let (notifier, _) = await makeNotifier(result: successOutput(#"{"ok":true}"#))

        let result = await notifier.send(payload)

        guard case .success = result else {
            XCTFail("exit 0 with ok:true must succeed, got: \(result)")
            return
        }
    }

    func testOkFalseEnvelopeIsRejectedAsTypedFailure() async {
        let (notifier, _) = await makeNotifier(result: successOutput(#"{"ok":false}"#))

        guard case let .failure(failure) = await notifier.send(payload) else {
            XCTFail("ok:false must be a typed failure")
            return
        }
        XCTAssertEqual(failure.code, .processFailed)
        XCTAssertEqual(failure.retryClass, .backoff)
        XCTAssertEqual(failure.userMessageKey, "quota.alert.lark.delivery_rejected")
        XCTAssertEqual(failure.diagnosticCode, "quotaAlert.lark.ok_false")
        XCTAssertEqual(failure.recovery, .retry)
    }

    func testNonJSONStdoutIsRejected() async {
        let (notifier, _) = await makeNotifier(result: successOutput("sent! (no json)"))

        guard case let .failure(failure) = await notifier.send(payload) else {
            XCTFail("non-JSON stdout must be a typed failure")
            return
        }
        XCTAssertEqual(failure.diagnosticCode, "quotaAlert.lark.ok_false")
    }

    func testClientFailurePassesThroughUnchanged() async {
        let clientFailure = ProviderFailure(
            code: .timedOut,
            retryClass: .backoff,
            userMessageKey: "test.timeout",
            diagnosticCode: "process.timeout.20s",
            recovery: .retry
        )
        let (notifier, _) = await makeNotifier(result: .failure(clientFailure))

        let result = await notifier.send(payload)

        XCTAssertEqual(result.failureValue, clientFailure)
    }

    func testChatIDOverrideAppearsInArguments() async throws {
        let (notifier, client) = await makeNotifier(
            result: successOutput(#"{"ok":true}"#),
            chatID: "oc_override_chat"
        )

        _ = await notifier.send(payload)

        let requests = await client.requests
        let arguments = try XCTUnwrap(requests.last).arguments
        let chatIDIndex = try XCTUnwrap(arguments.firstIndex(of: "--chat-id"))
        XCTAssertEqual(arguments[chatIDIndex + 1], "oc_override_chat")
    }

    func testChatIDConfigurationTrimsAndRejectsUnsafeValues() {
        XCTAssertEqual(
            LarkQuotaAlertConfiguration.validatedChatID("  oc_test_chat\n"),
            "oc_test_chat"
        )
        XCTAssertNil(LarkQuotaAlertConfiguration.validatedChatID(nil))
        XCTAssertNil(LarkQuotaAlertConfiguration.validatedChatID(" \n\t "))
        XCTAssertNil(LarkQuotaAlertConfiguration.validatedChatID("oc_test chat"))
        XCTAssertNil(LarkQuotaAlertConfiguration.validatedChatID("oc_test\nchat"))
        XCTAssertNil(
            LarkQuotaAlertConfiguration.validatedChatID(
                String(repeating: "a", count: 257)
            )
        )
    }

    func testNotifierRejectsInvalidChatID() {
        let client = FakeLarkProcessClient(result: successOutput(#"{"ok":true}"#))

        XCTAssertNil(
            LarkCLIQuotaAlertNotifier(
                processClient: client,
                executableURL: URL(fileURLWithPath: "/fake/lark-cli"),
                baseEnvironment: [:],
                chatID: "oc_test chat"
            )
        )
    }

    func testBaseEnvironmentOverridesFlagDefaultsOnConflict() async throws {
        let (notifier, client) = await makeNotifier(
            result: successOutput(#"{"ok":true}"#),
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "LARKSUITE_CLI_NO_SKILLS_NOTIFIER": "0"
            ]
        )

        _ = await notifier.send(payload)

        let requests = await client.requests
        let environment = try XCTUnwrap(requests.last).environment
        XCTAssertEqual(
            environment,
            [
                "PATH": "/usr/bin:/bin",
                "LARKSUITE_CLI_NO_UPDATE_NOTIFIER": "1",
                "LARKSUITE_CLI_NO_SKILLS_NOTIFIER": "0"
            ],
            "An explicit base value must win over the notifier's flag default"
        )
    }

    func testStatusReaderChecksBotIdentityWithReadOnlyCLICommand() async throws {
        let (reader, client) = await makeStatusReader(
            result: successOutput(
                #"{"identities":{"bot":{"status":"ready","available":true}}}"#
            )
        )

        let status = await reader.read()

        XCTAssertEqual(status, .ready)
        let requests = await client.requests
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.arguments, ["auth", "status", "--json"])
        XCTAssertEqual(
            request.environment,
            [
                "PATH": "/usr/bin:/bin",
                "HOME": "/Users/tester",
                "LARKSUITE_CLI_NO_UPDATE_NOTIFIER": "1",
                "LARKSUITE_CLI_NO_SKILLS_NOTIFIER": "1"
            ]
        )
        XCTAssertNil(request.standardInput)
    }

    func testStatusReaderReportsBotThatNeedsSetup() async {
        let (reader, _) = await makeStatusReader(
            result: successOutput(
                #"{"identities":{"bot":{"status":"not_configured","available":false}}}"#
            )
        )

        let status = await reader.read()

        XCTAssertEqual(status, .needsSetup)
    }

    func testStatusReaderRequiresConfiguredDestinationEvenWhenBotIsReady() async {
        let (reader, _) = await makeStatusReader(
            result: successOutput(
                #"{"identities":{"bot":{"status":"ready","available":true}}}"#
            ),
            isDestinationConfigured: false
        )

        let status = await reader.read()

        XCTAssertEqual(status, .needsChatID)
    }

    private final class TestBox<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    func testStatusReaderEvaluatesDestinationConfiguredDynamically() async {
        let configured = TestBox(false)
        let client = FakeLarkProcessClient(
            result: successOutput(
                #"{"identities":{"bot":{"status":"ready","available":true}}}"#
            )
        )
        let reader = LarkCLIQuotaAlertStatusReader(
            processClient: client,
            executableURL: URL(fileURLWithPath: "/fake/lark-cli"),
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/tester"],
            isDestinationConfigured: { configured.value }
        )

        let statusBefore = await reader.read()
        XCTAssertEqual(statusBefore, .needsChatID)

        configured.value = true
        let statusAfter = await reader.read()
        XCTAssertEqual(statusAfter, .ready)
    }

    func testNotifierResolvesChatIDDynamically() async {
        let currentChatID = TestBox<String?>(nil)
        let client = FakeLarkProcessClient(result: successOutput(#"{"ok":true}"#))
        let notifier = LarkCLIQuotaAlertNotifier(
            processClient: client,
            executableURL: URL(fileURLWithPath: "/fake/lark-cli"),
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/tester"],
            chatIDProvider: { currentChatID.value }
        )

        let missingResult = await notifier.send(payload)
        guard case let .failure(failure) = missingResult else {
            XCTFail("Missing chat ID must fail")
            return
        }
        XCTAssertEqual(failure.diagnosticCode, "quotaAlert.lark.chat_id_missing")

        currentChatID.value = "oc_dynamic_chat"
        let successResult = await notifier.send(payload)
        guard case .success = successResult else {
            XCTFail("Configured chat ID must succeed")
            return
        }
    }

    func testStatusReaderTreatsAuthErrorEnvelopeAsNeedsSetup() async {
        let (reader, _) = await makeStatusReader(
            result: successOutput(#"{"ok":false,"error":{"type":"auth"}}"#)
        )

        let status = await reader.read()

        XCTAssertEqual(status, .needsSetup)
    }

    func testStatusReaderReportsMalformedOutputAndProcessFailureAsUnavailable() async {
        let (malformedReader, _) = await makeStatusReader(
            result: successOutput("not-json")
        )
        let processFailure = ProviderFailure(
            code: .timedOut,
            retryClass: .backoff,
            userMessageKey: "test.timeout",
            diagnosticCode: "process.timeout.20s",
            recovery: .retry
        )
        let (failedReader, _) = await makeStatusReader(
            result: .failure(processFailure)
        )

        let malformedStatus = await malformedReader.read()
        let failedStatus = await failedReader.read()

        XCTAssertEqual(malformedStatus, .unavailable)
        XCTAssertEqual(failedStatus, .unavailable)
    }
}

private extension Result {
    var failureValue: Failure? {
        guard case let .failure(failure) = self else { return nil }
        return failure
    }
}
