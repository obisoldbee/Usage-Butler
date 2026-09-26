import Foundation

public struct HistoryAgeSample: Codable, Equatable, Sendable {
    public let boot: String
    public let continuousNanoseconds: UInt64
    public init(boot: String, continuousNanoseconds: UInt64) {
        self.boot = boot; self.continuousNanoseconds = continuousNanoseconds
    }
}

/// Sleep and disabled intervals in the same boot age the data. Power-off time
/// across boots is unknown; retain conservatively rather than trust wall jumps.
public struct HistoryRetentionClock: Codable, Equatable, Sendable {
    public private(set) var ageSeconds: Double = 0
    public private(set) var previous: HistoryAgeSample?
    public private(set) var conservative = false
    public init() {}
    public mutating func advance(_ sample: HistoryAgeSample) {
        defer { previous = sample }
        guard let previous else { return }
        guard previous.boot == sample.boot, !sample.boot.isEmpty,
              sample.continuousNanoseconds >= previous.continuousNanoseconds else {
            conservative = true; return
        }
        ageSeconds += Double(sample.continuousNanoseconds - previous.continuousNanoseconds) / 1e9
    }
}
