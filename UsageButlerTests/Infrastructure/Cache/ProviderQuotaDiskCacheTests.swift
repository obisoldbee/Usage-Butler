import Darwin
import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain
@testable import UsageButlerInfrastructure

final class ProviderQuotaDiskCacheTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_390_000)
    private let fetchedAt = Date(timeIntervalSince1970: 1_786_300_000)
    private let components = ["UsageButlerTests", "ProviderQuota", "v1"]

    func testRoundTripKeepsQuotaDataNeutralUntilCoreMarksProviderStale() async throws {
        let support = try TemporaryApplicationSupport()
        let cache = try makeCache(in: support)
        let original = quotaData(providerID: .openAI)

        let writeResult = await cache.save(original)
        XCTAssertEqual(writeResult, .success(writtenAt: fixedNow))
        let loaded = try unwrapHit(await cache.load(providerID: .openAI))
        XCTAssertEqual(loaded, original)

        for product in loaded.products {
            XCTAssertEqual(product.state.freshness, .unknown)
            for metric in product.metrics {
                XCTAssertEqual(metric.state.freshness, .unknown)
                XCTAssertNil(metric.state.failure)
            }
        }

        let state = providerState(providerID: .openAI)
        let reduced = ProviderReducer.reduce(
            state: state,
            event: .cacheLoaded(loaded),
            now: fixedNow
        )
        XCTAssertEqual(
            reduced.freshness,
            .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
        )
        let reducedData = try XCTUnwrap(reduced.lastGood)
        for product in reducedData.products {
            XCTAssertEqual(
                product.state.freshness,
                .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
            )
            for metric in product.metrics {
                XCTAssertEqual(
                    metric.state.freshness,
                    .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
                )
            }
        }
        XCTAssertTrue(reducedData.balances.allSatisfy {
            $0.state.freshness == .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
        })
        XCTAssertTrue(reducedData.resetEntitlements.allSatisfy {
            $0.state.freshness == .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
        })
    }

    func testMissIsDistinctAndEntriesArePerProvider() async throws {
        let support = try TemporaryApplicationSupport()
        let cache = try makeCache(in: support)

        let initialOpenAI = await cache.load(providerID: .openAI)
        XCTAssertEqual(initialOpenAI, .miss)
        let writeResult = await cache.save(quotaData(providerID: .openAI))
        XCTAssertEqual(writeResult, .success(writtenAt: fixedNow))
        let miniMaxResult = await cache.load(providerID: .miniMax)
        XCTAssertEqual(miniMaxResult, .miss)
        let loadedOpenAI = try unwrapHit(await cache.load(providerID: .openAI))
        XCTAssertEqual(loadedOpenAI.providerID, .openAI)
    }

    func testRetainedMetricProvenancePreservesItsOwnSourceSchemaAndVersion() async throws {
        let support = try TemporaryApplicationSupport()
        let cache = try makeCache(in: support)
        let original = quotaData(
            providerID: .openAI,
            metricSourceVersion: "0.9.0"
        )

        let writeResult = await cache.save(original)
        XCTAssertEqual(writeResult, .success(writtenAt: fixedNow))
        let loaded = try unwrapHit(await cache.load(providerID: .openAI))
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.source.cliVersion, "1.2.3")
        XCTAssertEqual(
            loaded.products.first?.metrics.first?.provenance.providerSource.cliVersion,
            "0.9.0"
        )
        XCTAssertEqual(
            loaded.products.first?.metrics.first?.provenance.providerSource.schemaVersion,
            "quota-schema-legacy"
        )
    }

    func testCorruptOversizedUnknownSchemaAndUnknownVersionAreTypedFailures() async throws {
        let support = try TemporaryApplicationSupport()
        let cache = try makeCache(in: support, maximumFileBytes: 64 * 1024)
        let directory = cacheDirectory(in: support)
        let file = cacheFile(in: support, providerID: .openAI)
        _ = await cache.load(providerID: .openAI)

        try writeRaw(Data("{".utf8), to: file)
        var failure = try unwrapFailure(await cache.load(providerID: .openAI))
        XCTAssertEqual(failure.code, .cacheCorrupt)
        XCTAssertEqual(failure.diagnosticCode, "cache.read.decode_invalid")

        try writeRaw(Data(repeating: 0x41, count: 64 * 1024 + 1), to: file)
        failure = try unwrapFailure(await cache.load(providerID: .openAI))
        XCTAssertEqual(failure.code, .cacheCorrupt)
        XCTAssertEqual(failure.diagnosticCode, "cache.file.oversized")

        var writeResult = await cache.save(quotaData(providerID: .openAI))
        XCTAssertEqual(writeResult, .success(writtenAt: fixedNow))
        try mutateEnvelope(at: file, key: "schema", value: "future.cache.schema")
        failure = try unwrapFailure(await cache.load(providerID: .openAI))
        XCTAssertEqual(failure.code, .schemaMismatch)
        XCTAssertEqual(failure.diagnosticCode, "cache.read.unknown_schema")

        writeResult = await cache.save(quotaData(providerID: .openAI))
        XCTAssertEqual(writeResult, .success(writtenAt: fixedNow))
        try mutateEnvelope(at: file, key: "version", value: 99)
        failure = try unwrapFailure(await cache.load(providerID: .openAI))
        XCTAssertEqual(failure.code, .schemaMismatch)
        XCTAssertEqual(failure.diagnosticCode, "cache.read.unknown_version")

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy {
            !$0.hasSuffix(".tmp")
        })
    }

    func testSymlinkAndFIFOAreRejectedWithoutFollowingOrBlocking() async throws {
        let support = try TemporaryApplicationSupport()
        let cache = try makeCache(in: support)
        let file = cacheFile(in: support, providerID: .openAI)
        _ = await cache.load(providerID: .openAI)

        let external = support.root.appendingPathComponent("outside.json", isDirectory: false)
        try writeRaw(Data("outside-sentinel".utf8), to: external)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)

        var failure = try unwrapFailure(await cache.load(providerID: .openAI))
        XCTAssertEqual(failure.code, .permissionDenied)
        XCTAssertEqual(failure.diagnosticCode, "cache.file.symlink_or_nonregular")
        XCTAssertEqual(try Data(contentsOf: external), Data("outside-sentinel".utf8))

        try FileManager.default.removeItem(at: file)
        let fifoResult = file.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }
        XCTAssertEqual(fifoResult, 0)
        failure = try unwrapFailure(await cache.load(providerID: .openAI))
        XCTAssertEqual(failure.code, .permissionDenied)
        XCTAssertEqual(failure.diagnosticCode, "cache.file.symlink_or_nonregular")
    }

    func testAtomicReplacementChangesInodeAndLeavesNoTemporaryEntries() async throws {
        let support = try TemporaryApplicationSupport()
        let cache = try makeCache(in: support)
        let file = cacheFile(in: support, providerID: .openAI)
        let directory = cacheDirectory(in: support)
        let first = quotaData(providerID: .openAI, balanceAmount: 12)
        let second = quotaData(providerID: .openAI, balanceAmount: 99)

        var writeResult = await cache.save(first)
        XCTAssertEqual(writeResult, .success(writtenAt: fixedNow))
        let firstInode = try inode(of: file)
        writeResult = await cache.save(second)
        XCTAssertEqual(writeResult, .success(writtenAt: fixedNow))
        let secondInode = try inode(of: file)

        XCTAssertNotEqual(firstInode, secondInode, "replacement must publish a new temp inode")
        let loaded = try unwrapHit(await cache.load(providerID: .openAI))
        XCTAssertEqual(loaded, second)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(entries, [ProviderQuotaDiskCache.cacheFileName(for: .openAI)])
    }

    func testProviderAndSourceIdentityMismatchesAreRejected() async throws {
        let support = try TemporaryApplicationSupport()
        let cache = try makeCache(in: support)

        let invalidSource = source(providerID: .miniMax)
        let invalidData = ProviderQuotaData(
            providerID: .openAI,
            source: invalidSource,
            fetchedAt: fetchedAt,
            products: [],
            balances: [],
            resetEntitlements: []
        )
        var failure = try unwrapFailure(await cache.save(invalidData))
        XCTAssertEqual(failure.code, .identityMismatch)
        let miss = await cache.load(providerID: .openAI)
        XCTAssertEqual(miss, .miss)

        var writeResult = await cache.save(quotaData(providerID: .openAI))
        XCTAssertEqual(writeResult, .success(writtenAt: fixedNow))
        let file = cacheFile(in: support, providerID: .openAI)
        try mutateEnvelope(at: file, key: "providerID", value: ProviderID.miniMax.rawValue)
        failure = try unwrapFailure(await cache.load(providerID: .openAI))
        XCTAssertEqual(failure.code, .identityMismatch)
        XCTAssertEqual(failure.diagnosticCode, "cache.read.identity_mismatch")

        writeResult = await cache.save(quotaData(providerID: .openAI))
        XCTAssertEqual(writeResult, .success(writtenAt: fixedNow))
        try mutateNestedEnvelope(
            at: file,
            objectKey: "source",
            key: "providerID",
            value: ProviderID.miniMax.rawValue
        )
        failure = try unwrapFailure(await cache.load(providerID: .openAI))
        XCTAssertEqual(failure.code, .identityMismatch)
    }

    func testPersistenceMinimizesTransientAndSensitiveFieldsAndUsesPrivateModes() async throws {
        let support = try TemporaryApplicationSupport()
        let cache = try makeCache(in: support)
        let sensitiveDiagnostic = "account=person@example.com token=never-persist-this"
        let sensitiveRawMessage = "{\"access_token\":\"never-persist-this\"}"
        let data = quotaData(
            providerID: .openAI,
            inferredPlan: true,
            transientFailureDiagnostic: sensitiveDiagnostic,
            sourceStatusMessage: sensitiveRawMessage
        )

        let writeResult = await cache.save(data)
        XCTAssertEqual(writeResult, .success(writtenAt: fixedNow))
        let file = cacheFile(in: support, providerID: .openAI)
        let contents = try String(decoding: Data(contentsOf: file), as: UTF8.self)
        for forbidden in [
            "authentication",
            "connection",
            "failure",
            "person@example.com",
            "never-persist-this",
            "access_token",
            "/Users/"
        ] {
            XCTAssertFalse(contents.contains(forbidden), "cache leaked \(forbidden)")
        }

        let loaded = try unwrapHit(await cache.load(providerID: .openAI))
        XCTAssertNil(loaded.products.first?.planLevel, "inferred plan must not inherit last-good")
        XCTAssertNil(loaded.products.first?.metrics.first?.sourceStatus?.message)
        XCTAssertNil(loaded.products.first?.metrics.first?.state.failure)

        var current = support.root
        for component in components {
            current.appendPathComponent(component, isDirectory: true)
            XCTAssertEqual(try permissions(of: current), mode_t(0o700))
        }
        XCTAssertEqual(try permissions(of: file), mode_t(0o600))

        let unsafe = quotaData(
            providerID: .openAI,
            executableIdentity: "/Users/private-user/bin/codex"
        )
        let failure = try unwrapFailure(await cache.save(unsafe))
        XCTAssertEqual(failure.code, .cacheUnavailable)
        XCTAssertEqual(failure.retryClass, .never)
        XCTAssertFalse(try String(decoding: Data(contentsOf: file), as: UTF8.self).contains("private-user"))
    }

    func testUnsafeFileAndDirectoryModesAndMissingBaseReturnTypedFailures() async throws {
        let support = try TemporaryApplicationSupport()
        let cache = try makeCache(in: support)
        let writeResult = await cache.save(quotaData(providerID: .openAI))
        XCTAssertEqual(writeResult, .success(writtenAt: fixedNow))
        let file = cacheFile(in: support, providerID: .openAI)

        XCTAssertEqual(Darwin.chmod(file.path, mode_t(0o644)), 0)
        var failure = try unwrapFailure(await cache.load(providerID: .openAI))
        XCTAssertEqual(failure.code, .permissionDenied)
        XCTAssertEqual(failure.diagnosticCode, "cache.file.unsafe_mode")

        XCTAssertEqual(Darwin.chmod(file.path, mode_t(0o600)), 0)
        let directory = cacheDirectory(in: support)
        XCTAssertEqual(Darwin.chmod(directory.path, mode_t(0o755)), 0)
        failure = try unwrapFailure(await cache.load(providerID: .openAI))
        XCTAssertEqual(failure.code, .permissionDenied)
        XCTAssertEqual(failure.diagnosticCode, "cache.directory.unsafe_mode")

        let missingBase = support.root.appendingPathComponent("not-created", isDirectory: true)
        let configuration = try ProviderQuotaDiskCacheConfiguration(
            applicationSupportDirectory: missingBase,
            versionedRelativeDirectory: components
        )
        let missingBaseCache = ProviderQuotaDiskCache(configuration: configuration)
        failure = try unwrapFailure(await missingBaseCache.load(providerID: .openAI))
        XCTAssertEqual(failure.code, .cacheUnavailable)
        XCTAssertTrue(failure.diagnosticCode.hasPrefix("cache.directory.open_base.io_"))
    }

    func testOversizedSavePreservesPriorEntryAndLeavesNoTemporaryFiles() async throws {
        let support = try TemporaryApplicationSupport()
        let cache = try makeCache(in: support, maximumFileBytes: 8 * 1024)
        let original = quotaData(providerID: .openAI)
        let writeResult = await cache.save(original)
        XCTAssertEqual(writeResult, .success(writtenAt: fixedNow))

        let oversized = quotaData(
            providerID: .openAI,
            sourceLabel: String(repeating: "safe-label-", count: 2_000)
        )
        let failure = try unwrapFailure(await cache.save(oversized))
        XCTAssertEqual(failure.code, .cacheCorrupt)
        XCTAssertEqual(failure.diagnosticCode, "cache.write.oversized")
        let loaded = try unwrapHit(await cache.load(providerID: .openAI))
        XCTAssertEqual(loaded, original)

        let entries = try FileManager.default.contentsOfDirectory(
            atPath: cacheDirectory(in: support).path
        )
        XCTAssertEqual(entries, [ProviderQuotaDiskCache.cacheFileName(for: .openAI)])
    }

    func testShutdownIsIdempotentAndPermanentlySealsLoadAndSave() async throws {
        let support = try TemporaryApplicationSupport()
        let cache = try makeCache(in: support)
        let original = quotaData(providerID: .openAI)
        let writeResult = await cache.save(original)
        XCTAssertEqual(writeResult, .success(writtenAt: fixedNow))

        await cache.shutdown()
        await cache.shutdown()

        var failure = try unwrapFailure(await cache.load(providerID: .openAI))
        XCTAssertEqual(failure.code, .shutdown)
        XCTAssertEqual(failure.diagnosticCode, "cache.client.shutdown")
        failure = try unwrapFailure(
            await cache.save(quotaData(providerID: .openAI, balanceAmount: 101))
        )
        XCTAssertEqual(failure.code, .shutdown)
        guard case let .failure(clearFailure) = await cache.clear(providerID: .openAI) else {
            return XCTFail("A shut down cache must reject clear")
        }
        XCTAssertEqual(clearFailure.code, .shutdown)

        let replacement = try makeCache(in: support)
        let loaded = try unwrapHit(await replacement.load(providerID: .openAI))
        XCTAssertEqual(loaded, original)
    }

    func testClearIsProviderScopedAndIdempotent() async throws {
        let support = try TemporaryApplicationSupport()
        let cache = try makeCache(in: support)
        let openAI = quotaData(providerID: .openAI)
        let miniMax = quotaData(providerID: .miniMax)
        let openAIWrite = await cache.save(openAI)
        let miniMaxWrite = await cache.save(miniMax)
        XCTAssertEqual(openAIWrite, .success(writtenAt: fixedNow))
        XCTAssertEqual(miniMaxWrite, .success(writtenAt: fixedNow))

        let first = await cache.clear(providerID: .openAI)
        XCTAssertEqual(
            first,
            .success(clearedAt: fixedNow, removedEntry: true)
        )
        let clearedOpenAI = await cache.load(providerID: .openAI)
        let retainedMiniMax = await cache.load(providerID: .miniMax)
        XCTAssertEqual(clearedOpenAI, .miss)
        XCTAssertEqual(try unwrapHit(retainedMiniMax), miniMax)

        let second = await cache.clear(providerID: .openAI)
        XCTAssertEqual(
            second,
            .success(clearedAt: fixedNow, removedEntry: false)
        )
    }

    func testClearRejectsSymlinkAndPreservesExternalTarget() async throws {
        let support = try TemporaryApplicationSupport()
        let cache = try makeCache(in: support)
        _ = await cache.load(providerID: .openAI)
        let file = cacheFile(in: support, providerID: .openAI)
        let external = support.root.appendingPathComponent("external.json")
        try writeRaw(Data("external-sentinel".utf8), to: external)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)

        guard case let .failure(failure) = await cache.clear(providerID: .openAI) else {
            return XCTFail("Expected symlink clear to fail")
        }
        XCTAssertEqual(failure.code, .permissionDenied)
        XCTAssertEqual(failure.diagnosticCode, "cache.file.symlink_or_nonregular")
        XCTAssertEqual(try Data(contentsOf: external), Data("external-sentinel".utf8))
    }

    func testConfigurationRejectsAbsoluteTraversalUnversionedAndOverCapLocations() throws {
        let support = try TemporaryApplicationSupport()

        XCTAssertThrowsError(
            try ProviderQuotaDiskCacheConfiguration(
                applicationSupportDirectory: support.root,
                versionedRelativeDirectory: ["UsageButler", "../escape", "v1"]
            )
        )
        XCTAssertThrowsError(
            try ProviderQuotaDiskCacheConfiguration(
                applicationSupportDirectory: support.root,
                versionedRelativeDirectory: ["UsageButler", "cache"]
            )
        )
        XCTAssertThrowsError(
            try ProviderQuotaDiskCacheConfiguration(
                applicationSupportDirectory: support.root,
                versionedRelativeDirectory: ["UsageButler", "v1"],
                maximumFileBytes: ProviderQuotaDiskCacheConfiguration.hardMaximumFileBytes + 1
            )
        )
    }

    private func makeCache(
        in support: TemporaryApplicationSupport,
        maximumFileBytes: Int = ProviderQuotaDiskCacheConfiguration.hardMaximumFileBytes
    ) throws -> ProviderQuotaDiskCache {
        let configuration = try ProviderQuotaDiskCacheConfiguration(
            applicationSupportDirectory: support.root,
            versionedRelativeDirectory: components,
            maximumFileBytes: maximumFileBytes
        )
        return ProviderQuotaDiskCache(configuration: configuration, now: { [fixedNow] in fixedNow })
    }

    private func cacheDirectory(in support: TemporaryApplicationSupport) -> URL {
        components.reduce(support.root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    private func cacheFile(
        in support: TemporaryApplicationSupport,
        providerID: ProviderID
    ) -> URL {
        cacheDirectory(in: support).appendingPathComponent(
            ProviderQuotaDiskCache.cacheFileName(for: providerID),
            isDirectory: false
        )
    }

    private func source(
        providerID: ProviderID,
        executableIdentity: String = "codex-cli"
    ) -> ProviderSourceIdentity {
        ProviderSourceIdentity(
            providerID: providerID,
            adapterID: "\(providerID.rawValue)-adapter",
            executableIdentity: executableIdentity,
            cliVersion: "1.2.3",
            schemaVersion: "quota-schema-v2",
            contractVersion: "provider-contract-v1"
        )
    }

    private func quotaData(
        providerID: ProviderID,
        balanceAmount: Decimal = 12,
        inferredPlan: Bool = false,
        transientFailureDiagnostic: String? = nil,
        sourceStatusMessage: String? = nil,
        executableIdentity: String = "codex-cli",
        sourceLabel: String = "Weekly quota",
        metricSourceVersion: String? = nil
    ) -> ProviderQuotaData {
        let providerSource = source(
            providerID: providerID,
            executableIdentity: executableIdentity
        )
        let productID = "coding"
        let metricIdentity = MetricSourceIdentity(
            providerID: providerID,
            sourceProductID: productID,
            sourceBucketID: "weekly",
            sourceMetricID: "percent"
        )
        let metricProviderSource: ProviderSourceIdentity
        if let metricSourceVersion {
            metricProviderSource = ProviderSourceIdentity(
                providerID: providerID,
                adapterID: providerSource.adapterID,
                executableIdentity: providerSource.executableIdentity,
                cliVersion: metricSourceVersion,
                schemaVersion: "quota-schema-legacy",
                contractVersion: "provider-contract-legacy"
            )
        } else {
            metricProviderSource = providerSource
        }
        let metricProvenance = MetricProvenance(
            sourceIdentity: metricIdentity,
            providerSource: metricProviderSource,
            fetchedAt: fetchedAt
        )
        let transientFailure = transientFailureDiagnostic.map {
            ProviderFailure(
                code: .networkUnavailable,
                retryClass: .backoff,
                userMessageKey: "provider.failure.network",
                diagnosticCode: $0,
                recovery: .retry
            )
        }
        let metric = QuotaMetric(
            id: MetricID(sourceIdentity: metricIdentity),
            sourceMetricID: metricIdentity.sourceMetricID,
            sourceLabel: sourceLabel,
            window: QuotaWindow(
                kind: .weekly,
                duration: 604_800,
                startsAt: fetchedAt.addingTimeInterval(-3_600),
                endsAt: fetchedAt.addingTimeInterval(601_200),
                timeEvent: QuotaTimeEvent(
                    kind: .reset,
                    occursAt: fetchedAt.addingTimeInterval(601_200)
                )
            ),
            value: .percent(
                DirectedPercent(sourceValue: 42, sourceDirection: .remaining)
            ),
            sourceStatus: SourceStatus(code: "ok", message: sourceStatusMessage),
            provenance: metricProvenance,
            state: nodeState(asOf: fetchedAt, failure: transientFailure)
        )
        let product = QuotaProductData(
            id: ProductID(providerID: providerID, sourceProductID: productID),
            sourceProductID: productID,
            titleKey: "quota.product.coding",
            canonicalOrder: 0,
            planLevel: inferredPlan
                ? PlanLevelObservation(
                    value: "Max",
                    origin: .inferred(
                        ruleID: "fixture-rule-v1",
                        catalogID: "fixture-catalog-v1",
                        sourceVersion: "1.2.3",
                        evidenceFields: ["video.current.totalCount"]
                    ),
                    contractVersion: "provider-contract-v1",
                    fetchedAt: fetchedAt
                )
                : PlanLevelObservation(
                    value: "Pro",
                    origin: .reported(sourceField: "plan.type"),
                    contractVersion: "provider-contract-v1",
                    fetchedAt: fetchedAt
                ),
            state: nodeState(asOf: fetchedAt, failure: transientFailure),
            metrics: [metric]
        )

        let balanceIdentity = MetricSourceIdentity(
            providerID: providerID,
            sourceProductID: productID,
            sourceBucketID: nil,
            sourceMetricID: "balance"
        )
        let balanceProvenance = MetricProvenance(
            sourceIdentity: balanceIdentity,
            providerSource: providerSource,
            fetchedAt: fetchedAt
        )
        let entitlementIdentity = MetricSourceIdentity(
            providerID: providerID,
            sourceProductID: productID,
            sourceBucketID: nil,
            sourceMetricID: "reset-entitlement"
        )
        let entitlementProvenance = MetricProvenance(
            sourceIdentity: entitlementIdentity,
            providerSource: providerSource,
            fetchedAt: fetchedAt
        )

        return ProviderQuotaData(
            providerID: providerID,
            source: providerSource,
            fetchedAt: fetchedAt,
            products: [product],
            balances: [
                QuotaBalance(
                    sourceBalanceID: "credits",
                    amount: balanceAmount,
                    unit: "credits",
                    provenance: balanceProvenance,
                    state: nodeState(asOf: fetchedAt, failure: transientFailure)
                )
            ],
            resetEntitlements: [
                ResetEntitlementSummary(
                    availableCount: 1,
                    details: [
                        ResetEntitlementDetail(
                            sourceID: "reset-1",
                            status: "available",
                            grantedAt: fetchedAt.addingTimeInterval(-86_400),
                            expiresAt: fetchedAt.addingTimeInterval(86_400),
                            title: "Courtesy reset"
                        )
                    ],
                    provenance: entitlementProvenance,
                    state: nodeState(asOf: fetchedAt, failure: transientFailure)
                )
            ]
        )
    }

    private func nodeState(
        asOf: Date,
        failure: ProviderFailure? = nil
    ) -> QuotaNodeState {
        QuotaNodeState(
            presence: .unknown,
            freshness: .unknown,
            refresh: RefreshState(
                activity: .idle,
                gate: .open,
                lastAttemptAt: nil,
                lastSuccessAt: asOf
            ),
            lastAttemptAt: nil,
            lastSuccessAt: asOf,
            failure: failure
        )
    }

    private func providerState(providerID: ProviderID) -> ProviderState {
        let evidence = AuthenticationEvidence(
            authority: .initialDetection,
            observedAt: fetchedAt
        )
        return ProviderState(
            id: providerID,
            capabilities: ProviderCapabilities(
                contractVersion: "provider-contract-v1",
                loginMethod: .oauth,
                hasOfficialDocumentation: true,
                allowsExecutableSelection: true
            ),
            connection: .detecting(startedAt: fetchedAt),
            presence: .unknown,
            authentication: .unknown(evidence),
            refresh: RefreshState(
                activity: .idle,
                gate: .open,
                lastAttemptAt: nil,
                lastSuccessAt: nil
            ),
            lastGood: nil,
            freshness: .unknown,
            discovery: .notStarted,
            persistence: .unknown,
            failure: nil
        )
    }

    private func unwrapHit(
        _ result: ProviderQuotaCacheLoadResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ProviderQuotaData {
        guard case let .hit(data) = result else {
            XCTFail("Expected cache hit, got \(result)", file: file, line: line)
            throw TestFailure.unexpectedResult
        }
        return data
    }

    private func unwrapFailure(
        _ result: ProviderQuotaCacheLoadResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ProviderFailure {
        guard case let .failure(failure) = result else {
            XCTFail("Expected cache failure, got \(result)", file: file, line: line)
            throw TestFailure.unexpectedResult
        }
        return failure
    }

    private func unwrapFailure(
        _ result: ProviderQuotaCacheWriteResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ProviderFailure {
        guard case let .failure(failure) = result else {
            XCTFail("Expected cache failure, got \(result)", file: file, line: line)
            throw TestFailure.unexpectedResult
        }
        return failure
    }

    private func writeRaw(_ data: Data, to file: URL) throws {
        try data.write(to: file)
        guard Darwin.chmod(file.path, mode_t(0o600)) == 0 else {
            throw POSIXTestFailure(errorNumber: errno)
        }
    }

    private func mutateEnvelope(at file: URL, key: String, value: Any) throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        object[key] = value
        try writeRaw(try JSONSerialization.data(withJSONObject: object), to: file)
    }

    private func mutateNestedEnvelope(
        at file: URL,
        objectKey: String,
        key: String,
        value: Any
    ) throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        var nested = try XCTUnwrap(object[objectKey] as? [String: Any])
        nested[key] = value
        object[objectKey] = nested
        try writeRaw(try JSONSerialization.data(withJSONObject: object), to: file)
    }

    private func permissions(of url: URL) throws -> mode_t {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw POSIXTestFailure(errorNumber: errno)
        }
        return status.st_mode & mode_t(0o7777)
    }

    private func inode(of url: URL) throws -> ino_t {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw POSIXTestFailure(errorNumber: errno)
        }
        return status.st_ino
    }
}

private final class TemporaryApplicationSupport: @unchecked Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-butler-provider-cache-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: mode_t(0o700)]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum TestFailure: Error {
    case unexpectedResult
}

private struct POSIXTestFailure: Error {
    let errorNumber: Int32
}
