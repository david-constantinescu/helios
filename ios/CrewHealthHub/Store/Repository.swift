import Foundation

/// All persistence goes through this repository. Health data never touches UserDefaults.
final class Repository {
    let db: SQLiteDB
    static let schemaVersion = 1
    private let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    init(db: SQLiteDB) throws {
        self.db = db
        try migrate()
    }

    /// Opens (or creates) the on-device database with file protection and backup exclusion.
    static func openDefault(inMemory: Bool = false) throws -> Repository {
        if inMemory { return try Repository(db: SQLiteDB(path: ":memory:")) }
        let fm = FileManager.default
        var dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("CrewHealthHub", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        let path = dir.appendingPathComponent("crew-health-hub.sqlite").path
        let repo = try Repository(db: SQLiteDB(path: path))
        // Background HealthKit delivery must be able to write while the phone is locked (after first unlock).
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
        return repo
    }

    // MARK: Migrations

    private func migrate() throws {
        try db.exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
        let v = try db.query("SELECT value FROM meta WHERE key='schema'").first?.string(0).flatMap(Int.init) ?? 0
        if v < 1 {
            try db.exec("""
            CREATE TABLE IF NOT EXISTS observations(
              id TEXT PRIMARY KEY, person_id TEXT NOT NULL, mission_id TEXT, ts REAL NOT NULL, metric TEXT NOT NULL,
              value REAL NOT NULL, unit TEXT, adapter TEXT, device TEXT, kind TEXT, quality TEXT, quality_reason TEXT,
              context TEXT, batch_id TEXT, dedupe_key TEXT NOT NULL UNIQUE, external_id TEXT);
            CREATE INDEX IF NOT EXISTS obs_pmt ON observations(person_id, metric, ts);
            CREATE INDEX IF NOT EXISTS obs_ext ON observations(external_id);
            CREATE INDEX IF NOT EXISTS obs_batch ON observations(batch_id);
            CREATE TABLE IF NOT EXISTS rejected(id TEXT PRIMARY KEY, person_id TEXT, ts REAL, metric TEXT, value REAL,
              unit TEXT, adapter TEXT, reason TEXT, created REAL);
            CREATE TABLE IF NOT EXISTS daily(key TEXT PRIMARY KEY, person_id TEXT, metric TEXT, day TEXT, json TEXT);
            CREATE INDEX IF NOT EXISTS daily_pm ON daily(person_id, metric, day);
            CREATE TABLE IF NOT EXISTS docs(collection TEXT, id TEXT, person_id TEXT, ts REAL, json TEXT, PRIMARY KEY(collection, id));
            CREATE INDEX IF NOT EXISTS docs_cp ON docs(collection, person_id, ts);
            CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value BLOB);
            INSERT OR REPLACE INTO meta(key, value) VALUES('schema', '1');
            """)
        }
    }

    // MARK: Observations

    private func row(_ o: Observation) -> [SQLValue] {
        let ctx: SQLValue = o.context.flatMap { try? enc.encode($0) }.map { .text(String(decoding: $0, as: UTF8.self)) } ?? .null
        return [.text(o.id), .text(o.personId), .text(o.missionId), .double(o.ts.timeIntervalSince1970), .text(o.metric),
                .double(o.value), .text(o.unit), .text(o.source.adapter), o.source.device.map { .text($0) } ?? .null,
                .text(o.source.kind.rawValue), .text(o.quality.rawValue), o.qualityReason.map { .text($0) } ?? .null,
                ctx, o.importBatchId.map { .text($0) } ?? .null, .text(o.dedupeKey), o.externalId.map { .text($0) } ?? .null]
    }

    private static let obsCols = "id, person_id, mission_id, ts, metric, value, unit, adapter, device, kind, quality, quality_reason, context, batch_id, dedupe_key, external_id"

    /// Inserts observations; duplicates (same dedupe key) are ignored unless `upsert` is set.
    @discardableResult
    func insert(_ obs: [Observation], upsert: Bool = false) throws -> Int {
        guard !obs.isEmpty else { return 0 }
        let verb = upsert ? "INSERT OR REPLACE" : "INSERT OR IGNORE"
        return try db.runMany("\(verb) INTO observations(\(Repository.obsCols)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", obs.map(row))
    }

    private func decodeObs(_ r: SQLRow) -> Observation {
        let ctx: ObsContext? = r.data(12).flatMap { try? dec.decode(ObsContext.self, from: $0) }
        return Observation(id: r.string(0) ?? "", personId: r.string(1) ?? "", missionId: r.string(2) ?? "",
                           ts: Date(timeIntervalSince1970: r.double(3) ?? 0), metric: r.string(4) ?? "", value: r.double(5) ?? 0,
                           unit: r.string(6) ?? "",
                           source: SourceInfo(adapter: r.string(7) ?? "", device: r.string(8), kind: SourceKind(rawValue: r.string(9) ?? "") ?? .device),
                           quality: Quality(rawValue: r.string(10) ?? "ok") ?? .ok, qualityReason: r.string(11), context: ctx,
                           importBatchId: r.string(13), dedupeKey: r.string(14) ?? "", externalId: r.string(15))
    }

    func observations(person: String, metric: MetricId, from: Date, to: Date) throws -> [Observation] {
        try db.query("SELECT \(Repository.obsCols) FROM observations WHERE person_id=? AND metric=? AND ts>=? AND ts<? ORDER BY ts",
                     [.text(person), .text(metric), .double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)]).map(decodeObs)
    }

