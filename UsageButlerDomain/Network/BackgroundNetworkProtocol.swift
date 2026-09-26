import Foundation

public struct BackgroundNetworkStatus: Codable, Equatable, Sendable {
    public let version: String
    public let pid: Int32
    public let executableSHA256: String
    public let sqliteVersion: String
    public let sqliteSourceID: String
    public let startedAt: Date
    public let sourceState: ProcessNetworkState
    public let sourceIssue: String?
    public let coverage: HistoryCoverage
    public let rule: HistoryUploadRule
    public let recoverySeconds: Int?
    public init(version: String, pid: Int32, executableSHA256: String = "", sqliteVersion: String = "", sqliteSourceID: String = "", startedAt: Date, sourceState: ProcessNetworkState,
                sourceIssue: String?, coverage: HistoryCoverage, rule: HistoryUploadRule, recoverySeconds: Int? = nil) {
        self.version = version; self.pid = pid; self.startedAt = startedAt; self.sourceState = sourceState
        self.executableSHA256 = executableSHA256
        self.sqliteVersion = sqliteVersion; self.sqliteSourceID = sqliteSourceID
        self.sourceIssue = sourceIssue; self.coverage = coverage; self.rule = rule
        self.recoverySeconds = recoverySeconds
    }
}

public struct BackgroundNetworkRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case status, snapshot, query, updateRule, enable, stop, refresh }
    public var protocolVersion = 1
    public let operation: Operation
    public var selectedKey: String?
    public var range: HistoryRange?
    public var applicationID: Int64?
    public var page = 0
    public var eventKind: String?
    public var rule: HistoryUploadRule?
    public init(_ operation: Operation) { self.operation = operation }
    public var isValid: Bool {
        protocolVersion == 1 && (selectedKey?.utf8.count ?? 0) <= 8_192 && (0...1023).contains(page)
            && (applicationID.map { $0 > 0 } ?? true)
            && (eventKind == nil || eventKind == "large" || eventKind == "sustained")
            && (operation != .query || range?.isValid == true)
            && (operation != .query || applicationID == nil || selectedKey == nil)
            && (operation != .updateRule || rule?.isValid == true)
    }
}

public struct BackgroundNetworkResponse: Codable, Sendable {
    public var protocolVersion = 1
    public var status: BackgroundNetworkStatus?
    public var snapshot: ProcessNetworkSnapshot?
    public var history: HistoryQueryResult?
    public var error: String?
    public init(status: BackgroundNetworkStatus? = nil, snapshot: ProcessNetworkSnapshot? = nil,
                history: HistoryQueryResult? = nil, error: String? = nil) {
        self.status = status; self.snapshot = snapshot; self.history = history; self.error = error
    }
}

public enum BackgroundNetworkWire {
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 4 * 1_048_576
    public static let version = "0.5.3 (14)"
    public static func encode(_ response: BackgroundNetworkResponse) throws -> Data {
        let data = try JSONEncoder().encode(response)
        guard data.count <= maximumResponseBytes else { throw Failure.responseTooLarge }
        return data
    }
    public enum Failure: Error, Sendable { case responseTooLarge, invalidRequest, invalidResponse, disconnected, timeout, remote(String) }
}
