import XCTest
@testable import CrewHealthHub

let utc = TimeZone(identifier: "UTC")!

func agg(_ metric: String, _ day: String, _ v: Double, sim: Bool = false, source: String = "dev") -> DailyAggregate {
    DailyAggregate(personId: "p", metric: metric, day: day, n: 1, mean: v, median: v, min: v, max: v, last: v, value: v, sources: [source], hasSimulated: sim)
}

func series(_ metric: String, start: String = "2026-01-01", _ values: [Double], sim: Bool = false) -> [DailyAggregate] {
    values.enumerated().map { agg(metric, DayKey.add(start, $0.offset, utc), $0.element, sim: sim) }
}

final class UnitTests: XCTestCase {
    func testConversions() throws {
        XCTAssertEqual(try UnitConversion.toCanonical(5.5, unit: "mmol/L", metric: "glucose", canonical: "mg/dL"), 99.088, accuracy: 0.001)
        XCTAssertEqual(try UnitConversion.toCanonical(98.6, unit: "°F", metric: "body_temp", canonical: "°C"), 37.0, accuracy: 0.001)
        XCTAssertEqual(try UnitConversion.toCanonical(16, unit: "kPa", metric: "bp_sys", canonical: "mmHg"), 120.01, accuracy: 0.01)
        XCTAssertEqual(try UnitConversion.toCanonical(0.97, unit: "fraction", metric: "spo2", canonical: "%"), 97, accuracy: 0.001)
        XCTAssertEqual(try UnitConversion.toCanonical(450, unit: "min", metric: "sleep_hours", canonical: "h"), 7.5)
        XCTAssertEqual(try UnitConversion.toCanonical(165, unit: "lb", metric: "weight", canonical: "kg"), 74.84, accuracy: 0.01)
        XCTAssertEqual(try UnitConversion.toCanonical(120, unit: "nSv/h", metric: "rad_dose_rate", canonical: "µSv/h"), 0.12, accuracy: 1e-9)
        XCTAssertEqual(try UnitConversion.toCanonical(2, unit: "mSv", metric: "rad_dose_cum", canonical: "µSv"), 2000)
        XCTAssertEqual(try UnitConversion.toCanonical(4, unit: "CPS", metric: "rad_cpm", canonical: "CPM"), 240)
        XCTAssertEqual(UnitConversion.spo2Percent(0.95), 95)
        XCTAssertEqual(UnitConversion.spo2Percent(96), 96)
        XCTAssertThrowsError(try UnitConversion.toCanonical(1, unit: "furlong", metric: "weight", canonical: "kg"))
    }
}

