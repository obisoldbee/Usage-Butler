import Foundation
import SQLite3
import UsageButlerCore
import UsageButlerDomain

/// Separate read-only executor. It owns no source, migrations or checkpoints.
/// A query holds at most a one-second snapshot, and uses small hourly summaries
/// except at minute-aligned range edges / the selected application's curve.
public actor NetworkHistoryQuery {
    private let path: URL
    public init(databaseURL: URL) { path = databaseURL }
    public func query(range: HistoryRange, applicationID: Int64? = nil, applicationKey: String? = nil, page: Int = 0,
                      eventKind: String? = nil) throws -> HistoryQueryResult {
        guard range.isValid, (0...1023).contains(page), applicationID.map({ $0 > 0 }) ?? true,
              (applicationKey?.utf8.count ?? 0) <= 8_192, applicationID == nil || applicationKey == nil,
              eventKind == nil || eventKind == "large" || eventKind == "sustained" else { throw NetworkHistoryError.invalidRequest }
        let db = try HistoryDatabase(path: path, readOnly: true)
        let schema = try db.scalar("PRAGMA user_version")
        guard schema == 1 || schema == 2 else { db.close(); throw NetworkHistoryError.unsupportedSchema }
        let observationColumn = schema == 2 ? "last_observation" : "NULL"
        let deadline = QueryDeadline()
        sqlite3_progress_handler(db.handle, 2_000, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<QueryDeadline>.fromOpaque(pointer).takeUnretainedValue().expired ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        defer { sqlite3_progress_handler(db.handle, 0, nil, nil); db.close(); withExtendedLifetime(deadline) {} }
        do {
            try db.execute("BEGIN")
            defer { try? db.execute("ROLLBACK") }
            let metadata = try HistorySchema.metadata(db)
            var selectedKey = applicationKey
            if let applicationID {
                let identity = try db.statement("SELECT stable FROM applications WHERE id=?"); identity.bind(1, applicationID)
                guard try identity.next() else { throw NetworkHistoryError.invalidRequest }; selectedKey = identity.text(0)
            }
            let start = range.start.timeIntervalSince1970, end = range.end.timeIntervalSince1970
            let segments = try db.statement("SELECT id,day FROM segments WHERE age>=0 AND day>=? AND day<=? ORDER BY id LIMIT 8193")
            segments.bind(1, Int64(floor(start / 86_400))); segments.bind(2, Int64(floor((end - 1) / 86_400)))
            var summaries: [Int64: HistoryTotals] = [:]
            var lastObservations: [Int64: Int64] = [:]
            var daily: [Int64: HistoryTotals] = [:]
            var curve: [Int: HistoryCurveBucket] = [:], lastCurveSegment: [Int: Int64] = [:]
            let widthMinutes = max(1, Int(ceil((end - start) / 60 / 1_440)))
            var segmentCount = 0
            var sourceSamples: UInt64 = 0, unattributed: UInt64 = 0, sourcePartial: UInt64 = 0, sourceObserved: UInt64 = 0
            while try segments.next() {
                segmentCount += 1; guard segmentCount <= 8_192 else { throw NetworkHistoryError.capacity }
                try deadline.check()
                let segment = segments.integer(0), day = segments.integer(1), dayStart = Double(day) * 86_400
                let lower = Int64(max(0, (start - dayStart) / 60)), upper = Int64(min(1_440, (end - dayStart) / 60))
                guard upper > lower else { continue }
                let source = try db.statement("SELECT samples,unattributed,partial,observed FROM source_minutes WHERE segment=? AND minute>=? AND minute<?")
                source.bind(1, segment); source.bind(2, lower); source.bind(3, upper)
                while try source.next() {
                    try deadline.check()
                    let values = (0..<4).map { source.integer(Int32($0)) }
                    guard values.allSatisfy({ $0 >= 0 }) else { throw NetworkHistoryError.corrupt }
                    func add(_ a: UInt64, _ b: Int64) throws -> UInt64 {
                        let sum = a.addingReportingOverflow(UInt64(b))
                        guard !sum.overflow else { throw NetworkHistoryError.corrupt }; return sum.partialValue
                    }
                    sourceSamples = try add(sourceSamples, values[0]); unattributed = try add(unattributed, values[1])
                    sourcePartial = try add(sourcePartial, values[2]); sourceObserved = try add(sourceObserved, values[3])
                }
                let hourLower = (lower + 59) / 60, hourUpper = upper / 60
                func accumulate(_ app: Int64, _ minute: HistoryMinute, observation: Int64) throws {
                    try deadline.check()
                    guard observation >= 0 else { throw NetworkHistoryError.corrupt }
                    lastObservations[app] = max(lastObservations[app] ?? 0, observation)
                    if summaries[app] == nil, summaries.count >= 8_192 { throw NetworkHistoryError.capacity }
                    summaries[app, default: .init()].merge(minute.totals)
                    daily[day, default: .init()].merge(minute.totals)
                }
                let appClause = selectedKey == nil ? "" : " AND app IN (SELECT id FROM applications WHERE stable=?)"
                if hourUpper > hourLower {
                    let s = try db.statement("SELECT app,payload,\(observationColumn) FROM hours WHERE segment=?\(appClause) AND minute>=? AND minute<?")
                    s.bind(1, segment); var index: Int32 = 2
                    if let selectedKey { s.bind(index, selectedKey); index += 1 }
                    s.bind(index, hourLower); s.bind(index + 1, hourUpper)
                    while try s.next() {
                        guard let value = HistoryMinute(encoded: s.data(1)) else { throw NetworkHistoryError.corrupt }
                        try accumulate(s.integer(0), value, observation: s.integer(2))
                    }
                }
                // Exact whole-minute edges, without counting the full hour twice.
                if lower != hourLower * 60 || upper != hourUpper * 60 || hourUpper <= hourLower {
                let s = try db.statement("SELECT app,minute,payload,\(observationColumn) FROM buckets WHERE segment=?\(appClause) AND minute>=? AND minute<? AND (minute<? OR minute>=?)")
                s.bind(1, segment); var index: Int32 = 2
                if let selectedKey { s.bind(index, selectedKey); index += 1 }
                s.bind(index, lower); s.bind(index + 1, upper)
                s.bind(index + 2, hourLower * 60); s.bind(index + 3, max(hourLower, hourUpper) * 60)
                while try s.next() {
                    guard let value = HistoryMinute(encoded: s.data(2)) else { throw NetworkHistoryError.corrupt }
                    try accumulate(s.integer(0), value, observation: s.integer(3))
                }
                }
                if let selectedKey {
                    let s = try db.statement("SELECT minute,payload FROM buckets WHERE segment=? AND app IN (SELECT id FROM applications WHERE stable=?) AND minute>=? AND minute<? ORDER BY minute")
                    s.bind(1, segment); s.bind(2, selectedKey); s.bind(3, lower); s.bind(4, upper)
                    while try s.next() {
                        try deadline.check()
                        guard let minute = HistoryMinute(encoded: s.data(1)) else { throw NetworkHistoryError.corrupt }
                        let wall = dayStart + Double(s.integer(0)) * 60
                        let group = Int((wall - start) / 60) / widthMinutes
                        guard (0..<1_440).contains(group) else { throw NetworkHistoryError.invalidRequest }
                        if curve[group] == nil {
                            let a = start + Double(group * widthMinutes) * 60
                            curve[group] = .init(id: group, start: .init(timeIntervalSince1970: a),
                                end: .init(timeIntervalSince1970: min(end, a + Double(widthMinutes * 60))), totals: .init(), segments: 0)
                        }
                        curve[group]?.totals.merge(minute.totals)
                        if lastCurveSegment[group] != segment {
                            curve[group]?.segments += 1; lastCurveSegment[group] = segment
                        }
                    }
                }
            }
            var grouped: [String: HistoryApplicationSummary] = [:]
            let identities = try db.statement("SELECT id,stable,identity FROM applications ORDER BY id")
            while try identities.next() {
                try deadline.check(); let id = identities.integer(0)
                guard let totals = summaries[id] else { continue }
                guard let identity = try? JSONDecoder().decode(ProcessNetworkApplicationIdentity.self, from: identities.data(2)) else { throw NetworkHistoryError.corrupt }
                let key = identities.text(1)
                var combined = grouped[key]?.totals ?? .init(); combined.merge(totals)
                let previous = grouped[key]
                let ordinal = lastObservations[id] ?? 0
                let useCurrent = previous == nil || ordinal > (lastObservations[previous!.id] ?? 0)
                // NULL v1 evidence predates the atomic migration boundary;
                // it supplies totals but cannot claim an observed ordering.
                // With only legacy evidence the representative is explicitly
                // unverified, never presented as the latest identity.
                grouped[key] = .init(id: useCurrent ? id : previous!.id,
                    identity: useCurrent ? identity : previous!.identity, totals: combined,
                    identitySnapshotCount: (previous?.identitySnapshotCount ?? 0) + 1,
                    identityOrder: max(ordinal, previous.map { lastObservations[$0.id] ?? 0 } ?? 0) > 0 ? .observed : .legacyUnverified)
            }
            let ordered = grouped.values.sorted {
                if $0.totals.upload != $1.totals.upload { return ($0.totals.upload ?? 0) > ($1.totals.upload ?? 0) }
                return $0.id < $1.id
            }
            let rows = selectedKey == nil ? Array(ordered.dropFirst(page * 64).prefix(64)) : Array(ordered.prefix(64))
            let events = try readEvents(db, range: range, stableKey: selectedKey, kind: eventKind, page: page)
            var coverage = HistoryCoverage()
            coverage.firstCollectedAt = metadata.first; coverage.lastCommittedAt = metadata.lastCommitted
            coverage.retentionTrimmed = metadata.retentionTrimmed; coverage.conservativeAge = metadata.age.conservative
            coverage.eventsTruncated = metadata.eventsTruncated
            coverage.unattributedSamples = unattributed; coverage.sourceSamples = sourceSamples
            coverage.sourcePartialSamples = sourcePartial; coverage.sourceObservedMicroseconds = sourceObserved
            coverage.recoveredUncleanSession = metadata.recoveredUnclean
            let oldest = try db.statement("SELECT min(first) FROM segments WHERE age>=0")
            if try oldest.next(), sqlite3_column_type(oldest.handle, 0) != SQLITE_NULL {
                coverage.oldestRetainedAt = .init(timeIntervalSince1970: oldest.double(0))
            }
            coverage.databaseBytes = db.sizes.database; coverage.walBytes = db.sizes.wal
            return .init(range: range, applications: rows, totalApplications: ordered.count, page: page,
                curve: curve.values.sorted { $0.id < $1.id },
                days: daily.keys.sorted().map { .init(day: .init(timeIntervalSince1970: Double($0) * 86_400), totals: daily[$0]!) },
                events: events, coverage: coverage)
        } catch {
            if deadline.expired || Task.isCancelled { throw NetworkHistoryError.queryTimedOut }
            throw error
        }
    }
    private func readEvents(_ db: HistoryDatabase, range: HistoryRange, stableKey: String?, kind: String?, page: Int) throws -> [HistoryUploadEvent] {
        let s = try db.statement("""
        SELECT e.id,e.app,a.identity,e.kind,e.first,e.last,e.bytes,e.peak,e.duration,e.rule,e.reason
        FROM events e JOIN applications a ON a.id=e.app
        WHERE e.segment IN (SELECT id FROM segments WHERE age>=0) AND e.last>? AND e.first<? \(stableKey == nil ? "" : "AND a.stable=?") \(kind == nil ? "" : "AND e.kind=?")
        ORDER BY e.last DESC,e.id DESC LIMIT 64 OFFSET ?
        """)
        s.bind(1, range.start.timeIntervalSince1970); s.bind(2, range.end.timeIntervalSince1970)
        var index: Int32 = 3
        if let stableKey { s.bind(index, stableKey); index += 1 }
        if let kind { s.bind(index, kind); index += 1 }; s.bind(index, Int64(page * 64))
        var result: [HistoryUploadEvent] = []
        while try s.next() {
            guard let identity = try? JSONDecoder().decode(ProcessNetworkApplicationIdentity.self, from: s.data(2)),
                  let bytes = HistoryActivityAccumulator.decodeBytes(s.data(6)),
                  let rule = try? JSONDecoder().decode(HistoryUploadRule.self, from: s.data(9)) else { throw NetworkHistoryError.corrupt }
            result.append(.init(id: s.integer(0), applicationID: s.integer(1), applicationKey: identity.key, name: identity.name, kind: s.text(3),
                start: .init(timeIntervalSince1970: s.double(4)), end: .init(timeIntervalSince1970: s.double(5)),
                bytes: bytes, peak: s.double(7), observedSeconds: s.double(8), rule: rule,
                endReason: sqlite3_column_type(s.handle, 10) == SQLITE_NULL ? nil : s.text(10)))
        }
        return result
    }
}

private final class QueryDeadline {
    private let start = DispatchTime.now().uptimeNanoseconds
    var expired: Bool { DispatchTime.now().uptimeNanoseconds - start > 1_000_000_000 }
    func check() throws { if expired || Task.isCancelled { throw NetworkHistoryError.queryTimedOut } }
}
