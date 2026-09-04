import Darwin
import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain
@testable import UsageButlerInfrastructure

final class OneShotChildProcessClientTests: XCTestCase {
    func testArgumentsEnvironmentAndOptionalStandardInputAreExact() async throws {
        let client = OneShotChildProcessClient()

        let argumentOutput = try unwrapSuccess(
            await client.run(
                request(
                    executable: "/usr/bin/printf",
                    arguments: ["%s|%s", "alpha", "beta"]
                )
            )
        )
        XCTAssertEqual(String(decoding: argumentOutput.standardOutput, as: UTF8.self), "alpha|beta")

        let environmentOutput = try unwrapSuccess(
            await client.run(
                request(
                    executable: "/usr/bin/env",
                    environment: [
                        "PATH": "/usr/bin:/bin",
                        "LANG": "C"
                    ]
                )
            )
        )
        let environmentLines = Set(
            String(decoding: environmentOutput.standardOutput, as: UTF8.self)
                .split(separator: "\n")
                .map(String.init)
        )
        XCTAssertEqual(
            environmentLines,
            Set(["PATH=/usr/bin:/bin", "LANG=C"]),
            "The child must receive only the request allowlist, never the parent environment."
        )

        let payload = Data([0x00, 0x01, 0x0A, 0xFF, 0x41])
        let stdinOutput = try unwrapSuccess(
            await client.run(
                request(executable: "/bin/cat", standardInput: payload)
            )
        )
        XCTAssertEqual(stdinOutput.standardOutput, payload)

        let eofOutput = try unwrapSuccess(
            await client.run(request(executable: "/bin/cat", standardInput: nil))
        )
        XCTAssertTrue(eofOutput.standardOutput.isEmpty, "nil stdin must be immediate EOF")
        await client.shutdown()
    }

    func testLarkNotificationSuppressionFlagsAreAllowlisted() async throws {
        let client = OneShotChildProcessClient()

        let output = try unwrapSuccess(
            await client.run(
                request(
                    executable: "/usr/bin/env",
                    environment: [
                        "PATH": "/usr/bin:/bin",
                        "LARKSUITE_CLI_NO_UPDATE_NOTIFIER": "1",
                        "LARKSUITE_CLI_NO_SKILLS_NOTIFIER": "1"
                    ]
                )
            )
        )
        let environmentLines = Set(
            String(decoding: output.standardOutput, as: UTF8.self)
                .split(separator: "\n")
                .map(String.init)
        )
        XCTAssertEqual(
            environmentLines,
            Set([
                "PATH=/usr/bin:/bin",
                "LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1",
                "LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1"
            ]),
            "The Feishu CLI suppression flags must pass the environment allowlist."
        )
        await client.shutdown()
    }

    func testStandardOutputAndStandardErrorDrainConcurrently() async throws {
        let client = OneShotChildProcessClient()
        let lineCount = 2_000
        let script =
            "i=0; while [ \"$i\" -lt \(lineCount) ]; do "
            + "printf 'out-%04d-0123456789abcdef\\n' \"$i\"; "
            + "printf 'err-%04d-fedcba9876543210\\n' \"$i\" >&2; "
            + "i=$((i + 1)); done"

        let output = try unwrapSuccess(
            await client.run(
                request(
                    executable: "/bin/sh",
                    arguments: ["-c", script],
                    timeout: .seconds(4),
                    standardOutputByteLimit: 256 * 1024,
                    standardErrorByteLimit: 256 * 1024,
                    lineLimit: lineCount
                )
            )
        )

        XCTAssertEqual(output.standardOutput.filter { $0 == 0x0A }.count, lineCount)
        XCTAssertEqual(output.redactedStandardError.filter { $0 == 0x0A }.count, lineCount)
        XCTAssertTrue(String(decoding: output.standardOutput, as: UTF8.self).contains("out-1999"))
        XCTAssertTrue(
            String(decoding: output.redactedStandardError, as: UTF8.self).contains("err-1999")
        )
        await client.shutdown()
    }

