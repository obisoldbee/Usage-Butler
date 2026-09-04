import Foundation
import UsageButlerCore
import UsageButlerDomain
import XCTest
@testable import UsageButlerProviders

final class OpenAIProviderAdapterTests: XCTestCase {
    func testAdapterSuccessUsesInjectedReaderAndKeepsDiagnosticsSafe() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_786_300_000)
        let secret = "TOP-SECRET-/Users/private/account@example.invalid"
        let source = ProviderSourceIdentity(
            providerID: .openAI,
            adapterID: secret,
            executableIdentity: secret,
            cliVersion: "0.147.0-\(secret)",
            schemaVersion: "schema-\(secret)",
            contractVersion: "contract-\(secret)"
        )
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: source,
            accountResponses: [.success(accountJSON())],
            rateLimitResponses: [.success(fullRateLimitsJSON(codexUsed: 40, sparkUsed: 1))]
        )
        let adapter = OpenAIProviderAdapter(reader: reader, now: { fetchedAt })

        let result = await adapter.read(scope: .provider)
        guard case let .success(data) = result else {
            return XCTFail("Expected complete success, got \(result)")
        }
        XCTAssertEqual(data.source, source)
        XCTAssertEqual(data.products.map(\.sourceProductID), ["codex", "codex_bengalfox"])
        XCTAssertEqual(data.products.first?.metrics.first?.provenance.providerSource, source)

        let calls = await reader.calls()
        XCTAssertEqual(calls.accountReads, 1)
        XCTAssertEqual(calls.rateLimitReads, 1)
        XCTAssertEqual(calls.shutdowns, 0)

        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.providerID, .openAI)
        XCTAssertEqual(diagnostic.diagnosticCode, "openai.read.success")
        XCTAssertEqual(diagnostic.safeFields["transport"], "injected_reader")
        XCTAssertEqual(diagnostic.safeFields["valid_bucket_count"], "2")
        XCTAssertEqual(diagnostic.safeFields["invalid_bucket_count"], "0")
        XCTAssertEqual(diagnostic.safeFields["last_outcome"], "success")
        let renderedSafeFields = diagnostic.safeFields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        XCTAssertFalse(renderedSafeFields.contains(secret))
        XCTAssertFalse(renderedSafeFields.localizedCaseInsensitiveContains("account@example.invalid"))
        XCTAssertFalse(diagnostic.safeFields.keys.contains("executableIdentity"))
    }

    func testMalformedSparkReturnsPartialAndCoreRetainsLastGoodSparkStale() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 8_000)
        let source = providerSource()
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: source,
            accountResponses: [.success(accountJSON()), .success(accountJSON())],
            rateLimitResponses: [
                .success(fullRateLimitsJSON(codexUsed: 40, sparkUsed: 1)),
                .success(malformedSparkJSON(codexUsed: 55))
            ]
        )
        let adapter = OpenAIProviderAdapter(reader: reader, now: { fetchedAt })

        let first = await adapter.read(scope: .provider)
        guard case let .success(firstData) = first else {
            return XCTFail("Expected initial complete success")
        }
        let second = await adapter.read(scope: .provider)
        guard case let .partial(patch, failure) = second else {
            return XCTFail("Expected malformed Spark to be partial, got \(second)")
        }

        XCTAssertEqual(failure.code, .schemaMismatch)
        XCTAssertEqual(failure.retryClass, .backoff)
        XCTAssertEqual(failure.recovery, .retry)
        guard case .patch = patch.productCollectionMutation else {
            return XCTFail("Malformed bucket/window data must retain failed product siblings")
        }
        XCTAssertEqual(patch.updatedProducts.map(\.sourceProductID), ["codex"])
        XCTAssertNil(patch.balances)
        XCTAssertFalse(patch.updatedProducts.contains { $0.sourceProductID == "codex_bengalfox" })

        var state = ProviderBootstrap.initialState(
            id: .openAI,
            capabilities: adapter.capabilities,
            now: fetchedAt
        )
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshSucceeded(firstData),
            now: fetchedAt
        )
        let partialAt = fetchedAt.addingTimeInterval(60)
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshPartiallySucceeded(patch, failure),
            now: partialAt
        )

        let retained = try XCTUnwrap(state.lastGood)
        XCTAssertEqual(retained.products.map(\.sourceProductID), ["codex", "codex_bengalfox"])
        XCTAssertEqual(try usedPercent(in: retained, productID: "codex"), Decimal(55))
        XCTAssertEqual(try usedPercent(in: retained, productID: "codex_bengalfox"), Decimal(1))
        XCTAssertEqual(state.presence, .unknown)
        XCTAssertEqual(state.failure, failure)
        XCTAssertEqual(state.freshness, .stale(asOf: fetchedAt, evaluatedAt: partialAt))

        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["last_outcome"], "partial")
        XCTAssertEqual(diagnostic.safeFields["invalid_bucket_count"], "1")
    }

    func testRateLimitFailureRemainsTypedFailureAndDoesNotBecomeNotEntitled() async {
        let failure = ProviderFailure(
            code: .networkUnavailable,
            retryClass: .backoff,
            userMessageKey: "requires login is untrusted display text",
            diagnosticCode: "fixture.network",
            recovery: .retry
        )
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: providerSource(),
            accountResponses: [.success(accountJSON())],
            rateLimitResponses: [.failure(failure)]
        )
        let adapter = OpenAIProviderAdapter(reader: reader, now: { Date(timeIntervalSince1970: 1) })

        let result = await adapter.read(scope: .provider)
        XCTAssertEqual(result, .failure(failure))

        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["last_outcome"], "failure_networkUnavailable")
        XCTAssertEqual(diagnostic.diagnosticCode, "openai.read.networkUnavailable")
    }

    func testRateLimitTimeoutKeepsTransportPhaseDiagnostic() async {
        let failure = ProviderFailure(
            code: .timedOut,
            retryClass: .backoff,
            userMessageKey: "provider.failure.timed_out",
            diagnosticCode: "openai.transport.rate_limits.timeout",
            recovery: .retry
        )
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: providerSource(),
            accountResponses: [.success(accountJSON())],
            rateLimitResponses: [.failure(failure)]
        )
        let adapter = OpenAIProviderAdapter(reader: reader)

        let result = await adapter.read(scope: .provider)
        XCTAssertEqual(result, .failure(failure))

        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["last_outcome"], "failure_timedOut")
        XCTAssertEqual(
            diagnostic.diagnosticCode,
            "openai.transport.rate_limits.timeout"
        )
    }

    func testAccountTimeoutPartialKeepsTransportPhaseDiagnostic() async {
        let failure = ProviderFailure(
            code: .timedOut,
            retryClass: .backoff,
            userMessageKey: "provider.failure.timed_out",
            diagnosticCode: "openai.transport.account.timeout",
            recovery: .retry
        )
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: providerSource(),
            accountResponses: [.failure(failure)],
            rateLimitResponses: [
                .success(fullRateLimitsJSON(codexUsed: 40, sparkUsed: 1))
            ]
        )
        let adapter = OpenAIProviderAdapter(reader: reader)

        guard case let .partial(_, returnedFailure) = await adapter.read(scope: .provider) else {
            return XCTFail("Expected successful quota with account timeout to remain partial")
        }
        XCTAssertEqual(returnedFailure, failure)

        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["last_outcome"], "partial")
        XCTAssertEqual(diagnostic.diagnosticCode, "openai.transport.account.timeout")
    }

    func testMalformedAccountMetadataReturnsPartialWhileKeepingValidQuotaPatch() async {
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: providerSource(),
            accountResponses: [.success(Data(#"{"account":"malformed"}"#.utf8))],
            rateLimitResponses: [.success(fullRateLimitsJSON(codexUsed: 40, sparkUsed: 1))]
        )
        let adapter = OpenAIProviderAdapter(
            reader: reader,
            now: { Date(timeIntervalSince1970: 100) }
        )

        let result = await adapter.read(scope: .provider)
        guard case let .partial(patch, failure) = result else {
            return XCTFail("Expected account metadata failure to remain partial")
        }
        XCTAssertEqual(failure.code, .schemaMismatch)
        XCTAssertEqual(failure.retryClass, .backoff)
        XCTAssertEqual(failure.recovery, .retry)
        guard case let .replaceAll(products) = patch.productCollectionMutation else {
            return XCTFail("Account-only failure must not make the quota product set partial")
        }
        XCTAssertEqual(products.map(\.sourceProductID), ["codex", "codex_bengalfox"])
        XCTAssertEqual(patch.updatedProducts.map(\.sourceProductID), ["codex", "codex_bengalfox"])
        XCTAssertTrue(patch.updatedProducts.allSatisfy { $0.state.presence == .unknown })
    }

    func testMissingOrNullResetContainerReturnsSuccessfulPatchWithoutFabricatedEntitlement() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 8_000)
        let source = providerSource()
        let missingPayload = Data(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 30, "windowDurationMins": 10080 }
            }
          }
        }
        """#.utf8)
        let nullPayload = Data(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 40, "windowDurationMins": 10080 }
            }
          },
          "rateLimitResetCredits": null
        }
        """#.utf8)
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: source,
            accountResponses: [.success(accountJSON()), .success(accountJSON())],
            rateLimitResponses: [.success(missingPayload), .success(nullPayload)]
        )
        let adapter = OpenAIProviderAdapter(reader: reader, now: { fetchedAt })
        var state = ProviderBootstrap.initialState(
            id: .openAI,
            capabilities: adapter.capabilities,
            now: fetchedAt.addingTimeInterval(-1)
        )

        for expectedUsed in [Decimal(30), Decimal(40)] {
            guard case let .successPatch(patch) = await adapter.read(scope: .provider) else {
                return XCTFail("A missing/null reset field must be a failure-free success patch")
            }
            XCTAssertNil(patch.resetEntitlements)
            state = ProviderReducer.reduce(
                state: state,
                event: .refreshPatchSucceeded(patch),
                now: fetchedAt
            )
            let committed = try XCTUnwrap(state.lastGood)
            XCTAssertTrue(committed.resetEntitlements.isEmpty)
            XCTAssertEqual(try usedPercent(in: committed, productID: "codex"), expectedUsed)
            XCTAssertEqual(state.freshness, .fresh(asOf: fetchedAt))
            XCTAssertNil(state.failure)
        }

        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["last_outcome"], "success")
        XCTAssertEqual(diagnostic.safeFields["invalid_reset_summary_count"], "0")
    }

    func testResetOmissionReplacesCompleteProductsButRetainsPriorResetStale() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 8_000)
        let source = providerSource()
        let firstPayload = Data(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 20, "windowDurationMins": 10080 }
            },
            "codex_bengalfox": {
              "limitId": "codex_bengalfox",
              "limitName": "GPT-5.3-Codex-Spark",
              "primary": { "usedPercent": 1, "windowDurationMins": 10080 }
            }
          },
          "rateLimitResetCredits": { "availableCount": 1, "details": null }
        }
        """#.utf8)
        let secondPayload = Data(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 30, "windowDurationMins": 10080 }
            }
          },
          "rateLimitResetCredits": null
        }
        """#.utf8)
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: source,
            accountResponses: [.success(accountJSON()), .success(accountJSON())],
            rateLimitResponses: [.success(firstPayload), .success(secondPayload)]
        )
        let adapter = OpenAIProviderAdapter(reader: reader, now: { fetchedAt })

        guard case let .success(first) = await adapter.read(scope: .provider) else {
            return XCTFail("Explicit reset summary should be a complete success")
        }
        guard case let .successPatch(patch) = await adapter.read(scope: .provider) else {
            return XCTFail("Legal reset omission should be a success patch")
        }
        guard case let .replaceAll(replacements) = patch.productCollectionMutation else {
            return XCTFail("A complete quota surface must replace the product set")
        }
        XCTAssertEqual(replacements.map(\.sourceProductID), ["codex"])

        var state = ProviderBootstrap.initialState(
            id: .openAI,
            capabilities: adapter.capabilities,
            now: fetchedAt.addingTimeInterval(-1)
        )
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshSucceeded(first),
            now: fetchedAt
        )
        let patchAt = fetchedAt.addingTimeInterval(60)
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshPatchSucceeded(patch),
            now: patchAt
        )

        let committed = try XCTUnwrap(state.lastGood)
        XCTAssertEqual(committed.products.map(\.sourceProductID), ["codex"])
        XCTAssertEqual(try usedPercent(in: committed, productID: "codex"), Decimal(30))
        XCTAssertEqual(committed.resetEntitlements.first?.availableCount, Decimal(1))
        guard case let .stale(asOf, evaluatedAt) = try XCTUnwrap(
            committed.resetEntitlements.first
        ).state.freshness else {
            return XCTFail("The retained reset row must be stale")
        }
        XCTAssertEqual(asOf, fetchedAt)
        XCTAssertEqual(evaluatedAt, patchAt)
        XCTAssertEqual(state.freshness, .stale(asOf: fetchedAt, evaluatedAt: patchAt))
        XCTAssertNil(state.failure)

        let projection = LiveProviderProjectionMapper.map(state, now: patchAt)
        XCTAssertEqual(
            projection.partialDataState,
            Stage3PartialDataState(freshAsOf: fetchedAt, retainedStaleAsOf: fetchedAt)
        )
        let projectedMetrics = projection.products.flatMap(\.metrics)
        XCTAssertEqual(
            projectedMetrics.first { $0.title == "Codex" }?.dataState,
            .fresh(asOf: fetchedAt)
        )
        XCTAssertEqual(
            projectedMetrics.first { $0.windowBadge == "重置权益" }?.dataState,
            .stale(asOf: fetchedAt)
        )
    }

    func testValidResetCountWithMalformedDetailSucceedsAsCountOnly() async throws {
        let payload = Data(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 35, "windowDurationMins": 10080 }
            }
          },
          "rateLimitResetCredits": {
            "availableCount": 2,
            "details": [
              { "id": "broken", "status": "available", "expiresAt": "not-a-timestamp" }
            ]
          }
        }
        """#.utf8)
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: providerSource(),
            accountResponses: [.success(accountJSON())],
            rateLimitResponses: [.success(payload)]
        )
        let adapter = OpenAIProviderAdapter(reader: reader)

        guard case let .success(data) = await adapter.read(scope: .provider) else {
            return XCTFail("Malformed optional detail must not downgrade a valid count")
        }
        let summary = try XCTUnwrap(data.resetEntitlements.first)
        XCTAssertEqual(summary.availableCount, Decimal(2))
        XCTAssertEqual(summary.details, [])

        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["last_outcome"], "success")
        XCTAssertEqual(diagnostic.safeFields["invalid_reset_detail_count"], "1")
        XCTAssertEqual(diagnostic.safeFields["invalid_reset_summary_count"], "0")
    }

    func testMalformedResetSummaryReturnsValidBucketPatchWithoutClearingEntitlement() async {
        let payload = Data(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 35, "windowDurationMins": 10080 }
            }
          },
          "rateLimitResetCredits": { "availableCount": "opaque", "details": [] }
        }
        """#.utf8)
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: providerSource(),
            accountResponses: [.success(accountJSON())],
            rateLimitResponses: [.success(payload)]
        )
        let adapter = OpenAIProviderAdapter(
            reader: reader,
            now: { Date(timeIntervalSince1970: 100) }
        )

        guard case let .partial(patch, failure) = await adapter.read(scope: .provider) else {
            return XCTFail("A malformed optional reset summary must not fail valid buckets")
        }
        XCTAssertEqual(failure.code, .schemaMismatch)
        XCTAssertEqual(failure.retryClass, .backoff)
        XCTAssertEqual(failure.recovery, .retry)
        XCTAssertEqual(patch.updatedProducts.map(\.sourceProductID), ["codex"])
        XCTAssertNil(patch.resetEntitlements)
        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["invalid_reset_summary_count"], "1")
    }

    func testMalformedResetSummaryStillReplacesCompleteProductSurface() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 8_000)
        let initialPayload = Data(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 20, "windowDurationMins": 10080 }
            },
            "codex_bengalfox": {
              "limitId": "codex_bengalfox",
              "limitName": "GPT-5.3-Codex-Spark",
              "primary": { "usedPercent": 1, "windowDurationMins": 10080 }
            }
          },
          "rateLimitResetCredits": { "availableCount": 1, "details": null }
        }
        """#.utf8)
        let malformedResetPayload = Data(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 35, "windowDurationMins": 10080 }
            }
          },
          "rateLimitResetCredits": { "availableCount": "opaque", "details": [] }
        }
        """#.utf8)
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: providerSource(),
            accountResponses: [.success(accountJSON()), .success(accountJSON())],
            rateLimitResponses: [.success(initialPayload), .success(malformedResetPayload)]
        )
        let adapter = OpenAIProviderAdapter(reader: reader, now: { fetchedAt })

        guard case let .success(initial) = await adapter.read(scope: .provider) else {
            return XCTFail("Expected complete initial quota")
        }
        guard case let .partial(patch, failure) = await adapter.read(scope: .provider) else {
            return XCTFail("Malformed reset summary must remain a retryable partial")
        }
        guard case let .replaceAll(replacements) = patch.productCollectionMutation else {
            return XCTFail("A complete quota surface must replace stale products")
        }
        XCTAssertEqual(replacements.map(\.sourceProductID), ["codex"])
        XCTAssertNil(patch.resetEntitlements)
        XCTAssertEqual(failure.retryClass, .backoff)

        var state = ProviderBootstrap.initialState(
            id: .openAI,
            capabilities: adapter.capabilities,
            now: fetchedAt.addingTimeInterval(-1)
        )
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshSucceeded(initial),
            now: fetchedAt
        )
        let partialAt = fetchedAt.addingTimeInterval(60)
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshPartiallySucceeded(patch, failure),
            now: partialAt
        )

        let committed = try XCTUnwrap(state.lastGood)
        XCTAssertEqual(committed.products.map(\.sourceProductID), ["codex"])
        XCTAssertEqual(try usedPercent(in: committed, productID: "codex"), Decimal(35))
        XCTAssertEqual(committed.resetEntitlements.first?.availableCount, Decimal(1))
        guard case .fresh = try XCTUnwrap(committed.products.first).state.freshness else {
            return XCTFail("Current Codex data must remain fresh")
        }
        guard case .stale = try XCTUnwrap(committed.resetEntitlements.first).state.freshness else {
            return XCTFail("Only the retained reset row should be stale")
        }
        XCTAssertEqual(state.freshness, .stale(asOf: fetchedAt, evaluatedAt: partialAt))
    }

    func testDiscoverUsesTypedAccountFieldForAuthenticationWithoutNotEntitled() async {
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: providerSource(),
            accountResponses: [.success(accountJSON(requiresAuth: true, accountType: nil))],
            rateLimitResponses: []
        )
        let adapter = OpenAIProviderAdapter(reader: reader, now: { Date(timeIntervalSince1970: 42) })

        let result = await adapter.discover()
        guard case let .success(discovery) = result else {
            return XCTFail("Expected typed requires-login discovery")
        }
        guard case .requiresLogin = discovery.connection else {
            return XCTFail("Expected requiresLogin connection")
        }
        guard case .warning = discovery.authentication else {
            return XCTFail("Expected warning authentication evidence")
        }
        XCTAssertNil(discovery.presence)
        XCTAssertNil(discovery.resolvedPresence)

        let calls = await reader.calls()
        XCTAssertEqual(calls.accountReads, 1)
        XCTAssertEqual(calls.rateLimitReads, 0)
    }

    func testDiscoverTreatsHealthyChatGPTAccountAsConnectedWhenProviderRequiresOpenAIAuth() async {
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: providerSource(),
            accountResponses: [
                .success(accountJSON(requiresAuth: true, accountType: "chatgpt"))
            ],
            rateLimitResponses: []
        )
        let adapter = OpenAIProviderAdapter(
            reader: reader,
            now: { Date(timeIntervalSince1970: 43) }
        )

        let result = await adapter.discover()
        guard case let .success(discovery) = result else {
            return XCTFail("Expected healthy ChatGPT discovery")
        }
        XCTAssertEqual(discovery.connection, .connected)
        guard case .healthy = discovery.authentication else {
            return XCTFail("Expected healthy authentication")
        }
        XCTAssertEqual(discovery.presence, .entitled)
        guard case .some(.entitled) = discovery.resolvedPresence else {
            return XCTFail("Expected authoritative entitlement from the account payload")
        }

        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.diagnosticCode, "openai.discover.success")
        XCTAssertEqual(diagnostic.safeFields["last_outcome"], "success")
    }

    func testDiscoverTreatsHealthyAPIKeyAccountAsConnectedWhenProviderRequiresOpenAIAuth() async {
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: providerSource(),
            accountResponses: [
                .success(accountJSON(requiresAuth: true, accountType: "apiKey"))
            ],
            rateLimitResponses: []
        )
        let adapter = OpenAIProviderAdapter(reader: reader)

        let result = await adapter.discover()
        guard case let .success(discovery) = result else {
            return XCTFail("Expected healthy API-key discovery")
        }
        XCTAssertEqual(discovery.connection, .connected)
        guard case .healthy = discovery.authentication else {
            return XCTFail("Expected healthy authentication")
        }
        XCTAssertEqual(discovery.presence, .entitled)
        guard case .some(.entitled) = discovery.resolvedPresence else {
            return XCTFail("Expected authoritative entitlement from the account payload")
        }
    }

    func testDiscoverWithoutAccountDoesNotRequestLoginWhenActiveProviderNeedsNoOpenAIAuth() async {
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: providerSource(),
            accountResponses: [.success(accountJSON(requiresAuth: false, accountType: nil))],
            rateLimitResponses: []
        )
        let adapter = OpenAIProviderAdapter(reader: reader)

        let result = await adapter.discover()
        guard case let .success(discovery) = result else {
            return XCTFail("Expected successful provider-neutral discovery")
        }
        XCTAssertEqual(discovery.connection, .connected)
        guard case .healthy = discovery.authentication else {
            return XCTFail("An active provider that needs no OpenAI auth is not a login failure")
        }
        XCTAssertNil(discovery.presence)
        XCTAssertNil(discovery.resolvedPresence)
    }

    func testDiscoverDoesNotClassifyFailureFromErrorText() async {
        let failure = ProviderFailure(
            code: .serviceUnavailable,
            retryClass: .backoff,
            userMessageKey: "requires login expired auth",
            diagnosticCode: "fixture.requires-login-looking-text",
            recovery: .retry
        )
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: providerSource(),
            accountResponses: [.failure(failure)],
            rateLimitResponses: []
        )
        let adapter = OpenAIProviderAdapter(reader: reader)

        let result = await adapter.discover()
        XCTAssertEqual(result, .failure(failure))
    }

    func testLoginHonorsCapabilityButNeverInvokesReaderOrLoginTransport() async {
        let reader = FakeOpenAIAppServerReader(
            sourceIdentity: providerSource(),
            accountResponses: [],
            rateLimitResponses: []
        )
        let capabilities = ProviderCapabilities(
            contractVersion: "usage-butler-provider-contract-v0.8",
            loginMethod: .oauth,
            hasOfficialDocumentation: true,
            allowsExecutableSelection: true
        )
        let adapter = OpenAIProviderAdapter(reader: reader, capabilities: capabilities)

        guard case let .failure(unwired) = await adapter.login(method: .oauth) else {
            return XCTFail("Expected explicitly unwired login")
        }
        XCTAssertEqual(unwired.diagnosticCode, "openai.login.not_wired")
        XCTAssertEqual(unwired.recovery, .openOfficialDocumentation)

        guard case let .failure(unsupported) = await adapter.login(method: .sso) else {
            return XCTFail("Expected capability mismatch")
        }
        XCTAssertEqual(unsupported.diagnosticCode, "openai.login.unsupported_method")

        let calls = await reader.calls()
        XCTAssertEqual(calls.accountReads, 0)
        XCTAssertEqual(calls.rateLimitReads, 0)
        XCTAssertEqual(calls.shutdowns, 0)
    }

    private func usedPercent(in data: ProviderQuotaData, productID: String) throws -> Decimal {
        let product = try XCTUnwrap(data.products.first { $0.sourceProductID == productID })
        let metric = try XCTUnwrap(product.metrics.first)
        guard case let .percent(percent) = metric.value else {
            XCTFail("Expected percent metric")
            return 0
        }
        return percent.sourceValue
    }

    private func providerSource() -> ProviderSourceIdentity {
        ProviderSourceIdentity(
            providerID: .openAI,
            adapterID: "openai.codex-app-server",
            executableIdentity: "selected-codex-v1",
            cliVersion: "0.147.0",
            schemaVersion: "account-rate-limits-v1",
            contractVersion: "usage-butler-provider-contract-v0.8"
        )
    }

    private func accountJSON(
        requiresAuth: Bool = false,
        accountType: String? = "chatgpt"
    ) -> Data {
        let account: String
        switch accountType {
        case .none:
            account = "null"
        case .some("chatgpt"):
            account = #"{"type":"chatgpt","planType":"pro"}"#
        case let .some(type):
            account = #"{"type":"\#(type)"}"#
        }
        return Data(
            #"{"account":\#(account),"requiresOpenaiAuth":\#(requiresAuth)}"#.utf8
        )
    }

    private func fullRateLimitsJSON(codexUsed: Int, sparkUsed: Int) -> Data {
        Data(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": {
                "usedPercent": \#(codexUsed),
                "windowDurationMins": 10080,
                "resetsAt": 1786846755
              },
              "planType": "pro",
              "credits": { "hasCredits": true, "unlimited": false, "balance": "12.5" }
            },
            "codex_bengalfox": {
              "limitId": "codex_bengalfox",
              "limitName": "GPT-5.3-Codex-Spark",
              "primary": {
                "usedPercent": \#(sparkUsed),
                "windowDurationMins": 10080,
                "resetsAt": 1786880818
              },
              "planType": "pro"
            }
          },
          "rateLimitResetCredits": { "availableCount": 0, "details": [] }
        }
        """#.utf8)
    }

    private func malformedSparkJSON(codexUsed: Int) -> Data {
        Data(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": {
                "usedPercent": \#(codexUsed),
                "windowDurationMins": 10080,
                "resetsAt": 1786846755
              },
              "planType": "pro"
            },
            "codex_bengalfox": {
              "limitId": "codex_bengalfox",
              "limitName": "GPT-5.3-Codex-Spark",
              "primary": {
                "usedPercent": "malformed",
                "windowDurationMins": 10080,
                "resetsAt": 1786880818
              },
              "planType": "pro"
            }
          }
        }
        """#.utf8)
    }
}