final class QCTests: XCTestCase {
    let cfg = AppConfig.shared
    func raw(_ m: String, _ v: Double, _ u: String, ts: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> RawObservation {
        RawObservation(personId: "p", missionId: "m", ts: ts, metric: m, value: v, unit: u, source: SourceInfo(adapter: "test", kind: .manual))
    }
    let now = Date(timeIntervalSince1970: 1_800_000_100)

    func testSanityRejection() {
        if case .reject = Ingest.qc(raw("heart_rate", 300, "bpm"), def: cfg.metric("heart_rate"), now: now, missionStart: nil, allowHistory: true) {} else { XCTFail() }
        if case .accept(let v, _, let q, _) = Ingest.qc(raw("heart_rate", 60, "bpm"), def: cfg.metric("heart_rate"), now: now, missionStart: nil, allowHistory: true) {
            XCTAssertEqual(v, 60); XCTAssertEqual(q, .ok)
        } else { XCTFail() }
    }
    func testFutureRejected() {
        let r = raw("heart_rate", 60, "bpm", ts: now.addingTimeInterval(600))
        if case .reject(let why) = Ingest.qc(r, def: cfg.metric("heart_rate"), now: now, missionStart: nil, allowHistory: true) { XCTAssertTrue(why.contains("future")) } else { XCTFail() }
    }
    func testUnknownMetricAndBadUnit() {
        if case .reject = Ingest.qc(raw("nope", 1, ""), def: nil, now: now, missionStart: nil, allowHistory: true) {} else { XCTFail() }
        if case .reject = Ingest.qc(raw("weight", 1, "stone"), def: cfg.metric("weight"), now: now, missionStart: nil, allowHistory: true) {} else { XCTFail() }
    }
    func testSuspectRules() {
        if case .accept(_, _, let q, _) = Ingest.qc(raw("spo2", 78, "%"), def: cfg.metric("spo2"), now: now, missionStart: nil, allowHistory: true) { XCTAssertEqual(q, .suspect) } else { XCTFail() }
        let before = raw("heart_rate", 60, "bpm", ts: Date(timeIntervalSince1970: 1_700_000_000))
        if case .accept(_, _, let q, _) = Ingest.qc(before, def: cfg.metric("heart_rate"), now: now, missionStart: Date(timeIntervalSince1970: 1_750_000_000), allowHistory: false) { XCTAssertEqual(q, .suspect) } else { XCTFail() }
    }
    func testDedupeAndPersistence() throws {
        let repo = try Repository.openDefault(inMemory: true)
        let ing = Ingest(repo: repo, config: cfg)
        let a = [raw("heart_rate", 60, "bpm"), raw("heart_rate", 62, "bpm", ts: Date(timeIntervalSince1970: 1_800_000_050))]
        let r1 = try ing.ingest(a, now: now)
        XCTAssertEqual(r1.inserted, 2)
        let r2 = try ing.ingest(a, now: now)       // re-import: no duplicates
        XCTAssertEqual(r2.inserted, 0); XCTAssertEqual(r2.duplicates, 2)
        XCTAssertEqual(try repo.count(person: "p"), 2)
    }
    func testJumpRuleAndBPPair() throws {
        let repo = try Repository.openDefault(inMemory: true)
        let ing = Ingest(repo: repo, config: cfg)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let r = try ing.ingest([raw("heart_rate", 60, "bpm", ts: t), raw("heart_rate", 160, "bpm", ts: t.addingTimeInterval(20))], now: now)
        XCTAssertEqual(r.suspect, 1)
        var s = raw("bp_sys", 70, "mmHg", ts: t); s.context = ObsContext(pairId: "x")
        var d = raw("bp_dia", 80, "mmHg", ts: t); d.context = ObsContext(pairId: "x")
        try ing.ingest([s, d], now: now)
        let rows = try repo.observations(person: "p", metrics: ["bp_sys", "bp_dia"], from: t.addingTimeInterval(-1), to: t.addingTimeInterval(1))
        XCTAssertTrue(rows.allSatisfy { $0.quality == .suspect })
    }
}

final class AggregationTests: XCTestCase {
    func obs(_ m: String, _ v: Double, _ ts: Date, start: Date? = nil, activity: String? = nil) -> Observation {
        Observation(id: newId(), personId: "p", missionId: "m", ts: ts, metric: m, value: v, unit: "", source: SourceInfo(adapter: "a", kind: .device),
                    quality: .ok, context: ObsContext(activity: activity, start: start), dedupeKey: newId())
    }
    func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testSleepNightAttributionAndOverlap() {
        // Night of 1 → 2 Jan: 23:00 – 07:00, with an overlapping second source 01:00 – 03:00 and a gap 03:00 – 03:30.
        XCTAssertEqual(Aggregator.dayOf(metric: "sleep_hours", ts: d("2026-01-01T23:30:00Z"), tz: utc), "2026-01-02")
        XCTAssertEqual(Aggregator.dayOf(metric: "sleep_hours", ts: d("2026-01-02T07:00:00Z"), tz: utc), "2026-01-02")
        let segs = [obs("sleep_hours", 4, d("2026-01-02T03:00:00Z"), start: d("2026-01-01T23:00:00Z")),
                    obs("sleep_hours", 2, d("2026-01-02T03:00:00Z"), start: d("2026-01-02T01:00:00Z")),
                    obs("sleep_hours", 3.5, d("2026-01-02T07:00:00Z"), start: d("2026-01-02T03:30:00Z"))]
        let a = Aggregator.aggregate(def: AppConfig.shared.metric("sleep_hours")!, personId: "p", day: "2026-01-02", obs: segs, tz: utc)!
        XCTAssertEqual(a.value, 7.5, accuracy: 0.001)
    }
    func testRestingHRDerivation() {
        let hr = (0..<12).map { obs("heart_rate", 50 + Double($0), d("2026-01-02T02:00:00Z").addingTimeInterval(Double($0) * 60), activity: "rest") }
        let a = Aggregator.aggregate(def: AppConfig.shared.metric("heart_rate_resting")!, personId: "p", day: "2026-01-02", obs: [], heartRateForDerivation: hr, tz: utc)!
        XCTAssertEqual(a.value, Stats.percentile(hr.map(\.value), 10), accuracy: 0.001)
        XCTAssertEqual(a.sources, ["derived:heart_rate"])
    }
    func testSumAndMean() {
        let ex = [obs("exercise_min", 30, d("2026-01-02T08:00:00Z")), obs("exercise_min", 45, d("2026-01-02T18:00:00Z"))]
        XCTAssertEqual(Aggregator.aggregate(def: AppConfig.shared.metric("exercise_min")!, personId: "p", day: "2026-01-02", obs: ex, tz: utc)!.value, 75)
        let bp = [obs("bp_sys", 120, d("2026-01-02T08:00:00Z")), obs("bp_sys", 130, d("2026-01-02T08:01:00Z"))]
        XCTAssertEqual(Aggregator.aggregate(def: AppConfig.shared.metric("bp_sys")!, personId: "p", day: "2026-01-02", obs: bp, tz: utc)!.value, 125)
    }
}

final class BaselineStatusTests: XCTestCase {
    let cfg = AppConfig.shared
    var params: EngineParams { cfg.ranges.engine }
    var rhr: MetricDef { cfg.metric("heart_rate_resting")! }

