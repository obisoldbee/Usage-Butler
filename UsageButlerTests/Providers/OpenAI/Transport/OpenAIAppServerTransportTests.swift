import Darwin
import Foundation
import UsageButlerDomain
import XCTest
@testable import UsageButlerProviders

final class OpenAIAppServerTransportTests: XCTestCase {
    func testTransportComposesDirectlyWithExistingProviderAdapter() async throws {
        let process = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{}}"#),
            .line(#"{"id":2,"result":{"account":{"type":"chatgpt","planType":"pro"},"requiresOpenaiAuth":false}}"#),
            .line(#"{"id":3,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":40,"windowDurationMins":10080}}},"rateLimitResetCredits":{"availableCount":0,"details":[]}}}"#)
        ])
        let factory = FakeOpenAIAppServerProcessFactory(processes: [process])
        let transport = makeTransport(factory: factory)
        let adapter = OpenAIProviderAdapter(
            reader: transport,
            now: { Date(timeIntervalSince1970: 1_786_300_000) }
        )

        let result = await adapter.read(scope: .provider)
        guard case let .success(data) = result else {
            return XCTFail("Expected composed adapter success, got \(result)")
        }
        XCTAssertEqual(data.products.map(\.sourceProductID), ["codex"])
        XCTAssertEqual(factory.makeCount(), 1)

        await adapter.shutdown()
        let closeCount = await process.closeCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testPublicBoundaryPerformsHandshakeReturnsOnlyResultObjectAndReusesOneProcess() async throws {
        let process = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{"server":"fixture"}}"#),
            .line(#"{"method":"account/updated","params":{"ignored":true}}"#),
            .line(#"{"id":2,"result":{"account":{"type":"chatgpt","planType":"pro"},"requiresOpenaiAuth":false}}"#),
            .line(#"{"method":"quota/updated"}"#),
            .line(#"{"id":3,"result":{"rateLimitsByLimitId":{},"rateLimitResetCredits":{"availableCount":0,"details":[]}}}"#)
        ])
        let factory = FakeOpenAIAppServerProcessFactory(processes: [process])
        let sleeper = ControlledOpenAITransportSleeper()
        let transport = makeTransport(factory: factory, sleeper: sleeper)

        let accountPayload = try unwrapSuccess(await transport.readAccount())
        let account = try OpenAIAppServerDecoder.decodeAccountRead(from: accountPayload)
        XCTAssertEqual(account.account?.planType, "pro")
        XCTAssertFalse(account.requiresOpenAIAuth)
        let accountObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: accountPayload) as? [String: Any]
        )
        XCTAssertNil(accountObject["id"])

        let rateLimitPayload = try unwrapSuccess(await transport.readRateLimits())
        let rateLimits = try OpenAIAppServerDecoder.decodeRateLimitsRead(from: rateLimitPayload)
        XCTAssertEqual(rateLimits.rateLimitResetCredits?.availableCount, 0)

        let messages = try await process.sentMessages()
        XCTAssertEqual(messages.map(\.method), [
            "initialize", "initialized", "account/read", "account/rateLimits/read"
        ])
        XCTAssertNil(messages[1].id)
        XCTAssertTrue(messages[1].paramsPresent)
        XCTAssertTrue(messages[1].paramsAreEmpty)
        XCTAssertEqual(messages[2].refreshToken, false)
        XCTAssertEqual(factory.makeCount(), 1)
        let initialStartCount = await process.startCount()
        let initialCloseCount = await process.closeCount()
        XCTAssertEqual(initialStartCount, 1)
        XCTAssertEqual(initialCloseCount, 0)

        let launch = try XCTUnwrap(factory.configurations().first)
        XCTAssertEqual(launch.executableURL.path, "/fixture/bin/codex")
        XCTAssertEqual(launch.arguments, ["app-server", "--stdio"])
        XCTAssertEqual(launch.environment["HOME"], "/fixture/home")
        XCTAssertEqual(launch.environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(launch.environment["LC_CTYPE"], "UTF-8")
        XCTAssertEqual(launch.environment["HTTPS_PROXY"], "http://127.0.0.1:7897")
        XCTAssertTrue(launch.environment["PATH"]?.hasPrefix("/fixture/bin:") == true)
        XCTAssertNil(launch.environment["OPENAI_API_KEY"])
        XCTAssertEqual(Set(launch.environment.keys), [
            "PATH", "HOME", "LANG", "LC_CTYPE", "HTTPS_PROXY"
        ])

        await transport.shutdown()
        let shutdownCloseCount = await process.closeCount()
        XCTAssertEqual(shutdownCloseCount, 1)
    }

