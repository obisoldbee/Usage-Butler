import CryptoKit
import Darwin
import Foundation
import XCTest
import UsageButlerCore
import UsageButlerDomain
@testable import UsageButlerInfrastructure
@testable import UsageButlerProviders

private let cacheNow = Date(timeIntervalSince1970: 1_792_022_400)
private let cacheFetched = cacheNow.addingTimeInterval(-600)
private func cacheToken(subject: String = "user_CACHE_FAKE_A", signature: String = "FAKE_SIGNATURE", expired: Bool = false) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: ["sub":"auth0|" + subject,"exp":cacheNow.addingTimeInterval(expired ? -1 : 3600).timeIntervalSince1970], options:.sortedKeys)
    return "e30." + payload.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") + "." + signature
}
private actor CacheSessionReader: CursorSessionReading {
    var token: String?
    var count = 0
    init(_ token: String? = cacheToken()) { self.token = token }
    func load() throws -> CursorReadOnlySession? { count += 1; return try token.map { try .init(token:$0,now:cacheNow) } }
    func set(_ token: String?) { self.token = token }
}
private actor CacheNoHTTP: GrokBotHTTPTransport {
    var count = 0
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) { count += 1; throw URLError(.notConnectedToInternet) }
}
private actor CacheAuthorizationGate {
    let grant: GrokBotCacheAssociation
    var calls = 0
    var blockCall: Int?
    var blocked = false
    var release: CheckedContinuation<Void,Never>?
    var arrival: CheckedContinuation<Void,Never>?
    init(_ grant: GrokBotCacheAssociation, blockCall: Int) { self.grant = grant; self.blockCall = blockCall }
    func current() async -> GrokBotCacheAssociation? {
        calls += 1
        if calls == blockCall {
            await withCheckedContinuation { continuation in
                release = continuation; blocked = true; arrival?.resume(); arrival = nil
            }
        }
        return grant // Deliberately stale/non-cooperative authorization snapshot.
    }
    func waitUntilBlocked() async { if blocked { return }; await withCheckedContinuation { arrival = $0 } }
    func resume() { release?.resume(); release = nil }
}
private actor GrokCacheOperationGate: ProviderQuotaCache {
    let original: ProviderQuotaData
    let blockLoad: Bool
    var clearCalls = 0
    var isBlocked = false
    var release: CheckedContinuation<Void,Never>?
    var arrival: CheckedContinuation<Void,Never>?
    init(_ original: ProviderQuotaData, blockLoad: Bool) { self.original = original; self.blockLoad = blockLoad }
    private func block() async {
        await withCheckedContinuation { continuation in
            release = continuation; isBlocked = true; arrival?.resume(); arrival = nil
        }
    }
    func waitUntilBlocked() async { if isBlocked { return }; await withCheckedContinuation { arrival = $0 } }
    func resume() { release?.resume(); release = nil }
    func load(providerID: ProviderID) async -> ProviderQuotaCacheLoadResult {
        if blockLoad { await block() }
        return .hit(original) // Deliberately late even after clear.
    }
    func save(_ data: ProviderQuotaData) async -> ProviderQuotaCacheWriteResult { .success(writtenAt:cacheNow) }
    func clear(providerID: ProviderID) async -> ProviderQuotaCacheClearResult {
        clearCalls += 1
        if !blockLoad && clearCalls == 1 { await block() }
        return .success(clearedAt:cacheNow,removedEntry:true)
    }
    func shutdown() async {}
}
private actor CacheStartupClockGate: ClockPort {
    var reads = 0
    var blocked = false
    var release: CheckedContinuation<Void,Never>?
    var arrival: CheckedContinuation<Void,Never>?
    func reading() async -> ClockReading {
        reads += 1
        if reads == 1 {
            await withCheckedContinuation { continuation in
                release = continuation; blocked = true; arrival?.resume(); arrival = nil
            }
        }
        return .init(wallTime:cacheNow,monotonicTime:.init(nanoseconds:0))
    }
    func waitUntilBlocked() async { if blocked { return }; await withCheckedContinuation { arrival = $0 } }
    func resume() { release?.resume(); release = nil }
    func sleep(until deadline: MonotonicInstant) async throws { throw CancellationError() }
}
private struct CacheFixedClock: ClockPort {
    func reading() async -> ClockReading { .init(wallTime:cacheNow,monotonicTime:.init(nanoseconds:0)) }
    func sleep(until deadline: MonotonicInstant) async throws { throw CancellationError() }
}

