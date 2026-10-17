import CryptoKit
import Foundation
import UsageButlerCore
import UsageButlerDomain

/// Exact-session association is authenticated by AES-GCM. No token, subject,
/// token hash, key, raw response, or persistent account identifier is encoded.
public actor GrokBotEncryptedQuotaCache: ProviderQuotaCache {
    private struct Envelope: Codable {
        let schema: String
        let version: Int
        let providerID: ProviderID
        let sealed: Data
    }
    private static let schema = "usage-butler.grokbot.normalized-last-good.aes-gcm"
    private static let aad = Data("usage-butler.grokbot.normalized-last-good.aes-gcm/v1/grokBot".utf8)
    private let file: ProviderQuotaDiskCache
    private let authorization: @Sendable () async -> GrokBotCacheAssociation?
    private let now: @Sendable () -> Date
    private var revision: UInt64 = 0
    private var acceptsOperations = true

    public init(configuration: ProviderQuotaDiskCacheConfiguration,
                authorization: @escaping @Sendable () async -> GrokBotCacheAssociation?,
                now: @escaping @Sendable () -> Date = { Date() }) {
        file = ProviderQuotaDiskCache(configuration: configuration, now: now)
        self.authorization = authorization; self.now = now
    }
    public func load(providerID: ProviderID) async -> ProviderQuotaCacheLoadResult {
        guard acceptsOperations, providerID == .grokBot else { return .miss }
        let current = revision
        // Closed authorization returns before touching the source or cache filesystem.
        guard let grant = await authorization(), grant.expiresAt > now(),
              acceptsOperations, revision == current, !Task.isCancelled else { return .miss }
        do {
            guard let bytes = try await file.readProtectedGrokEntry() else { return .miss }
            let outer: Envelope
            do { outer = try Self.decoder().decode(Envelope.self, from: bytes) }
            catch { throw ProviderQuotaCacheFailure.corrupt("cache.grok.envelope_invalid") }
            guard outer.schema == Self.schema else { throw ProviderQuotaCacheFailure.unsupportedSchema("cache.grok.unknown_schema") }
            guard outer.version == 1 else { throw ProviderQuotaCacheFailure.unsupportedSchema("cache.grok.unknown_version") }
            guard outer.providerID == .grokBot else { throw ProviderQuotaCacheFailure.identityMismatch("cache.grok.provider_mismatch") }
            let box: AES.GCM.SealedBox
            do { box = try AES.GCM.SealedBox(combined: outer.sealed) }
            catch { throw ProviderQuotaCacheFailure.corrupt("cache.grok.sealed_shape_invalid") }
            let plaintext: Data
            do { plaintext = try AES.GCM.open(box, using: grant.key, authenticating: Self.aad) }
            catch { return .miss } // Rotation and failed authentication cannot be distinguished without a persisted identity.
            let data: ProviderQuotaData
            do {
                let payload = try Self.decoder().decode(ProviderQuotaCacheEnvelopeDTO.self, from: plaintext)
                data = try payload.domain(requestedProviderID: .grokBot, grokSessionScope: grant.sessionScope)
            } catch { throw ProviderQuotaCacheFailure.corrupt("cache.grok.normalized_payload_invalid") }
            guard let confirmed = await authorization(), confirmed.expiresAt > now(), grant.matches(confirmed),
                  acceptsOperations, revision == current, !Task.isCancelled else { return .miss }
            return .hit(data)
        } catch let failure as ProviderFailure {
            guard acceptsOperations, revision == current, !Task.isCancelled else { return .miss }
            return .failure(failure)
        } catch {
            guard acceptsOperations, revision == current, !Task.isCancelled else { return .miss }
            return .failure(ProviderQuotaCacheFailure.unavailable("cache.grok.read_unavailable"))
        }
    }

    public func save(_ data: ProviderQuotaData) async -> ProviderQuotaCacheWriteResult {
        guard acceptsOperations, data.providerID == .grokBot else { return .failure(Self.cancelled()) }
        let current = revision
        let commitRevision = await file.grokProtectedRevision()
        guard let grant = await authorization(), grant.expiresAt > now(), data.source.sessionScope == grant.sessionScope,
              acceptsOperations, revision == current, !Task.isCancelled else { return .failure(Self.cancelled()) }
        do {
            let payload = try ProviderQuotaCacheEnvelopeDTO(domain: data, allowingEncryptedGrok: true)
            let normalized = try Self.encoder().encode(payload)
            let sealed = try AES.GCM.seal(normalized, using: grant.key, authenticating: Self.aad)
            guard let combined = sealed.combined else { return .failure(Self.cancelled()) }
            let bytes = try Self.encoder().encode(Envelope(schema: Self.schema, version: 1, providerID: .grokBot, sealed: combined))
            guard let confirmed = await authorization(), confirmed.expiresAt > now(), grant.matches(confirmed),
                  acceptsOperations, revision == current, !Task.isCancelled else { return .failure(Self.cancelled()) }
            // The file actor checks this ticket and performs rename without an await.
            // A clear that wins either deletes the earlier write or rejects this one.
            guard try await file.writeProtectedGrokEntry(bytes, expectedRevision: commitRevision) else {
                return .failure(Self.cancelled())
            }
            return .success(writtenAt: now())
        } catch let failure as ProviderFailure { return .failure(failure) }
        catch { return .failure(ProviderQuotaCacheFailure.rejected("cache.grok.encryption_or_payload_rejected")) }
    }
    public func clear(providerID: ProviderID) async -> ProviderQuotaCacheClearResult {
        guard providerID == .grokBot else { return .success(clearedAt: now(), removedEntry: false) }
        revision &+= 1
        return await file.clear(providerID: .grokBot)
    }
    public func shutdown() async {
        acceptsOperations = false; revision &+= 1
        await file.shutdown()
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.sortedKeys]; return encoder
    }
    private static func decoder() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970; return decoder }
    private static func cancelled() -> ProviderFailure {
        .init(code: .cancelled, retryClass: .never, userMessageKey: "provider.failure.cancelled", diagnosticCode: "cache.grok.authorization_or_revision_changed", recovery: nil)
    }
}