    func testProductionProxyResolverCopiesOnlyExactAllowlistIntoTransportEnvironment() {
        let expectedProxyEnvironment = [
            "HTTP_PROXY": "http://127.0.0.1:7897",
            "HTTPS_PROXY": "http://127.0.0.1:7897",
            "ALL_PROXY": "socks5://127.0.0.1:7897",
            "NO_PROXY": "127.0.0.1,localhost",
            "http_proxy": "http://127.0.0.1:7898",
            "https_proxy": "http://127.0.0.1:7898",
            "all_proxy": "socks5://127.0.0.1:7898",
            "no_proxy": "::1"
        ]
        var parentEnvironment = expectedProxyEnvironment
        parentEnvironment["PATH"] = "/parent/bin"
        parentEnvironment["HOME"] = "/parent/home"
        parentEnvironment["OPENAI_API_KEY"] = "must-not-reach-child"
        parentEnvironment["CODEX_API_KEY"] = "must-not-reach-child"
        parentEnvironment["Http_Proxy"] = "must-not-reach-child"

        let resolved = OpenAIProxyEnvironmentResolver.resolve(
            environment: parentEnvironment
        )
        XCTAssertEqual(resolved, expectedProxyEnvironment)

        let launchResult = OpenAIAppServerEnvironmentBuilder.makeLaunchConfiguration(
            configuration(explicitProxyEnvironment: resolved)
        )
        guard case let .success(launch) = launchResult else {
            return XCTFail("Expected allowlisted production proxy environment")
        }
        for (key, value) in expectedProxyEnvironment {
            XCTAssertEqual(launch.environment[key], value)
        }
        XCTAssertEqual(
            Set(launch.environment.keys),
            Set(["PATH", "HOME", "LANG", "LC_CTYPE"])
                .union(expectedProxyEnvironment.keys)
        )
        XCTAssertNil(launch.environment["OPENAI_API_KEY"])
        XCTAssertNil(launch.environment["CODEX_API_KEY"])
        XCTAssertNil(launch.environment["Http_Proxy"])
    }