@MainActor final class GrokBotEncryptedQuotaCacheTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws { for root in roots { try FileManager.default.removeItem(at:root) }; roots = [] }
    private func configuration() throws -> ProviderQuotaDiskCacheConfiguration {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ub-grok-encrypted-synthetic-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]); roots.append(root)
        return try .init(applicationSupportDirectory:root,versionedRelativeDirectory:["GrokCacheTests","v1"])
    }
    private func path(_ config: ProviderQuotaDiskCacheConfiguration) -> URL {
        config.versionedRelativeDirectory.reduce(config.applicationSupportDirectory) { $0.appendingPathComponent($1) }.appendingPathComponent("grokBot.quota-last-good.json")
    }
    private func adapter(_ reader: CacheSessionReader = CacheSessionReader()) -> GrokBotProviderAdapter {
        .init(reader:reader,client:.init(transport:CacheNoHTTP()),now:{ cacheNow })
    }
    private func cache(_ config: ProviderQuotaDiskCacheConfiguration, _ adapter: GrokBotProviderAdapter) -> GrokBotEncryptedQuotaCache {
        .init(configuration:config,authorization:{ await adapter.quotaCacheAssociation() },now:{ cacheNow })
    }
    private func association(_ adapter: GrokBotProviderAdapter) async throws -> GrokBotCacheAssociation {
        let grant = await adapter.quotaCacheAssociation()
        return try XCTUnwrap(grant)
    }
    private func data(_ adapter: GrokBotProviderAdapter) async throws -> ProviderQuotaData {
        await adapter.setAccessEnabled(true)
        let grant = try await association(adapter)
        return try GrokSharedQuotaMapper.map(Data(#"{"availability":"available","weeklyIncludedStatus":{"status":"metered"},"weeklyIncludedUsage":{"usedCents":275,"budgetCents":1000,"periodStart":"2026-10-01T00:00:00Z","resetsAt":"2026-10-22T00:00:00Z","resetCounter":2},"monthlyUsage":{"usedCents":23,"limitCents":null,"creditsUsedCents":11},"ignoredSecret":"RAW_SERVER_SECRET"}"#.utf8),fetchedAt:cacheFetched,sessionScope:grant.sessionScope)
    }
    private func controller(_ adapter: GrokBotProviderAdapter, _ cache: any ProviderQuotaCache, enabled: Bool = true) throws -> ProviderController {
        let clock = CacheFixedClock()
        return try .init(initialState:ProviderBootstrap.initialState(id:.grokBot,capabilities:adapter.capabilities,now:cacheNow),initiallyEnabled:enabled,adapter:adapter,cache:cache,clock:clock,scheduler:RefreshScheduler(clock:clock),policy:.init(cadence:.manualOnly,manualCooldown:.seconds(0),retryBackoff:[.seconds(60)],shutdownGrace:.seconds(1)))
    }
    func testCrossInstanceRestartRestoresStaleWithoutChangingOriginalSuccessTime() async throws {
        let token = cacheToken()
        let config = try configuration(), firstAdapter = adapter(CacheSessionReader(token))
        let original = try await data(firstAdapter), first = cache(config,firstAdapter)
        let saved = await first.save(original); XCTAssertEqual(saved,.success(writtenAt:cacheNow))
        await first.shutdown(); await firstAdapter.shutdown()
        let secondAdapter = adapter(CacheSessionReader(token)), second = cache(config,secondAdapter)
        let controller = try controller(secondAdapter,second)
        _ = await controller.send(.start)
        let state = await controller.projection().state
        if case let .degraded(failure) = state.persistence { XCTFail(failure.diagnosticCode) }
        XCTAssertEqual(state.lastGood?.fetchedAt,cacheFetched)
        XCTAssertEqual(state.freshness,.stale(asOf:cacheFetched,evaluatedAt:cacheNow))
        XCTAssertEqual(state.lastGood?.grokBotUsage,original.grokBotUsage)
        XCTAssertNotEqual(state.lastGood?.source.sessionScope,original.source.sessionScope)
        XCTAssertEqual(state.lastGood?.products[0].metrics[0].provenance.providerSource,state.lastGood?.source)
        XCTAssertEqual(state.lastGood?.products[0].metrics[0].state.lastSuccessAt,cacheFetched)
        if case .healthy = state.authentication { XCTFail("Stale local association is not server authentication") }
    }
    func testDifferentAccountRotatedSessionExpiredAndMissingSourceAreSafeMisses() async throws {
        let config = try configuration(), firstAdapter = adapter()
        let original = try await data(firstAdapter), first = cache(config,firstAdapter)
        _ = await first.save(original); await first.shutdown()
        for token in [cacheToken(subject:"user_CACHE_FAKE_B"),cacheToken(signature:"ROTATED_FAKE_SIGNATURE"),cacheToken(expired:true),"not-a-jwt",nil] {
            let next = adapter(CacheSessionReader(token)); await next.setAccessEnabled(true)
            let loaded = await cache(config,next).load(providerID:.grokBot)
            XCTAssertEqual(loaded,.miss)
        }
    }
    func testLegacyEncryptedPayloadRemainsLegacyAndCannotSurviveSharedPreparation() async throws {
        let config = try configuration(), adapter = adapter(), grant = try await associationAfterEnable(adapter)
        let original = try GrokBotQuotaMapper.map(Data(#"{"usagePercent":55}"#.utf8), fetchedAt:cacheFetched, sessionScope:grant.sessionScope)
        let cache = cache(config,adapter)
        _ = await cache.save(original)
        guard case let .hit(restored) = await cache.load(providerID:.grokBot) else { return XCTFail("Legacy safe payload must still decode") }
        XCTAssertEqual(restored.source.adapterID,"cursor-sand"); XCTAssertNil(restored.grokBotUsage?.shared)
        let discard = await adapter.prepareForRead(retaining:restored.source)
        XCTAssertTrue(discard)
    }
    private func associationAfterEnable(_ adapter:GrokBotProviderAdapter) async throws -> GrokBotCacheAssociation {
        await adapter.setAccessEnabled(true)
        return try await association(adapter)
    }
    func testDefaultOffDoesNotReadSessionOrCacheAndMakesNoRequests() async throws {
        let config = try configuration(), reader = CacheSessionReader(), http = CacheNoHTTP()
        let adapter = GrokBotProviderAdapter(reader:reader,client:.init(transport:http),now:{ cacheNow })
        let cache = cache(config,adapter), controller = try controller(adapter,cache,enabled:false)
        _ = await controller.send(.start)
        let reads = await reader.count, requests = await http.count
        XCTAssertEqual(reads,0); XCTAssertEqual(requests,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:path(config).deletingLastPathComponent().path))
    }
    func testRevokeClearsMemoryAndDiskWithoutReadingSourceAgain() async throws {
        let config = try configuration(), reader = CacheSessionReader(), adapter = adapter(reader)
        let original = try await data(adapter), cache = cache(config,adapter)
        _ = await cache.save(original)
        let controller = try controller(adapter,cache); _ = await controller.send(.start)
        let before = await reader.count
        _ = await controller.send(.setEnabled(false))
        let state = await controller.projection().state, after = await reader.count
        XCTAssertNil(state.lastGood); XCTAssertNil(state.refresh.lastSuccessAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath:path(config).path)); XCTAssertEqual(before,after)
        let loaded = await cache.load(providerID:.grokBot); XCTAssertEqual(loaded,.miss)
        let afterMiss = await reader.count; XCTAssertEqual(afterMiss,after)
    }
    func testClearCacheRemovesBothMemoryAndDiskInManualMode() async throws {
        let config = try configuration(), adapter = adapter(), original = try await data(adapter), cache = cache(config,adapter)
        _ = await cache.save(original)
        let controller = try controller(adapter,cache); _ = await controller.send(.start); _ = await controller.send(.clearCache)
        let state = await controller.projection().state
        XCTAssertNil(state.lastGood); XCTAssertFalse(FileManager.default.fileExists(atPath:path(config).path))
        let delayed = await cache.save(original)
        guard case .failure = delayed else { return XCTFail("A queued old source scope cannot revive a completed clear") }
        XCTAssertFalse(FileManager.default.fileExists(atPath:path(config).path))
    }
    func testLateSaveAuthorizationCannotResurrectClearedEntry() async throws {
        for blockedCall in [1,2] {
            let config = try configuration(), adapter = adapter(), original = try await data(adapter)
            let grant = try await association(adapter), gate = CacheAuthorizationGate(grant,blockCall:blockedCall)
            let cache = GrokBotEncryptedQuotaCache(configuration:config,authorization:{ await gate.current() },now:{ cacheNow })
            let save = Task { await cache.save(original) }
            await gate.waitUntilBlocked(); _ = await cache.clear(providerID:.grokBot); await gate.resume()
            let result = await save.value
            guard case .failure = result else { return XCTFail("A late save must be rejected") }
            XCTAssertFalse(FileManager.default.fileExists(atPath:path(config).path))
        }
    }
    func testFileRevisionFenceRejectsWriteQueuedAfterClear() async throws {
        let config = try configuration(), file = ProviderQuotaDiskCache(configuration:config)
        let old = await file.grokProtectedRevision()
        _ = await file.clear(providerID:.grokBot)
        let committed = try await file.writeProtectedGrokEntry(Data("NEVER_COMMIT".utf8),expectedRevision:old)
        XCTAssertFalse(committed); XCTAssertFalse(FileManager.default.fileExists(atPath:path(config).path))
    }
    func testLateLoadConfirmationCannotRestoreAfterClear() async throws {
        let config = try configuration(), adapter = adapter(), original = try await data(adapter), saved = cache(config,adapter)
        _ = await saved.save(original)
        let grant = try await association(adapter), gate = CacheAuthorizationGate(grant,blockCall:2)
        let cache = GrokBotEncryptedQuotaCache(configuration:config,authorization:{ await gate.current() },now:{ cacheNow })
        let load = Task { await cache.load(providerID:.grokBot) }
        await gate.waitUntilBlocked(); _ = await cache.clear(providerID:.grokBot); await gate.resume()
        let result = await load.value; XCTAssertEqual(result,.miss)
        XCTAssertFalse(FileManager.default.fileExists(atPath:path(config).path))
    }
    func testCancelledSaveCannotCreateAnEntry() async throws {
        let config = try configuration(), adapter = adapter(), original = try await data(adapter)
        let grant = try await association(adapter), gate = CacheAuthorizationGate(grant,blockCall:1)
        let cache = GrokBotEncryptedQuotaCache(configuration:config,authorization:{ await gate.current() },now:{ cacheNow })
        let save = Task { await cache.save(original) }; await gate.waitUntilBlocked(); save.cancel(); await gate.resume()
        let result = await save.value; guard case .failure = result else { return XCTFail("Cancelled save") }
        XCTAssertFalse(FileManager.default.fileExists(atPath:path(config).path))
    }
    func testPermissionsAndCiphertextContainNoCredentialIdentityOrRawResponse() async throws {
        let config = try configuration(), adapter = adapter(), original = try await data(adapter), cache = cache(config,adapter)
        _ = await cache.save(original)
        let file = path(config), bytes = try Data(contentsOf:file)
        let mode = try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber
        let directoryMode = try FileManager.default.attributesOfItem(atPath:file.deletingLastPathComponent().path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue,0o600); XCTAssertEqual(directoryMode.intValue,0o700)
        let raw = try XCTUnwrap(String(data:bytes,encoding:.utf8))
        for forbidden in [cacheToken(),"user_CACHE_FAKE_A","auth0|",original.source.sessionScope!,"RAW_SERVER_SECRET",SHA256.hash(data:Data(cacheToken().utf8)).map { String(format:"%02x",$0) }.joined()] { XCTAssertFalse(raw.contains(forbidden)) }
        let json = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        XCTAssertEqual(Set(json.keys),["schema","version","providerID","sealed"])
        let grant = try await association(adapter)
        let keyBytes = grant.key.withUnsafeBytes { Data($0) }
        XCTAssertNil(bytes.range(of:keyBytes)); XCTAssertFalse(raw.contains(keyBytes.base64EncodedString()))
        let normalized = try AES.GCM.open(AES.GCM.SealedBox(combined:Data(base64Encoded:json["sealed"] as! String)!),using:grant.key,authenticating:Data("usage-butler.grokbot.normalized-last-good.aes-gcm/v1/grokBot".utf8))
        let text = String(data:normalized,encoding:.utf8)!
        for forbidden in ["sessionScope","RAW_SERVER_SECRET","user_CACHE_FAKE_A",cacheToken()] { XCTAssertFalse(text.contains(forbidden)) }
    }
    func testCorruptionHeaderTamperingAndOverlargeEntryAreSafeMisses() async throws {
        let config = try configuration(), adapter = adapter(), original = try await data(adapter), cache = cache(config,adapter)
        _ = await cache.save(original); let url = path(config), originalBytes = try Data(contentsOf:url)
        for key in ["schema","version","providerID","sealed"] {
            var json = try JSONSerialization.jsonObject(with:originalBytes) as! [String:Any]
            if key == "version" { json[key] = 2 } else if key == "sealed" {
                var sealed = Data(base64Encoded:json[key] as! String)!; sealed[sealed.count-1] ^= 1; json[key] = sealed.base64EncodedString()
            } else { json[key] = "wrong" }
            try JSONSerialization.data(withJSONObject:json).write(to:url)
            let loaded = await cache.load(providerID:.grokBot)
            if key == "sealed" { XCTAssertEqual(loaded,.miss) }
            else { guard case .failure = loaded else { return XCTFail("Malformed envelope needs safe health evidence") } }
        }
        for bytes in [Data("broken".utf8),Data(repeating:0,count:1_048_577)] {
            try bytes.write(to:url); let loaded = await cache.load(providerID:.grokBot)
            guard case let .failure(failure) = loaded else { return XCTFail("Corrupt file needs health evidence") }
            XCTAssertEqual(failure.code,.cacheCorrupt)
        }
    }
    func testUnsafePermissionsAndSymlinkAreSafeMissesWithoutTouchingTarget() async throws {
        let config = try configuration(), adapter = adapter(), original = try await data(adapter), cache = cache(config,adapter)
        _ = await cache.save(original); let url = path(config)
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:url.path)
        let unsafeResult = await cache.load(providerID:.grokBot)
        guard case let .failure(unsafeFailure) = unsafeResult else { return XCTFail("Unsafe permissions need health evidence") }
        XCTAssertEqual(unsafeFailure.code,.permissionDenied)
        try FileManager.default.removeItem(at:url)
        let target = config.applicationSupportDirectory.appendingPathComponent("outside-private-file")
        try Data("DO_NOT_TOUCH".utf8).write(to:target);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
        try FileManager.default.createSymbolicLink(at:url,withDestinationURL:target)
        let linked = await cache.load(providerID:.grokBot)
        guard case let .failure(linkFailure) = linked else { return XCTFail("Symlink needs health evidence") }
        XCTAssertEqual(linkFailure.code,.permissionDenied)
        let save = await cache.save(original), clear = await cache.clear(providerID:.grokBot)
        if case .success = save { XCTFail("Cannot replace symlink") }; if case .success = clear { XCTFail("Cannot follow symlink") }
        XCTAssertEqual(try Data(contentsOf:target),Data("DO_NOT_TOUCH".utf8))
    }
    func testCorruptCachePublishesNoOldDataAndRecordsDegradedPersistence() async throws {
        let config = try configuration(), adapter = adapter(), original = try await data(adapter), cache = cache(config,adapter)
        _ = await cache.save(original)
        try Data("not an envelope".utf8).write(to:path(config))
        let controller = try controller(adapter,cache); _ = await controller.send(.start)
        let state = await controller.projection().state
        XCTAssertNil(state.lastGood)
        guard case let .degraded(failure) = state.persistence else { return XCTFail("Cache miss must retain health evidence") }
        XCTAssertEqual(failure.code,.cacheCorrupt)
        XCTAssertEqual(failure.diagnosticCode,"cache.grok.envelope_invalid")
        XCTAssertFalse(failure.diagnosticCode.contains("not an envelope"))
    }
    func testStaleAccessGrantCannotReenableAfterNewerRevokeOrShutdown() async throws {
        let reader = CacheSessionReader(), adapter = adapter(reader)
        await adapter.setAccessEnabled(true,generation:10)
        await adapter.setAccessEnabled(false,generation:11)
        await adapter.setAccessEnabled(true,generation:10)
        let revoked = await adapter.quotaCacheAssociation(), reads = await reader.count
        XCTAssertNil(revoked); XCTAssertEqual(reads,0)
        await adapter.shutdown(); await adapter.setAccessEnabled(true,generation:12)
        let stopped = await adapter.quotaCacheAssociation(), stoppedReads = await reader.count
        XCTAssertNil(stopped); XCTAssertEqual(stoppedReads,0)
    }
    func testUnknownEnvelopeSchemaAndVersionHaveFixedSafeHealthCodes() async throws {
        let config = try configuration(), adapter = adapter(), original = try await data(adapter), cache = cache(config,adapter)
        _ = await cache.save(original); let file = path(config), bytes = try Data(contentsOf:file)
        for (key,value,code) in [("schema","other","cache.grok.unknown_schema"),("version","2","cache.grok.unknown_version")] {
            var json = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
            json[key] = key == "version" ? 2 : value
            try JSONSerialization.data(withJSONObject:json).write(to:file)
            let result = await cache.load(providerID:.grokBot)
            guard case let .failure(failure) = result else { return XCTFail("No old value may publish") }
            XCTAssertEqual(failure.code,.schemaMismatch); XCTAssertEqual(failure.diagnosticCode,code)
        }
    }
    func testLateStartupCacheHitCannotPublishAfterRevokeAndRegrant() async throws {
        let seeded = adapter(), original = try await data(seeded), gate = GrokCacheOperationGate(original,blockLoad:true)
        let next = adapter(), controller = try controller(next,gate)
        let start = Task { await controller.send(.start) }
        await gate.waitUntilBlocked()
        _ = await controller.send(.setEnabled(false)); _ = await controller.send(.setEnabled(true))
        await gate.resume(); _ = await start.value
        let projection = await controller.projection()
        XCTAssertTrue(projection.isEnabled); XCTAssertNil(projection.state.lastGood)
    }
    func testGrokRevokeIsNotDeferredBehindAnInFlightClear() async throws {
        let adapter = adapter(), original = try await data(adapter), gate = GrokCacheOperationGate(original,blockLoad:false)
        let controller = try controller(adapter,gate); _ = await controller.send(.start)
        let clear = Task { await controller.send(.clearCache) }
        await gate.waitUntilBlocked()
        let revoke = await controller.send(.setEnabled(false))
        await gate.resume(); _ = await clear.value
        let projection = await controller.projection()
        XCTAssertEqual(revoke,.completed); XCTAssertFalse(projection.isEnabled); XCTAssertNil(projection.state.lastGood)
        let grant = await adapter.quotaCacheAssociation(); XCTAssertNil(grant)
    }
    func testUnderlyingIOFailureKeepsSafeDiagnosticHealthWithoutPublishingData() async throws {
        let config = try configuration(), adapter = adapter()
        await adapter.setAccessEnabled(true)
        let missing = try ProviderQuotaDiskCacheConfiguration(applicationSupportDirectory:config.applicationSupportDirectory.appendingPathComponent("absent-base"),versionedRelativeDirectory:["GrokCacheTests","v1"])
        let cache = cache(missing,adapter), controller = try controller(adapter,cache)
        _ = await controller.send(.start)
        let state = await controller.projection().state
        XCTAssertNil(state.lastGood)
        guard case let .degraded(failure) = state.persistence else { return XCTFail("I/O health cannot be swallowed") }
        XCTAssertEqual(failure.code,.cacheUnavailable)
        XCTAssertEqual(failure.diagnosticCode,"cache.directory.open_base.io_2")
        XCTAssertFalse(failure.diagnosticCode.contains(config.applicationSupportDirectory.path))
    }
    func testDirectorySymlinkIsRejectedWithoutCreatingAnythingInItsTarget() async throws {
        let config = try configuration(), adapter = adapter(), original = try await data(adapter), cache = cache(config,adapter)
        let outside = config.applicationSupportDirectory.appendingPathComponent("outside-directory")
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try FileManager.default.createSymbolicLink(at:config.applicationSupportDirectory.appendingPathComponent("GrokCacheTests"),withDestinationURL:outside)
        let loaded = await cache.load(providerID:.grokBot), saved = await cache.save(original)
        guard case let .failure(failure) = loaded else { return XCTFail("Directory symlink must be a safe miss with health evidence") }
        XCTAssertEqual(failure.code,.permissionDenied)
        guard case .failure = saved else { return XCTFail("Must not write through directory symlink") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:outside.path),[])
    }
    func testEncryptedWriteObeysConfiguredSizeLimitBeforeCreatingEntry() async throws {
        let config = try configuration(), adapter = adapter(), original = try await data(adapter)
        let bounded = try ProviderQuotaDiskCacheConfiguration(applicationSupportDirectory:config.applicationSupportDirectory,versionedRelativeDirectory:config.versionedRelativeDirectory,maximumFileBytes:128)
        let result = await cache(bounded,adapter).save(original)
        guard case let .failure(failure) = result else { return XCTFail("Encrypted envelope must remain bounded") }
        XCTAssertEqual(failure.diagnosticCode,"cache.grok.oversized")
        XCTAssertFalse(FileManager.default.fileExists(atPath:path(config).path))
    }
    func testRevokeClearFailureStillRemovesMemoryAndRecordsPersistenceFailure() async throws {
        let config = try configuration(), adapter = adapter(), original = try await data(adapter), cache = cache(config,adapter)
        _ = await cache.save(original)
        let controller = try controller(adapter,cache); _ = await controller.send(.start)
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:path(config).path)
        _ = await controller.send(.setEnabled(false))
        let state = await controller.projection().state
        XCTAssertNil(state.lastGood)
        guard case let .degraded(failure) = state.persistence else { return XCTFail("Failed file removal must remain visible") }
        XCTAssertEqual(failure.code,.permissionDenied)
        let grant = await adapter.quotaCacheAssociation(); XCTAssertNil(grant)
    }
    func testRevokeDuringStartupClockReadCannotPublishPreviouslyLoadedCache() async throws {
        let config = try configuration(), adapter = adapter(), original = try await data(adapter), cache = cache(config,adapter)
        _ = await cache.save(original)
        let clock = CacheStartupClockGate()
        let controller = try ProviderController(initialState:ProviderBootstrap.initialState(id:.grokBot,capabilities:adapter.capabilities,now:cacheNow),initiallyEnabled:true,adapter:adapter,cache:cache,clock:clock,scheduler:RefreshScheduler(clock:clock),policy:.init(cadence:.manualOnly,manualCooldown:.seconds(0),retryBackoff:[.seconds(60)],shutdownGrace:.seconds(1)))
        let start = Task { await controller.send(.start) }
        await clock.waitUntilBlocked()
        _ = await controller.send(.setEnabled(false)); _ = await controller.send(.setEnabled(true))
        await clock.resume(); _ = await start.value
        let projection = await controller.projection()
        XCTAssertTrue(projection.isEnabled); XCTAssertNil(projection.state.lastGood)
        XCTAssertFalse(FileManager.default.fileExists(atPath:path(config).path))
    }
    func testExistingCiphertextIsNotAccessedWhileAuthorizationIsOff() async throws {
        let config = try configuration(), first = adapter(), original = try await data(first)
        _ = await cache(config,first).save(original)
        try FileManager.default.setAttributes([.posixPermissions:0o000],ofItemAtPath:path(config).path)
        let reader = CacheSessionReader(), next = adapter(reader)
        let result = await cache(config,next).load(providerID:.grokBot), reads = await reader.count
        XCTAssertEqual(result,.miss); XCTAssertEqual(reads,0)
    }
    func testOriginalCLICachePayloadShapeDoesNotGainGrokFields() throws {
        for provider in [ProviderID.openAI,.miniMax,.ark] {
            let source = ProviderSourceIdentity(providerID:provider,adapterID:"fixture",executableIdentity:"FAKE_CLI",cliVersion:"fixture",schemaVersion:"fixture",contractVersion:"fixture")
            let data = ProviderQuotaData(providerID:provider,source:source,fetchedAt:cacheFetched,products:[],balances:[],resetEntitlements:[])
            let bytes = try JSONEncoder().encode(ProviderQuotaCacheEnvelopeDTO(domain:data))
            let object = try JSONSerialization.jsonObject(with:bytes) as! [String:Any], payload = object["payload"] as! [String:Any]
            XCTAssertEqual(Set(payload.keys),["providerID","fetchedAt","products","balances","resetEntitlements"])
        }
    }
}