    func testOutputByteAndLineLimitsReturnTypedFailures() async throws {
        let client = OneShotChildProcessClient()

        let byteFailure = try unwrapFailure(
            await client.run(
                request(
                    executable: "/usr/bin/printf",
                    arguments: ["0123456789"],
                    standardOutputByteLimit: 4
                )
            )
        )
        XCTAssertEqual(byteFailure.code, .processFailed)
        XCTAssertEqual(byteFailure.retryClass, .never)
        XCTAssertEqual(byteFailure.diagnosticCode, "process.stdout.byte_limit")

        let lineFailure = try unwrapFailure(
            await client.run(
                request(
                    executable: "/usr/bin/printf",
                    arguments: ["one\ntwo\n"],
                    lineLimit: 1
                )
            )
        )
        XCTAssertEqual(lineFailure.code, .processFailed)
        XCTAssertEqual(lineFailure.diagnosticCode, "process.stdout.line_limit")

        let standardErrorByteFailure = try unwrapFailure(
            await client.run(
                request(
                    executable: "/bin/sh",
                    arguments: ["-c", "printf 0123456789 >&2"],
                    standardErrorByteLimit: 4
                )
            )
        )
        XCTAssertEqual(standardErrorByteFailure.code, .processFailed)
        XCTAssertEqual(standardErrorByteFailure.diagnosticCode, "process.stderr.byte_limit")

        let standardErrorLineFailure = try unwrapFailure(
            await client.run(
                request(
                    executable: "/bin/sh",
                    arguments: ["-c", "printf 'one\\ntwo\\n' >&2"],
                    lineLimit: 1
                )
            )
        )
        XCTAssertEqual(standardErrorLineFailure.code, .processFailed)
        XCTAssertEqual(standardErrorLineFailure.diagnosticCode, "process.stderr.line_limit")
        await client.shutdown()
    }

    func testStandardErrorIsGenericallyRedactedBeforeResultConstruction() async throws {
        let client = OneShotChildProcessClient()
        let script =
            "printf '%s\\n' 'home=/Users/alice/private' >&2\n"
            + "printf '%s\\n' 'token=tok_live_SUPERSECRET123' >&2\n"
            + "printf '%s\\n' '\"api_key\":\"fixture-key-value\"' >&2\n"
            + "printf '%s\\n' 'Authorization: Bearer bearer-secret-value' >&2\n"
            + "printf '%s\\n' 'person@example.com' >&2\n"
            + "printf '%s\\n' 'https://urluser:urlpass@example.com/path' >&2\n"
            + "printf '%s\\n' 'sk_fixturesecret123' >&2\n"

        let output = try unwrapSuccess(
            await client.run(
                request(
                    executable: "/bin/sh",
                    environment: ["HOME": "/Users/alice"],
                    standardInput: Data(script.utf8),
                    lineLimit: 20
                )
            )
        )
        let diagnostic = String(decoding: output.redactedStandardError, as: UTF8.self)

        for forbidden in [
            "alice",
            "tok_live_SUPERSECRET123",
            "fixture-key-value",
            "bearer-secret-value",
            "person@example.com",
            "urluser",
            "urlpass",
            "sk_fixturesecret123"
        ] {
            XCTAssertFalse(diagnostic.contains(forbidden), "redacted stderr leaked \(forbidden)")
        }
        XCTAssertTrue(diagnostic.contains("<home>"))
        XCTAssertTrue(diagnostic.contains("<redacted>"))
        XCTAssertTrue(diagnostic.contains("<email>"))
        XCTAssertTrue(diagnostic.contains("<redacted-key>"))
        await client.shutdown()
    }

    func testRedactionCarriesSensitivePatternsAcrossReadChunks() {
        let collector = BoundedRedactedStandardErrorCollector(
            byteLimit: 4_096,
            lineLimit: 10,
            homePaths: ["/Users/chunk-user"],
            onViolation: { _ in }
        )

        collector.accept(Data("Authorization: Bea".utf8))
        collector.accept(Data("rer split-secret-value\nmail=split@example.com\n".utf8))
        collector.accept(Data("path=/Users/chunk-".utf8))
        collector.accept(Data("user/private\n".utf8))
        collector.finish()

        let diagnostic = String(decoding: collector.output, as: UTF8.self)
        XCTAssertNil(collector.violation)
        XCTAssertFalse(diagnostic.contains("split-secret-value"))
        XCTAssertFalse(diagnostic.contains("split@example.com"))
        XCTAssertFalse(diagnostic.contains("chunk-user"))
        XCTAssertTrue(diagnostic.contains("Authorization: <redacted>"))
        XCTAssertTrue(diagnostic.contains("<email>"))
        XCTAssertTrue(diagnostic.contains("<home>/private"))
    }

