/// Runtime contract metadata is not verified merely because an executable was found.
/// Historical receipts and compiled-in catalog constants must stay `.unverified`;
/// only a caller that actually performed the named runtime read may construct
/// `.runtimeRead` provenance.
public struct RuntimeContractFieldObservation: Equatable, Sendable {
    public enum Provenance: Equatable, Sendable {
        case unverified
        case runtimeRead(operationID: String)
    }

    public static let unverifiedValue = "runtime-unverified"
    public static let unverified = RuntimeContractFieldObservation(
        value: nil,
        provenance: .unverified
    )

    public let value: String?
    public let provenance: Provenance

    private init(value: String?, provenance: Provenance) {
        self.value = value
        self.provenance = provenance
    }

    static func runtimeRead(
        _ value: String,
        operationID: String
    ) -> RuntimeContractFieldObservation {
        RuntimeContractFieldObservation(
            value: value,
            provenance: .runtimeRead(operationID: operationID)
        )
    }

    var verifiedValue: String? {
        guard case let .runtimeRead(operationID) = provenance,
              !operationID.isEmpty,
              let value,
              !value.isEmpty else {
            return nil
        }
        return value
    }

    var provenanceValue: String {
        verifiedValue ?? Self.unverifiedValue
    }
}

public enum ProviderAdapterStage {
    /// Production adapters are wired through Core-owned ports. Their transports remain
    /// injectable so the default validation path stays offline and credential-free.
    public static let implementationStatus = "production-runtime-integrated-stage11"
}
