import Foundation

struct AppSettings: Codable, Equatable {
    var onboarded = false
    var escalationContact = ""
    var devMode = false
    var hkEnabled = false
    var hkWriteBack = true
    var hkHistoryDays = 365
    var bridgeURL = "ws://127.0.0.1:8765"
    var bridgeToken = ""
    var notificationsEnabled = false
    var engine: EngineParams? = nil
    var currentPersonId: String? = nil
    var drillDone: [String] = []
    var reviewed: [String: String] = [:]   // guidance id → reviewer name (dev mode only)
    var autoPauseOnEscalate = true
    var hubURL = "nasa.softhoarders.me"
    var hubCode = ""
    var hubEnabled = false

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = AppSettings()
        onboarded = try c.v(.onboarded, z.onboarded); escalationContact = try c.v(.escalationContact, z.escalationContact)
        devMode = try c.v(.devMode, z.devMode); hkEnabled = try c.v(.hkEnabled, z.hkEnabled); hkWriteBack = try c.v(.hkWriteBack, z.hkWriteBack)
        hkHistoryDays = try c.v(.hkHistoryDays, z.hkHistoryDays); bridgeURL = try c.v(.bridgeURL, z.bridgeURL); bridgeToken = try c.v(.bridgeToken, z.bridgeToken)
        notificationsEnabled = try c.v(.notificationsEnabled, z.notificationsEnabled); engine = try c.decodeIfPresent(EngineParams.self, forKey: .engine)
        currentPersonId = try c.decodeIfPresent(String.self, forKey: .currentPersonId); drillDone = try c.v(.drillDone, z.drillDone)
        reviewed = try c.v(.reviewed, z.reviewed); autoPauseOnEscalate = try c.v(.autoPauseOnEscalate, z.autoPauseOnEscalate)
        hubURL = try c.v(.hubURL, z.hubURL); hubCode = try c.v(.hubCode, z.hubCode); hubEnabled = try c.v(.hubEnabled, z.hubEnabled)
    }
}

struct ChangeItem: Identifiable, Hashable {
    var id: String
    var regionId: String
    var metric: MetricId?
    var text: String
    var level: Level
    var previous: Level
    var spark: [Double]
}

struct EscalationItem: Identifiable, Hashable {
    var id: String { key }
    var key: String
    var text: String
}

struct PersonSnapshot {
    var person: Person
    var mission: Mission
    var asOf: Date
    var evalDay: String
    var missionDay: Int
    var overall: StatusResult
    var summary: String
    var regions: [String: StatusResult]
    var hazards: [String: StatusResult]
    var evals: [MetricId: MetricEval]
    var metricStatuses: [MetricId: StatusResult]
    var symptoms: [SymptomStatus]
    var patterns: [FiredPattern]
    var radiation: RadiationResult?
    var guidance: [GuidanceItem]
    var actions: [ActionItem]
    var changes: [ChangeItem]
    var prompts: [Prompt]
    var adherence: [String: Double]
    var quests: QuestSnapshot
    var hasSimulated: Bool
    var unacked: [EscalationItem]
    var lastDataAt: Date?
    var computedAt: Date
}

extension Notification.Name {
    static let hubSnapshotsChanged = Notification.Name("hubSnapshotsChanged")
    static let hubDataChanged = Notification.Name("hubDataChanged")
}

/// Recompute orchestration (PART 5.10): ingestion marks dirty keys → debounce 250 ms → aggregates →
/// baselines → statuses → roll-ups → guidance → persisted statuses → `hubSnapshotsChanged`.
final class Hub {
    static let shared: Hub = {
        do { return try Hub(repo: Repository.openDefault(), config: .shared) }
        catch { fatalError("Database failed to open: \(error)") }
    }()

