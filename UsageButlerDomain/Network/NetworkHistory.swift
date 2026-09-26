import Foundation

/// Exact output of one accepted source frame, before publication throttling.
/// A nil direction is an unobserved interval, never an observed zero.
public struct ProcessNetworkSettlement: Sendable {
    public struct Application: Sendable {
        public let identity: ProcessNetworkApplicationIdentity
        public let upload: UInt64?
        public let download: UInt64?
        public let uploadIssue: String?
        public let downloadIssue: String?
        public init(identity: ProcessNetworkApplicationIdentity, upload: UInt64?, download: UInt64?,
                    uploadIssue: String?, downloadIssue: String?) {
            self.identity = identity; self.upload = upload; self.download = download
            self.uploadIssue = uploadIssue; self.downloadIssue = downloadIssue
        }
    }
    public let session: String
    public let sequence: UInt64
    public let start: Date?
    public let end: Date
    public let monotonicEnd: UInt64
    public let durationNanoseconds: UInt64
    public let complete: Bool
    public let admissionTruncated: Bool
    public let issue: String?
    public let lostFrames: UInt64
    public let applications: [Application]
    public init(session: String, sequence: UInt64, start: Date?, end: Date, monotonicEnd: UInt64,
                durationNanoseconds: UInt64, complete: Bool, lostFrames: UInt64,
                admissionTruncated: Bool = false, issue: String? = nil, applications: [Application]) {
        self.session = session; self.sequence = sequence; self.start = start; self.end = end
        self.monotonicEnd = monotonicEnd; self.durationNanoseconds = durationNanoseconds
        self.complete = complete; self.lostFrames = lostFrames; self.applications = applications
        self.admissionTruncated = admissionTruncated; self.issue = issue
    }
}

public struct HistoryQuality: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let uploadGap = Self(rawValue: 1 << 0)
    public static let downloadGap = Self(rawValue: 1 << 1)
    public static let clockChanged = Self(rawValue: 1 << 2)
    public static let baseline = Self(rawValue: 1 << 3)
    public static let uploadOverflow = Self(rawValue: 1 << 4)
    public static let downloadOverflow = Self(rawValue: 1 << 5)
    public static let membersChanged = Self(rawValue: 1 << 6)
    public static let sequenceGap = Self(rawValue: 1 << 7)
    public static let sourcePartial = Self(rawValue: 1 << 8)
    public static let minuteBoundary = Self(rawValue: 1 << 9)
    public static let capacity = Self(rawValue: 1 << 10)
    public static let conservativeAge = Self(rawValue: 1 << 11)
    public static let counterReset = Self(rawValue: 1 << 12)
}

public struct HistoryRange: Codable, Equatable, Sendable {
    /// Queries take whole minute buckets. Never prorate an indivisible counter delta.
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    public static func recent(days: Double, now: Date = Date()) -> Self {
        let end = ceil(now.timeIntervalSince1970 / 60) * 60
        return .init(start: Date(timeIntervalSince1970: end - days * 86_400), end: Date(timeIntervalSince1970: end))
    }
    public var isValid: Bool {
        let a = start.timeIntervalSince1970, b = end.timeIntervalSince1970
        return a.isFinite && b.isFinite && a >= 0 && b < 253_402_300_800 && b > a
            && b - a <= 15 * 86_400 && a.truncatingRemainder(dividingBy: 60) == 0
            && b.truncatingRemainder(dividingBy: 60) == 0
    }
}

public struct HistoryTotals: Codable, Equatable, Sendable {
    public var upload: UInt64? = 0
    public var download: UInt64? = 0
    public var uploadObservedMicroseconds: UInt64 = 0
    public var downloadObservedMicroseconds: UInt64 = 0
    public var uploadSamples: UInt64 = 0
    public var downloadSamples: UInt64 = 0
    public var peakUpload: Double = 0
    public var peakDownload: Double = 0
    public var quality: HistoryQuality = []
    public init() {}
}

public enum HistoryIdentityOrder: String, Codable, Equatable, Sendable {
    case observed
    case legacyUnverified = "legacy-unverified"
}

