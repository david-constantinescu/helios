import Foundation

// MARK: - Baseline (PART 5.3)

enum BaselineEngine {
    /// Computes the personal baseline for `evalDay` from the daily series.
    /// The window is the `windowDays` days ending `baselineLagDays` before `evalDay`, so a developing
    /// change does not immediately absorb itself into "normal". Excluded days (e.g. illness) are skipped.
    static func compute(def: MetricDef, personId: String, series: [DailyAggregate], evalDay: String, params: EngineParams,
                        excludedDays: Set<String> = [], locked: Baseline? = nil, now: Date = Date(), tz: TimeZone = .current) -> Baseline {
        let valid = series.filter { $0.day <= evalDay }
        let learningDays = def.minLearningDays ?? params.minLearningDays
        let nDays = valid.count
        let lastDay = valid.last?.day
        let stale = lastDay.map { DayKey.diff(evalDay, $0, tz) > params.staleDays } ?? true

        if var l = locked {
            l.state = stale ? .stale : .active
            l.locked = true
            return l
        }

        let lagEnd = DayKey.add(evalDay, -params.baselineLagDays, tz)
        let lagStart = DayKey.add(lagEnd, -(params.windowDays - 1), tz)
        var window = valid.filter { $0.day >= lagStart && $0.day <= lagEnd && !excludedDays.contains($0.day) }
        if window.count < 5 {
            // Not enough history before the lag: fall back to the most recent window including today.
            let start = DayKey.add(evalDay, -(params.windowDays - 1), tz)
            window = valid.filter { $0.day >= start && !excludedDays.contains($0.day) }
        }
        if window.count < 5 {
            // Still thin: use everything the person has (e.g. an older Apple Health history), most recent 90 days first.
            let all = valid.filter { !excludedDays.contains($0.day) }
            window = Array(all.suffix(90))
            if window.isEmpty { window = Array(valid.suffix(90)) }
        }
        let xs = window.map(\.value)
        let med = Stats.median(xs)
        let mad = Stats.mad(xs, median: med)
        let spread = max(1.4826 * (mad.isUsable ? mad : 0), def.minSpread)
        let sourceMix = Array(Set(window.flatMap(\.sources))).sorted()

        var note: String?
        // Device-change check: compare days from the most recent source with days from earlier sources.
        if sourceMix.count > 1, let newest = window.last?.sources.first {
            let newDays = window.filter { $0.sources == [newest] }.map(\.value)
            let oldDays = window.filter { !$0.sources.contains(newest) }.map(\.value)
            if newDays.count >= 3 && oldDays.count >= 3 {
                let diff = abs(Stats.median(newDays) - Stats.median(oldDays))
                if diff > 2 * spread {
                    note = "Device changed: readings from \(newest) differ from earlier sources by \(String(format: "%.1f", diff)) \(def.unit). Consider resetting your normal."
                }
            }
        }

        // Your normal starts from whatever history exists (imported Apple Health included): no learning period.
        _ = learningDays
        let state: BaselineState = stale ? .stale : (xs.isEmpty ? .learning : .active)
        return Baseline(personId: personId, metric: def.id, state: state, windowDays: params.windowDays, nDays: nDays,
                        median: med, mad: mad.isUsable ? mad : 0, spread: spread, updatedAt: now, sourceMix: sourceMix, note: note)
    }
}

// MARK: - Deviation, trend and status (PART 5.4 – 5.5)

struct MetricEval: Hashable {
    var def: MetricDef
    var status: StatusResult
    var baseline: Baseline
    var latest: DailyAggregate?
    var absLevel: Level
    var baseLevel: Level
    var dz: Double?               // directional z of the latest day
    var z: Double?                // signed z of the latest day
    var slopePerDay: Double?
    var slopeNorm: Double?
    var persistWatch: Int
    var persistAct: Int
    /// Signed z of recent entries (oldest → newest), within the last 14 days; used by pattern rules.
    var recentZ: [Double]
    var learningProgress: (n: Int, of: Int)? {
        baseline.state == .learning ? (baseline.nDays, def.minLearningDays ?? EngineParams.defaults.minLearningDays) : nil
    }
    static func == (a: MetricEval, b: MetricEval) -> Bool { a.status == b.status && a.baseline == b.baseline }
    func hash(into h: inout Hasher) { h.combine(status); h.combine(baseline) }

    /// Count of trailing recent entries deviating in the given direction by at least `z`.
    func streak(_ dir: String, z threshold: Double) -> Int {
        var n = 0
        for v in recentZ.reversed() {
            let d = dir == "high" ? v : (dir == "low" ? -v : abs(v))
            if d >= threshold { n += 1 } else { break }
        }
        return n
    }
}