    func testRedactionBoundsRawCarryForLongUnterminatedSensitiveLine() {
        let collector = BoundedRedactedStandardErrorCollector(
            byteLimit: 16_384,
            lineLimit: 10,
            homePaths: [],
            onViolation: { _ in }
        )
        let sentinel = "secret-" + String(repeating: "X", count: 2_048)
        collector.accept(Data("Authorization: Bearer \(sentinel)".utf8))

        XCTAssertLessThanOrEqual(collector.maximumRawCarryByteCountForTesting, 512)
        XCTAssertFalse(collector.rawCarryContainsForTesting(Data(sentinel.utf8)))

        collector.finish()
        let diagnostic = String(decoding: collector.output, as: UTF8.self)
        XCTAssertFalse(diagnostic.contains(sentinel))
        XCTAssertTrue(diagnostic.contains("Authorization: <redacted>"))
    }

    func testInvalidExecutableURLAndNonzeroExitMapToTypedFailures() async throws {
        let client = OneShotChildProcessClient()
        let invalidURL = try XCTUnwrap(URL(string: "relative/tool"))
        let invalidRequest = ChildProcessRequest(
            executableURL: invalidURL,
            arguments: [],
            environment: [:],
            standardInput: nil,
            limits: limits()
        )

        let invalidFailure = try unwrapFailure(await client.run(invalidRequest))
        XCTAssertEqual(invalidFailure.code, .missingExecutable)
        XCTAssertEqual(invalidFailure.retryClass, .afterRecovery)
        XCTAssertEqual(invalidFailure.recovery, .selectExecutable)

        let missingFailure = try unwrapFailure(
            await client.run(request(executable: "/definitely/missing/usage-butler-process-fixture"))
        )
        XCTAssertEqual(missingFailure.code, .missingExecutable)
        XCTAssertEqual(missingFailure.retryClass, .afterRecovery)
        XCTAssertEqual(missingFailure.recovery, .selectExecutable)

        let disallowedEnvironmentFailure = try unwrapFailure(
            await client.run(
                request(
                    executable: "/usr/bin/env",
                    environment: ["PROVIDER_API_TOKEN": "must-never-reach-child"]
                )
            )
        )
        XCTAssertEqual(disallowedEnvironmentFailure.code, .processFailed)
        XCTAssertEqual(disallowedEnvironmentFailure.retryClass, .never)
        XCTAssertEqual(
            disallowedEnvironmentFailure.diagnosticCode,
            "process.request.invalid_environment"
        )

        let zeroTimeoutRequest = request(
            executable: "/usr/bin/printf",
            arguments: ["must-not-run"],
            timeout: .zero
        )
        let zeroTimeoutFailure = try unwrapFailure(await client.run(zeroTimeoutRequest))
        XCTAssertEqual(zeroTimeoutFailure.code, .processFailed)
        XCTAssertEqual(zeroTimeoutFailure.retryClass, .never)
        XCTAssertEqual(zeroTimeoutFailure.diagnosticCode, "process.request.invalid_limits")

        let exitFailure = try unwrapFailure(
            await client.run(
                request(executable: "/bin/sh", arguments: ["-c", "exit 23"])
            )
        )
        XCTAssertEqual(exitFailure.code, .processFailed)
        XCTAssertEqual(exitFailure.retryClass, .backoff)
        XCTAssertEqual(exitFailure.diagnosticCode, "process.exit.23")
        XCTAssertEqual(exitFailure.recovery, .retry)
        await client.shutdown()
    }

    func testOptInNonzeroExitReturnsBoundedOutputForAdapterClassification() async throws {
        let client = OneShotChildProcessClient()
        let output = try unwrapSuccess(
            await client.run(
                request(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "printf 'provider marker'; printf 'token=secret-value' >&2; exit 23"
                    ],
                    nonZeroExitPolicy: .returnBoundedOutput
                )
            )
        )

