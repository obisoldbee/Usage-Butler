import UsageButlerDomain

public protocol BackgroundNetworkClient: Sendable {
    func request(_ request: BackgroundNetworkRequest) async throws -> BackgroundNetworkResponse
    func disconnect() async
}
