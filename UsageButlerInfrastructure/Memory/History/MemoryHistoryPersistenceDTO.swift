import Foundation
import UsageButlerCore
import UsageButlerDomain

enum MemoryHistoryPersistenceDTOError: Error, Equatable {
    case invalidShape
    case invalidPoint
    case unknownSchema
    case unknownVersion
}

struct MemoryHistoryEnvelopeDTO: Codable {
    static let schemaIdentifier = "usage-butler.memory-history"
    static let formatVersion = 2

    let schema: String
    let version: Int
    let points: [MemoryHistoryPointDTO]

    init(points: [MemoryHistoryPoint]) throws {
        schema = Self.schemaIdentifier
        version = Self.formatVersion
        self.points = try points.map(MemoryHistoryPointDTO.init)
    }

    func domainPoints() throws -> [MemoryHistoryPoint] {
        guard schema == Self.schemaIdentifier else {
            throw MemoryHistoryPersistenceDTOError.unknownSchema
        }
        guard version == 1 || version == Self.formatVersion else {
            throw MemoryHistoryPersistenceDTOError.unknownVersion
        }
        return try points.map {
            try $0.domain(includesPressureRatio: version >= 2)
        }
    }
}

struct MemoryHistoryPointDTO: Codable {
    enum Pressure: String, Codable {
        case normal
        case warning
        case critical
        case unknown
    }

    let timestamp: Date
    let ratio: Double?
    let pressureRatio: Double?
    let pressure: Pressure

    init(_ point: MemoryHistoryPoint) throws {
        guard point.timestamp.timeIntervalSince1970.isFinite else {
            throw MemoryHistoryPersistenceDTOError.invalidPoint
        }
        if let ratio = point.estimatedUsedRatio,
           !ratio.isFinite || !(0...1).contains(ratio) {
            throw MemoryHistoryPersistenceDTOError.invalidPoint
        }
        if let pressureRatio = point.pressureRatio,
           !pressureRatio.isFinite || !(0...1).contains(pressureRatio) {
            throw MemoryHistoryPersistenceDTOError.invalidPoint
        }

        timestamp = point.timestamp
        ratio = point.estimatedUsedRatio
        pressureRatio = point.pressureRatio
        switch point.pressure {
        case .normal: pressure = .normal
        case .warning: pressure = .warning
        case .critical: pressure = .critical
        case .unknown: pressure = .unknown
        }
    }

    func domain(includesPressureRatio: Bool) throws -> MemoryHistoryPoint {
        guard timestamp.timeIntervalSince1970.isFinite else {
            throw MemoryHistoryPersistenceDTOError.invalidPoint
        }
        if let ratio, !ratio.isFinite || !(0...1).contains(ratio) {
            throw MemoryHistoryPersistenceDTOError.invalidPoint
        }
        if let pressureRatio,
           !pressureRatio.isFinite || !(0...1).contains(pressureRatio) {
            throw MemoryHistoryPersistenceDTOError.invalidPoint
        }

        let domainPressure: MemoryPressureState
        switch pressure {
        case .normal: domainPressure = .normal
        case .warning: domainPressure = .warning
        case .critical: domainPressure = .critical
        case .unknown: domainPressure = .unknown
        }
        return MemoryHistoryPoint(
            timestamp: timestamp,
            estimatedUsedRatio: ratio,
            pressureRatio: includesPressureRatio ? pressureRatio : nil,
            pressure: domainPressure
        )
    }
}

enum MemoryHistoryStrictSchema {
    private static let envelopeKeys: Set<String> = [
        "schema", "version", "points"
    ]
    private static let requiredPointKeys: Set<String> = [
        "timestamp", "pressure"
    ]
    private static let versionOnePointKeys = requiredPointKeys.union(["ratio"])
    private static let versionTwoPointKeys = versionOnePointKeys.union([
        "pressureRatio"
    ])

    static func validate(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MemoryHistoryPersistenceDTOError.invalidShape
        }

        guard let envelope = object as? [String: Any],
              Set(envelope.keys) == envelopeKeys,
              let version = envelope["version"] as? Int,
              let points = envelope["points"] as? [Any] else {
            throw MemoryHistoryPersistenceDTOError.invalidShape
        }

        let allowedPointKeys = version == 1
            ? versionOnePointKeys
            : versionTwoPointKeys

        for value in points {
            guard let point = value as? [String: Any] else {
                throw MemoryHistoryPersistenceDTOError.invalidShape
            }
            let keys = Set(point.keys)
            guard requiredPointKeys.isSubset(of: keys),
                  keys.isSubset(of: allowedPointKeys) else {
                throw MemoryHistoryPersistenceDTOError.invalidShape
            }
        }
    }
}