enum StatusEngine {
    static func directional(_ z: Double, _ dir: Direction) -> Double {
        switch dir { case .high: return z; case .low: return -z; case .both: return abs(z) }
    }

    /// Absolute band level for a value (bands inclusive; highest level wins where they overlap).
    static func absoluteLevel(_ v: Double, range: RangeDef?) -> (Level, Band?) {
        guard let r = range else { return (.ok, nil) }
        var best: (Level, Band?) = (.ok, nil)
        for b in r.bands where v >= b.min && v <= b.max {
            let l = Level(name: b.level)
            if l > best.0 { best = (l, b) }
        }
        return best
    }

    static func fmt(_ v: Double, _ def: MetricDef) -> String {
        if def.unit == "1–5" { return abs(v - v.rounded()) < 0.05 ? String(Int(v.rounded())) : String(format: "%.1f", v) }
        return String(format: "%.\(def.decimals)f", v)
    }
    static func unitText(_ def: MetricDef) -> String {
        switch def.unit { case "1–5": return " pt"; case "steps": return " steps"; default: return " " + def.unit }
    }

    static func evaluate(def: MetricDef, personId: String, series: [DailyAggregate], evalDay: String, params: EngineParams,
                         range: RangeDef?, rules: [AlwaysEscalateRule], excludedDays: Set<String> = [],
                         locked: Baseline? = nil, now: Date = Date(), tz: TimeZone = .current) -> MetricEval {
        let valid = series.filter { $0.day <= evalDay }
        let baseline = BaselineEngine.compute(def: def, personId: personId, series: valid, evalDay: evalDay, params: params,
                                              excludedDays: excludedDays, locked: locked, now: now, tz: tz)
        func result(_ level: Level, _ conf: Confidence, _ reasons: [Reason], through: String?) -> StatusResult {
            StatusResult(personId: personId, scope: .metric, id: def.id, level: level, confidence: conf, reasons: reasons, computedAt: now, dataThrough: through)
        }
        guard let latest = valid.last else {
            return MetricEval(def: def, status: result(.unknown, .low, [Reason(code: "no_data", text: "No measurement yet.", metric: def.id)], through: nil),
                              baseline: baseline, latest: nil, absLevel: .unknown, baseLevel: .unknown, dz: nil, z: nil, slopePerDay: nil,
                              slopeNorm: nil, persistWatch: 0, persistAct: 0, recentZ: [])
        }
        let age = DayKey.diff(evalDay, latest.day, tz)
        if age > params.staleDays {
            return MetricEval(def: def, status: result(.unknown, .low, [Reason(code: "stale", text: "No recent measurement (last one \(age) days ago). Please re-measure.", metric: def.id)], through: latest.day),
                              baseline: baseline, latest: latest, absLevel: .unknown, baseLevel: .unknown, dz: nil, z: nil, slopePerDay: nil,
                              slopeNorm: nil, persistWatch: 0, persistAct: 0, recentZ: [])
        }

        var reasons: [Reason] = []
        let x = latest.value
        let unit = unitText(def)

        // 1. Absolute ranges (can only raise concern).
        let (absLevel, band) = absoluteLevel(x, range: range)
        if absLevel >= .watch, let r = range {
            let okBand = r.bands.first { $0.level == "ok" }
            let okText = okBand.map { " (general range \(fmt($0.min, def))–\(fmt($0.max, def))\(unit))" } ?? ""
            reasons.append(Reason(code: "abs_range", text: "\(def.label) of \(fmt(x, def))\(unit) is outside the general range\(okText).",
                                  metric: def.id, value: x))
            _ = band
        }

        // 2. Personal baseline.
        var baseLevel = Level.ok
        var dzLatest: Double?, zLatest: Double?, slopePerDay: Double?, slopeNorm: Double?
        var persistW = 0, persistA = 0
        var recentZ: [Double] = []
        let recentStart = DayKey.add(evalDay, -13, tz)
        let recent = valid.filter { $0.day >= recentStart }

        if baseline.state == .active && baseline.median.isUsable {
            let m = baseline.median, s = baseline.spread
            recentZ = recent.map { ($0.value - m) / s }
            let z = (x - m) / s
            zLatest = z
            dzLatest = directional(z, def.direction)
            // Persistence on daily values.
            for v in recentZ.reversed() { if directional(v, def.direction) >= params.watchZ { persistW += 1 } else { break } }
            // Persistence on 3-day rolling median.
            let vals = recent.map(\.value)
            var x3z: [Double] = []
            for i in 0..<vals.count { let w = Array(vals[max(0, i - 2)...i]); x3z.append(directional((Stats.median(w) - m) / s, def.direction)) }
            for v in x3z.reversed() { if v >= params.actZ { persistA += 1 } else { break } }
            // Theil–Sen trend over the last 14 days (≥ 5 points).
            if recent.count >= 5 {
                let pts = recent.map { (x: Double(DayKey.diff($0.day, evalDay, tz)), y: $0.value) }
                if let sl = Stats.theilSen(pts) {
                    slopePerDay = sl
                    var dirSlope: Double
                    switch def.direction {
                    case .high: dirSlope = sl
                    case .low: dirSlope = -sl
                    case .both: dirSlope = (sl >= 0) == (x >= m) ? abs(sl) : -abs(sl)   // only "moving away from normal" counts
                    }
                    slopeNorm = dirSlope * 7 / s
                }
            }
            let dz = dzLatest!
            let sn = slopeNorm ?? 0
            if dz >= params.escalateZ && absLevel >= .watch { baseLevel = .escalate }
            else if persistA >= params.persistActDays || (sn >= params.trendAct && dz >= params.watchZ) { baseLevel = .act }
            else if persistW >= params.persistWatchDays || (sn >= params.trendWatch && dz >= 1.0) { baseLevel = .watch }

            let diff = x - m
            if dz >= params.watchZ {
                let dirWord = diff >= 0 ? "above" : "below"
                let days = persistW >= 2 ? " for \(persistW) days in a row" : " today"
                reasons.append(Reason(code: "deviation", text: "\(def.label) is \(fmt(abs(diff), def))\(unit) \(dirWord) your usual \(fmt(m, def)) (\(String(format: "%.1f", abs(z)))× your normal day-to-day variation)\(days).",
                                      metric: def.id, value: x, baseline: m, z: z))
            }
            if let sl = slopePerDay, sn >= params.trendWatch {
                let word = sl >= 0 ? "rising" : "falling"
                reasons.append(Reason(code: "trend", text: "\(def.label) has been \(word) by about \(fmt(abs(sl * 7), def))\(unit) per week over the last 2 weeks.",
                                      metric: def.id, value: x, baseline: m, slopePerDay: sl))
            }
            if baseLevel == .ok && absLevel <= .ok {
                reasons.append(Reason(code: "within_normal", text: "\(def.label) \(fmt(x, def))\(unit) is within your normal (\(fmt(m, def)) ± \(fmt(s, def))).",
                                      metric: def.id, value: x, baseline: m, z: z))
            }
            if let note = baseline.note { reasons.append(Reason(code: "device_change", text: note, metric: def.id)) }
        } else if baseline.state == .learning {
            let N = def.minLearningDays ?? params.minLearningDays
            reasons.append(Reason(code: "learning", text: "No history for this yet; using general ranges.", metric: def.id, value: x))
        }

        var level = max(absLevel, baseLevel)

        // 3. Hard rules that can never be downgraded.
        for r in rules where r.metric == def.id {
            if let b = r.below, x < b { level = .escalate; reasons.insert(Reason(code: "always_escalate", text: "\(r.reason): \(fmt(x, def))\(unit).", metric: def.id, value: x), at: 0) }
            if let a = r.above, x > a { level = .escalate; reasons.insert(Reason(code: "always_escalate", text: "\(r.reason): \(fmt(x, def))\(unit).", metric: def.id, value: x), at: 0) }
        }

        // 4. Confidence.
        let simOnly = valid.suffix(14).allSatisfy(\.hasSimulated)
        var conf: Confidence
        if baseline.state == .learning || baseline.nDays < 3 { conf = .low }
        else if baseline.nDays >= 14 && baseline.sourceMix.count <= 1 { conf = .high }
        else { conf = .medium }
        // Spec 5.5: simulated-only data is always low confidence (honesty over drama).
        if simOnly { conf = .low }

        reasons.sort { a, b in
            let rank = ["always_escalate": 0, "deviation": 1, "abs_range": 2, "trend": 3, "learning": 4, "device_change": 5, "within_normal": 6]
            return (rank[a.code] ?? 9) < (rank[b.code] ?? 9)
        }
        return MetricEval(def: def, status: result(level, conf, reasons, through: latest.day), baseline: baseline, latest: latest,
                          absLevel: absLevel, baseLevel: baseLevel, dz: dzLatest, z: zLatest, slopePerDay: slopePerDay,
                          slopeNorm: slopeNorm, persistWatch: persistW, persistAct: persistA, recentZ: recentZ)
    }
}