        XCTAssertEqual(output.termination, .exited(code: 23))
        XCTAssertEqual(String(decoding: output.standardOutput, as: UTF8.self), "provider marker")
        let stderr = String(decoding: output.redactedStandardError, as: UTF8.self)
        XCTAssertTrue(stderr.contains("token=<redacted>"))
        XCTAssertFalse(stderr.contains("secret-value"))
        await client.shutdown()
    }

    func testTimeoutEscalatesPastTermAndReapsTheOwnedPID() async throws {
        let client = OneShotChildProcessClient(terminationGracePeriod: .milliseconds(50))
        let clock = ContinuousClock()
        let startedAt = clock.now
        let timeoutRequest = request(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; exec /bin/sleep 5"],
            timeout: .milliseconds(200)
        )
        let task = Task {
            await client.run(timeoutRequest)
        }
        let processIDs = try await waitForProcessIDs(client, count: 1)

        let failure = try unwrapFailure(await task.value)
        let elapsed = startedAt.duration(to: clock.now)
        XCTAssertEqual(failure.code, .timedOut)
        XCTAssertEqual(failure.retryClass, .backoff)
        XCTAssertEqual(failure.diagnosticCode, "process.timeout")
        XCTAssertLessThan(elapsed, .seconds(2))
        let activeProcessCount = await client.activeProcessCountForTesting()
        XCTAssertEqual(activeProcessCount, 0)
        assertReaped(processIDs)
        await client.shutdown()
    }

    func testTimeoutDoesNotWaitForDescendantInheritedPipes() async throws {
        let client = OneShotChildProcessClient(
            terminationGracePeriod: .milliseconds(50)
        )
        let clock = ContinuousClock()
        let startedAt = clock.now
        let timeoutRequest = inheritedPipeRequest(timeout: .milliseconds(150))
        let task = Task {
            await client.run(timeoutRequest)
        }
        let processIDs = try await waitForProcessIDs(client, count: 1)

        let failure = try unwrapFailure(await task.value)
        XCTAssertEqual(failure.code, .timedOut)
        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
        let activeProcessCount = await client.activeProcessCountForTesting()
        XCTAssertEqual(activeProcessCount, 0)
        assertReaped(processIDs)
        await client.shutdown()
    }

    func testTaskCancellationTerminatesAndReapsTheOwnedPID() async throws {
        let client = OneShotChildProcessClient(terminationGracePeriod: .milliseconds(50))
        let cancellationRequest = request(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: .seconds(3)
        )
        let task = Task {
            await client.run(cancellationRequest)
        }
        let processIDs = try await waitForProcessIDs(client, count: 1)

        task.cancel()
        let failure = try unwrapFailure(await task.value)
        XCTAssertEqual(failure.code, .cancelled)
        XCTAssertEqual(failure.retryClass, .never)
        XCTAssertEqual(failure.diagnosticCode, "process.cancelled")
        let activeProcessCount = await client.activeProcessCountForTesting()
        XCTAssertEqual(activeProcessCount, 0)
        assertReaped(processIDs)
        await client.shutdown()
    }

    func testCancellationDoesNotWaitForDescendantInheritedPipes() async throws {
        let client = OneShotChildProcessClient(
            terminationGracePeriod: .milliseconds(50)
        )
        let cancellationRequest = inheritedPipeRequest(timeout: .seconds(5))
        let task = Task {
            await client.run(cancellationRequest)
        }
        let processIDs = try await waitForProcessIDs(client, count: 1)
        let clock = ContinuousClock()
        let cancelledAt = clock.now

        task.cancel()
        let failure = try unwrapFailure(await task.value)
        XCTAssertEqual(failure.code, .cancelled)
        XCTAssertLessThan(cancelledAt.duration(to: clock.now), .seconds(1))
        let activeProcessCount = await client.activeProcessCountForTesting()
        XCTAssertEqual(activeProcessCount, 0)
        assertReaped(processIDs)
        await client.shutdown()
    }

    func testShutdownSealsClientTerminatesAllChildrenAndWaitsForReap() async throws {
        let client = OneShotChildProcessClient(terminationGracePeriod: .milliseconds(50))
        let firstRequest = request(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: .seconds(3)
        )
        let secondRequest = request(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: .seconds(3)
        )
        let first = Task {
            await client.run(firstRequest)
        }
        let second = Task {
            await client.run(secondRequest)
        }
        let processIDs = try await waitForProcessIDs(client, count: 2)

        await client.shutdown()
        let firstFailure = try unwrapFailure(await first.value)
        let secondFailure = try unwrapFailure(await second.value)
        XCTAssertEqual(firstFailure.code, .shutdown)
        XCTAssertEqual(secondFailure.code, .shutdown)
        let activeProcessCount = await client.activeProcessCountForTesting()
        XCTAssertEqual(activeProcessCount, 0)
        assertReaped(processIDs)

        let sealedFailure = try unwrapFailure(
            await client.run(
                request(executable: "/usr/bin/printf", arguments: ["must-not-run"])
            )
        )
        XCTAssertEqual(sealedFailure.code, .shutdown)
        XCTAssertEqual(sealedFailure.diagnosticCode, "process.client.shutdown")
    }

    func testShutdownDoesNotWaitForDescendantInheritedPipes() async throws {
        let client = OneShotChildProcessClient(
            terminationGracePeriod: .milliseconds(50)
        )
        let shutdownRequest = inheritedPipeRequest(timeout: .seconds(5))
        let task = Task {
            await client.run(shutdownRequest)
        }
        let processIDs = try await waitForProcessIDs(client, count: 1)
        let clock = ContinuousClock()
        let shutdownAt = clock.now

        await client.shutdown()
        let failure = try unwrapFailure(await task.value)
        XCTAssertEqual(failure.code, .shutdown)
        XCTAssertLessThan(shutdownAt.duration(to: clock.now), .seconds(1))
        let activeProcessCount = await client.activeProcessCountForTesting()
        XCTAssertEqual(activeProcessCount, 0)
        assertReaped(processIDs)
    }

    private func inheritedPipeRequest(timeout: Duration) -> ChildProcessRequest {
        request(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "/bin/sleep 2 & trap '' TERM; wait"
            ],
            timeout: timeout
        )
    }

    private func request(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        timeout: Duration = .seconds(2),
        standardOutputByteLimit: Int = 1024 * 1024,
        standardErrorByteLimit: Int = 1024 * 1024,
        lineLimit: Int = 10_000,
        nonZeroExitPolicy: ChildProcessNonZeroExitPolicy = .typedFailure
    ) -> ChildProcessRequest {
        ChildProcessRequest(
            executableURL: URL(fileURLWithPath: executable, isDirectory: false),
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            limits: limits(
                timeout: timeout,
                standardOutputByteLimit: standardOutputByteLimit,
                standardErrorByteLimit: standardErrorByteLimit,
                lineLimit: lineLimit
            ),
            nonZeroExitPolicy: nonZeroExitPolicy
        )
    }

    private func limits(
        timeout: Duration = .seconds(2),
        standardOutputByteLimit: Int = 1024 * 1024,
        standardErrorByteLimit: Int = 1024 * 1024,
        lineLimit: Int = 10_000
    ) -> ChildProcessLimits {
        ChildProcessLimits(
            timeout: timeout,
            standardOutputByteLimit: standardOutputByteLimit,
            standardErrorByteLimit: standardErrorByteLimit,
            lineLimit: lineLimit
        )
    }

    private func unwrapSuccess(
        _ result: Result<ChildProcessOutput, ProviderFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ChildProcessOutput {
        switch result {
        case let .success(output):
            return output
        case let .failure(failure):
            XCTFail("Unexpected process failure: \(failure)", file: file, line: line)
            throw TestHarnessError.unexpectedFailure
        }
    }

    private func unwrapFailure(
        _ result: Result<ChildProcessOutput, ProviderFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ProviderFailure {
        switch result {
        case .success:
            XCTFail("Expected a typed process failure", file: file, line: line)
            throw TestHarnessError.unexpectedSuccess
        case let .failure(failure):
            return failure
        }
    }

    private func waitForProcessIDs(
        _ client: OneShotChildProcessClient,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [pid_t] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            let processIDs = await client.activeProcessIDsForTesting()
            if processIDs.count == count {
                return processIDs
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(count) owned process IDs", file: file, line: line)
        throw TestHarnessError.processDidNotLaunch
    }

    private func assertReaped(
        _ processIDs: [pid_t],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for processID in processIDs {
            errno = 0
            XCTAssertEqual(Darwin.kill(processID, 0), -1, file: file, line: line)
            XCTAssertEqual(errno, ESRCH, "PID \(processID) still exists", file: file, line: line)
        }
    }
}

private enum TestHarnessError: Error {
    case unexpectedFailure
    case unexpectedSuccess
    case processDidNotLaunch
}
