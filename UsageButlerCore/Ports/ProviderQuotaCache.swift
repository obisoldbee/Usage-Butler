import Foundation
import UsageButlerDomain

public enum ProviderQuotaCacheLoadResult: Equatable, Sendable {
    case hit(ProviderQuotaData)
    case miss
    case failure(ProviderFailure)
}

public enum ProviderQuotaCacheWriteResult: Equatable, Sendable {
    case success(writtenAt: Date)
    case failure(ProviderFailure)
}

public enum ProviderQuotaCacheClearResult: Equatable, Sendable {
    case success(clearedAt: Date, removedEntry: Bool)
    case failure(ProviderFailure)
}

public protocol ProviderQuotaCache: Actor {
    func load(providerID: ProviderID) async -> ProviderQuotaCacheLoadResult
    func save(_ data: ProviderQuotaData) async -> ProviderQuotaCacheWriteResult
    func clear(providerID: ProviderID) async -> ProviderQuotaCacheClearResult
    func shutdown() async
}