    func eval(_ s: [DailyAggregate], def: MetricDef? = nil, day: String? = nil) -> MetricEval {
        let d = def ?? rhr
        return StatusEngine.evaluate(def: d, personId: "p", series: s, evalDay: day ?? s.last!.day, params: params,
                                     range: cfg.ranges.ranges[d.id], rules: cfg.ranges.alwaysEscalate, now: Date(), tz: utc)
    }

    func testLearningThenActive() {
        let s = series("heart_rate_resting", [60, 61, 59, 60, 62])
        let e = eval(s)
        XCTAssertEqual(e.baseline.state, .learning)
        XCTAssertEqual(e.status.level, .ok)
        XCTAssertTrue(e.status.reasons.contains { $0.code == "learning" })
        let e2 = eval(series("heart_rate_resting", [60, 61, 59, 60, 62, 61, 60, 59]))
        XCTAssertEqual(e2.baseline.state, .active)
    }
    func testMADFloor() {
        let e = eval(series("heart_rate_resting", Array(repeating: 60, count: 20)))
        XCTAssertEqual(e.baseline.spread, rhr.minSpread)    // MAD 0 → floor
    }
    func testStale() {
        let s = series("heart_rate_resting", Array(repeating: 60, count: 10))
        let e = eval(s, day: DayKey.add(s.last!.day, 15, utc))
        XCTAssertEqual(e.status.level, .unknown)
    }
    func testPersistentRiseWatchThenAct() {
        var v: [Double] = (0..<20).map { 60 + ($0 % 3 == 0 ? 1 : ($0 % 3 == 1 ? -1 : 0)) }
        v += [66, 66.5]                     // z ≈ 2+ for 2 days → watch
        let w = eval(series("heart_rate_resting", v))
        XCTAssertEqual(w.status.level, .watch, "\(w.status.reasons)")
        XCTAssertTrue(w.status.reasons.contains { $0.code == "deviation" && $0.text.contains("above your usual") })
        v += [69, 70, 71]                   // 3-day median z ≥ 3 for 3 days → act
        let a = eval(series("heart_rate_resting", v))
        XCTAssertEqual(a.status.level, .act)
    }
    func testSingleDayIsNotPersistent() {
        let v: [Double] = (0..<20).map { 60 + ($0 % 2 == 0 ? 1 : -1) } + [66]
        XCTAssertEqual(eval(series("heart_rate_resting", v)).baseLevel, .ok)
    }
    func testAbsoluteOnlyRaises() {
        // Personal normal is high (95), so z is ~0, but absolute band still flags watch.
        let e = eval(series("heart_rate_resting", Array(repeating: 95, count: 20)))
        XCTAssertEqual(e.baseLevel, .ok)
        XCTAssertEqual(e.status.level, .watch)
    }
    func testEscalateNeedsAbsolute() {
        let v: [Double] = Array(repeating: 60, count: 20) + [125]
        XCTAssertEqual(eval(series("heart_rate_resting", v)).status.level, .escalate)
    }
    func testAlwaysEscalateSpO2() {
        let spo2 = cfg.metric("spo2")!
        let e = eval(series("spo2", Array(repeating: 97, count: 10) + [87]), def: spo2)
        XCTAssertEqual(e.status.level, .escalate)
        XCTAssertEqual(e.status.reasons.first?.code, "always_escalate")
    }
    func testDirectionalLowOnly() {
        // HRV is direction "low": a big rise is not a concern.
        let hrv = cfg.metric("hrv")!
        let up = eval(series("hrv", Array(repeating: 50, count: 20) + [90, 92, 95]), def: hrv)
        XCTAssertEqual(up.status.level, .ok)
        let down = eval(series("hrv", Array(repeating: 50, count: 20) + [30, 28, 27]), def: hrv)
        XCTAssertGreaterThanOrEqual(down.status.level, .watch)
    }
    func testTrendWatch() {
        let v: [Double] = Array(repeating: 60, count: 14) + (1...8).map { 60 + Double($0) * 0.9 }
        let e = eval(series("heart_rate_resting", v))
        XCTAssertGreaterThanOrEqual(e.status.level, .watch)
        XCTAssertNotNil(e.slopeNorm)
    }
    func testSimulatedIsLowConfidence() {
        let e = eval(series("heart_rate_resting", Array(repeating: 60, count: 20), sim: true))
        XCTAssertEqual(e.status.confidence, .low)
    }
    func testDeviceChangeNote() {
        var s = series("heart_rate_resting", Array(repeating: 60, count: 12))
        let s2 = (0..<9).map { agg("heart_rate_resting", DayKey.add("2026-01-13", $0, utc), 75, source: "newwatch") }
        s += s2
        let b = BaselineEngine.compute(def: rhr, personId: "p", series: s, evalDay: s.last!.day, params: params, tz: utc)
        XCTAssertNotNil(b.note)
    }
}

final class RollupPatternTests: XCTestCase {
    let cfg = AppConfig.shared
    func st(_ id: String, _ l: Level, _ c: Confidence) -> StatusResult {
        StatusResult(personId: "p", scope: .metric, id: id, level: l, confidence: c, reasons: [Reason(code: "x", text: id)], computedAt: Date(), dataThrough: nil)
    }
    func testWorstOfWithConfidenceDowngrade() {
        let r = RollupEngine.rollup(personId: "p", config: cfg, metricStatuses: ["heart_rate_resting": st("heart_rate_resting", .act, .low), "mood": st("mood", .watch, .high)],
                                    symptoms: [], patterns: [], now: Date())
        XCTAssertEqual(r.regions["heart"]?.level, .watch)       // low-confidence act shown as watch
        XCTAssertEqual(r.regions["brain"]?.level, .watch)
        XCTAssertEqual(r.overall.level, .watch)
        let r2 = RollupEngine.rollup(personId: "p", config: cfg, metricStatuses: ["heart_rate_resting": st("heart_rate_resting", .act, .high)], symptoms: [], patterns: [], now: Date())
        XCTAssertEqual(r2.regions["heart"]?.level, .act)
        XCTAssertEqual(r2.hazards["gravity"]?.level, .act)
        XCTAssertEqual(r2.regions["lungs"]?.level, .unknown)
    }
    func testRedFlagSymptomEscalates() {
        let o = Observation(id: "1", personId: "p", missionId: "m", ts: Date(), metric: "symptom", value: 1, unit: "severity", source: SourceInfo(adapter: "manual", kind: .manual),
                            quality: .ok, context: ObsContext(symptom: "chest_pain"), dedupeKey: "k")
        let s = SymptomEngine.evaluate([o], config: cfg, asOf: Date(), lookbackDays: 3)
        XCTAssertEqual(s.first?.level, .escalate)
        let r = RollupEngine.rollup(personId: "p", config: cfg, metricStatuses: [:], symptoms: s, patterns: [], now: Date())
        XCTAssertEqual(r.overall.level, .escalate)
    }
    func testSleepDebtPattern() {
        let p = cfg.ranges.engine
        let sleep = StatusEngine.evaluate(def: cfg.metric("sleep_hours")!, personId: "p", series: series("sleep_hours", Array(repeating: 7.5, count: 20) + [5, 5.1, 4.9]),
                                          evalDay: DayKey.add("2026-01-01", 22, utc), params: p, range: nil, rules: [], tz: utc)
        let hrv = StatusEngine.evaluate(def: cfg.metric("hrv")!, personId: "p", series: series("hrv", Array(repeating: 55, count: 20) + [54, 40, 38]),
                                        evalDay: DayKey.add("2026-01-01", 22, utc), params: p, range: nil, rules: [], tz: utc)
        let fired = PatternEngine.evaluate(config: cfg, evals: ["sleep_hours": sleep, "hrv": hrv], adherence: [:], params: p)
        XCTAssertTrue(fired.contains { $0.id == "sleep_debt" })
        XCTAssertFalse(fired.contains { $0.id == "cardio_strain" })
    }
}

final class RadiationTests: XCTestCase {
    let cfg = AppConfig.shared.radiation
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func samples(minutes: Int, rate: (Int) -> Double, step: Int = 1) -> [RadSample] {
        stride(from: 0, to: minutes, by: step).map { RadSample(ts: t0.addingTimeInterval(Double($0) * 60), rate: rate($0)) }
    }
    func testBackgroundAndSpikeEnterExit() {
        let s = samples(minutes: 240) { m in (m >= 120 && m < 150) ? 3.0 : 0.10 + Double(m % 5) * 0.002 }
        let r = RadiationEngine.analyze(samples: s, config: cfg, budget: nil, missionStart: t0, plannedDays: 10, asOf: s.last!.ts)
        XCTAssertEqual(r.background ?? 0, 0.104, accuracy: 0.01)
        XCTAssertEqual(r.events.count, 1)
        XCTAssertNotNil(r.events.first?.end)
        XCTAssertGreaterThanOrEqual(r.events.first!.peak, 3.0)
        XCTAssertEqual(r.level, .watch)                     // event ended recently
    }
    func testActiveSpikeIsAct() {
        let s = samples(minutes: 200) { m in m >= 190 ? 2.0 : 0.1 }
        let r = RadiationEngine.analyze(samples: s, config: cfg, budget: nil, missionStart: t0, plannedDays: 10, asOf: s.last!.ts)
        XCTAssertNotNil(r.activeEvent)
        XCTAssertEqual(r.level, .act)
    }
    func testShortBlipIsNotASpike() {
        let s = samples(minutes: 200) { m in m == 100 ? 5.0 : 0.1 }
        let r = RadiationEngine.analyze(samples: s, config: cfg, budget: nil, missionStart: t0, plannedDays: 10, asOf: s.last!.ts)
        XCTAssertEqual(r.events.count, 0)
    }
    func testTrapezoidWithGap() {
        // 1 µSv/h constant for 60 min, then a 30-min gap, then 60 more minutes → 2 µSv, 30 min unmonitored.
        var s = samples(minutes: 61) { _ in 1.0 }
        s += (0...60).map { RadSample(ts: t0.addingTimeInterval(Double(90 + $0) * 60), rate: 1.0) }
        let r = RadiationEngine.analyze(samples: s, config: cfg, budget: 100, missionStart: t0, plannedDays: 10, asOf: s.last!.ts)
        XCTAssertEqual(r.cumulative_uSv, 2.0, accuracy: 1e-6)
        XCTAssertEqual(r.unmonitoredMinutes, 30, accuracy: 0.01)
        XCTAssertEqual(r.percentUsed ?? 0, 2.0, accuracy: 1e-6)
    }
    func testCounterResetAndBudgetTier() {
        let s = samples(minutes: 120) { _ in 30.0 }
        let dev = [RadSample(ts: t0, rate: 10), RadSample(ts: t0.addingTimeInterval(60), rate: 12), RadSample(ts: t0.addingTimeInterval(120), rate: 1)]
        let r = RadiationEngine.analyze(samples: s, deviceCumulative: dev, config: cfg, budget: 70, missionStart: t0, plannedDays: 10, asOf: s.last!.ts)
        XCTAssertEqual(r.deviceResets, 1)
        XCTAssertGreaterThan(r.percentUsed ?? 0, 75)
        XCTAssertGreaterThanOrEqual(r.level, .act)
    }
}

final class GuidanceSchedulerTests: XCTestCase {
    let cfg = AppConfig.shared
    func testLookupOrderAndEscalationText() {
        XCTAssertNotNil(GuidanceEngine.block(cfg, metric: "heart_rate_resting", level: .escalate))
        // hrv has no escalate block → falls back to act
        XCTAssertEqual(GuidanceEngine.block(cfg, metric: "hrv", level: .escalate), cfg.guidance.metrics["hrv"]?["act"])
        let e = StatusEngine.evaluate(def: cfg.metric("heart_rate_resting")!, personId: "p", series: series("heart_rate_resting", Array(repeating: 60, count: 20) + [72, 73, 74, 75]),
                                      evalDay: DayKey.add("2026-01-01", 23, utc), params: cfg.ranges.engine, range: nil, rules: [], tz: utc)
        let items = GuidanceEngine.build(config: cfg, evals: ["heart_rate_resting": e], symptoms: [], patterns: [], radiation: nil, escalationContact: "Call CAPCOM")
        let it = items.first!
        XCTAssertTrue(it.tags.contains("draft"))           // unverified guidance is always tagged
        if it.level >= .act { XCTAssertTrue(it.whenToEscalate.contains("Call CAPCOM")) }
        XCTAssertFalse(GuidanceEngine.topActions(items).isEmpty)
        XCTAssertLessThanOrEqual(GuidanceEngine.topActions(items).count, 3)
    }
    func testSchedulerAdherence() {
        let r = cfg.routines.first { $0.id == "daily_checkin" }!
        let start = DayKey.start("2026-01-01", utc)
        let now = DayKey.start("2026-01-05", utc).addingTimeInterval(20 * 3600)   // before the 22:00 grace deadline
        // Check-ins done on days 1, 2, 4; missed day 3; day 5 pending (within grace).
        let times = ["2026-01-01", "2026-01-02", "2026-01-04"].map { DayKey.start($0, utc).addingTimeInterval(9 * 3600) }
        let ps = Scheduler.prompts(personId: "p", routines: [r], fromDay: "2026-01-01", toDay: "2026-01-05", obsTimes: ["mood": times],
                                   explicit: [:], now: now, missionStart: start, tz: utc)
        XCTAssertEqual(ps.filter { $0.state == .done }.count, 3)
        XCTAssertEqual(ps.filter { $0.state == .missed }.count, 1)
        XCTAssertEqual(ps.filter { $0.state == .pending }.count, 1)
        XCTAssertEqual(Scheduler.adherence(ps, now: now)["daily_checkin"] ?? 0, 0.75, accuracy: 1e-9)
        // Snooze overrides derived state.
        var sn = ps.last!; sn.state = .snoozed; sn.snoozedUntil = now.addingTimeInterval(3600)
        let ps2 = Scheduler.prompts(personId: "p", routines: [r], fromDay: "2026-01-05", toDay: "2026-01-05", obsTimes: [:], explicit: [sn.id: sn], now: now, missionStart: start, tz: utc)
        XCTAssertEqual(ps2.first?.state, .snoozed)
    }
    func testQuestCapsAndNoSleepRestrictionReward() {
        let ex = series("exercise_min", start: "2026-01-05", [200, 200, 200])     // Monday start; cap 90/day
        let snap = QuestEngine.evaluate(config: cfg, daily: ["exercise_min": ex], prompts: [], asOfDay: "2026-01-07", missionStartDay: "2026-01-05",
                                        drillDone: false, anyBaselineActive: false, escalationUnacked: false, tz: utc)
        XCTAssertEqual(snap.quests.first { $0.def.kind == "exercise" }?.progress, 270)
        let sleepShort = series("sleep_hours", start: "2026-01-05", [4, 4, 4])
        let s2 = QuestEngine.evaluate(config: cfg, daily: ["sleep_hours": sleepShort], prompts: [], asOfDay: "2026-01-07", missionStartDay: "2026-01-05",
                                      drillDone: false, anyBaselineActive: false, escalationUnacked: false, tz: utc)
        XCTAssertEqual(s2.quests.first { $0.def.kind == "sleep_window" }?.progress, 0)
    }
}