public struct HistoryApplicationSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let identity: ProcessNetworkApplicationIdentity
    public var totals: HistoryTotals
    public let identitySnapshotCount: Int
    // Optional on the wire so older frozen snapshots decode conservatively.
    public let identityObservation: HistoryIdentityOrder?
    public var identityOrder: HistoryIdentityOrder { identityObservation ?? .legacyUnverified }
    public init(id: Int64, identity: ProcessNetworkApplicationIdentity, totals: HistoryTotals, identitySnapshotCount: Int = 1,
                identityOrder: HistoryIdentityOrder = .legacyUnverified) {
        self.id = id; self.identity = identity; self.totals = totals
        self.identitySnapshotCount = identitySnapshotCount
        identityObservation = identityOrder
    }
}

public struct HistoryCurveBucket: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let start: Date
    public let end: Date
    public var totals: HistoryTotals
    public var segments: Int
    public init(id: Int, start: Date, end: Date, totals: HistoryTotals, segments: Int) {
        self.id = id; self.start = start; self.end = end; self.totals = totals; self.segments = segments
    }
}

public struct HistoryDailySummary: Codable, Equatable, Sendable, Identifiable {
    public var id: Date { day }
    public let day: Date
    public var totals: HistoryTotals
    public init(day: Date, totals: HistoryTotals) { self.day = day; self.totals = totals }
}

public struct HistoryUploadRule: Codable, Equatable, Sendable {
    public var largeBytes: UInt64
    public var sustainedSeconds: Double
    public var sustainedBytesPerSecond: Double
    public init(largeBytes: UInt64 = 104_857_600, sustainedSeconds: Double = 60,
                sustainedBytesPerSecond: Double = 102_400) {
        self.largeBytes = largeBytes; self.sustainedSeconds = sustainedSeconds
        self.sustainedBytesPerSecond = sustainedBytesPerSecond
    }
    public var isValid: Bool {
        largeBytes >= 1_048_576 && largeBytes <= 1_125_899_906_842_624
            && sustainedSeconds.isFinite && (5...86_400).contains(sustainedSeconds)
            && sustainedBytesPerSecond.isFinite && (1_024...107_374_182_400).contains(sustainedBytesPerSecond)
    }
}

public struct HistoryUploadEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let applicationID: Int64
    public let applicationKey: String
    public let name: String
    public let kind: String
    public let start: Date
    public let end: Date
    public let bytes: UInt64
    public let peak: Double
    public let observedSeconds: Double
    public let rule: HistoryUploadRule
    public let endReason: String?
    public init(id: Int64, applicationID: Int64, applicationKey: String, name: String, kind: String, start: Date, end: Date,
                bytes: UInt64, peak: Double, observedSeconds: Double, rule: HistoryUploadRule, endReason: String?) {
        self.id = id; self.applicationID = applicationID; self.name = name; self.kind = kind
        self.applicationKey = applicationKey
        self.start = start; self.end = end; self.bytes = bytes; self.peak = peak
        self.observedSeconds = observedSeconds; self.rule = rule; self.endReason = endReason
    }
}

public struct HistoryCoverage: Codable, Equatable, Sendable {
    public var firstCollectedAt: Date?
    public var lastCommittedAt: Date?
    public var oldestRetainedAt: Date?
    public var retentionDays = 14
    public var retentionTrimmed = false
    public var eventsTruncated = false
    public var unattributedSamples: UInt64 = 0
    public var sourceSamples: UInt64 = 0
    public var sourcePartialSamples: UInt64 = 0
    public var sourceObservedMicroseconds: UInt64 = 0
    public var conservativeAge = false
    public var databaseBytes: Int64 = 0
    public var walBytes: Int64 = 0
    public var uncommittedSeconds: Double = 0
    public var recoveredUncleanSession = false
    public var issue: String?
    public init() {}
}

public struct HistoryQueryResult: Codable, Equatable, Sendable {
    public let range: HistoryRange
    public let applications: [HistoryApplicationSummary]
    public let totalApplications: Int
    public let page: Int
    public let curve: [HistoryCurveBucket]
    public let days: [HistoryDailySummary]
    public let events: [HistoryUploadEvent]
    public let coverage: HistoryCoverage
    public init(range: HistoryRange, applications: [HistoryApplicationSummary], totalApplications: Int,
                page: Int, curve: [HistoryCurveBucket], days: [HistoryDailySummary],
                events: [HistoryUploadEvent], coverage: HistoryCoverage) {
        self.range = range; self.applications = applications; self.totalApplications = totalApplications
        self.page = page; self.curve = curve; self.days = days; self.events = events; self.coverage = coverage
    }
}
