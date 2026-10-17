import Foundation

public protocol GrokBotHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class RejectGrokBotRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct EphemeralGrokBotHTTPTransport: GrokBotHTTPTransport {
    public static let maximumResponseBytes = 65_536
    private let protocolClasses: [URLProtocol.Type]?
    public init() { protocolClasses = nil }
    init(protocolClasses: [URLProtocol.Type]) { self.protocolClasses = protocolClasses }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try GrokBotHTTPClient.validate(request)
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration, delegate: RejectGrokBotRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw GrokBotReadError.schema }
            if http.statusCode != 200 { return (Data(), http) }
            guard response.expectedContentLength <= Self.maximumResponseBytes else { throw GrokBotReadError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else { throw GrokBotReadError.responseTooLarge }
                data.append(byte)
            }
            return (data, http)
        } onCancel: { session.invalidateAndCancel() }
    }
}

public struct GrokBotHTTPClient: Sendable {
    public enum Endpoint: String, Sendable {
        case identity = "/api/auth/me", sand = "/api/dashboard/get-sand-usage-status", shared = "/api/dashboard/v2/usage-status"
        var url: URL { URL(string: "https://cursor.com" + rawValue + (self == .shared ? "?scope=user" : ""))! }
    }
    private let transport: any GrokBotHTTPTransport
    public init(transport: any GrokBotHTTPTransport = EphemeralGrokBotHTTPTransport()) { self.transport = transport }
    public static func validate(_ request: URLRequest) throws {
        guard let url = request.url, url.scheme == "https", url.host == "cursor.com", url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              let endpoint = Endpoint(rawValue: url.path),
              url.absoluteString == endpoint.url.absoluteString, request.httpBodyStream == nil,
              request.httpMethod == (endpoint == .sand ? "POST" : "GET"),
              (endpoint == .sand ? request.httpBody == Data("{}".utf8) : request.httpBody == nil) else { throw GrokBotReadError.unsupportedEndpoint }
    }
    func fetch(_ endpoint: Endpoint, session: CursorReadOnlySession) async throws -> Data {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = endpoint == .sand ? "POST" : "GET"
        request.timeoutInterval = 5
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(session.cookie, forHTTPHeaderField: "Cookie")
        if endpoint == .sand {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.httpBody = Data("{}".utf8)
        }
        try Self.validate(request)
        try Task.checkCancellation()
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        guard response.url == request.url else { throw GrokBotReadError.redirect }
        guard !(300...399).contains(response.statusCode) else { throw GrokBotReadError.redirect }
        guard response.statusCode == 200 else { throw GrokBotReadError.http(response.statusCode) }
        guard !data.isEmpty else { throw GrokBotReadError.schema }
        guard data.count <= EphemeralGrokBotHTTPTransport.maximumResponseBytes else { throw GrokBotReadError.responseTooLarge }
        return data
    }
    func verify(session: CursorReadOnlySession) async throws {
        struct Identity: Decodable { let sub: String }
        let identity: Identity
        do { identity = try JSONDecoder().decode(Identity.self, from: await fetch(.identity, session: session)) }
        catch let error as DecodingError { _ = error; throw GrokBotReadError.schema }
        guard CursorReadOnlySession.normalizedSubject(identity.sub) == session.subject else { throw GrokBotReadError.identityMismatch }
    }
}
