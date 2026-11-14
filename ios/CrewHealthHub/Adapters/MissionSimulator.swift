import Foundation

/// Simulator adapter (PART 6.2). Seedable, deterministic generator that feeds the *same* ingest pipeline
/// as every real adapter (never bypasses the engines). All observations carry `source.kind = simulated`.
/// The generative model is illustrative only — not clinical.
final class MissionSimulator: ObservableObject {
    static let shared = MissionSimulator()

    struct SimConfig: Codable, Hashable {
        var missionId: String
        var seed: UInt32
        var days: Int
        var scenario: String
        var personIds: [String]
        var events: [SimEvent] = []
    }
    struct SimEvent: Codable, Hashable {
        var kind: String           // spike | short_sleep | mood_dip
        var day: Int
        var hour: Double
        var length: Int            // days for sleep / mood
    }

    enum Speed: Double, CaseIterable, Identifiable {
        case x1 = 1, x60 = 60, x600 = 600, x3600 = 3600, dayPerSec = 86400, fiveDaysPerSec = 432000
        var id: Double { rawValue }
        var label: String {
            switch self { case .x1: return "1×"; case .x60: return "60×"; case .x600: return "600×"; case .x3600: return "3600×"; case .dayPerSec: return "1 day/s"; case .fiveDaysPerSec: return "5 days/s" }
        }
    }

    static let scenarios: [(id: String, label: String)] = [("full_mission", "Full mission storyline"), ("baseline_only", "Baseline only"),
                                                           ("radiation_event", "Radiation event"), ("strain_pattern", "Strain pattern")]

    @Published private(set) var config: SimConfig?
    @Published private(set) var running = false
    @Published var speed: Speed = .dayPerSec
    @Published private(set) var simNow: Date?
    @Published private(set) var autoPausedReason: String?
    @Published private(set) var busy = false

    private let hub = Hub.shared
    private let work = DispatchQueue(label: "simulator", qos: .userInitiated)
    private var timer: Timer?
    private var inFlight = false
    private var plan: [[[String: Double]]] = []   // [person][day][metric]
    private let tickInterval = 0.25
    private var tz: TimeZone { hub.tz }

    init() {
        if let c = try? hub.repo.get("simconfig", id: "current", as: SimConfig.self), let m = hub.mission(c.missionId) {
            config = c
            simNow = m.simNow
            buildPlan()
        }
    }

    var mission: Mission? { config.flatMap { hub.mission($0.missionId) } }
    var simDay: Int {
        guard let m = mission, let now = simNow else { return 0 }
        return max(0, DayKey.diff(DayKey.of(now, tz), DayKey.of(m.startDate, tz), tz))
    }

    // MARK: Setup

