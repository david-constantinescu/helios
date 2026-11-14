import Foundation

// MARK: - Symptoms

struct SymptomStatus: Hashable {
    var code: String
    var label: String
    var region: String
    var hazards: [String]
    var severity: Int
    var ts: Date
    var level: Level
    var redFlag: Bool
    var reason: Reason
}

enum SymptomEngine {
    /// Symptoms reported in the last `lookbackDays` days. Red flags escalate immediately and bypass baselines.
    static func evaluate(_ obs: [Observation], config: AppConfig, asOf: Date, lookbackDays: Int) -> [SymptomStatus] {
        let since = asOf.addingTimeInterval(-Double(lookbackDays) * 86400)
        var latestByCode: [String: Observation] = [:]
        for o in obs where o.metric == "symptom" && o.ts >= since && o.ts <= asOf.addingTimeInterval(300) {
            guard let code = o.context?.symptom else { continue }
            if let prev = latestByCode[code], prev.ts > o.ts && prev.value >= o.value { continue }
            latestByCode[code] = o
        }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        return latestByCode.values.map { o in
            let code = o.context?.symptom ?? "other"
            let def = config.symptomByCode[code]
            let sev = Int(o.value.rounded())
            var level = Level(name: config.ranges.symptomLevels[String(sev)] ?? "watch")
            var why = "You reported \(def?.label.lowercased() ?? code) (severity \(sev) of 3) on \(df.string(from: o.ts))."
            var redFlag = false
            for r in config.ranges.alwaysEscalate where r.metric == "symptom" && (r.match ?? []).contains(code) {
                if let ms = r.minSeverity, Double(sev) < ms { continue }
                level = .escalate; redFlag = true; why = "\(r.reason): \(def?.label ?? code)."
            }
            return SymptomStatus(code: code, label: def?.label ?? code, region: def?.region ?? "whole_body", hazards: def?.hazards ?? [],
                                 severity: sev, ts: o.ts, level: level, redFlag: redFlag,
                                 reason: Reason(code: redFlag ? "red_flag" : "symptom", text: why, metric: "symptom", value: Double(sev)))
        }.sorted { $0.level > $1.level }
    }
}

// MARK: - Compound patterns (PART 5.6)

struct FiredPattern: Hashable {
    var id: String
    var def: PatternDef
    var reason: Reason
}

enum PatternEngine {
    static func holds(_ c: PatternCond, evals: [MetricId: MetricEval], adherence: [String: Double], params: EngineParams) -> Bool {
        if let all = c.all { return all.allSatisfy { holds($0, evals: evals, adherence: adherence, params: params) } }
        if let any = c.anyOf { return any.contains { holds($0, evals: evals, adherence: adherence, params: params) } }
        if let below = c.adherenceBelow {
            guard let a = adherence[c.routine ?? "daily_checkin"] else { return false }
            return a < below
        }
        guard let m = c.metric, let e = evals[m], e.status.level != .unknown else { return false }
        let dir = c.dir ?? "both"
        let days = c.days ?? 1
        if e.baseline.state == .active {
            return e.streak(dir, z: params.watchZ) >= days
        }
        // While learning, fall back to absolute bands for the latest value.
        return days <= 1 && e.absLevel >= .watch
    }

    static func evaluate(config: AppConfig, evals: [MetricId: MetricEval], adherence: [String: Double], params: EngineParams) -> [FiredPattern] {
        config.guidance.patterns.compactMap { id, def in
            guard holds(def.fires, evals: evals, adherence: adherence, params: params) else { return nil }
            return FiredPattern(id: id, def: def, reason: Reason(code: "pattern:\(id)", text: "\(def.label): \(def.whatItMayMean.first ?? "several indicators changed together.")"))
        }.sorted { $0.id < $1.id }
    }
}

// MARK: - Roll-up (PART 5.5 step 7)

struct Rollup {
    var regions: [String: StatusResult]
    var hazards: [String: StatusResult]
    var overall: StatusResult
}

enum RollupEngine {
    /// A low-confidence "act" is shown as "watch" with a note. Escalate is never downgraded.
    static func effective(_ s: StatusResult) -> (Level, Reason?) {
        if s.level == .act && s.confidence == .low {
            return (.watch, Reason(code: "low_confidence", text: "Shown as Watch until there is enough data to be sure.", metric: s.id))
        }
        return (s.level, nil)
    }

