import Foundation
import UsageButlerCore
import UsageButlerDomain
import XCTest
@testable import UsageButlerInfrastructure
@testable import UsageButlerProviders

final class ArkAuthenticationStatusTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_300_000)

    func testSessionDeadlineDrivesHealthyWarningAndExpiredBoundaries() throws {
        let parsed = try parse(expired: false, expiresAt: fixedNow.addingTimeInterval(900))
        for (remaining, expected) in [(86_401.0, "healthy"), (86_400.0, "warning"),
                                      (1.0, "warning"), (0.0, "expired"), (-1.0, "expired")] {
            let expiration = fixedNow.addingTimeInterval(remaining)
            let result = ArkAuthenticationStatusClassifier.classify(
                parsed, now: fixedNow, contractVersion: ArkDomainContract.quotaContractVersion,
                sessionExpiresAt: expiration
            )
            switch result.authentication {
            case let .healthy(evidence):
                XCTAssertEqual(expected, "healthy")
                XCTAssertEqual(evidence.expiresAt, expiration)
            case let .warning(evidence):
                XCTAssertEqual(expected, "warning")
                XCTAssertEqual(evidence.expiresAt, expiration)
            case .expired: XCTAssertEqual(expected, "expired")
            case .unknown: XCTFail("known expiry and control-plane ok must be classified")
            }
            XCTAssertEqual(result.requiresLoginEvidence != nil, remaining <= 0)
        }
    }

    func testUnavailableSessionExpiryIsUnknownNotFabricatedHealthy() throws {
        let parsed = try parse(expired: false, expiresAt: fixedNow.addingTimeInterval(900))
        let result = ArkAuthenticationStatusClassifier.classify(
            parsed, now: fixedNow, contractVersion: ArkDomainContract.quotaContractVersion,
            sessionExpiryUnavailable: true
        )
        guard case .unknown = result.authentication else { return XCTFail("expiry must stay unknown") }
        XCTAssertNil(result.requiresLoginEvidence)
    }

    func testNeedsLoginTakesPrecedenceOverFutureSessionExpiry() throws {
        let parsed = try ArkAuthenticationStatusParser.parse(Data(#"{"control_plane_auth":{"status":"needs_login"}}"#.utf8))
        let result = ArkAuthenticationStatusClassifier.classify(
            parsed, now: fixedNow, contractVersion: ArkDomainContract.quotaContractVersion,
            sessionExpiresAt: fixedNow.addingTimeInterval(86_400)
        )
        XCTAssertNotNil(result.requiresLoginEvidence)
        guard case .unknown = result.authentication else { return XCTFail("login is required now") }
    }

    func testNeedsLoginWithoutExpirationRequiresLoginButDoesNotInventExpired() throws {
        let parsed = try ArkAuthenticationStatusParser.parse(
            Data(#"{"control_plane_auth":{"status":"needs_login"},"logged_in":true}"#.utf8)
        )

        let observation = ArkAuthenticationStatusClassifier.classify(
            parsed,
            now: fixedNow,
            contractVersion: ArkDomainContract.quotaContractVersion
        )

        XCTAssertNotNil(observation.requiresLoginEvidence)
        guard case let .unknown(evidence) = observation.authentication else {
            return XCTFail("needs_login alone is not explicit expiration evidence")
        }
        XCTAssertEqual(evidence.observedAt, fixedNow)
    }

    func testRenewableIDTokenExpirationDoesNotOverrideHealthyControlPlane() throws {
        let parsed = try ArkAuthenticationStatusParser.parse(
            Data(
                #"{"control_plane_auth":{"status":"ok"},"volc_sso":{"expired":true,"id_token_expires_at":"2030-01-01T00:00:00Z"}}"#.utf8
            )
        )

        let observation = ArkAuthenticationStatusClassifier.classify(
            parsed,
            now: fixedNow,
            contractVersion: ArkDomainContract.quotaContractVersion
        )

        XCTAssertNil(observation.requiresLoginEvidence)
        guard case let .healthy(evidence) = observation.authentication else {
            return XCTFail("an expired ID token does not mean the CLI session cannot renew")
        }
        XCTAssertEqual(evidence.observedAt, fixedNow)
        guard case let .providerReport(sourceField, _) = evidence.authority else {
            return XCTFail("expected control-plane authority")
        }
        XCTAssertEqual(sourceField, "control_plane_auth.status")
    }

    func testFifteenMinuteIDTokenDoesNotProduceSessionWarning() throws {
        let expiration = fixedNow.addingTimeInterval(15 * 60)
        let parsed = try parse(expired: false, expiresAt: expiration)

        let observation = ArkAuthenticationStatusClassifier.classify(
            parsed,
            now: fixedNow,
            contractVersion: ArkDomainContract.quotaContractVersion
        )

        XCTAssertNil(observation.requiresLoginEvidence)
        guard case .healthy = observation.authentication else {
            return XCTFail("a renewable ID token deadline must not create a session warning")
        }
    }

    func testPastIDTokenDeadlineDoesNotRequireLoginWhenControlPlaneIsHealthy() throws {
        let expiration = fixedNow.addingTimeInterval(-60)
        let parsed = try parse(expired: false, expiresAt: expiration)

        let observation = ArkAuthenticationStatusClassifier.classify(
            parsed,
            now: fixedNow,
            contractVersion: ArkDomainContract.quotaContractVersion
        )

        XCTAssertNil(observation.requiresLoginEvidence)
        guard case .healthy = observation.authentication else {
            return XCTFail("CLI control-plane health must take precedence over the ID token")
        }
    }

    func testUnusedIDTokenMetadataDoesNotInvalidateControlPlaneStatus() throws {
        let parsed = try ArkAuthenticationStatusParser.parse(
            Data(#"{"control_plane_auth":{"status":"ok"},"volc_sso":{"expired":false,"id_token_expires_at":"not-a-date"}}"#.utf8)
        )
        let observation = ArkAuthenticationStatusClassifier.classify(
            parsed, now: fixedNow, contractVersion: ArkDomainContract.quotaContractVersion
        )
        guard case .healthy = observation.authentication else {
            return XCTFail("unused ID-token metadata is not the auth-status contract")
        }
    }

    func testIDTokenAloneDoesNotProveSessionHealthOrExpiration() throws {
        for expired in [false, true] {
            let parsed = try ArkAuthenticationStatusParser.parse(
                Data("{\"volc_sso\":{\"expired\":\(expired),\"id_token_expires_at\":\"2030-01-01T00:00:00Z\"}}".utf8)
            )
            let observation = ArkAuthenticationStatusClassifier.classify(
                parsed, now: fixedNow, contractVersion: ArkDomainContract.quotaContractVersion
            )
            XCTAssertNil(observation.requiresLoginEvidence)
            guard case .unknown = observation.authentication else {
                return XCTFail("ID token metadata cannot establish full session status")
            }
        }
    }

    func testNeedsLoginIsNotOverriddenByFutureIDTokenDeadline() throws {
        let parsed = try ArkAuthenticationStatusParser.parse(
            Data(#"{"control_plane_auth":{"status":"needs_login"},"volc_sso":{"expired":false,"id_token_expires_at":"2030-01-01T00:00:00Z"}}"#.utf8)
        )
        let observation = ArkAuthenticationStatusClassifier.classify(
            parsed, now: fixedNow, contractVersion: ArkDomainContract.quotaContractVersion
        )
        XCTAssertNotNil(observation.requiresLoginEvidence)
        guard case .unknown = observation.authentication else {
            return XCTFail("needs_login requires recovery without inventing an expiry cause")
        }
    }

    func testReaderUsesExactReadOnlyArgumentsAndReplacementEnvironment() async {
        let process = ArkAuthFakeChildProcessClient(results: [
            .success(output(#"{"control_plane_auth":{"status":"ok"}}"#))
        ])
        let executableURL = URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        let environment = ["HOME": "/safe-home", "LANG": "en_US.UTF-8"]
        let now = fixedNow
        let reader = ArkAuthenticationStatusReader(
            processClient: process,
            executableURL: executableURL,
            environment: environment,
            now: { now }
        )

        guard case let .success(observation) = await reader.readAuthenticationStatus() else {
            return XCTFail("expected a parsed auth-status observation")
        }
        guard case .healthy = observation.authentication else {
            return XCTFail("control-plane ok is authoritative healthy evidence")
        }

        let requests = await process.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].executableURL, executableURL)
        XCTAssertEqual(requests[0].arguments, ["auth", "status", "--format", "json"])
        XCTAssertEqual(requests[0].environment, environment)
        XCTAssertNil(requests[0].standardInput)
        XCTAssertEqual(requests[0].limits, ArkAuthenticationStatusReader.defaultLimits)
    }

    func testReaderCachesSuccessfulProbeWithinMinimumInterval() async {
        let process = ArkAuthFakeChildProcessClient(results: [
            .success(output(#"{"control_plane_auth":{"status":"ok"}}"#))
        ])
        let clock = ArkAuthMutableNow(fixedNow)
        let reader = ArkAuthenticationStatusReader(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            minimumProbeInterval: 60,
            now: { clock.now() }
        )

        guard case .success = await reader.readAuthenticationStatus(),
              case .success = await reader.readAuthenticationStatus() else {
            return XCTFail("both reads should return the successful cached result")
        }
        let requestCount = await process.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testCachedWarningBecomesExpiredAtKnownSessionDeadlineWithoutNewProbe() async {
        let expiration = fixedNow.addingTimeInterval(30)
        let evidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "identity_store.refresh_token.exp",
                contractVersion: ArkDomainContract.quotaContractVersion
            ),
            observedAt: fixedNow,
            expiresAt: expiration
        )
        let cached = ArkAuthenticationObservation(
            authentication: .warning(evidence),
            requiresLoginEvidence: nil,
            observedAt: fixedNow
        )

        guard case let .success(observation) = ArkAuthenticationStatusReader.reevaluateCached(
            .success(cached),
            now: expiration
        ) else {
            return XCTFail("cached observation should remain available")
        }
        guard case .expired = observation.authentication else {
            return XCTFail("a cached warning must not overwrite an elapsed session as warning")
        }
        XCTAssertEqual(observation.requiresLoginEvidence, evidence)
        XCTAssertEqual(observation.observedAt, fixedNow)
    }

    func testReaderReevaluatesCachedWarningAfterSessionDeadlineWithoutNewChild() async throws {
        let expiration = fixedNow.addingTimeInterval(30)
        let home = try makeSessionHome(expiration: expiration.timeIntervalSince1970)
        defer { try? FileManager.default.removeItem(at: home) }
        let process = ArkAuthFakeChildProcessClient(results: [
            .success(output(
                #"{"control_plane_auth":{"status":"ok"},"active_profile":{"owner_trn":"test-owner"},"volc_sso":{"identity":{"account_id":"123","trn":"test-owner"}}}"#
            ))
        ])
        let clock = ArkAuthMutableNow(fixedNow)
        let reader = ArkAuthenticationStatusReader(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            sessionExpiryReader: ArkSessionExpiryReader(homeDirectory: home),
            minimumProbeInterval: 60,
            now: { clock.now() }
        )

        guard case let .success(first) = await reader.readAuthenticationStatus(),
              case .warning = first.authentication else {
            return XCTFail("the first probe should observe the near-term session warning")
        }
        clock.advance(by: 30)
        guard case let .success(second) = await reader.readAuthenticationStatus(),
              case .expired = second.authentication else {
            return XCTFail("the cached observation must age to expired at the known deadline")
        }
        XCTAssertNotNil(second.requiresLoginEvidence)
        let requestCount = await process.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testReaderCachesFailedProbeWithinMinimumInterval() async {
        let expectedFailure = ProviderFailure(
            code: .processFailed,
            retryClass: .backoff,
            userMessageKey: "provider.failure.process",
            diagnosticCode: "test.auth-status.failure",
            recovery: .retry
        )
        let process = ArkAuthFakeChildProcessClient(results: [.failure(expectedFailure)])
        let clock = ArkAuthMutableNow(fixedNow)
        let reader = ArkAuthenticationStatusReader(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            minimumProbeInterval: 60,
            now: { clock.now() }
        )

        for _ in 0..<2 {
            guard case let .failure(failure) = await reader.readAuthenticationStatus() else {
                return XCTFail("both reads should return the failed cached result")
            }
            XCTAssertEqual(failure.code, expectedFailure.code)
            XCTAssertEqual(failure.diagnosticCode, "ark.auth-status.child.processFailed")
        }
        let requestCount = await process.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testReaderProbesAgainAfterMinimumInterval() async {
        let process = ArkAuthFakeChildProcessClient(results: [
            .success(output(#"{"control_plane_auth":{"status":"ok"}}"#)),
            .success(output(#"{"control_plane_auth":{"status":"needs_login"}}"#))
        ])
        let clock = ArkAuthMutableNow(fixedNow)
        let reader = ArkAuthenticationStatusReader(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            minimumProbeInterval: 60,
            now: { clock.now() }
        )

        guard case .success = await reader.readAuthenticationStatus() else {
            return XCTFail("the first probe should succeed")
        }
        clock.advance(by: 61)
        guard case let .success(observation) = await reader.readAuthenticationStatus() else {
            return XCTFail("the second probe should succeed")
        }
        XCTAssertNotNil(observation.requiresLoginEvidence)
        let requestCount = await process.capturedRequests().count
        XCTAssertEqual(requestCount, 2)
    }

    func testReaderProbesAgainImmediatelyAfterCacheInvalidation() async {
        let process = ArkAuthFakeChildProcessClient(results: [
            .success(output(#"{"control_plane_auth":{"status":"ok"}}"#)),
            .success(output(#"{"control_plane_auth":{"status":"needs_login"}}"#))
        ])
        let clock = ArkAuthMutableNow(fixedNow)
        let reader = ArkAuthenticationStatusReader(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            minimumProbeInterval: 60,
            now: { clock.now() }
        )

        guard case .success = await reader.readAuthenticationStatus() else {
            return XCTFail("the first probe should succeed")
        }
        await reader.invalidateCache()
        guard case let .success(observation) = await reader.readAuthenticationStatus() else {
            return XCTFail("the invalidated probe should succeed")
        }
        XCTAssertNotNil(observation.requiresLoginEvidence)
        let requestCount = await process.capturedRequests().count
        XCTAssertEqual(requestCount, 2)
    }

    func testReaderCoalescesConcurrentProbeCallers() async {
        let process = ArkAuthSuspendingChildProcessClient()
        let reader = ArkAuthenticationStatusReader(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        )
        let first = Task { await reader.readAuthenticationStatus() }
        await process.waitUntilRequestStarts()
        let second = Task { await reader.readAuthenticationStatus() }

        for _ in 0..<20 { await Task.yield() }
        let requestCountWhileBlocked = await process.requestCount()
        XCTAssertEqual(requestCountWhileBlocked, 1)

        await process.resume(with: output(#"{"control_plane_auth":{"status":"ok"}}"#))
        guard case .success = await first.value,
              case .success = await second.value else {
            return XCTFail("both callers should share the successful probe")
        }
        let finalRequestCount = await process.requestCount()
        XCTAssertEqual(finalRequestCount, 1)
    }

    func testNonzeroAuthStatusDoesNotGuessAuthenticationRequired() async {
        let process = ArkAuthFakeChildProcessClient(results: [
            .success(
                ChildProcessOutput(
                    termination: .exited(code: 1),
                    standardOutput: Data(#"{"message":"opaque"}"#.utf8),
                    redactedStandardError: Data("opaque".utf8)
                )
            )
        ])
        let reader = ArkAuthenticationStatusReader(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        )

        guard case let .failure(failure) = await reader.readAuthenticationStatus() else {
            return XCTFail("nonzero unstructured output must remain a process failure")
        }
        XCTAssertEqual(failure.code, .processFailed)
        XCTAssertNotEqual(failure.code, .authenticationRequired)
        XCTAssertNotEqual(failure.code, .authenticationExpired)
    }

    func testAdapterStopsBeforeUsageWhenTypedAuthRequiresLogin() async {
        let loginEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "control_plane_auth.status",
                contractVersion: ArkDomainContract.quotaContractVersion
            ),
            observedAt: fixedNow
        )
        let authReader = ArkAuthFakeStatusReader(
            result: .success(
                ArkAuthenticationObservation(
                    authentication: .unknown(loginEvidence),
                    requiresLoginEvidence: loginEvidence,
                    observedAt: fixedNow
                )
            )
        )
        let usageProcess = ArkAuthFakeChildProcessClient(results: [])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: usageProcess,
            authenticationStatusReader: authReader,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        guard case let .success(discovery) = await adapter.discover() else {
            return XCTFail("typed auth requires-login is a successful discovery result")
        }
        XCTAssertEqual(discovery.connection, .requiresLogin(loginEvidence))
        guard case .unknown = discovery.authentication else {
            return XCTFail("needs_login without expiration must stay auth unknown")
        }
        let usageRequests = await usageProcess.capturedRequests()
        XCTAssertTrue(usageRequests.isEmpty)
    }

    func testAdapterPreservesTypedWarningAfterSuccessfulUsageDiscovery() async {
        let evidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fake.session-warning",
                contractVersion: ArkDomainContract.quotaContractVersion
            ),
            observedAt: fixedNow
        )
        let authReader = ArkAuthFakeStatusReader(
            result: .success(
                ArkAuthenticationObservation(
                    authentication: .warning(evidence),
                    requiresLoginEvidence: nil,
                    observedAt: fixedNow
                )
            )
        )
        let usageProcess = ArkAuthFakeChildProcessClient(results: [
            .success(output(bothPlansNotEntitledJSON))
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: usageProcess,
            authenticationStatusReader: authReader,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        guard case let .success(discovery) = await adapter.discover() else {
            return XCTFail("quota discovery should succeed")
        }
        XCTAssertEqual(discovery.connection, .connected)
        XCTAssertEqual(discovery.authentication, .warning(evidence))
        let usageRequestCount = await usageProcess.capturedRequests().count
        XCTAssertEqual(usageRequestCount, 1)
    }

    func testAuthReadFailureFallsBackToSuccessfulUsageWithoutInventingExpiry() async {
        let authReader = ArkAuthFakeStatusReader(
            result: .failure(
                ProviderFailure(
                    code: .schemaMismatch,
                    retryClass: .never,
                    userMessageKey: "provider.failure.schema",
                    diagnosticCode: "test.auth.schema",
                    recovery: nil
                )
            )
        )
        let usageProcess = ArkAuthFakeChildProcessClient(results: [
            .success(output(bothPlansNotEntitledJSON))
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: usageProcess,
            authenticationStatusReader: authReader,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        guard case let .success(discovery) = await adapter.discover() else {
            return XCTFail("successful quota discovery remains usable")
        }
        XCTAssertEqual(discovery.connection, .connected)
        guard case .healthy = discovery.authentication else {
            return XCTFail("the successful quota operation proves current auth works")
        }
    }

    func testReadAuthStatusFailureStillSurfacesQuotaAsUnknown() async {
        let authReader = ArkAuthFakeStatusReader(
            result: .failure(
                ProviderFailure(
                    code: .schemaMismatch,
                    retryClass: .never,
                    userMessageKey: "provider.failure.schema",
                    diagnosticCode: "test.auth.schema",
                    recovery: nil
                )
            )
        )
        let usageProcess = ArkAuthFakeChildProcessClient(results: [
            .success(output(bothPlansNotEntitledJSON))
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: usageProcess,
            authenticationStatusReader: authReader,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        guard case .success = await adapter.read(scope: .provider) else {
            return XCTFail("an inconclusive auth probe must not suppress quota data")
        }
        // ProviderController observes authentication through the ProviderAdapter
        // witness; a direct call on the concrete actor would bind the async
        // extension default instead of the synchronous isolated member.
        let authState = await (adapter as any ProviderAdapter).authenticationAfterRead()
        guard case .unknown = authState else {
            return XCTFail("a failed auth probe stays unknown, never fabricated healthy")
        }
    }

    func testReadNonzeroExitWithTypedNeedsLoginReclassifiesToAuthenticationRequired() async {
        let loginEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "control_plane_auth.status",
                contractVersion: ArkDomainContract.quotaContractVersion
            ),
            observedAt: fixedNow
        )
        let authReader = ArkAuthFakeStatusReader(
            result: .success(
                ArkAuthenticationObservation(
                    authentication: .unknown(loginEvidence),
                    requiresLoginEvidence: loginEvidence,
                    observedAt: fixedNow
                )
            )
        )
        let usageProcess = ArkAuthFakeChildProcessClient(results: [
            .success(
                ChildProcessOutput(
                    termination: .exited(code: 1),
                    standardOutput: Data(),
                    redactedStandardError: Data("opaque".utf8)
                )
            )
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: usageProcess,
            authenticationStatusReader: authReader,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        guard case let .failure(failure) = await adapter.read(scope: .provider) else {
            return XCTFail("the failing quota read stays a failure")
        }
        XCTAssertEqual(failure.code, .authenticationRequired)
        XCTAssertEqual(failure.retryClass, .afterRecovery)
        XCTAssertEqual(failure.diagnosticCode, "ark.adapter.process.auth_required")
        guard case .login(.sso)? = failure.recovery else {
            return XCTFail("recovery must route to the SSO login flow")
        }
        let usageRequests = await usageProcess.capturedRequests()
        XCTAssertEqual(usageRequests.first?.arguments, ["usage", "plan", "--format", "json"])
    }

    func testReadNonzeroExitWithTypedExpiredReclassifiesToAuthenticationExpired() async {
        let loginEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "volc_sso.expired",
                contractVersion: ArkDomainContract.quotaContractVersion
            ),
            observedAt: fixedNow
        )
        let authReader = ArkAuthFakeStatusReader(
            result: .success(
                ArkAuthenticationObservation(
                    authentication: .expired(
                        AuthenticationExpiryEvidence(
                            authority: .explicitExpiration(
                                sourceField: "volc_sso.expired",
                                contractVersion: ArkDomainContract.quotaContractVersion
                            ),
                            observedAt: fixedNow
                        )
                    ),
                    requiresLoginEvidence: loginEvidence,
                    observedAt: fixedNow
                )
            )
        )
        let usageProcess = ArkAuthFakeChildProcessClient(results: [
            .success(
                ChildProcessOutput(
                    termination: .exited(code: 1),
                    standardOutput: Data(),
                    redactedStandardError: Data("opaque".utf8)
                )
            )
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: usageProcess,
            authenticationStatusReader: authReader,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        guard case let .failure(failure) = await adapter.read(scope: .provider) else {
            return XCTFail("the failing quota read stays a failure")
        }
        XCTAssertEqual(failure.code, .authenticationExpired)
        XCTAssertEqual(failure.retryClass, .afterRecovery)
        XCTAssertEqual(failure.diagnosticCode, "ark.adapter.process.auth_expired")
        guard case .login(.sso)? = failure.recovery else {
            return XCTFail("recovery must route to the SSO login flow")
        }
    }

    func testProductionProcessClientNonzeroExitWithTypedExpiredReclassifiesToAuthenticationExpired() async {
        let loginEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "volc_sso.expired",
                contractVersion: ArkDomainContract.quotaContractVersion
            ),
            observedAt: fixedNow
        )
        let authReader = ArkAuthFakeStatusReader(
            result: .success(
                ArkAuthenticationObservation(
                    authentication: .expired(
                        AuthenticationExpiryEvidence(
                            authority: .explicitExpiration(
                                sourceField: "volc_sso.expired",
                                contractVersion: ArkDomainContract.quotaContractVersion
                            ),
                            observedAt: fixedNow
                        )
                    ),
                    requiresLoginEvidence: loginEvidence,
                    observedAt: fixedNow
                )
            )
        )
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: OneShotChildProcessClient(),
            authenticationStatusReader: authReader,
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            environment: ["PATH": "/usr/bin:/bin"],
            now: { now }
        )

        guard case let .failure(failure) = await adapter.read(scope: .provider) else {
            return XCTFail("the failing quota read stays a failure")
        }
        XCTAssertEqual(failure.code, .authenticationExpired)
        XCTAssertEqual(failure.retryClass, .afterRecovery)
        XCTAssertEqual(failure.diagnosticCode, "ark.adapter.process.auth_expired")
        guard case .login(.sso)? = failure.recovery else {
            return XCTFail("recovery must route to the SSO login flow")
        }
    }

    func testReadNonzeroExitWithHealthyAuthKeepsProcessFailure() async {
        let evidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "control_plane_auth.status",
                contractVersion: ArkDomainContract.quotaContractVersion
            ),
            observedAt: fixedNow
        )
        let authReader = ArkAuthFakeStatusReader(
            result: .success(
                ArkAuthenticationObservation(
                    authentication: .healthy(evidence),
                    requiresLoginEvidence: nil,
                    observedAt: fixedNow
                )
            )
        )
        let usageProcess = ArkAuthFakeChildProcessClient(results: [
            .success(
                ChildProcessOutput(
                    termination: .exited(code: 1),
                    standardOutput: Data(),
                    redactedStandardError: Data("opaque".utf8)
                )
            )
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: usageProcess,
            authenticationStatusReader: authReader,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        guard case let .failure(failure) = await adapter.read(scope: .provider) else {
            return XCTFail("the failing quota read stays a failure")
        }
        XCTAssertEqual(failure.code, .processFailed)
        XCTAssertEqual(failure.retryClass, .backoff)
        XCTAssertEqual(failure.diagnosticCode, "ark.adapter.process.nonzero_exit")
    }

    func testReadNonzeroExitWithAuthReadFailureKeepsProcessFailure() async {
        let authReader = ArkAuthFakeStatusReader(
            result: .failure(
                ProviderFailure(
                    code: .schemaMismatch,
                    retryClass: .never,
                    userMessageKey: "provider.failure.schema",
                    diagnosticCode: "test.auth.schema",
                    recovery: nil
                )
            )
        )
        let usageProcess = ArkAuthFakeChildProcessClient(results: [
            .success(
                ChildProcessOutput(
                    termination: .exited(code: 1),
                    standardOutput: Data(),
                    redactedStandardError: Data("opaque".utf8)
                )
            )
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: usageProcess,
            authenticationStatusReader: authReader,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        guard case let .failure(failure) = await adapter.read(scope: .provider) else {
            return XCTFail("the failing quota read stays a failure")
        }
        XCTAssertEqual(failure.code, .processFailed)
        XCTAssertEqual(failure.retryClass, .backoff)
        XCTAssertEqual(failure.diagnosticCode, "ark.adapter.process.nonzero_exit")
    }

    func testReadNonzeroExitWithoutAuthReaderKeepsProcessFailure() async {
        let usageProcess = ArkAuthFakeChildProcessClient(results: [
            .success(
                ChildProcessOutput(
                    termination: .exited(code: 1),
                    standardOutput: Data(),
                    redactedStandardError: Data("opaque".utf8)
                )
            )
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: usageProcess,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        guard case let .failure(failure) = await adapter.read(scope: .provider) else {
            return XCTFail("the failing quota read stays a failure")
        }
        XCTAssertEqual(failure.code, .processFailed)
        XCTAssertEqual(failure.retryClass, .backoff)
        XCTAssertEqual(failure.diagnosticCode, "ark.adapter.process.nonzero_exit")
    }

    private func parse(expired: Bool, expiresAt: Date) throws -> ParsedArkAuthenticationStatus {
        let value = ISO8601DateFormatter().string(from: expiresAt)
        return try ArkAuthenticationStatusParser.parse(
            Data(
                """
                {"control_plane_auth":{"status":"ok"},"volc_sso":{"expired":\(expired),"id_token_expires_at":"\(value)"}}
                """.utf8
            )
        )
    }

    private func makeSessionHome(expiration: TimeInterval) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent(".arkcli/identities/volc-123")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"trn":"test-owner","source":"arkcli"}"#.utf8)
            .write(to: directory.appendingPathComponent("metadata.json"))
        let payload = try JSONSerialization.data(withJSONObject: ["exp": expiration])
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let token = try JSONSerialization.data(withJSONObject: [
            "refresh_token": "e30.\(payload).signature"
        ])
        try token.write(to: directory.appendingPathComponent("token.json"))
        return home
    }

    private func output(_ json: String) -> ChildProcessOutput {
        ChildProcessOutput(
            termination: .exited(code: 0),
            standardOutput: Data(json.utf8),
            redactedStandardError: Data()
        )
    }

    private var bothPlansNotEntitledJSON: String {
        """
        {
          "items": [
            { "product": "agent-plan", "subscribed": false, "periods": [] },
            { "product": "coding-plan", "subscribed": false, "periods": [] }
          ]
        }
        """
    }
}

private actor ArkAuthFakeStatusReader: ArkAuthenticationStatusReading {
    private let result: Result<ArkAuthenticationObservation, ProviderFailure>
    private var didShutdown = false

    init(result: Result<ArkAuthenticationObservation, ProviderFailure>) {
        self.result = result
    }

    func readAuthenticationStatus() async -> Result<ArkAuthenticationObservation, ProviderFailure> {
        result
    }

    func shutdown() async {
        didShutdown = true
    }
}

private actor ArkAuthFakeChildProcessClient: ChildProcessClient {
    private var results: [Result<ChildProcessOutput, ProviderFailure>]
    private var requests: [ChildProcessRequest] = []

    init(results: [Result<ChildProcessOutput, ProviderFailure>]) {
        self.results = results
    }

    func run(_ request: ChildProcessRequest) async -> Result<ChildProcessOutput, ProviderFailure> {
        requests.append(request)
        guard !results.isEmpty else {
            return .failure(
                ProviderFailure(
                    code: .protocolViolation,
                    retryClass: .never,
                    userMessageKey: "test.fake.exhausted",
                    diagnosticCode: "test.fake.exhausted",
                    recovery: nil
                )
            )
        }
        return results.removeFirst()
    }

    func shutdown() async {}

    func capturedRequests() -> [ChildProcessRequest] {
        requests
    }
}

private actor ArkAuthSuspendingChildProcessClient: ChildProcessClient {
    private var requests: [ChildProcessRequest] = []
    private var continuations: [CheckedContinuation<ChildProcessOutput, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func run(_ request: ChildProcessRequest) async -> Result<ChildProcessOutput, ProviderFailure> {
        requests.append(request)
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        let output = await withCheckedContinuation { continuations.append($0) }
        return .success(output)
    }

    func waitUntilRequestStarts() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume(with output: ChildProcessOutput) {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume(returning: output) }
    }

    func requestCount() -> Int { requests.count }

    func shutdown() async {}
}

private final class ArkAuthMutableNow: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value = value.addingTimeInterval(interval)
    }
}