    /// Creates a simulated mission whose last day is today, with one crew member, David.
    @discardableResult
    func setup(scenario: String = "full_mission", seed: UInt32 = 42, days: Int = 180, crewCount: Int = 1, environment: String = "station") -> Mission {
        pause()
        if let old = config { for pid in old.personIds { try? hub.repo.deleteObservations(person: pid); try? hub.repo.delete("person", id: pid) }; try? hub.repo.delete("mission", id: old.missionId) }
        let cal = DayKey.calendar(tz)
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -(days - 1), to: Date())!)
        let mid = "sim-\(newId().prefix(8))"
        var m = Mission(id: mid, name: "Artemis Habitat", environment: environment, startDate: start, plannedDays: days, isSimulated: true)
        m.simNow = start
        hub.save(m)
        let names = [("David", "commander")]
        var ids: [String] = []
        for i in 0..<max(1, min(crewCount, names.count)) {
            let p = Person(id: "\(mid)-p\(i)", displayName: names[i].0, avatar: nil, role: names[i].1, missionId: mid,
                           consent: Consent(shareStatus: true, shareMetrics: i != 2, shareRadiation: true))
            hub.save(p); ids.append(p.id)
        }
        let c = SimConfig(missionId: mid, seed: seed, days: days, scenario: scenario, personIds: ids)
        try? hub.repo.put("simconfig", id: "current", c)
        config = c
        simNow = start
        autoPausedReason = nil
        buildPlan()
        hub.updateSettings { $0.currentPersonId = ids.first }
        hub.refresh(ids)
        return m
    }

    func remove() {
        pause()
        guard let c = config else { return }
        for pid in c.personIds { try? hub.repo.deleteObservations(person: pid); try? hub.repo.delete("person", id: pid) }
        try? hub.repo.delete("mission", id: c.missionId)
        try? hub.repo.delete("simconfig", id: "current")
        config = nil; simNow = nil
        hub.updateSettings { s in if let cur = s.currentPersonId, c.personIds.contains(cur) { s.currentPersonId = self.hub.persons().first?.id } }
        NotificationCenter.default.post(name: .hubSnapshotsChanged, object: nil, userInfo: ["persons": []])
    }

    // MARK: Generative model

    private func buildPlan() {
        guard let c = config else { return }
        plan = c.personIds.indices.map { pi in planFor(personIndex: pi, c: c) }
    }

    private func storyline(_ c: SimConfig) -> (sleepCut: ClosedRange<Int>?, hrDrift: (Int, Int, Int)?, spikeDay: Int?, moodDip: ClosedRange<Int>?, exerciseDrop: ClosedRange<Int>?, weightLossFrom: Int?) {
        switch c.scenario {
        case "baseline_only": return (nil, nil, nil, nil, nil, nil)
        case "radiation_event": return (nil, nil, 12, nil, nil, nil)
        case "strain_pattern": return (12...18, (16, 30, 45), nil, nil, nil, nil)
        default: return (22...28, (35, 50, 80), 60, 85...100, 115...125, 110)
        }
    }

    private func planFor(personIndex pi: Int, c: SimConfig) -> [[String: Double]] {
        var rng = SeededRandom(seed: c.seed &+ UInt32(pi * 7919))
        let st = storyline(c)
        let lead = pi == 0                         // the storyline plays out fully for the first crew member
        let base: [String: (Double, Double)] = [
            "heart_rate_resting": (60 + Double(pi) * 3, 1.6), "hrv": (55 - Double(pi) * 4, 4.5), "sleep_hours": (7.2, 0.4),
            "sleep_quality": (4.0, 0.35), "mood": (4.0, 0.3), "stress": (2.0, 0.3), "workload": (2.6, 0.4), "appetite": (4.0, 0.3),
            "bp_sys": (118, 3.5), "bp_dia": (76, 2.5), "body_temp": (36.6, 0.12), "spo2": (97.5, 0.45), "resp_rate": (14, 0.7),
            "exercise_min": (75, 9), "activity_steps": (6500, 900), "weight": (74 - Double(pi) * 6, 0.18), "glucose": (94, 6), "water_l": (2.2, 0.25),
        ]
        var ar: [String: Double] = [:]
        var out: [[String: Double]] = []
        for d in 0..<c.days {
            var day: [String: Double] = [:]
            for (m, (b, sd)) in base {
                let prev = ar[m] ?? 0
                let noise = 0.5 * prev + rng.normal(0, sd * 0.866)
                ar[m] = noise
                var v = b + noise
                let dd = Double(d)
                if let (a, peak, end) = st.hrDrift {
                    let f: Double = dd < Double(a) ? 0 : (dd <= Double(peak) ? (dd - Double(a)) / Double(peak - a) : (dd < Double(peak + 10) ? 1 : max(0, 1 - (dd - Double(peak + 10)) / Double(end - peak - 10))))
                    let k = lead ? 1.0 : 0.25
                    if m == "heart_rate_resting" { v += 11 * f * k }
                    if m == "hrv" { v -= 20 * f * k }
                    if m == "bp_sys" { v += 7 * f * k }
                    if m == "bp_dia" { v += 4 * f * k }
                    if m == "stress" { v += 1.2 * f * k }
                    if m == "workload" { v += 1.0 * f * k }
                }
                if let r = st.sleepCut, r.contains(d), lead || pi == 1 {
                    if m == "sleep_hours" { v = 5.1 + rng.normal(0, 0.25) }
                    if m == "sleep_quality" { v -= 1.2 }
                    if m == "hrv" { v -= 6 }
                }
                if let r = st.moodDip, r.contains(d) {
                    let k = lead ? 1.0 : 0.3
                    if m == "mood" { v -= 1.3 * k }
                    if m == "stress" { v += 1.2 * k }
                    if m == "sleep_quality" { v -= 0.9 * k }
                    if m == "appetite" { v -= 0.8 * k }
                }
                if let r = st.exerciseDrop, r.contains(d), lead {
                    if m == "exercise_min" { v = 25 + rng.normal(0, 6) }
                    if m == "activity_steps" { v -= 2200 }
                }
                if let w = st.weightLossFrom, d >= w, lead, m == "weight" { v -= 0.045 * Double(d - w) }
                for e in c.events where m == "sleep_hours" && e.kind == "short_sleep" && d >= e.day && d < e.day + e.length { v = 4.8 + rng.normal(0, 0.2) }
                for e in c.events where e.kind == "mood_dip" && d >= e.day && d < e.day + e.length {
                    if m == "mood" { v = 2.4 + rng.normal(0, 0.2) }
                    if m == "stress" { v = 4.0 + rng.normal(0, 0.2) }
                }
                if ["mood", "stress", "workload", "sleep_quality", "appetite"].contains(m) { v = max(1, min(5, v)).rounded() }
                if ["exercise_min", "activity_steps"].contains(m) { v = max(0, v).rounded() }
                if m == "sleep_hours" { v = max(2, min(11, v)) }
                day[m] = v
            }
            // Check-ins are skipped on some days during the mood dip (isolation strain + adherence drop).
            if let r = st.moodDip, r.contains(d), lead, rng.next() < 0.45 { day["_skip_checkin"] = 1 }
            out.append(day)
        }
        return out
    }

    /// Radiation dose rate (µSv/h) at time t for a crew member. Background is a PLACEHOLDER 0.10 µSv/h.
    private func radiation(at t: Date, start: Date, pi: Int, c: SimConfig, noise: inout SeededRandom) -> Double {
        let bg = 0.10 * (1 + Double(pi) * 0.03)
        var v = bg + noise.normal(0, 0.008)
        var spikes: [Date] = []
        if let d = storyline(c).spikeDay { spikes.append(start.addingTimeInterval(Double(d) * 86400 + 10 * 3600)) }
        for e in c.events where e.kind == "spike" { spikes.append(start.addingTimeInterval(Double(e.day) * 86400 + e.hour * 3600)) }
        for s in spikes {
            let dt = t.timeIntervalSince(s) / 60   // minutes
            guard dt >= 0 else { continue }
            let peak = bg * 80                      // illustrative shape: ramp over 20 min, e-fold decay ~2 h
            v += dt < 20 ? peak * dt / 20 : peak * exp(-(dt - 20) / 120)
        }
        return max(0.001, v)
    }

    private func eventWindows(_ c: SimConfig, start: Date) -> [ClosedRange<Date>] {
        var spikes: [Date] = []
        if let d = storyline(c).spikeDay { spikes.append(start.addingTimeInterval(Double(d) * 86400 + 10 * 3600)) }
        for e in c.events where e.kind == "spike" { spikes.append(start.addingTimeInterval(Double(e.day) * 86400 + e.hour * 3600)) }
        return spikes.map { $0.addingTimeInterval(-15 * 60)...$0.addingTimeInterval(8 * 3600) }
    }

    /// All observations with timestamps in (from, to].
    private func generate(from: Date, to: Date) -> [RawObservation] {
        guard let c = config, let m = mission, to > from else { return [] }
        let start = m.startDate
        var out: [RawObservation] = []
        let src = SourceInfo(adapter: "simulator", device: "Simulator", kind: .simulated)
        let firstDay = max(0, DayKey.diff(DayKey.of(from, tz), DayKey.of(start, tz), tz))
        let lastDay = min(c.days - 1, DayKey.diff(DayKey.of(to, tz), DayKey.of(start, tz), tz))
        let schedule: [(String, Double)] = [("sleep_hours", 7.0), ("heart_rate_resting", 7.08), ("hrv", 7.08), ("resp_rate", 7.08), ("spo2", 7.15),
                                            ("mood", 8.15), ("stress", 8.15), ("workload", 8.15), ("sleep_quality", 8.15), ("appetite", 8.16),
                                            ("exercise_min", 18.0), ("water_l", 20.0), ("activity_steps", 21.0)]
        let env = m.environment
        for (pi, pid) in c.personIds.enumerated() where pi < plan.count {
            if lastDay >= firstDay {
                for d in firstDay...lastDay {
                    let dayStart = DayKey.calendar(tz).date(byAdding: .day, value: d, to: start)!
                    let p = plan[pi][d]
                    var items = schedule
                    if d % 3 == 0 { items += [("bp_sys", 8.5), ("bp_dia", 8.5), ("body_temp", 8.55), ("glucose", 7.8)] }
                    if d % 7 == 0 { items.append(("weight", 7.3)) }
                    for (metric, hour) in items {
                        if metric == "appetite" && env != "mars_base" && d % 2 == 1 { continue }
                        if ["mood", "stress", "workload", "sleep_quality"].contains(metric) && p["_skip_checkin"] != nil { continue }
                        let ts = dayStart.addingTimeInterval(hour * 3600 + Double(pi) * 60)
                        guard ts > from && ts <= to, let v = p[metric], let def = hub.config.metric(metric) else { continue }
                        var ctx: ObsContext? = nil
                        if metric == "sleep_hours" { ctx = ObsContext(start: ts.addingTimeInterval(-v * 3600)) }
                        if metric == "bp_sys" || metric == "bp_dia" { ctx = ObsContext(pairId: "\(pid)-\(d)") }
                        out.append(RawObservation(personId: pid, missionId: c.missionId, ts: ts, metric: metric, value: v.rounded(to: def.decimals + 1),
                                                  unit: def.unit, source: src, context: ctx))
                    }
                }
            }
            // Radiation: every 10 min (= maxGapMin, so no false 'unmonitored' gaps), every minute inside event windows.
            var noise = SeededRandom(seed: c.seed &+ UInt32(pi) &+ UInt32(Int(from.timeIntervalSince1970 / 60) & 0xFFFF))
            let windows = eventWindows(c, start: start)
            var t = Date(timeIntervalSince1970: (from.timeIntervalSince1970 / 60).rounded(.down) * 60 + 60)
            while t <= to {
                let inEvent = windows.contains { $0.contains(t) }
                let minuteOfDay = Int(t.timeIntervalSince(DayKey.calendar(tz).startOfDay(for: t)) / 60)
                if inEvent || minuteOfDay % 10 == 0 {
                    out.append(RawObservation(personId: pid, missionId: c.missionId, ts: t, metric: "rad_dose_rate",
                                              value: radiation(at: t, start: start, pi: pi, c: c, noise: &noise).rounded(to: 4), unit: "µSv/h", source: src))
                }
                // Skip ahead quickly outside event windows.
                if inEvent { t.addTimeInterval(60) }
                else {
                    let next = t.addingTimeInterval(Double(10 - minuteOfDay % 10) * 60)
                    let nextWindow = windows.map(\.lowerBound).filter { $0 > t }.min() ?? .distantFuture
                    t = min(next, max(t.addingTimeInterval(60), nextWindow))
                }
            }
        }
        return out
    }

    // MARK: Playback

    func play() {
        guard config != nil, timer == nil else { return }
        autoPausedReason = nil
        running = true
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
    }

    func pause() { timer?.invalidate(); timer = nil; running = false }

    private func tick() {
        guard !inFlight, let c = config, let m = mission, let now = simNow else { return }
        let end = min(m.startDate.addingTimeInterval(Double(c.days) * 86400 - 60), Date())
        if now >= end { pause(); return }
        var step = speed.rawValue * tickInterval
        // Slow down inside radiation event windows so the event is visible as it happens.
        if eventWindows(c, start: m.startDate).contains(where: { $0.contains(now) || ($0.lowerBound > now && $0.lowerBound < now.addingTimeInterval(step)) }) {
            step = min(step, 10 * 60)
        }
        advance(to: min(now.addingTimeInterval(step), end))
    }

    /// Emits everything between the current sim time and `target`, then recomputes (used by tick and jump).
    func advance(to target: Date, completion: (() -> Void)? = nil) {
        guard let c = config, let from = simNow, target > from else { completion?(); return }
        inFlight = true
        busy = true
        work.async {
            let raws = self.generate(from: from, to: target)
            if var m = self.hub.mission(c.missionId) { m.simNow = target; self.hub.save(m) }
            for chunk in stride(from: 0, to: raws.count, by: 5000) {
                _ = try? self.hub.submit(Array(raws[chunk..<min(chunk + 5000, raws.count)]), allowHistory: false, wait: false)
            }
            self.hub.refresh(c.personIds, wait: true)
            let escalation = c.personIds.compactMap { self.hub.snapshot($0) }.first { !$0.unacked.isEmpty }
            DispatchQueue.main.async {
                self.simNow = target
                self.inFlight = false
                self.busy = false
                if let e = escalation, self.running, self.hub.settings().autoPauseOnEscalate {
                    self.pause()
                    self.autoPausedReason = "Paused: \(e.person.displayName) — \(e.unacked.first?.text ?? "escalation")"
                }
                completion?()
            }
        }
    }

    func jump(toDay day: Int) {
        guard let m = mission else { return }
        let target = min(m.startDate.addingTimeInterval(Double(day) * 86400 + 12 * 3600), Date())
        if let now = simNow, target > now { advance(to: target) }
    }

    /// Restart playback from day 0 (keeps the same mission and seed).
    func restart() {
        pause()
        guard let c = config, var m = mission else { return }
        for pid in c.personIds { try? hub.repo.deleteObservations(person: pid) }
        m.simNow = m.startDate
        hub.save(m)
        simNow = m.startDate
        autoPausedReason = nil
        for pid in c.personIds { hub.invalidateSimCache(pid) }
        hub.refresh(c.personIds)
    }

    func inject(_ kind: String) {
        guard var c = config, let m = mission, let now = simNow else { return }
        let day = DayKey.diff(DayKey.of(now, tz), DayKey.of(m.startDate, tz), tz)
        let hour = now.timeIntervalSince(DayKey.calendar(tz).startOfDay(for: now)) / 3600 + 0.05
        switch kind {
        case "spike": c.events.append(SimEvent(kind: "spike", day: day, hour: hour, length: 0))
        case "short_sleep": c.events.append(SimEvent(kind: "short_sleep", day: day + 1, hour: 0, length: 3))
        case "mood_dip": c.events.append(SimEvent(kind: "mood_dip", day: day + 1, hour: 0, length: 5))
        default: return
        }
        config = c
        try? hub.repo.put("simconfig", id: "current", c)
        buildPlan()
    }
}