    let config: AppConfig
    let repo: Repository
    let ingest: Ingest
    var tz: TimeZone = .current
    private let queue = DispatchQueue(label: "hub.engine", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingDirty: Set<DirtyKey> = []
    private var pendingPersons: Set<String> = []
    private var scheduled = false
    private var _snapshots: [String: PersonSnapshot] = [:]
    private var simCache: [String: Bool] = [:]

    init(repo: Repository, config: AppConfig) {
        self.repo = repo
        self.config = config
        self.ingest = Ingest(repo: repo, config: config)
    }

    // MARK: Settings, persons, missions

    func settings() -> AppSettings { (try? repo.get("settings", id: "app", as: AppSettings.self)) ?? AppSettings() }
    func saveSettings(_ s: AppSettings) { try? repo.put("settings", id: "app", s) }
    func updateSettings(_ f: (inout AppSettings) -> Void) { var s = settings(); f(&s); saveSettings(s) }
    func engineParams() -> EngineParams { settings().engine ?? config.ranges.engine }

    func persons() -> [Person] { (try? repo.list("person", as: Person.self)) ?? [] }
    func person(_ id: String) -> Person? { try? repo.get("person", id: id, as: Person.self) }
    func save(_ p: Person) { try? repo.put("person", id: p.id, person: nil, ts: p.createdAt, p) }
    func missions() -> [Mission] { (try? repo.list("mission", as: Mission.self)) ?? [] }
    func mission(_ id: String) -> Mission? { try? repo.get("mission", id: id, as: Mission.self) }
    func save(_ m: Mission) { try? repo.put("mission", id: m.id, ts: m.startDate, m) }
    func healthKitOwner() -> Person? { persons().first { $0.isHealthKitOwner } }

    func clock(_ m: Mission) -> Date { m.simNow ?? Date() }

    // MARK: Snapshots

    func snapshot(_ personId: String) -> PersonSnapshot? { lock.lock(); defer { lock.unlock() }; return _snapshots[personId] }
    private func setSnapshot(_ s: PersonSnapshot) { lock.lock(); _snapshots[s.person.id] = s; lock.unlock() }
    func invalidateSimCache(_ personId: String) { lock.lock(); simCache[personId] = nil; lock.unlock() }

    // MARK: Ingestion entry point (used by every adapter)

    @discardableResult
    func submit(_ raws: [RawObservation], allowHistory: Bool = true, wait: Bool = false) throws -> IngestResult {
        guard !raws.isEmpty else { return IngestResult() }
        var missionStart: Date? = nil
        if let mid = raws.first?.missionId { missionStart = mission(mid)?.startDate }
        ingest.tz = tz
        let r = try ingest.ingest(raws, missionStart: missionStart, allowHistory: allowHistory)
        if raws.contains(where: { $0.source.kind == .simulated }) { for p in Set(raws.map(\.personId)) { lock.lock(); simCache[p] = true; lock.unlock() } }
        enqueue(dirty: r.dirty, persons: Set(raws.map(\.personId)), wait: wait)
        return r
    }

    /// Called after deletions (HealthKit deleted objects, undo import).
    func removed(_ obs: [Observation], wait: Bool = false) {
        var keys = Set<DirtyKey>()
        for o in obs { keys.formUnion(Ingest.dirtyKeys(for: o, tz: tz)) }
        for p in Set(obs.map(\.personId)) { invalidateSimCache(p) }
        enqueue(dirty: keys, persons: Set(obs.map(\.personId)), wait: wait)
    }

    func enqueue(dirty: Set<DirtyKey>, persons: Set<String>, wait: Bool = false) {
        lock.lock()
        pendingDirty.formUnion(dirty)
        pendingPersons.formUnion(persons)
        let shouldSchedule = !scheduled
        if !wait { scheduled = true }
        lock.unlock()
        if wait { queue.sync { self.process() }; return }
        if shouldSchedule {
            queue.asyncAfter(deadline: .now() + 0.25) { self.process() }
        }
    }

    /// Requests a recompute of a person without new data (clock changed, settings changed …).
    func refresh(_ personIds: [String], wait: Bool = false) { enqueue(dirty: [], persons: Set(personIds), wait: wait) }
    func refreshAll(wait: Bool = false) { refresh(persons().map(\.id), wait: wait) }

    private func process() {
        lock.lock()
        let dirty = pendingDirty, persons = pendingPersons
        pendingDirty = []; pendingPersons = []; scheduled = false
        lock.unlock()
        guard !dirty.isEmpty || !persons.isEmpty else { return }
        aggregate(dirty)
        var changed: [String] = []
        for pid in persons { if let s = recompute(pid) { setSnapshot(s); changed.append(pid) } }
        NotificationCenter.default.post(name: .hubSnapshotsChanged, object: nil, userInfo: ["persons": changed])
    }

    // MARK: Aggregation of dirty days

    func aggregate(_ dirty: Set<DirtyKey>) {
        let groups = Dictionary(grouping: dirty) { "\($0.personId)|\($0.metric)" }
        for (_, keys) in groups {
            guard let k0 = keys.first, let def = config.metric(k0.metric) else { continue }
            let days = Set(keys.map(\.day))
            let minDay = days.min()!, maxDay = days.max()!
            let from = DayKey.start(minDay, tz).addingTimeInterval(-12 * 3600)
            let to = DayKey.start(maxDay, tz).addingTimeInterval(36 * 3600)
            let obs = ((try? repo.observations(person: k0.personId, metric: def.id, from: from, to: to)) ?? []).filter { $0.quality == .ok }
            let byDay = Dictionary(grouping: obs) { Aggregator.dayOf(metric: def.id, ts: $0.ts, tz: tz) }
            var hrByDay: [String: [Observation]] = [:]
            if def.aggregation == "resting_hr" {
                let hr = ((try? repo.observations(person: k0.personId, metric: "heart_rate", from: from, to: to)) ?? []).filter { $0.quality == .ok }
                hrByDay = Dictionary(grouping: hr) { DayKey.of($0.ts, tz) }
            }
            var put: [DailyAggregate] = []
            for day in days {
                if let a = Aggregator.aggregate(def: def, personId: k0.personId, day: day, obs: byDay[day] ?? [],
                                                heartRateForDerivation: hrByDay[day] ?? [], tz: tz) { put.append(a) }
                else { try? repo.deleteDaily(person: k0.personId, metric: def.id, day: day) }
            }
            try? repo.putDaily(put)
        }
    }

    /// Full rebuild from raw observations (Settings → "Rebuild from raw data").
    func rebuild(person: String, progress: ((Double) -> Void)? = nil) {
        queue.sync {
            try? repo.clearDaily(person: person)
            let metrics = (try? repo.observedMetrics(person: person)) ?? []
            var keys = Set<DirtyKey>()
            for (i, m) in metrics.enumerated() {
                guard let (a, b) = try? repo.range(person: person, metric: m) else { continue }
                let first = Aggregator.dayOf(metric: m, ts: a, tz: tz), last = Aggregator.dayOf(metric: m, ts: b, tz: tz)
                for d in DayKey.range(from: first, to: last, tz) {
                    keys.insert(DirtyKey(personId: person, metric: m, day: d))
                    if m == "heart_rate" { keys.insert(DirtyKey(personId: person, metric: "heart_rate_resting", day: d)) }
                }
                progress?(Double(i) / Double(max(metrics.count, 1)) * 0.5)
            }
            let grouped = Dictionary(grouping: keys) { $0.metric }
            for (i, (_, ks)) in grouped.enumerated() {
                aggregate(Set(ks))
                progress?(0.5 + Double(i + 1) / Double(max(grouped.count, 1)) * 0.5)
            }
            invalidateSimCache(person)
            if let s = recompute(person) { setSnapshot(s) }
        }
        NotificationCenter.default.post(name: .hubSnapshotsChanged, object: nil, userInfo: ["persons": [person]])
    }

    // MARK: Full evaluation of one person

    func recompute(_ personId: String) -> PersonSnapshot? {
        guard let person = person(personId), let mission = mission(person.missionId) else { return nil }
        let settings = settings()
        let params = settings.engine ?? config.ranges.engine
        let asOf = clock(mission)
        let evalDay = DayKey.of(asOf, tz)
        let yesterday = DayKey.add(evalDay, -1, tz)
        let daily = (try? repo.allDaily(person: personId, to: evalDay)) ?? [:]

        // Days with moderate+ symptoms are excluded from vital-sign baselines (illness should not shape "normal").
        let illnessDays = Set((daily["symptom"] ?? []).filter { $0.value >= 2 }.map(\.day))
        let locked = Dictionary(((try? repo.list("lockedBaseline", person: personId, as: Baseline.self)) ?? []).map { ($0.metric, $0) }, uniquingKeysWith: { a, _ in a })

        var evals: [MetricId: MetricEval] = [:]
        var prevEvals: [MetricId: MetricEval] = [:]
        for def in config.metrics where def.engine == "baseline" {
            let series = daily[def.id] ?? []
            let excl = ["heart_rate", "heart_rate_resting", "hrv", "body_temp", "wrist_temp", "spo2", "resp_rate"].contains(def.id) ? illnessDays : []
            evals[def.id] = StatusEngine.evaluate(def: def, personId: personId, series: series, evalDay: evalDay, params: params,
                                                  range: config.ranges.ranges[def.id], rules: config.ranges.alwaysEscalate,
                                                  excludedDays: excl, locked: locked[def.id], now: asOf, tz: tz)
            prevEvals[def.id] = StatusEngine.evaluate(def: def, personId: personId, series: series, evalDay: yesterday, params: params,
                                                      range: config.ranges.ranges[def.id], rules: config.ranges.alwaysEscalate,
                                                      excludedDays: excl, locked: locked[def.id], now: asOf.addingTimeInterval(-86400), tz: tz)
        }

        // Tracked metrics (everything else from Apple Health): compared with your own normal for display,
        // but they never drive regions, "What changed", guidance or alerts.
        var tracked: [MetricId: MetricEval] = [:]
        for def in config.metrics where def.engine == "track" {
            guard let series = daily[def.id], !series.isEmpty else { continue }
            tracked[def.id] = StatusEngine.evaluate(def: def, personId: personId, series: series, evalDay: evalDay, params: params,
                                                    range: nil, rules: [], excludedDays: [], locked: nil, now: asOf, tz: tz)
        }

        // Symptoms.
        let symObs = (try? repo.observations(person: personId, metric: "symptom", from: asOf.addingTimeInterval(-Double(params.symptomLookbackDays + 1) * 86400),
                                             to: asOf.addingTimeInterval(300))) ?? []
        let symptoms = SymptomEngine.evaluate(symObs.filter { $0.quality != .rejected }, config: config, asOf: asOf, lookbackDays: params.symptomLookbackDays)

        // Radiation.
        var radiation: RadiationResult? = nil
        var metricStatuses = evals.mapValues(\.status)
        let radFrom = min(mission.startDate, asOf.addingTimeInterval(-86400 * 30)).addingTimeInterval(-86400 * 2)
        let radSamples = ((try? repo.series(person: personId, metric: "rad_dose_rate", from: radFrom, to: asOf.addingTimeInterval(60))) ?? [])
            .map { RadSample(ts: $0.0, rate: $0.1) }
        if !radSamples.isEmpty {
            let devCum = ((try? repo.series(person: personId, metric: "rad_dose_cum", from: radFrom, to: asOf.addingTimeInterval(60))) ?? [])
                .map { RadSample(ts: $0.0, rate: $0.1) }
            let budget = mission.radiationBudget.total_uSv ?? config.radiation.budget.total_uSv
            let r = RadiationEngine.analyze(samples: radSamples, deviceCumulative: devCum, config: config.radiation, budget: budget,
                                            missionStart: mission.startDate, plannedDays: mission.plannedDays, asOf: asOf, staleDays: params.staleDays)
            radiation = r
            let conf: Confidence = r.background == nil ? .low : .medium
            metricStatuses["rad_dose_rate"] = StatusResult(personId: personId, scope: .metric, id: "rad_dose_rate", level: r.level, confidence: conf,
                                                           reasons: r.reasons, computedAt: asOf, dataThrough: r.lastSample.map { DayKey.of($0, tz) })
            for ev in r.events {
                let marker = EventMarker(id: "\(personId)|\(ev.id)", personId: personId, ts: ev.start, end: ev.end, kind: .radiation_spike,
                                         label: "Radiation event (peak \(RadiationEngine.f3(ev.peak)) µSv/h)", peak: ev.peak, open: ev.open)
                try? repo.put("event", id: marker.id, person: personId, ts: marker.ts, marker)
            }
        }

        // Prompts and adherence.
        let routines = Scheduler.activeRoutines(config: config, environment: mission.environment)
        let routineMetrics = Array(Set(routines.flatMap(\.metrics)))
        let promptFrom = max(DayKey.add(evalDay, -14, tz), DayKey.of(mission.startDate, tz))
        let recentObs = (try? repo.observations(person: personId, metrics: routineMetrics, from: DayKey.start(promptFrom, tz), to: asOf.addingTimeInterval(60))) ?? []
        let obsTimes = Dictionary(grouping: recentObs.filter { $0.ts <= asOf }, by: \.metric).mapValues { $0.map(\.ts) }
        let explicit = Dictionary(((try? repo.list("prompt", person: personId, as: Prompt.self)) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let prompts = Scheduler.prompts(personId: personId, routines: routines, fromDay: promptFrom, toDay: evalDay, obsTimes: obsTimes,
                                        explicit: explicit, now: asOf, missionStart: mission.startDate, tz: tz)
        let adherence = Scheduler.adherence(prompts, now: asOf)

        // Patterns, roll-up, guidance.
        let patterns = PatternEngine.evaluate(config: config, evals: evals, adherence: adherence, params: params)
        let roll = RollupEngine.rollup(personId: personId, config: config, metricStatuses: metricStatuses, symptoms: symptoms, patterns: patterns, now: asOf)
        let guidance = GuidanceEngine.build(config: config, evals: evals, symptoms: symptoms, patterns: patterns, radiation: radiation,
                                            escalationContact: settings.escalationContact)
        let actions = GuidanceEngine.topActions(guidance)

        // What changed since yesterday.
        var changes: [ChangeItem] = []
        for (mid, e) in evals {
            let now = RollupEngine.effective(e.status).0
            let prev = prevEvals[mid].map { RollupEngine.effective($0.status).0 } ?? .unknown
            guard now >= .watch || (now != prev && prev >= .watch) else { continue }
            let spark = (daily[mid] ?? []).suffix(14).map(\.value)
            let lead = now != prev && prev != .unknown ? "\(prev.label) → \(now.label). " : ""
            let text = lead + (e.status.reasons.first { $0.code != "within_normal" }?.text ?? e.status.reasons.first?.text ?? e.def.label)
            changes.append(ChangeItem(id: "m:\(mid)", regionId: e.def.regions.first ?? "whole_body", metric: mid, text: text, level: now, previous: prev, spark: spark))
        }
        for s in symptoms where s.level >= .watch {
            changes.append(ChangeItem(id: "s:\(s.code)", regionId: s.region, metric: "symptom", text: s.reason.text, level: s.level, previous: .unknown, spark: []))
        }
        if let r = radiation, r.level >= .watch {
            let spark = Array(radSamples.suffix(60).map(\.rate))
            changes.append(ChangeItem(id: "rad", regionId: "whole_body", metric: "rad_dose_rate", text: r.reasons.first?.text ?? "Radiation", level: r.level, previous: .unknown, spark: spark))
        }
        for p in patterns {
            changes.append(ChangeItem(id: "p:\(p.id)", regionId: p.def.raises.first ?? "brain", metric: nil, text: p.reason.text, level: .watch, previous: .unknown, spark: []))
        }
        changes.sort { $0.level != $1.level ? $0.level > $1.level : ($0.level != $0.previous) && ($1.level == $1.previous) }

        // Escalations that must be acknowledged (sticky, never auto-dismissed).
        var escal: [EscalationItem] = []
        for (mid, e) in evals where e.status.level == .escalate {
            escal.append(EscalationItem(key: "metric:\(mid)|\(e.latest?.day ?? evalDay)", text: e.status.reasons.first?.text ?? e.def.label))
        }
        for s in symptoms where s.level == .escalate {
            escal.append(EscalationItem(key: "symptom:\(s.code)|\(Int(s.ts.timeIntervalSince1970))", text: s.reason.text))
        }
        if let r = radiation, r.level == .escalate {
            escal.append(EscalationItem(key: "radiation|\(r.activeEvent.map { Int($0.start.timeIntervalSince1970) } ?? 0)", text: r.reasons.first?.text ?? "Radiation"))
        }
        let acks = Set(((try? repo.list("ack", person: personId, as: EscalationAck.self)) ?? []).map(\.key))
        let unacked = escal.filter { !acks.contains($0.key) }

        // Quests.
        let quests = QuestEngine.evaluate(config: config, daily: daily, prompts: prompts, asOfDay: evalDay,
                                          missionStartDay: DayKey.of(mission.startDate, tz), drillDone: settings.drillDone.contains(personId),
                                          anyBaselineActive: evals.values.contains { $0.baseline.state == .active },
                                          escalationUnacked: !unacked.isEmpty, tz: tz)
        for b in quests.badges where b.earned {
            let id = "\(personId)|\(b.def.id)"
            if (try? repo.get("badge", id: id, as: BadgeAward.self)) == nil {
                try? repo.put("badge", id: id, person: personId, ts: asOf, BadgeAward(id: id, personId: personId, badgeId: b.def.id, awardedAt: asOf, why: b.why))
            }
        }

        // Simulated-data flag.
        lock.lock(); var sim = simCache[personId]; lock.unlock()
        if sim == nil { sim = (try? repo.hasSimulated(person: personId)) ?? false; lock.lock(); simCache[personId] = sim; lock.unlock() }

        // Persist statuses.
        for s in Array(metricStatuses.values) + Array(roll.regions.values) + Array(roll.hazards.values) + [roll.overall] {
            try? repo.put("status", id: "\(personId)|\(s.scope.rawValue)|\(s.id)", person: personId, ts: asOf, s)
        }

        let lastData = evals.values.compactMap { $0.latest?.day }.max().map { DayKey.start($0, tz) }
        let missionDay = max(1, DayKey.diff(evalDay, DayKey.of(mission.startDate, tz), tz) + 1)
        return PersonSnapshot(person: person, mission: mission, asOf: asOf, evalDay: evalDay, missionDay: missionDay, overall: roll.overall,
                              summary: RollupEngine.summary(roll.overall, config: config), regions: roll.regions, hazards: roll.hazards,
                              evals: evals.merging(tracked) { a, _ in a }, metricStatuses: metricStatuses, symptoms: symptoms, patterns: patterns, radiation: radiation,
                              guidance: guidance, actions: actions, changes: Array(changes.prefix(8)),
                              prompts: prompts.filter { DayKey.of($0.dueAt, tz) == evalDay || $0.state == .pending },
                              adherence: adherence, quests: quests, hasSimulated: mission.isSimulated || (sim ?? false), unacked: unacked,
                              lastDataAt: radSamples.last?.ts ?? lastData, computedAt: Date())
    }

    // MARK: User actions

    func acknowledge(_ item: EscalationItem, personId: String, note: String) {
        let a = EscalationAck(personId: personId, key: item.key, acknowledgedAt: Date(), note: note)
        try? repo.put("ack", id: "\(personId)|\(item.key)", person: personId, a)
        refresh([personId])
    }

    func setPrompt(_ p: Prompt) {
        try? repo.put("prompt", id: p.id, person: p.personId, ts: p.dueAt, p)
        refresh([p.personId])
    }

    func lockBaseline(_ b: Baseline) {
        var l = b; l.locked = true
        try? repo.put("lockedBaseline", id: b.key, person: b.personId, l)
        refresh([b.personId])
    }
    func unlockBaseline(person: String, metric: String) {
        try? repo.delete("lockedBaseline", id: "\(person)|\(metric)")
        refresh([person])
    }

    func undoImport(batchId: String) -> Int {
        let rows = (try? repo.deleteBatch(batchId)) ?? []
        self.removed(rows)
        return rows.count
    }

    func deleteEverything() {
        queue.sync {
            try? repo.deleteAll()
            lock.lock(); _snapshots = [:]; simCache = [:]; lock.unlock()
        }
        NotificationCenter.default.post(name: .hubSnapshotsChanged, object: nil, userInfo: ["persons": []])
    }
}
