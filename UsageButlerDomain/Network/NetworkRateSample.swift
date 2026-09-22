import Foundation

/// One buffered rate observation for one interface.
///
/// It is stamped with the *source counter sample* identity, never with the
/// publish time of the snapshot that happened to carry it. A snapshot that
/// re-emits an unchanged rate therefore cannot add a phantom "fresh" point.
public struct NetworkRateSample: Equatable, Sendable {
    public let sourceID: String
    public let interfaceName: String
    public let samplingInterval: TimeInterval?
    public var sampleID: String { "\(sourceID)|\(interfaceName)|\(captureSessionID.rawValue)|\(counterEpoch.rawValue)|\(sampledMonotonic.nanoseconds)" }
    public let captureSessionID: CaptureSessionID
    /// Counter epoch of the underlying interface sample. A change means the
    /// totals are not comparable and the trend must break.
    public let counterEpoch: CounterEpoch
    /// Wall time of the source counter sample (display axis only).
    public let sampledAt: Date
    /// Monotonic time of the source counter sample (ordering and dedup).
    public let sampledMonotonic: MonotonicInstant
    /// `nil` when that direction's rate was unknown; unknown is not zero.
    public let uploadBytesPerSecond: Double?
    public let downloadBytesPerSecond: Double?

    public init(
        captureSessionID: CaptureSessionID,
        counterEpoch: CounterEpoch,
        sampledAt: Date,
        sampledMonotonic: MonotonicInstant,
        uploadBytesPerSecond: Double?,
        downloadBytesPerSecond: Double?,
        sourceID: String = "interface-counters",
        interfaceName: String = "",
        samplingInterval: TimeInterval? = nil
    ) {
        self.sourceID = sourceID
        self.interfaceName = interfaceName
        self.samplingInterval = samplingInterval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.captureSessionID = captureSessionID
        self.counterEpoch = counterEpoch
        self.sampledAt = sampledAt
        self.sampledMonotonic = sampledMonotonic
        self.uploadBytesPerSecond = uploadBytesPerSecond.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.downloadBytesPerSecond = downloadBytesPerSecond.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// A sample with neither direction known still carries information: it is a
    /// hole in the observation, and dropping it would let the chart bridge the
    /// gap with a fabricated straight line.
    public var isGap: Bool {
        uploadBytesPerSecond == nil && downloadBytesPerSecond == nil
    }
}
