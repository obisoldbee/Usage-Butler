public enum ProviderID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case openAI
    case miniMax
    case ark

    public var id: String { rawValue }

    public var canonicalOrder: Int {
        switch self {
        case .openAI: 0
        case .miniMax: 1
        case .ark: 2
        }
    }
}