    func testUnknownResponseIDIsTypedProtocolFailureAndNextReadBuildsFreshSession() async throws {
        let failed = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{}}"#),
            .line(#"{"id":999,"result":{"account":null,"requiresOpenaiAuth":true}}"#)
        ])
        let recovered = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{}}"#),
            .line(#"{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus"},"requiresOpenaiAuth":false}}"#)
        ])
        let factory = FakeOpenAIAppServerProcessFactory(processes: [failed, recovered])
        let transport = makeTransport(factory: factory)

        let failure = try unwrapFailure(await transport.readAccount())
        XCTAssertEqual(failure.code, .protocolViolation)
        XCTAssertEqual(failure.diagnosticCode, "openai.transport.account.unknown_response_id")
        let failedCloseCount = await failed.closeCount()
        XCTAssertEqual(failedCloseCount, 1)

        let recoveredPayload = try unwrapSuccess(await transport.readAccount())
        let account = try OpenAIAppServerDecoder.decodeAccountRead(from: recoveredPayload)
        XCTAssertEqual(account.account?.planType, "plus")
        XCTAssertEqual(factory.makeCount(), 2)
        let recoveredRequestIDs = try await recovered.sentMessages().compactMap(\.id)
        XCTAssertEqual(recoveredRequestIDs, [1, 2])
        await transport.shutdown()
    }

    func testInvalidJSONClosesSessionAndDoesNotReconnectInsideTheFailingRead() async throws {
        let process = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{}}"#),
            .line("not-json")
        ])
        let replacement = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{}}"#),
            .line(#"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#)
        ])
        let factory = FakeOpenAIAppServerProcessFactory(processes: [process, replacement])
        let transport = makeTransport(factory: factory)

        let failure = try unwrapFailure(await transport.readAccount())
        XCTAssertEqual(failure.code, .protocolViolation)
        XCTAssertEqual(failure.diagnosticCode, "openai.transport.account.invalid_json")
        let invalidJSONCloseCount = await process.closeCount()
        XCTAssertEqual(invalidJSONCloseCount, 1)
        XCTAssertEqual(factory.makeCount(), 1, "A failed read must not transparently reconnect")

        _ = try unwrapSuccess(await transport.readAccount())
        XCTAssertEqual(factory.makeCount(), 2, "The next independent read may rebuild")
        await transport.shutdown()
    }

    func testInitializeRPCFailureClosesChildAndNextReadBuildsFreshHandshake() async throws {
        let failed = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"error":{"code":-32600,"message":"raw must not escape"}}"#)
        ])
        let recovered = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{}}"#),
            .line(#"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#)
        ])
        let factory = FakeOpenAIAppServerProcessFactory(processes: [failed, recovered])
        let transport = makeTransport(factory: factory)

        let failure = try unwrapFailure(await transport.readAccount())
        XCTAssertEqual(failure.code, .serviceUnavailable)
        XCTAssertEqual(failure.diagnosticCode, "openai.transport.startup.rpc_error.-32600")
        let failedCloseCount = await failed.closeCount()
        XCTAssertEqual(failedCloseCount, 1)
        XCTAssertEqual(factory.makeCount(), 1)

        _ = try unwrapSuccess(await transport.readAccount())
        XCTAssertEqual(factory.makeCount(), 2)
        await transport.shutdown()
    }

    func testEOFClosesSessionAndNextIndependentReadCanRebuild() async throws {
        let failed = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{}}"#),
            .failure(.endOfFile)
        ])
        let recovered = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{}}"#),
            .line(#"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#)
        ])
        let factory = FakeOpenAIAppServerProcessFactory(processes: [failed, recovered])
        let transport = makeTransport(factory: factory)

        let failure = try unwrapFailure(await transport.readAccount())
        XCTAssertEqual(failure.code, .sessionEOF)
        XCTAssertEqual(failure.diagnosticCode, "openai.transport.account.session_eof")
        let eofCloseCount = await failed.closeCount()
        XCTAssertEqual(eofCloseCount, 1)

        _ = try unwrapSuccess(await transport.readAccount())
        XCTAssertEqual(factory.makeCount(), 2)
        await transport.shutdown()
    }

    func testStartupTimeoutIsPhaseTypedReapsAndAllowsLaterRebuild() async throws {
        let timedOut = FakeOpenAIAppServerProcess(events: [])
        let recovered = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{}}"#),
            .line(#"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#)
        ])
        let factory = FakeOpenAIAppServerProcessFactory(processes: [timedOut, recovered])
        let sleeper = ControlledOpenAITransportSleeper()
        let transport = makeTransport(factory: factory, sleeper: sleeper)

        let read = Task { await transport.readAccount() }
        try await waitForActiveSleeps(sleeper, count: 1)
        let activeStartupDurations = await sleeper.activeDurations()
        XCTAssertEqual(activeStartupDurations, [.seconds(15)])
        await sleeper.fireNext()

        let failure = try unwrapFailure(await read.value)
        XCTAssertEqual(failure.code, .timedOut)
        XCTAssertEqual(failure.diagnosticCode, "openai.transport.startup.timeout")
        let startupTimeoutCloseCount = await timedOut.closeCount()
        XCTAssertEqual(startupTimeoutCloseCount, 1)

        _ = try unwrapSuccess(await transport.readAccount())
        XCTAssertEqual(factory.makeCount(), 2)
        await transport.shutdown()
    }

    func testAccountAndRateLimitTimeoutsUseIndependentPhaseBudgets() async throws {
        let accountProcess = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{}}"#)
        ])
        let accountFactory = FakeOpenAIAppServerProcessFactory(processes: [accountProcess])
        let accountSleeper = ControlledOpenAITransportSleeper()
        let accountTransport = makeTransport(factory: accountFactory, sleeper: accountSleeper)
        let accountRead = Task { await accountTransport.readAccount() }
        try await waitForRequestedSleep(accountSleeper, duration: .seconds(15), occurrence: 2)
        await accountSleeper.fireActive(duration: .seconds(15))
        let accountFailure = try unwrapFailure(await accountRead.value)
        XCTAssertEqual(accountFailure.diagnosticCode, "openai.transport.account.timeout")
        let accountTimeoutCloseCount = await accountProcess.closeCount()
        XCTAssertEqual(accountTimeoutCloseCount, 1)

        let rateProcess = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{}}"#),
            .line(#"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#)
        ])
        let rateFactory = FakeOpenAIAppServerProcessFactory(processes: [rateProcess])
        let rateSleeper = ControlledOpenAITransportSleeper()
        let rateTransport = makeTransport(factory: rateFactory, sleeper: rateSleeper)
        _ = try unwrapSuccess(await rateTransport.readAccount())
        let rateRead = Task { await rateTransport.readRateLimits() }
        try await waitForRequestedSleep(rateSleeper, duration: .seconds(30), occurrence: 1)
        await rateSleeper.fireActive(duration: .seconds(30))
        let rateFailure = try unwrapFailure(await rateRead.value)
        XCTAssertEqual(rateFailure.diagnosticCode, "openai.transport.rate_limits.timeout")
        let rateTimeoutCloseCount = await rateProcess.closeCount()
        XCTAssertEqual(rateTimeoutCloseCount, 1)
    }

    func testRPCErrorKeepsRawMessageOutOfFailureAndLeavesSessionReusable() async throws {
        let secret = "token=SUPER-SECRET account@example.invalid /Users/private"
        let process = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{}}"#),
            .line(#"{"id":2,"error":{"code":-32001,"message":"\#(secret)"}}"#),
            .line(#"{"id":3,"result":{"rateLimitsByLimitId":{}}}"#)
        ])
        let factory = FakeOpenAIAppServerProcessFactory(processes: [process])
        let transport = makeTransport(factory: factory)

        let failure = try unwrapFailure(await transport.readAccount())
        XCTAssertEqual(failure.code, .serviceUnavailable)
        XCTAssertEqual(failure.diagnosticCode, "openai.transport.account.rpc_error.-32001")
        XCTAssertFalse(String(describing: failure).contains(secret))
        let rpcErrorCloseCount = await process.closeCount()
        XCTAssertEqual(rpcErrorCloseCount, 0)

        _ = try unwrapSuccess(await transport.readRateLimits())
        XCTAssertEqual(factory.makeCount(), 1)
        await transport.shutdown()
    }

    func testShutdownSealsTransportAndClosesOnlyItsInjectedOwnedProcess() async throws {
        let owned = FakeOpenAIAppServerProcess(events: [
            .line(#"{"id":1,"result":{}}"#),
            .line(#"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#)
        ])
        let neverOwned = FakeOpenAIAppServerProcess(events: [])
        let factory = FakeOpenAIAppServerProcessFactory(processes: [owned, neverOwned])
        let transport = makeTransport(factory: factory)

        _ = try unwrapSuccess(await transport.readAccount())
        await transport.shutdown()
        let ownedCloseCount = await owned.closeCount()
        let neverOwnedCloseCount = await neverOwned.closeCount()
        XCTAssertEqual(ownedCloseCount, 1)
        XCTAssertEqual(neverOwnedCloseCount, 0)

        let failure = try unwrapFailure(await transport.readRateLimits())
        XCTAssertEqual(failure.code, .shutdown)
        XCTAssertEqual(failure.diagnosticCode, "openai.transport.shutdown")
        XCTAssertEqual(factory.makeCount(), 1)
    }

    func testInvalidExecutableAndNonAllowlistedEnvironmentFailBeforeProcessCreation() async throws {
        let factory = FakeOpenAIAppServerProcessFactory(processes: [])
        let invalidURL = try XCTUnwrap(URL(string: "relative/codex"))
        let invalidExecutable = OpenAIAppServerTransport(
            configuration: configuration(executableURL: invalidURL),
            processFactory: factory,
            sleeper: ControlledOpenAITransportSleeper()
        )
        let executableFailure = try unwrapFailure(await invalidExecutable.readAccount())
        XCTAssertEqual(executableFailure.code, .missingExecutable)
        XCTAssertEqual(factory.makeCount(), 0)

        let invalidEnvironment = OpenAIAppServerTransport(
            configuration: configuration(
                explicitProxyEnvironment: ["OPENAI_API_KEY": "must-not-reach-child"]
            ),
            processFactory: factory,
            sleeper: ControlledOpenAITransportSleeper()
        )
        let environmentFailure = try unwrapFailure(await invalidEnvironment.readAccount())
        XCTAssertEqual(environmentFailure.code, .processFailed)
        XCTAssertEqual(
            environmentFailure.diagnosticCode,
            "openai.transport.environment.not_allowlisted"
        )
        XCTAssertEqual(factory.makeCount(), 0)
    }

    func testFoundationProcessDeliversFragmentedInitializeAndMultipleLinesWithinOneSecond() async throws {
        let fixture = try makeLocalExecutable(body: #"""
        pid_file="${FAKE_PID_FILE:?}"
        log_file="${FAKE_LOG_FILE:?}"
        printf '%s' "$$" > "$pid_file"
        while IFS= read -r line; do
            printf '%s\n' "$line" >> "$log_file"
            case "$line" in
                *'"method":"initialize"'*)
                    printf '%s' '{"id":1,"res'
                    /bin/sleep 0.05
                    printf '%s\n' 'ult":{}}'
                    ;;
                *'"method":"initialized"'*)
                    ;;
                *'"method":"account\/read"'*|*'"method":"account/read"'*)
                    printf '%s\n%s\n' \
                        '{"method":"fixture/notice","params":{}}' \
                        '{"id":2,"result":{"account":{"type":"chatgpt","planType":"fixture"},"requiresOpenaiAuth":false}}'
                    ;;
            esac
        done
        """#)
        var ownedPID: pid_t?
        defer {
            terminateLocalProcessIfNeeded(ownedPID)
            try? FileManager.default.removeItem(at: fixture.directoryURL)
        }

        let process = FoundationOpenAIAppServerProcessFactory(
            terminationGracePeriod: .milliseconds(50)
        ).makeProcess(configuration: fixture.launchConfiguration)
        let session = OpenAIAppServerRPCSession(
            process: process,
            sleeper: ContinuousOpenAITransportSleeper()
        )
        let clock = ContinuousClock()
        let startedAt = clock.now
        let startup = await session.startAndInitialize(timeout: .seconds(1))
        let startupElapsed = startedAt.duration(to: clock.now)
        guard case .success = startup else {
            return XCTFail("Expected local Foundation initialize success, got \(startup)")
        }
        XCTAssertLessThan(startupElapsed, .seconds(1))
        ownedPID = try await waitForLocalPID(at: fixture.pidFileURL)

        let accountResult = await session.readAccount(timeout: .seconds(1))
        guard case let .success(accountPayload) = accountResult else {
            let received = (try? String(contentsOf: fixture.logFileURL, encoding: .utf8))
                ?? "<no fixture log>"
            return XCTFail("Unexpected account failure: \(accountResult); child received: \(received)")
        }
        let account = try OpenAIAppServerDecoder.decodeAccountRead(from: accountPayload)
        XCTAssertEqual(account.account?.planType, "fixture")

        await session.shutdown()
        let pid = try XCTUnwrap(ownedPID)
        let childExited = await waitForLocalProcessExit(pid)
        XCTAssertTrue(childExited)
    }

    func testFoundationProcessChildExitWakesPendingInitializeAndLeavesNoOrphan() async throws {
        let fixture = try makeLocalExecutable(body: #"""
        pid_file="${FAKE_PID_FILE:?}"
        printf '%s' "$$" > "$pid_file"
        IFS= read -r _
        exit 0
        """#)
        var ownedPID: pid_t?
        defer {
            terminateLocalProcessIfNeeded(ownedPID)
            try? FileManager.default.removeItem(at: fixture.directoryURL)
        }

        let process = FoundationOpenAIAppServerProcessFactory(
            terminationGracePeriod: .milliseconds(50)
        ).makeProcess(configuration: fixture.launchConfiguration)
        let session = OpenAIAppServerRPCSession(
            process: process,
            sleeper: ContinuousOpenAITransportSleeper()
        )
        let clock = ContinuousClock()
        let startedAt = clock.now
        let startup = await session.startAndInitialize(timeout: .seconds(1))
        let elapsed = startedAt.duration(to: clock.now)
        guard case let .failure(failure) = startup else {
            return XCTFail("Expected local child-exit failure")
        }
        XCTAssertEqual(failure.code, .sessionEOF)
        XCTAssertEqual(failure.diagnosticCode, "openai.transport.startup.session_eof")
        XCTAssertLessThan(elapsed, .seconds(1))

        ownedPID = try await waitForLocalPID(at: fixture.pidFileURL)
        let pid = try XCTUnwrap(ownedPID)
        let childExited = await waitForLocalProcessExit(pid)
        XCTAssertTrue(childExited)
    }

    func testFoundationProcessStartupTimeoutKillsAndReapsTERMResistantChild() async throws {
        let fixture = try makeLocalExecutable(body: #"""
        pid_file="${FAKE_PID_FILE:?}"
        trap '' TERM
        printf '%s' "$$" > "$pid_file"
        while :; do :; done
        """#)
        var ownedPID: pid_t?
        defer {
            terminateLocalProcessIfNeeded(ownedPID)
            try? FileManager.default.removeItem(at: fixture.directoryURL)
        }

        let process = FoundationOpenAIAppServerProcessFactory(
            terminationGracePeriod: .milliseconds(50)
        ).makeProcess(configuration: fixture.launchConfiguration)
        let sleeper = ControlledOpenAITransportSleeper()
        let session = OpenAIAppServerRPCSession(
            process: process,
            sleeper: sleeper
        )
        let startup = Task {
            await session.startAndInitialize(timeout: .milliseconds(100))
        }
        // The fixture writes its PID only after installing the TERM trap. Gate the
        // timeout on both child and sleeper readiness so this always tests KILL/reap.
        ownedPID = try await waitForLocalPID(at: fixture.pidFileURL)
        try await waitForActiveSleeps(sleeper, count: 1)
        let pid = try XCTUnwrap(ownedPID)
        XCTAssertTrue(localProcessExists(pid))

        let clock = ContinuousClock()
        let startedAt = clock.now
        await sleeper.fireNext()
        let result = await startup.value
        let elapsed = startedAt.duration(to: clock.now)

        guard case let .failure(failure) = result else {
            return XCTFail("Expected local startup timeout")
        }
        XCTAssertEqual(failure.code, .timedOut)
        XCTAssertEqual(failure.diagnosticCode, "openai.transport.startup.timeout")
        XCTAssertLessThan(elapsed, .seconds(2))
        let childExited = await waitForLocalProcessExit(pid)
        XCTAssertTrue(childExited)
    }

    func testFoundationProcessCloseBeforeStartIsBoundedAndLaunchesNoChild() async throws {
        let fixture = try makeLocalExecutable(body: #"""
        printf '%s' "$$" > "${FAKE_PID_FILE:?}"
        while :; do :; done
        """#)
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let process = FoundationOpenAIAppServerProcessFactory(
            terminationGracePeriod: .milliseconds(50)
        ).makeProcess(configuration: fixture.launchConfiguration)
        let clock = ContinuousClock()
        let startedAt = clock.now
        await process.close()
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pidFileURL.path))
    }

    private func makeTransport(
        factory: FakeOpenAIAppServerProcessFactory,
        sleeper: ControlledOpenAITransportSleeper = ControlledOpenAITransportSleeper()
    ) -> OpenAIAppServerTransport {
        OpenAIAppServerTransport(
            configuration: configuration(),
            processFactory: factory,
            sleeper: sleeper
        )
    }

    private func configuration(
        executableURL: URL = URL(fileURLWithPath: "/fixture/bin/codex"),
        explicitProxyEnvironment: [String: String] = [
            "HTTPS_PROXY": "http://127.0.0.1:7897"
        ]
    ) -> OpenAIAppServerTransportConfiguration {
        OpenAIAppServerTransportConfiguration(
            executableURL: executableURL,
            homeDirectoryURL: URL(fileURLWithPath: "/fixture/home", isDirectory: true),
            sourceIdentity: ProviderSourceIdentity(
                providerID: .openAI,
                adapterID: "openai.codex-app-server",
                executableIdentity: "selected-codex-fixture",
                cliVersion: "fixture",
                schemaVersion: "account-rate-limits-v1",
                contractVersion: "usage-butler-provider-contract-v0.8"
            ),
            explicitProxyEnvironment: explicitProxyEnvironment
        )
    }

    private func makeLocalExecutable(body: String) throws -> LocalOpenAIExecutableFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageButlerOpenAI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let executableURL = directoryURL.appendingPathComponent("fake-codex")
        let pidFileURL = directoryURL.appendingPathComponent("child.pid")
        try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executableURL.path
        )
        return LocalOpenAIExecutableFixture(
            directoryURL: directoryURL,
            executableURL: executableURL,
            pidFileURL: pidFileURL
        )
    }

    private func waitForLocalPID(
        at pidFileURL: URL,
        timeout: Duration = .seconds(1)
    ) async throws -> pid_t {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let data = try? Data(contentsOf: pidFileURL),
               let text = String(data: data, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0 {
                return pid
            }
            try await clock.sleep(for: .milliseconds(5))
        }
        throw OpenAITransportTestError.waitTimedOut
    }

    private func waitForLocalProcessExit(
        _ pid: pid_t,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if !localProcessExists(pid) { return true }
            try? await clock.sleep(for: .milliseconds(5))
        }
        return !localProcessExists(pid)
    }

    private func localProcessExists(_ pid: pid_t) -> Bool {
        errno = 0
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func terminateLocalProcessIfNeeded(_ pid: pid_t?) {
        guard let pid, localProcessExists(pid) else { return }
        _ = Darwin.kill(pid, SIGKILL)
    }

    private func unwrapSuccess(
        _ result: Result<Data, ProviderFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        switch result {
        case let .success(data):
            return data
        case let .failure(failure):
            XCTFail("Unexpected failure: \(failure)", file: file, line: line)
            throw OpenAITransportTestError.unexpectedFailure
        }
    }

    private func unwrapFailure(
        _ result: Result<Data, ProviderFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ProviderFailure {
        switch result {
        case .success:
            XCTFail("Expected failure", file: file, line: line)
            throw OpenAITransportTestError.unexpectedSuccess
        case let .failure(failure):
            return failure
        }
    }

    private func waitForActiveSleeps(
        _ sleeper: ControlledOpenAITransportSleeper,
        count: Int
    ) async throws {
        for _ in 0..<10_000 {
            if await sleeper.activeDurations().count == count { return }
            await Task.yield()
        }
        throw OpenAITransportTestError.waitTimedOut
    }

    private func waitForRequestedSleep(
        _ sleeper: ControlledOpenAITransportSleeper,
        duration: Duration,
        occurrence: Int
    ) async throws {
        for _ in 0..<10_000 {
            if await sleeper.hasOnlyActiveSleep(duration: duration, occurrence: occurrence) {
                return
            }
            await Task.yield()
        }
        throw OpenAITransportTestError.waitTimedOut
    }
}

private struct LocalOpenAIExecutableFixture {
    let directoryURL: URL
    let executableURL: URL
    let pidFileURL: URL

    var logFileURL: URL {
        directoryURL.appendingPathComponent("child.log")
    }

    var launchConfiguration: OpenAIAppServerLaunchConfiguration {
        OpenAIAppServerLaunchConfiguration(
            executableURL: executableURL,
            environment: [
                "PATH": "/usr/bin:/bin",
                "HOME": directoryURL.path,
                "LANG": "en_US.UTF-8",
                "LC_CTYPE": "UTF-8",
                "FAKE_PID_FILE": pidFileURL.path,
                "FAKE_LOG_FILE": logFileURL.path
            ]
        )
    }
}

private struct CapturedRPCMessage: Equatable, Sendable {
    let id: Int64?
    let method: String
    let paramsPresent: Bool
    let paramsAreEmpty: Bool
    let refreshToken: Bool?
}

private enum FakeOpenAIProcessEvent: Sendable {
    case line(String)
    case failure(OpenAIAppServerProcessError)
}

private actor FakeOpenAIAppServerProcess: OpenAIAppServerProcess {
    private var events: [FakeOpenAIProcessEvent]
    private var lineWaiters: [CheckedContinuation<Result<Data, OpenAIAppServerProcessError>, Never>] = []
    private var sent: [Data] = []
    private var starts = 0
    private var closes = 0
    private var closed = false

    init(events: [FakeOpenAIProcessEvent]) {
        self.events = events
    }

    func start() async -> Result<Void, OpenAIAppServerProcessError> {
        starts += 1
        return closed ? .failure(.closed) : .success(())
    }

    func writeLine(_ line: Data) async -> Result<Void, OpenAIAppServerProcessError> {
        guard !closed else { return .failure(.closed) }
        sent.append(line)
        return .success(())
    }

    func nextLine() async -> Result<Data, OpenAIAppServerProcessError> {
        if !events.isEmpty {
            switch events.removeFirst() {
            case let .line(line): return .success(Data(line.utf8))
            case let .failure(failure): return .failure(failure)
            }
        }
        if closed { return .failure(.closed) }
        return await withCheckedContinuation { continuation in
            lineWaiters.append(continuation)
        }
    }

    func safeStandardErrorSummary() async -> OpenAIStandardErrorSummary {
        OpenAIStandardErrorSummary(byteCount: 0, lineCount: 0, classification: .empty)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        closes += 1
        let waiters = lineWaiters
        lineWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: .failure(.closed))
        }
    }

    func sentMessages() throws -> [CapturedRPCMessage] {
        try sent.map { data in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let params = object["params"] as? [String: Any]
            return CapturedRPCMessage(
                id: (object["id"] as? NSNumber)?.int64Value,
                method: try XCTUnwrap(object["method"] as? String),
                paramsPresent: object.keys.contains("params"),
                paramsAreEmpty: params?.isEmpty == true,
                refreshToken: params?["refreshToken"] as? Bool
            )
        }
    }

    func startCount() -> Int { starts }
    func closeCount() -> Int { closes }
}

private final class FakeOpenAIAppServerProcessFactory: OpenAIAppServerProcessFactory,
    @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [FakeOpenAIAppServerProcess]
    private var capturedConfigurations: [OpenAIAppServerLaunchConfiguration] = []

    init(processes: [FakeOpenAIAppServerProcess]) {
        self.processes = processes
    }

    func makeProcess(
        configuration: OpenAIAppServerLaunchConfiguration
    ) -> any OpenAIAppServerProcess {
        lock.lock()
        defer { lock.unlock() }
        capturedConfigurations.append(configuration)
        guard !processes.isEmpty else {
            return FakeOpenAIAppServerProcess(events: [.failure(.launchFailed)])
        }
        return processes.removeFirst()
    }

    func makeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedConfigurations.count
    }

    func configurations() -> [OpenAIAppServerLaunchConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return capturedConfigurations
    }
}

private actor ControlledOpenAITransportSleeper: OpenAITransportSleeper {
    private struct Waiter {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var requested: [Duration] = []
    private var waiters: [UUID: Waiter] = [:]
    private var order: [UUID] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        requested.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(duration: duration, continuation: continuation)
                order.append(id)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func fireNext() {
        guard let id = order.first else { return }
        resume(id: id, result: .success(()))
    }

    func fireActive(duration: Duration) {
        guard let id = order.first(where: { waiters[$0]?.duration == duration }) else { return }
        resume(id: id, result: .success(()))
    }

    func hasOnlyActiveSleep(duration: Duration, occurrence: Int) -> Bool {
        requested.filter { $0 == duration }.count >= occurrence
            && activeDurations() == [duration]
    }

    func activeDurations() -> [Duration] {
        order.compactMap { waiters[$0]?.duration }
    }

    private func cancel(id: UUID) {
        resume(id: id, result: .failure(CancellationError()))
    }

    private func resume(id: UUID, result: Result<Void, Error>) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        waiter.continuation.resume(with: result)
    }
}

private enum OpenAITransportTestError: Error {
    case unexpectedFailure
    case unexpectedSuccess
    case waitTimedOut
}