private struct FakeOpenAIReaderCalls: Equatable, Sendable {
    let accountReads: Int
    let rateLimitReads: Int
    let shutdowns: Int
}

private actor FakeOpenAIAppServerReader: OpenAIAppServerReader {
    nonisolated let sourceIdentity: ProviderSourceIdentity

    private var accountResponses: [Result<Data, ProviderFailure>]
    private var rateLimitResponses: [Result<Data, ProviderFailure>]
    private var accountReadCount = 0
    private var rateLimitReadCount = 0
    private var shutdownCount = 0

    init(
        sourceIdentity: ProviderSourceIdentity,
        accountResponses: [Result<Data, ProviderFailure>],
        rateLimitResponses: [Result<Data, ProviderFailure>]
    ) {
        self.sourceIdentity = sourceIdentity
        self.accountResponses = accountResponses
        self.rateLimitResponses = rateLimitResponses
    }

    func readAccount() async -> Result<Data, ProviderFailure> {
        accountReadCount += 1
        guard !accountResponses.isEmpty else {
            return .failure(Self.exhaustedFailure(operation: "account"))
        }
        return accountResponses.removeFirst()
    }

    func readRateLimits() async -> Result<Data, ProviderFailure> {
        rateLimitReadCount += 1
        guard !rateLimitResponses.isEmpty else {
            return .failure(Self.exhaustedFailure(operation: "rate_limits"))
        }
        return rateLimitResponses.removeFirst()
    }

    func shutdown() async {
        shutdownCount += 1
    }

    func calls() -> FakeOpenAIReaderCalls {
        FakeOpenAIReaderCalls(
            accountReads: accountReadCount,
            rateLimitReads: rateLimitReadCount,
            shutdowns: shutdownCount
        )
    }

    private static func exhaustedFailure(operation: String) -> ProviderFailure {
        ProviderFailure(
            code: .protocolViolation,
            retryClass: .never,
            userMessageKey: "fixture.exhausted",
            diagnosticCode: "fixture.\(operation).exhausted",
            recovery: nil
        )
    }
}
