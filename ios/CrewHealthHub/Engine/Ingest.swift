import Foundation
import CryptoKit

struct DirtyKey: Hashable {
    let personId: String
    let metric: MetricId
    let day: String
}

struct IngestResult {
    var accepted = 0
    var inserted = 0
    var duplicates = 0
    var rejected = 0
    var suspect = 0
    var rejectReasons: [String: Int] = [:]
    var dirty: Set<DirtyKey> = []

    mutating func merge(_ o: IngestResult) {
        accepted += o.accepted; inserted += o.inserted; duplicates += o.duplicates; rejected += o.rejected; suspect += o.suspect
        for (k, v) in o.rejectReasons { rejectReasons[k, default: 0] += v }
        dirty.formUnion(o.dirty)
    }
}

/// QC outcome for a single raw observation (pure; unit-tested).
enum QCOutcome: Equatable {
    case accept(value: Double, unit: String, quality: Quality, reason: String?)
    case reject(String)
}

/// Ingestion pipeline (PART 5.1): validate → normalise units → sanity → plausibility → dedupe → persist → mark dirty.
final class Ingest {
    let repo: Repository
    let config: AppConfig
    var tz: TimeZone = .current

    init(repo: Repository, config: AppConfig) {
        self.repo = repo
        self.config = config
    }

    // MARK: Pure QC

    static func qc(_ raw: RawObservation, def: MetricDef?, now: Date, missionStart: Date?, allowHistory: Bool) -> QCOutcome {
        guard let def else { return .reject("Unknown metric \(raw.metric)") }
        guard raw.value.isUsable else { return .reject("Value is not a number") }
        guard raw.ts.timeIntervalSince1970 > 0 else { return .reject("Unparseable timestamp") }
        if raw.ts > now.addingTimeInterval(5 * 60) { return .reject("Timestamp is in the future") }
        let v: Double
        do { v = try UnitConversion.toCanonical(raw.value, unit: raw.unit, metric: raw.metric, canonical: def.unit) }
        catch { return .reject(error.localizedDescription) }
        if let lo = def.sanityMin, v < lo { return .reject("Below sanity limit (\(lo) \(def.unit))") }
        if let hi = def.sanityMax, v > hi { return .reject("Above sanity limit (\(hi) \(def.unit))") }
        var quality = Quality.ok
        var reason: String?
        if let ms = missionStart, raw.ts < ms, !allowHistory {
            quality = .suspect; reason = "Before mission start"
        }
        if raw.metric == "spo2" && v < 80 {
            quality = .suspect; reason = "SpO₂ below 80% — check sensor contact"
        }
        return .accept(value: v, unit: def.unit, quality: quality, reason: reason)
    }

    static func dedupeKey(person: String, metric: String, ts: Date, value: Double, adapter: String) -> String {
        let s = "\(person)|\(metric)|\(Int(ts.timeIntervalSince1970.rounded()))|\(value.rounded(to: 3))|\(adapter)"
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Jump threshold for the "implausible jump within one minute" rule (engineering, not clinical).
    static func jumpThreshold(_ def: MetricDef) -> Double { def.minSpread * 10 }

    // MARK: Pipeline

    @discardableResult
    func ingest(_ raws: [RawObservation], missionStart: Date? = nil, allowHistory: Bool = true, now: Date = Date()) throws -> IngestResult {
        var result = IngestResult()
        var normal: [Observation] = []
        var upserts: [Observation] = []
        // Process in time order so the jump rule sees predecessors.
        let sorted = raws.sorted { $0.ts < $1.ts }
        var lastByMetric: [String: Observation] = [:]

        for raw in sorted {
            let def = config.metric(raw.metric)
            switch Ingest.qc(raw, def: def, now: now, missionStart: missionStart, allowHistory: allowHistory) {
            case .reject(let why):
                result.rejected += 1
                result.rejectReasons[why, default: 0] += 1
                try? repo.reject(raw, reason: why)
            case .accept(let value, let unit, var quality, var reason):
                let key = raw.dedupeKey ?? Ingest.dedupeKey(person: raw.personId, metric: raw.metric, ts: raw.ts, value: value, adapter: raw.source.adapter)
                // Jump rule: implausible change versus the previous reading less than a minute earlier.
                let lk = "\(raw.personId)|\(raw.metric)"
                let prev = lastByMetric[lk] ?? (raw.metric == "symptom" ? nil : try? repo.latest(person: raw.personId, metric: raw.metric, before: raw.ts))
                // Radiation can legitimately change fast (events), so the jump rule applies to baseline metrics only.
                if let def, let prev, quality == .ok, def.engine == "baseline", def.kind == "point",
                   raw.ts.timeIntervalSince(prev.ts) < 60, raw.ts.timeIntervalSince(prev.ts) >= 0,
                   abs(value - prev.value) > Ingest.jumpThreshold(def), prev.dedupeKey != key {
                    quality = .suspect; reason = "Implausible jump within one minute"
                }
                if quality == .suspect { result.suspect += 1 }
                let obs = Observation(id: raw.stableId ?? newId(), personId: raw.personId, missionId: raw.missionId, ts: raw.ts,
                                      metric: raw.metric, value: value, unit: unit, source: raw.source, quality: quality,
                                      qualityReason: reason, context: raw.context, importBatchId: raw.importBatchId,
                                      dedupeKey: key, externalId: raw.externalId)
                lastByMetric[lk] = obs
                if raw.upsert { upserts.append(obs) } else { normal.append(obs) }
                result.accepted += 1
                for d in Ingest.dirtyKeys(for: obs, tz: tz) { result.dirty.insert(d) }
            }
        }

        try repo.db.transaction {
            let n1 = try repo.insert(normal)
            let n2 = try repo.insert(upserts, upsert: true)
            result.inserted = n1 + n2
            result.duplicates = normal.count - n1
            try checkBloodPressurePairs(normal + upserts)
        }
        return result
    }

    /// Days whose aggregates must be recomputed after this observation changes.
    static func dirtyKeys(for o: Observation, tz: TimeZone) -> [DirtyKey] {
        let day = Aggregator.dayOf(metric: o.metric, ts: o.ts, tz: tz)
        var keys = [DirtyKey(personId: o.personId, metric: o.metric, day: day)]
        if o.metric == "heart_rate" { keys.append(DirtyKey(personId: o.personId, metric: "heart_rate_resting", day: day)) }
        return keys
    }

    /// Plausibility: systolic must exceed diastolic for the same cuff reading (paired by pairId or within 60 s).
    private func checkBloodPressurePairs(_ obs: [Observation]) throws {
        let bp = obs.filter { $0.metric == "bp_sys" || $0.metric == "bp_dia" }
        guard !bp.isEmpty else { return }
        for o in bp {
            let other = o.metric == "bp_sys" ? "bp_dia" : "bp_sys"
            let cands = try repo.observations(person: o.personId, metric: other, from: o.ts.addingTimeInterval(-60), to: o.ts.addingTimeInterval(61))
            guard let partner = cands.first(where: { o.context?.pairId == nil || $0.context?.pairId == o.context?.pairId }) else { continue }
            let sys = o.metric == "bp_sys" ? o : partner
            let dia = o.metric == "bp_dia" ? o : partner
            if sys.value <= dia.value {
                try repo.markQuality(ids: [sys.id, dia.id], quality: .suspect, reason: "Systolic not above diastolic")
            }
        }
    }
}
