import CryptoKit
import Foundation
import SQLite3
import UsageButlerCore
import UsageButlerDomain

struct HistoryStoreMetadata: Codable, Sendable {
    var age = HistoryRetentionClock()
    var rule = HistoryUploadRule()
    var first: Date?
    var lastCommitted: Date?
    var retentionTrimmed = false
    var eventsTruncated = false
    var clean = true
    var collectionDesired = true
    var recoveredUnclean = false
    var retiredSegments: [Int64]?
}

enum HistorySchema {
    static func prepare(_ db: HistoryDatabase) throws {
        let version = try db.scalar("PRAGMA user_version")
        guard version <= 2 else { throw NetworkHistoryError.unsupportedSchema }
        if version == 1 {
            // No backfill: v1 never recorded observation order. Migration is
            // atomic and preserves every payload and immutable identity.
            try db.execute("""
            BEGIN IMMEDIATE;
            ALTER TABLE buckets ADD COLUMN last_observation INTEGER;
            ALTER TABLE hours ADD COLUMN last_observation INTEGER;
            INSERT INTO metadata VALUES('observation-order',X'30');
            PRAGMA user_version=2;
            COMMIT;
            """)
            return
        }
        guard version == 0 else { return }
        guard try db.scalar("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0 else {
            throw NetworkHistoryError.unsupportedSchema
        }
        try db.execute("""
        BEGIN IMMEDIATE;
        CREATE TABLE metadata(key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID;
        CREATE TABLE sessions(source TEXT PRIMARY KEY, sequence TEXT NOT NULL, last REAL NOT NULL) WITHOUT ROWID;
        CREATE TABLE applications(id INTEGER PRIMARY KEY AUTOINCREMENT, digest TEXT NOT NULL UNIQUE, stable TEXT NOT NULL, identity BLOB NOT NULL);
        CREATE INDEX applications_stable ON applications(stable);
        CREATE TABLE segments(id INTEGER PRIMARY KEY, source TEXT NOT NULL, day INTEGER NOT NULL,
            first REAL NOT NULL, last REAL NOT NULL, age REAL NOT NULL);
        CREATE TABLE buckets(segment INTEGER NOT NULL, app INTEGER NOT NULL, minute INTEGER NOT NULL,
            payload BLOB NOT NULL CHECK(length(payload)=56), last_observation INTEGER, PRIMARY KEY(segment,app,minute)) WITHOUT ROWID;
        CREATE TABLE hours(segment INTEGER NOT NULL, app INTEGER NOT NULL, minute INTEGER NOT NULL,
            payload BLOB NOT NULL CHECK(length(payload)=56), last_observation INTEGER, PRIMARY KEY(segment,app,minute)) WITHOUT ROWID;
        CREATE TABLE segment_apps(segment INTEGER NOT NULL, app INTEGER NOT NULL, PRIMARY KEY(segment,app)) WITHOUT ROWID;
        CREATE TABLE source_minutes(segment INTEGER NOT NULL, minute INTEGER NOT NULL, samples INTEGER NOT NULL,
            unattributed INTEGER NOT NULL, partial INTEGER NOT NULL, observed INTEGER NOT NULL,
            PRIMARY KEY(segment,minute)) WITHOUT ROWID;
        CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT, app INTEGER NOT NULL, segment INTEGER NOT NULL,
            kind TEXT NOT NULL, first REAL NOT NULL, last REAL NOT NULL, bytes BLOB NOT NULL,
            peak REAL NOT NULL, duration REAL NOT NULL, rule BLOB NOT NULL, reason TEXT);
        CREATE INDEX events_time ON events(last,app);
        INSERT INTO metadata VALUES('observation-order',X'30');
        PRAGMA user_version=2;
        COMMIT;
        """)
    }
    static func metadata(_ db: HistoryDatabase, allowMissing: Bool = false) throws -> HistoryStoreMetadata {
        let s = try db.statement("SELECT value FROM metadata WHERE key='state'")
        guard try s.next() else {
            guard allowMissing else { throw NetworkHistoryError.corrupt }; return .init()
        }
        guard let value = try? JSONDecoder().decode(HistoryStoreMetadata.self, from: s.data(0)) else {
            throw NetworkHistoryError.corrupt
        }
        return value
    }
    static func write(_ value: HistoryStoreMetadata, to db: HistoryDatabase) throws {
        let s = try db.statement("INSERT INTO metadata VALUES('state',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        s.bind(1, try JSONEncoder().encode(value)); try s.run()
    }
}

/// One instance owns the source's writer lease. Accepted frames are written to
/// one open transaction, bounded by five frames / five seconds. The SQLite page
/// cache is bounded; no week-sized Swift cache or unbounded async write queue.
public actor NetworkHistoryStore {
    public struct Configuration: Sendable {
        public let pageLimit: Int
        public let catalogueLimit: Int
        public let eventLimit: Int
        public init(pageLimit: Int = 126_976, catalogueLimit: Int = 8_192, eventLimit: Int = 50_000) {
            self.pageLimit = pageLimit; self.catalogueLimit = catalogueLimit; self.eventLimit = eventLimit
        }
    }
    public nonisolated let databaseURL: URL
    private let lease: HistoryFileLease
    private let db: HistoryDatabase
    private let configuration: Configuration
    private let clock: @Sendable () -> HistoryAgeSample
    private var metadata: HistoryStoreMetadata
    private var closed = false
    private var failure: NetworkHistoryError?
    private var checkpointPending = false
    private var inTransaction = false
    private var pendingFrames = 0
    private var pendingSince: UInt64?
    private var lastAccepted: Date?
    private var activeSession: String?
    private var activeSequence: UInt64 = 0
    private var previousSourceComplete = false
    private var segment: Int64?
    private var segmentDay: Int64?
    private var lastRetentionAge: Double = -.infinity
    private var maintenancePending = true
    private var identities: [String: Int64] = [:]
    private var activities = HistoryActivityAccumulator()
    private var observationOrdinal: Int64

    public init(directory: URL, configuration: Configuration = .init(),
                clock: @escaping @Sendable () -> HistoryAgeSample = SystemHistoryAgeClock.sample) throws {
        lease = try HistoryFileLease(directory: directory)
        databaseURL = directory.appendingPathComponent("history-v1.sqlite")
        db = try HistoryDatabase(path: databaseURL, pageLimit: configuration.pageLimit)
        self.configuration = configuration; self.clock = clock
        let creating = try db.scalar("PRAGMA user_version") == 0
        try HistorySchema.prepare(db)
        let order = try db.statement("SELECT value FROM metadata WHERE key='observation-order'")
        guard try order.next(), let ordinal = Int64(String(decoding: order.data(0), as: UTF8.self)), ordinal >= 0 else {
            throw NetworkHistoryError.corrupt
        }
        observationOrdinal = ordinal
        var initial = try HistorySchema.metadata(db, allowMissing: creating)
        initial.recoveredUnclean = !initial.clean; initial.clean = false
        let retired = initial.retiredSegments ?? []
        guard retired.count <= configuration.catalogueLimit, retired.allSatisfy({ $0 > 0 }),
              Set(retired).count == retired.count else { throw NetworkHistoryError.corrupt }
        initial.age.advance(clock()); metadata = initial
        try HistorySchema.write(initial, to: db)
        // An interrupted event is evidence up to its last committed sample,
        // not evidence that it continued while the process was absent.
        try db.execute("UPDATE events SET reason='service-restarted' WHERE reason IS NULL")
        try db.protectSidecars()
    }

    public func accept(_ frame: ProcessNetworkSettlement) throws {
        guard !closed else { throw NetworkHistoryError.closed }
        if let failure { throw failure }
        guard frame.applications.count <= 256, frame.session.utf8.count <= 128,
              Set(frame.applications.map(\.identity.key)).count == frame.applications.count,
              frame.end.timeIntervalSince1970.isFinite,
              (0..<253_402_300_800).contains(frame.end.timeIntervalSince1970) else { throw NetworkHistoryError.invalidRequest }
        do {
            let newSession = activeSession != frame.session
            if newSession {
                try flush()
                let checkpoint = try db.statement("SELECT sequence FROM sessions WHERE source=?")
                checkpoint.bind(1, frame.session)
                if try checkpoint.next() {
                    guard let sequence = UInt64(checkpoint.text(0)) else { throw NetworkHistoryError.corrupt }
                    activeSequence = sequence
                } else { activeSequence = 0 }
                activeSession = frame.session; segment = nil; segmentDay = nil
                previousSourceComplete = false
                activities.finishAll(reason: "source-session-changed")
            }
            guard frame.sequence > activeSequence else { return }
            metadata.age.advance(clock())
            if !inTransaction { try maintenanceSlice() }
            if !inTransaction {
                if db.sizes.wal > 8 * 1_048_576 || checkpointPending { checkpointPending = try !db.checkpoint(allowBusy: true) }
                try db.execute("BEGIN IMMEDIATE"); inTransaction = true
            }
            guard observationOrdinal < Int64.max else { throw NetworkHistoryError.capacity }
            observationOrdinal += 1
            let order = try db.statement("UPDATE metadata SET value=? WHERE key='observation-order'")
            order.bind(1, Data(String(observationOrdinal).utf8)); try order.run()
            let seconds = Double(frame.durationNanoseconds) / 1e9
            let clockChanged = frame.start.map { abs(frame.end.timeIntervalSince($0) - seconds) > 0.25 } ?? false
            let wall = frame.end.timeIntervalSince1970
            let day = Int64(floor(wall / 86_400)), minute = Int64(floor((wall - Double(day) * 86_400) / 60))
            if segment == nil || segmentDay != day || clockChanged {
                if clockChanged { activities.finishAll(reason: "wall-clock-changed") }
                else if segmentDay != nil, segmentDay != day { activities.finishAll(reason: "utc-day-boundary") }
                guard try db.scalar("SELECT count(*) FROM segments") < configuration.catalogueLimit else { throw NetworkHistoryError.capacity }
                let highest = max(try db.scalar("SELECT COALESCE(max(id),0) FROM segments"), metadata.retiredSegments?.max() ?? 0)
                guard highest < Int64.max else { throw NetworkHistoryError.capacity }
                let s = try db.statement("INSERT INTO segments(id,source,day,first,last,age) VALUES(?,?,?,?,?,?)")
                s.bind(1, highest + 1); s.bind(2, frame.session); s.bind(3, day); s.bind(4, wall)
                s.bind(5, wall); s.bind(6, metadata.age.ageSeconds)
                try s.run(); segment = highest + 1; segmentDay = day
            }
            guard let segment else { throw NetworkHistoryError.corrupt }
            var quality: HistoryQuality = []
            if newSession || frame.start == nil { quality.insert(.baseline) }
            if !frame.complete { quality.insert(.sourcePartial) }
            if frame.admissionTruncated { quality.insert(.capacity) }
            if frame.lostFrames > 0 { quality.insert(.sequenceGap) }
            if clockChanged { quality.insert(.clockChanged) }
            if metadata.age.conservative { quality.insert(.conservativeAge) }
            let bucketStart = Double(day) * 86_400 + Double(minute) * 60
            let endOffset = Int32(((wall - bucketStart) * 1_000).rounded(.down))
            // A discontinuity can span hours. It has zero observed duration;
            // do not overflow an offset trying to depict it as observed time.
            let intervalValid = seconds > 0 && seconds <= 30 && !clockChanged
            let startOffset = intervalValid ? endOffset - Int32((seconds * 1_000).rounded()) : endOffset
            if startOffset < 0 { quality.insert(.minuteBoundary) }
            let sourceMinute = try db.statement("""
            INSERT INTO source_minutes VALUES(?,?,1,?,?,?) ON CONFLICT(segment,minute) DO UPDATE SET
            samples=samples+1,unattributed=unattributed+excluded.unattributed,
            partial=partial+excluded.partial,observed=observed+excluded.observed
            """)
            sourceMinute.bind(1, segment); sourceMinute.bind(2, minute)
            sourceMinute.bind(3, Int64(frame.applications.filter { $0.identity.evidence == .unknown }.count))
            sourceMinute.bind(4, Int64(frame.complete && !frame.admissionTruncated ? 0 : 1))
            let observedSource = previousSourceComplete && frame.complete && intervalValid && frame.lostFrames == 0 && !newSession
            sourceMinute.bind(5, observedSource ? Int64(frame.durationNanoseconds / 1_000) : 0)
            try sourceMinute.run(); previousSourceComplete = frame.complete
            var admittedIDs = Set<String>()
            for app in frame.applications {
                // Unknown identities deliberately have a new key every frame.
                // Preserve their existence as un-attributed source coverage;
                // never manufacture PID/name continuity or exhaust the catalogue.
                guard app.identity.evidence != .unknown else { continue }
                let id = try identityID(app.identity); admittedIDs.insert(app.identity.key)
                let reference = try db.statement("INSERT OR IGNORE INTO segment_apps VALUES(?,?)")
                reference.bind(1, segment); reference.bind(2, id); try reference.run()
                var flags = quality
                for reason in [app.uploadIssue, app.downloadIssue].compactMap({ $0 }) {
                    if reason == "members-changed" { flags.insert(.membersChanged) }
                    if reason == "counter-unavailable-or-reset" { flags.insert(.counterReset) }
                }
                if app.uploadIssue == "overflow" { flags.insert(.uploadOverflow) }
                if app.downloadIssue == "overflow" { flags.insert(.downloadOverflow) }
                let value = HistoryMinute(upload: intervalValid ? app.upload : nil,
                    download: intervalValid ? app.download : nil,
                    durationNanoseconds: intervalValid ? frame.durationNanoseconds : 0,
                    firstMillisecond: startOffset, lastMillisecond: endOffset, quality: flags)
                try merge(value, table: "buckets", segment: segment, app: id, minute: minute)
                try merge(value.shifted(milliseconds: Int32(minute % 60) * 60_000), table: "hours",
                          segment: segment, app: id, minute: minute / 60)
                activities.accept(app: id, stableKey: app.identity.key, segment: segment, upload: intervalValid ? app.upload : nil,
                    end: frame.end, seconds: intervalValid ? seconds : 0, rule: metadata.rule)
                try db.ensureWriteBudget()
            }
            activities.finishMissing(admittedIDs)
            try writeActivities()
            let segmentUpdate = try db.statement("UPDATE segments SET last=?,age=? WHERE id=?")
            segmentUpdate.bind(1, wall); segmentUpdate.bind(2, metadata.age.ageSeconds); segmentUpdate.bind(3, segment)
            try segmentUpdate.run()
            if newSession, try db.scalar("SELECT count(*) FROM sessions") >= configuration.catalogueLimit {
                throw NetworkHistoryError.capacity
            }
            let update = try db.statement("INSERT INTO sessions VALUES(?,?,?) ON CONFLICT(source) DO UPDATE SET sequence=excluded.sequence,last=excluded.last")
            update.bind(1, frame.session); update.bind(2, String(frame.sequence)); update.bind(3, wall); try update.run()
            activeSequence = frame.sequence; lastAccepted = frame.end
            if metadata.first == nil { metadata.first = frame.end }
            pendingFrames += 1
            if pendingSince == nil { pendingSince = frame.monotonicEnd }
            let elapsed = pendingSince.map { frame.monotonicEnd >= $0 ? frame.monotonicEnd - $0 : UInt64.max } ?? 0
            if pendingFrames >= 5 || elapsed >= 5_000_000_000 { try flush() }
        } catch {
            fail(error); throw failure ?? .corrupt
        }
    }

    private func identityID(_ identity: ProcessNetworkApplicationIdentity) throws -> Int64 {
        guard identity.key.utf8.count <= 8_192, identity.name.utf8.count <= 1_024,
              (identity.installationPath?.utf8.count ?? 0) <= 8_192,
              (identity.bundleID?.utf8.count ?? 0) <= 1_024 else { throw NetworkHistoryError.invalidRequest }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(identity)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let id = identities[digest] { return id }
        let query = try db.statement("SELECT id FROM applications WHERE digest=?"); query.bind(1, digest)
        let id: Int64
        if try query.next() { id = query.integer(0) }
        else {
            guard try db.scalar("SELECT count(*) FROM applications") < configuration.catalogueLimit else { throw NetworkHistoryError.capacity }
            let insert = try db.statement("INSERT INTO applications(digest,stable,identity) VALUES(?,?,?)")
            insert.bind(1, digest); insert.bind(2, identity.key); insert.bind(3, data); try insert.run(); id = sqlite3_last_insert_rowid(db.handle)
        }
        if identities.count >= 256 { identities.removeAll(keepingCapacity: true) }
        identities[digest] = id; return id
    }

    private func merge(_ value: HistoryMinute, table: String, segment: Int64, app: Int64, minute: Int64) throws {
        // table is an internal literal, never protocol input.
        let query = try db.statement("SELECT payload FROM \(table) WHERE segment=? AND app=? AND minute=?")
        query.bind(1, segment); query.bind(2, app); query.bind(3, minute)
        var merged = value
        if try query.next() {
            guard var existing = HistoryMinute(encoded: query.data(0)) else { throw NetworkHistoryError.corrupt }
            existing.merge(value); merged = existing
        }
        let update = try db.statement("INSERT INTO \(table)(segment,app,minute,payload,last_observation) VALUES(?,?,?,?,?) ON CONFLICT(segment,app,minute) DO UPDATE SET payload=excluded.payload,last_observation=excluded.last_observation")
        update.bind(1, segment); update.bind(2, app); update.bind(3, minute); update.bind(4, merged.encoded)
        update.bind(5, observationOrdinal)
        try update.run()
    }

    public func flush() throws {
        guard !closed else { throw NetworkHistoryError.closed }
        if let failure { throw failure }
        guard inTransaction else { return }
        do {
            var committed = metadata; committed.lastCommitted = lastAccepted
            try HistorySchema.write(committed, to: db)
            try db.ensureWriteBudget()
            try db.execute("COMMIT"); inTransaction = false
            metadata = committed; pendingFrames = 0; pendingSince = nil
            try db.protectSidecars()
            let sizes = db.sizes
            if sizes.wal > 8 * 1_048_576 || checkpointPending { checkpointPending = try !db.checkpoint(allowBusy: true) }
            let after = db.sizes
            guard after.wal <= 16 * 1_048_576, after.database + after.wal <= 512 * 1_048_576 else {
                throw NetworkHistoryError.capacity
            }
        } catch { fail(error); throw failure ?? .corrupt }
    }

    public func setUploadRule(_ rule: HistoryUploadRule) throws {
        guard rule.isValid, !closed else { throw NetworkHistoryError.invalidRequest }
        try flush(); activities.finishAll(reason: "rule-changed")
        try db.execute("BEGIN IMMEDIATE"); inTransaction = true
        do { try writeActivities(); metadata.rule = rule; try flush() }
        catch { fail(error); throw failure ?? .corrupt }
    }
    public func uploadRule() -> HistoryUploadRule { metadata.rule }
    public func collectionIsDesired() -> Bool { metadata.collectionDesired }
    public func setCollectionDesired(_ value: Bool) throws {
        do { try flush(); metadata.collectionDesired = value; try HistorySchema.write(metadata, to: db) }
        catch { fail(error); throw failure ?? .corrupt }
    }
    public func coverage() -> HistoryCoverage {
        var result = HistoryCoverage(); result.firstCollectedAt = metadata.first; result.lastCommittedAt = metadata.lastCommitted
        result.retentionTrimmed = metadata.retentionTrimmed; result.conservativeAge = metadata.age.conservative
        result.eventsTruncated = metadata.eventsTruncated
        result.recoveredUncleanSession = metadata.recoveredUnclean
        result.databaseBytes = db.sizes.database; result.walBytes = db.sizes.wal
        if let pendingSince {
            let now = DispatchTime.now().uptimeNanoseconds
            result.uncommittedSeconds = now >= pendingSince ? Double(now - pendingSince) / 1e9 : 0
        }
        result.issue = failure?.code ?? (checkpointPending ? "history.checkpoint-pending" : nil)
        return result
    }
    public func close() throws {
        guard !closed else { return }
        defer { db.close(); lease.release(); closed = true }
        if let failure { throw failure }
        activities.finishAll(reason: "collection-stopped")
        if !inTransaction { try db.execute("BEGIN IMMEDIATE"); inTransaction = true }
        try writeActivities(); metadata.clean = true; try flush(); try db.checkpoint()
    }
    private func fail(_ error: Error) {
        if inTransaction { try? db.execute("ROLLBACK") }
        inTransaction = false
        failure = error as? NetworkHistoryError ?? .corrupt
        pendingFrames = 0; pendingSince = nil
    }
    /// One bounded slice per invocation; callers return to the source loop
    /// between slices. Never await/yield inside one unbounded deletion loop.
    /// Tombstones, not a Swift queue, are the durable maintenance cursor.
    public func maintain() throws {
        guard !closed else { throw NetworkHistoryError.closed }
        if let failure { throw failure }
        guard !inTransaction else { return }
        do { metadata.age.advance(clock()); try maintenanceSlice() }
        catch { fail(error); throw failure ?? .corrupt }
    }
    private func maintenanceTransaction(_ body: () throws -> Void) throws {
        if db.sizes.wal > 8 * 1_048_576 { checkpointPending = try !db.checkpoint(allowBusy: true) }
        try db.execute("BEGIN IMMEDIATE")
        do { try body(); try db.ensureWriteBudget(); try db.execute("COMMIT") }
        catch { try? db.execute("ROLLBACK"); throw error }
    }
    private func maintenanceSlice() throws {
        let cutoff = metadata.age.ageSeconds - 14 * 86_400
        if metadata.age.ageSeconds - lastRetentionAge >= 3_600 {
            lastRetentionAge = metadata.age.ageSeconds
            if cutoff > 0 {
                // At most catalogueLimit segment rows. Hide all newly expired
                // segments atomically before incrementally reclaiming pages.
                try maintenanceTransaction {
                    let mark = try db.statement("UPDATE segments SET age=-1 WHERE age>=0 AND age<?")
                    mark.bind(1, cutoff); try mark.run()
                    if sqlite3_changes(db.handle) > 0 {
                        maintenancePending = true; metadata.retentionTrimmed = true
                        try HistorySchema.write(metadata, to: db)
                    }
                }
            }
        }
        guard maintenancePending else { return }
        // Move only bounded metadata, not the large child tables. These durable
        // IDs preserve cleanup ownership while freeing physical segment slots.
        let available = configuration.catalogueLimit - (metadata.retiredSegments?.count ?? 0)
        if available > 0 {
            let expired = try db.statement("SELECT id FROM segments WHERE age<0 ORDER BY id LIMIT \(available)")
            var ids: [Int64] = []
            while try expired.next() { ids.append(expired.integer(0)) }
            if !ids.isEmpty {
                try maintenanceTransaction {
                    metadata.retiredSegments = (metadata.retiredSegments ?? []) + ids
                    let remove = try db.statement("DELETE FROM segments WHERE id=?")
                    for id in ids { remove.bind(1, id); try remove.run(); remove.reset() }
                    try HistorySchema.write(metadata, to: db)
                }
            }
        }
        if let segment {
            let marked = try db.scalar("SELECT count(*) FROM segments WHERE id=\(segment) AND age<0") > 0
            if (metadata.retiredSegments ?? []).contains(segment) || marked {
                self.segment = nil; segmentDay = nil; activities.finishAll(reason: "retention-boundary")
            }
        }
        var reclaimed = 0
        try maintenanceTransaction {
            // Retired-only identities/sessions need no slot while their hidden
            // child rows drain. Live activity provenance remains a reference.
            try db.execute("DELETE FROM applications WHERE id IN (SELECT id FROM applications WHERE id NOT IN (SELECT r.app FROM segment_apps r JOIN segments s ON s.id=r.segment WHERE s.age>=0) AND id NOT IN (SELECT e.app FROM events e JOIN segments s ON s.id=e.segment WHERE s.age>=0) LIMIT 256)")
            reclaimed += Int(sqlite3_changes(db.handle))
            try db.execute("DELETE FROM sessions WHERE source IN (SELECT source FROM sessions WHERE source NOT IN (SELECT source FROM segments WHERE age>=0) LIMIT 128)")
            reclaimed += Int(sqlite3_changes(db.handle))
        }
        if reclaimed > 0 { identities.removeAll(keepingCapacity: true) }
        guard let id = metadata.retiredSegments?.first else {
            let marked = try db.scalar("SELECT count(*) FROM segments WHERE age<0") > 0
            maintenancePending = reclaimed > 0 || marked
            return
        }

        var remaining = 2_048
        for table in ["events", "buckets", "hours", "source_minutes", "segment_apps"] {
            let key: String
            switch table {
            case "buckets", "hours": key = "segment,app,minute"
            case "source_minutes": key = "segment,minute"
            case "segment_apps": key = "segment,app"
            default: key = "id"
            }
            let limit = min(remaining, table == "events" ? 128 : 2_048)
            var removed: Int32 = 0
            try maintenanceTransaction {
                let chunk = try db.statement("DELETE FROM \(table) WHERE (\(key)) IN (SELECT \(key) FROM \(table) WHERE segment=? LIMIT \(limit))")
                chunk.bind(1, id); try chunk.run(); removed = sqlite3_changes(db.handle)
            }
            remaining -= Int(removed)
            if removed == limit { return }
        }
        try maintenanceTransaction {
            metadata.retiredSegments?.removeFirst()
            try HistorySchema.write(metadata, to: db)
        }
        identities.removeAll(keepingCapacity: true)
    }

    private func writeActivities() throws {
        for activity in activities.drainChanges() {
            if activity.databaseID == nil {
                guard try db.scalar("SELECT count(*) FROM events") < configuration.eventLimit else {
                    metadata.eventsTruncated = true; continue
                }
                let s = try db.statement("INSERT INTO events(app,segment,kind,first,last,bytes,peak,duration,rule,reason) VALUES(?,?,?,?,?,?,?,?,?,?)")
                s.bind(1, activity.app); s.bind(2, activity.segment); s.bind(3, activity.kind)
                s.bind(4, activity.start.timeIntervalSince1970); s.bind(5, activity.end.timeIntervalSince1970)
                s.bind(6, HistoryActivityAccumulator.bytes(activity.bytes)); s.bind(7, activity.peak)
                s.bind(8, activity.seconds); s.bind(9, try JSONEncoder().encode(activity.rule))
                if let reason = activity.reason { s.bind(10, reason) }; try s.run()
                activities.assign(activity.key, id: sqlite3_last_insert_rowid(db.handle))
            } else if let id = activity.databaseID {
                let s = try db.statement("UPDATE events SET last=?,bytes=?,peak=?,duration=?,reason=? WHERE id=?")
                s.bind(1, activity.end.timeIntervalSince1970); s.bind(2, HistoryActivityAccumulator.bytes(activity.bytes))
                s.bind(3, activity.peak); s.bind(4, activity.seconds)
                if let reason = activity.reason { s.bind(5, reason) }; s.bind(6, id); try s.run()
            }
        }
    }
}
