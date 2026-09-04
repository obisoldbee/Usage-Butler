import Foundation
import UsageButlerDomain

public enum ProviderBootstrapError: Error, Equatable, Sendable {
    case missingCapabilities(ProviderID)
}

public enum ProviderBootstrap {
    public static func initialState(
        id: ProviderID,
        capabilities: ProviderCapabilities,
        now: Date
    ) -> ProviderState {
        let initialEvidence = AuthenticationEvidence(
            authority: .initialDetection,
            observedAt: now
        )

        return ProviderState(
            id: id,
            capabilities: capabilities,
            connection: .detecting(startedAt: now),
            presence: .unknown,
            authentication: .unknown(initialEvidence),
            refresh: RefreshState(
                activity: .detecting(generation: 0, startedAt: now),
                gate: .open,
                lastAttemptAt: nil,
                lastSuccessAt: nil
            ),
            lastGood: nil,
            freshness: .unknown,
            discovery: .detecting(startedAt: now, generation: 0),
            persistence: .unknown,
            failure: nil
        )
    }

    public static func initialStates(
        capabilitiesByProvider: [ProviderID: ProviderCapabilities],
        now: Date
    ) throws -> [ProviderState] {
        try ProviderID.allCases
            .sorted { $0.canonicalOrder < $1.canonicalOrder }
            .map { id in
                guard let capabilities = capabilitiesByProvider[id] else {
                    throw ProviderBootstrapError.missingCapabilities(id)
                }
                return initialState(id: id, capabilities: capabilities, now: now)
            }
    }
}
