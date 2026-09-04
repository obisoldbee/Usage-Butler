import Foundation

public enum MemoryPressureState: Equatable, Sendable {
    case normal
    case warning
    case critical
    case unknown
}

public enum MemoryFieldID: String, CaseIterable, Equatable, Hashable, Sendable {
    case physical
    case used
    case cachedFiles
    case swapUsed
    case appMemory
    case wired
    case compressed
}

public enum MemoryValueProvenance: Equatable, Sendable {
    case directSystemValue
    case directVMPageCounter
    case derivedSystemEstimate(formulaID: String)
}

public enum MemorySystemSource: String, Equatable, Sendable {
    case physicalMemory
    case hostVMInfo64
    case hostPageSize
    case swapUsage
}

public enum MemoryUnavailableReason: Equatable, Sendable {
    case sourceReadFailed(MemorySystemSource)
    case invalidSystemValue(source: MemorySystemSource)
    case shortSystemStructure(source: MemorySystemSource)
    case arithmeticOverflow(formulaID: String)
    case arithmeticUnderflow(formulaID: String)
    case inconsistentCounters(formulaID: String)
}

public enum MemoryFieldAvailability: Equatable, Sendable {
    case available(bytes: UInt64)
    case unavailable(MemoryUnavailableReason)

    public var bytes: UInt64? {
        guard case let .available(bytes) = self else { return nil }
        return bytes
    }
}

public struct MemorySummaryField: Equatable, Identifiable, Sendable {
    public let id: MemoryFieldID
    public let availability: MemoryFieldAvailability
    public let provenance: MemoryValueProvenance

    public init(
        id: MemoryFieldID,
        availability: MemoryFieldAvailability,
        provenance: MemoryValueProvenance
    ) {
        self.id = id
        self.availability = availability
        self.provenance = provenance
    }

    public var bytes: UInt64? { availability.bytes }
}

public struct MemoryTrendPoint: Equatable, Identifiable, Sendable {
    public let id: Int
    public let timestamp: Date
    /// `nil` means only that the derived load ratio is unavailable. The
    /// independently sampled pressure state can still be rendered.
    public let loadRatio: Double?
    /// Independent continuous pressure value. It is never derived from the
    /// load ratio; `nil` is rendered as a real chart gap.
    public let pressureRatio: Double?
    public let pressure: MemoryPressureState

    public init(
        id: Int,
        timestamp: Date,
        loadRatio: Double?,
        pressureRatio: Double? = nil,
        pressure: MemoryPressureState
    ) {
        self.id = id
        self.timestamp = timestamp
        if let loadRatio,
           loadRatio.isFinite,
           (0...1).contains(loadRatio) {
            self.loadRatio = loadRatio
        } else {
            self.loadRatio = nil
        }
        if let pressureRatio,
           pressureRatio.isFinite,
           (0...1).contains(pressureRatio) {
            self.pressureRatio = pressureRatio
        } else {
            self.pressureRatio = nil
        }
        self.pressure = pressure
    }

    public var isLoadRatioUnavailable: Bool { loadRatio == nil }
    public var isPressureRatioUnavailable: Bool { pressureRatio == nil }
}