    func observations(person: String, metrics: [MetricId], from: Date, to: Date) throws -> [Observation] {
        guard !metrics.isEmpty else { return [] }
        let qs = Array(repeating: "?", count: metrics.count).joined(separator: ",")
        return try db.query("SELECT \(Repository.obsCols) FROM observations WHERE person_id=? AND metric IN (\(qs)) AND ts>=? AND ts<? ORDER BY ts",
                            [.text(person)] + metrics.map { .text($0) } + [.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)]).map(decodeObs)
    }

    /// Lightweight (ts, value) series of OK-quality rows — used for high-volume radiation data.
    func series(person: String, metric: MetricId, from: Date, to: Date) throws -> [(Date, Double)] {
        try db.query("SELECT ts, value FROM observations WHERE person_id=? AND metric=? AND ts>=? AND ts<? AND quality='ok' ORDER BY ts",
                     [.text(person), .text(metric), .double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)])
            .map { (Date(timeIntervalSince1970: $0.double(0) ?? 0), $0.double(1) ?? 0) }
    }

    func latest(person: String, metric: MetricId, before: Date? = nil) throws -> Observation? {
        let t = (before ?? Date.distantFuture).timeIntervalSince1970
        return try db.query("SELECT \(Repository.obsCols) FROM observations WHERE person_id=? AND metric=? AND ts<=? AND quality!='rejected' ORDER BY ts DESC LIMIT 1",
                            [.text(person), .text(metric), .double(t)]).first.map(decodeObs)
    }

    func observation(dedupeKey: String) throws -> Observation? {
        try db.query("SELECT \(Repository.obsCols) FROM observations WHERE dedupe_key=?", [.text(dedupeKey)]).first.map(decodeObs)
    }

    func markQuality(ids: [String], quality: Quality, reason: String) throws {
        for id in ids { try db.run("UPDATE observations SET quality=?, quality_reason=? WHERE id=?", [.text(quality.rawValue), .text(reason), .text(id)]) }
    }

    /// Deletes observations by HealthKit UUID (deleted-objects sync). Returns the removed rows so days can be recomputed.
    func deleteByExternalIds(_ ids: [String]) throws -> [Observation] {
        guard !ids.isEmpty else { return [] }
        var removed: [Observation] = []
        try db.transaction {
            for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
                let qs = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let p = chunk.map { SQLValue.text($0) }
                removed += try db.query("SELECT \(Repository.obsCols) FROM observations WHERE external_id IN (\(qs))", p).map(decodeObs)
                try db.run("DELETE FROM observations WHERE external_id IN (\(qs))", p)
            }
        }
        return removed
    }

    func deleteBatch(_ batchId: String) throws -> [Observation] {
        let rows = try db.query("SELECT \(Repository.obsCols) FROM observations WHERE batch_id=?", [.text(batchId)]).map(decodeObs)
        try db.run("DELETE FROM observations WHERE batch_id=?", [.text(batchId)])
        return rows
    }

    func deleteObservations(person: String) throws {
        try db.run("DELETE FROM observations WHERE person_id=?", [.text(person)])
        try db.run("DELETE FROM daily WHERE person_id=?", [.text(person)])
        try db.run("DELETE FROM docs WHERE person_id=?", [.text(person)])
    }

    func deleteObservations(person: String, adapter: String) throws -> Int {
        try db.run("DELETE FROM observations WHERE person_id=? AND adapter=?", [.text(person), .text(adapter)])
    }

    struct InventoryRow: Hashable { let metric: String; let count: Int; let first: Date; let last: Date; let sources: String; let suspect: Int }
    func inventory(person: String) throws -> [InventoryRow] {
        try db.query("""
            SELECT metric, COUNT(*), MIN(ts), MAX(ts), GROUP_CONCAT(DISTINCT adapter), SUM(CASE WHEN quality='suspect' THEN 1 ELSE 0 END)
            FROM observations WHERE person_id=? GROUP BY metric ORDER BY metric
            """, [.text(person)]).map {
            InventoryRow(metric: $0.string(0) ?? "", count: $0.int(1) ?? 0, first: Date(timeIntervalSince1970: $0.double(2) ?? 0),
                         last: Date(timeIntervalSince1970: $0.double(3) ?? 0), sources: $0.string(4) ?? "", suspect: $0.int(5) ?? 0)
        }
    }

    func count(person: String, adapter: String? = nil) throws -> Int {
        if let a = adapter {
            return try db.query("SELECT COUNT(*) FROM observations WHERE person_id=? AND adapter=?", [.text(person), .text(a)]).first?.int(0) ?? 0
        }
        return try db.query("SELECT COUNT(*) FROM observations WHERE person_id=?", [.text(person)]).first?.int(0) ?? 0
    }

    func firstObservationDate(person: String) throws -> Date? {
        try db.query("SELECT MIN(ts) FROM observations WHERE person_id=?", [.text(person)]).first?.double(0).map { Date(timeIntervalSince1970: $0) }
    }

    func hasSimulated(person: String) throws -> Bool {
        (try db.query("SELECT 1 FROM observations WHERE person_id=? AND kind='simulated' LIMIT 1", [.text(person)]).first) != nil
    }

    /// Distinct (metric, ts) pairs touched for a person — used for full rebuilds.
    func observedMetrics(person: String) throws -> [String] {
        try db.query("SELECT DISTINCT metric FROM observations WHERE person_id=?", [.text(person)]).compactMap { $0.string(0) }
    }

    func range(person: String, metric: String) throws -> (Date, Date)? {
        guard let r = try db.query("SELECT MIN(ts), MAX(ts) FROM observations WHERE person_id=? AND metric=?", [.text(person), .text(metric)]).first,
              let a = r.double(0), let b = r.double(1) else { return nil }
        return (Date(timeIntervalSince1970: a), Date(timeIntervalSince1970: b))
    }

    // MARK: Rejected (audit list; never fed to engines)

    func reject(_ raw: RawObservation, reason: String) throws {
        try db.run("INSERT OR REPLACE INTO rejected(id, person_id, ts, metric, value, unit, adapter, reason, created) VALUES(?,?,?,?,?,?,?,?,?)",
                   [.text(newId()), .text(raw.personId), .double(raw.ts.timeIntervalSince1970), .text(raw.metric), .double(raw.value),
                    .text(raw.unit), .text(raw.source.adapter), .text(reason), .double(Date().timeIntervalSince1970)])
    }

    struct RejectedRow: Hashable { let ts: Date; let metric: String; let value: Double; let unit: String; let adapter: String; let reason: String }
    func rejected(person: String, limit: Int = 100) throws -> [RejectedRow] {
        try db.query("SELECT ts, metric, value, unit, adapter, reason FROM rejected WHERE person_id=? ORDER BY created DESC LIMIT ?", [.text(person), .int(Int64(limit))]).map {
            RejectedRow(ts: Date(timeIntervalSince1970: $0.double(0) ?? 0), metric: $0.string(1) ?? "", value: $0.double(2) ?? 0,
                        unit: $0.string(3) ?? "", adapter: $0.string(4) ?? "", reason: $0.string(5) ?? "")
        }
    }

    // MARK: Daily aggregates

    func putDaily(_ aggs: [DailyAggregate]) throws {
        try db.runMany("INSERT OR REPLACE INTO daily(key, person_id, metric, day, json) VALUES(?,?,?,?,?)", aggs.map {
            [.text($0.key), .text($0.personId), .text($0.metric), .text($0.day), .text(String(decoding: try! enc.encode($0), as: UTF8.self))]
        })
    }

    func deleteDaily(person: String, metric: String, day: String) throws {
        try db.run("DELETE FROM daily WHERE key=?", [.text("\(person)|\(metric)|\(day)")])
    }

    func daily(person: String, metric: MetricId, from: String? = nil, to: String? = nil) throws -> [DailyAggregate] {
        try db.query("SELECT json FROM daily WHERE person_id=? AND metric=? AND day>=? AND day<=? ORDER BY day",
                     [.text(person), .text(metric), .text(from ?? "0000"), .text(to ?? "9999")])
            .compactMap { $0.data(0).flatMap { try? dec.decode(DailyAggregate.self, from: $0) } }
    }

    func allDaily(person: String, to: String? = nil) throws -> [MetricId: [DailyAggregate]] {
        let rows = try db.query("SELECT json FROM daily WHERE person_id=? AND day<=? ORDER BY day", [.text(person), .text(to ?? "9999")])
        var out: [MetricId: [DailyAggregate]] = [:]
        for r in rows { if let a = r.data(0).flatMap({ try? dec.decode(DailyAggregate.self, from: $0) }) { out[a.metric, default: []].append(a) } }
        return out
    }

    func clearDaily(person: String) throws { try db.run("DELETE FROM daily WHERE person_id=?", [.text(person)]) }

    // MARK: Generic documents (persons, missions, statuses, events, prompts, quests, badges, settings …)

    func put<T: Encodable>(_ collection: String, id: String, person: String? = nil, ts: Date? = nil, _ value: T) throws {
        let data = try enc.encode(value)
        try db.run("INSERT OR REPLACE INTO docs(collection, id, person_id, ts, json) VALUES(?,?,?,?,?)",
                   [.text(collection), .text(id), person.map { .text($0) } ?? .null, .double((ts ?? Date()).timeIntervalSince1970),
                    .text(String(decoding: data, as: UTF8.self))])
    }

    func get<T: Decodable>(_ collection: String, id: String, as: T.Type) throws -> T? {
        try db.query("SELECT json FROM docs WHERE collection=? AND id=?", [.text(collection), .text(id)]).first
            .flatMap { $0.data(0) }.flatMap { try? dec.decode(T.self, from: $0) }
    }

    func list<T: Decodable>(_ collection: String, person: String? = nil, as: T.Type, since: Date? = nil) throws -> [T] {
        var sql = "SELECT json FROM docs WHERE collection=?"
        var p: [SQLValue] = [.text(collection)]
        if let person { sql += " AND person_id=?"; p.append(.text(person)) }
        if let since { sql += " AND ts>=?"; p.append(.double(since.timeIntervalSince1970)) }
        sql += " ORDER BY ts"
        return try db.query(sql, p).compactMap { $0.data(0).flatMap { try? dec.decode(T.self, from: $0) } }
    }

    func delete(_ collection: String, id: String) throws {
        try db.run("DELETE FROM docs WHERE collection=? AND id=?", [.text(collection), .text(id)])
    }

    func deleteAll(_ collection: String, person: String) throws {
        try db.run("DELETE FROM docs WHERE collection=? AND person_id=?", [.text(collection), .text(person)])
    }

    // MARK: Key-value (HealthKit anchors, adapter state)

    func setKV(_ key: String, _ data: Data?) throws {
        if let data { try db.run("INSERT OR REPLACE INTO kv(key, value) VALUES(?,?)", [.text(key), .blob(data)]) }
        else { try db.run("DELETE FROM kv WHERE key=?", [.text(key)]) }
    }
    func kv(_ key: String) throws -> Data? { try db.query("SELECT value FROM kv WHERE key=?", [.text(key)]).first?.data(0) }
    func deleteKV(prefix: String) throws { try db.run("DELETE FROM kv WHERE key LIKE ?", [.text(prefix + "%")]) }

    // MARK: Export / delete all

    func exportAll() throws -> Data {
        var out: [String: Any] = ["schema": "crew-health-hub-export/1", "exportedAt": Date().iso]
        out["observations"] = try db.query("SELECT \(Repository.obsCols) FROM observations ORDER BY ts").map { r -> [String: Any] in
            let o = decodeObs(r)
            var d: [String: Any] = ["id": o.id, "personId": o.personId, "missionId": o.missionId, "ts": o.ts.iso, "metric": o.metric,
                                    "value": o.value, "unit": o.unit, "adapter": o.source.adapter, "kind": o.source.kind.rawValue,
                                    "quality": o.quality.rawValue, "dedupeKey": o.dedupeKey]
            if let dev = o.source.device { d["device"] = dev }
            if let e = o.externalId { d["externalId"] = e }
            if let c = o.context, let cd = try? enc.encode(c), let cj = try? JSONSerialization.jsonObject(with: cd) { d["context"] = cj }
            return d
        }
        out["documents"] = try db.query("SELECT collection, id, json FROM docs").map { r -> [String: Any] in
            ["collection": r.string(0) ?? "", "id": r.string(1) ?? "",
             "value": (r.data(2).flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? NSNull()]
        }
        return try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    }

    func deleteAll() throws {
        try db.exec("DELETE FROM observations; DELETE FROM rejected; DELETE FROM daily; DELETE FROM docs; DELETE FROM kv;")
    }
}