    static func rollup(personId: String, config: AppConfig, metricStatuses: [MetricId: StatusResult], symptoms: [SymptomStatus],
                       patterns: [FiredPattern], extraHazardReasons: [String: [(Level, Reason)]] = [:], now: Date) -> Rollup {
        func combine(scope: StatusScope, id: String, contributors: [(Level, Confidence, [Reason])]) -> StatusResult {
            let known = contributors.filter { $0.0 != .unknown }
            guard !known.isEmpty else {
                return StatusResult(personId: personId, scope: scope, id: id, level: .unknown, confidence: .low,
                                    reasons: [Reason(code: "no_data", text: "No recent data for this area.")], computedAt: now, dataThrough: nil)
            }
            let worst = known.map(\.0).max()!
            let reasons = known.filter { $0.0 >= .watch }.sorted { $0.0 > $1.0 }.flatMap(\.2)
            let conf = known.filter { $0.0 == worst }.map(\.1).max() ?? .low
            return StatusResult(personId: personId, scope: scope, id: id, level: worst, confidence: conf,
                                reasons: reasons.isEmpty ? [Reason(code: "all_ok", text: "Everything linked to this area is within your normal.")] : reasons,
                                computedAt: now, dataThrough: nil)
        }
        func metricContribution(_ mid: MetricId) -> (Level, Confidence, [Reason])? {
            guard let s = metricStatuses[mid] else { return nil }
            let (lvl, note) = effective(s)
            var rs = Array(s.reasons.prefix(2))
            if let note { rs.append(note) }
            return (lvl, s.confidence, rs)
        }

        var regions: [String: StatusResult] = [:]
        for r in config.regions {
            var contrib: [(Level, Confidence, [Reason])] = config.metrics(inRegion: r.id).compactMap { metricContribution($0.id) }
            for s in symptoms where s.region == r.id { contrib.append((s.level, .high, [s.reason])) }
            for p in patterns where p.def.raises.contains(r.id) { contrib.append((.watch, .medium, [p.reason])) }
            regions[r.id] = combine(scope: .region, id: r.id, contributors: contrib)
        }

        var hazards: [String: StatusResult] = [:]
        for h in config.hazards {
            var contrib: [(Level, Confidence, [Reason])] = h.feeds.compactMap { metricContribution($0) }
            for s in symptoms where s.hazards.contains(h.id) { contrib.append((s.level, .high, [s.reason])) }
            for p in patterns where p.def.raisesHazards.contains(h.id) { contrib.append((.watch, .medium, [p.reason])) }
            for (lvl, reason) in extraHazardReasons[h.id] ?? [] { contrib.append((lvl, .medium, [reason])) }
            hazards[h.id] = combine(scope: .hazard, id: h.id, contributors: contrib)
        }

        // Overall: worst region + counts of distinct issues. Never a numeric "health score".
        var counts: [String: Int] = ["watch": 0, "act": 0, "escalate": 0]
        for s in metricStatuses.values { let l = effective(s).0; if l >= .watch { counts[l.name, default: 0] += 1 } }
        for s in symptoms where s.level >= .watch { counts[s.level.name, default: 0] += 1 }
        for _ in patterns { counts["watch", default: 0] += 1 }
        let regionLevels = regions.values.map(\.level)
        let worst = regionLevels.max() ?? .unknown
        let anyKnown = regionLevels.contains { $0 != .unknown }
        var overallReasons = regions.values.filter { $0.level == worst && worst >= .watch }.flatMap { $0.reasons.prefix(1) }
        if overallReasons.isEmpty { overallReasons = [Reason(code: anyKnown ? "all_ok" : "no_data", text: anyKnown ? "All clear today." : "Not enough data yet.")] }
        let overall = StatusResult(personId: personId, scope: .overall, id: "overall", level: anyKnown ? worst : .unknown,
                                   confidence: regions.values.filter { $0.level == worst }.map(\.confidence).max() ?? .low,
                                   reasons: overallReasons, computedAt: now, dataThrough: nil, counts: counts)
        return Rollup(regions: regions, hazards: hazards, overall: overall)
    }

    /// One-line summary for the hero card (PART 11 copy).
    static func summary(_ overall: StatusResult, config: AppConfig) -> String {
        let c = overall.counts ?? [:]
        switch overall.level {
        case .unknown: return config.s("overall.unknown")
        case .ok: return overall.confidence == .low ? "No concerns — compared with your own history." : config.s("overall.ok")
        case .escalate: return config.s("overall.escalate", ["reason": overall.reasons.first?.text.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? "see details"])
        case .act:
            let n = (c["act"] ?? 0)
            let w = c["watch"] ?? 0
            return config.s("overall.act", ["n": String(max(n, 1))]) + (w > 0 ? " " + config.s("overall.watch", ["n": String(w)]) : "")
        case .watch:
            return config.s("overall.watch", ["n": String(max(c["watch"] ?? 1, 1))]) + " Nothing urgent."
        }
    }
}
