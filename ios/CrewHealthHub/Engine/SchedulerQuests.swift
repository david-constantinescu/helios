import Foundation

// MARK: - Scheduler (PART 5.9)

enum Scheduler {
    /// Routines with the environment profile's overrides applied.
    static func activeRoutines(config: AppConfig, environment: String) -> [RoutineDef] {
        let env = config.environment(environment)
        return config.routines.compactMap { r in
            var r = r
            if let o = env?.routineOverrides[r.id] {
                if let c = o.cadence { r.cadence = c }
                if let e = o.enabled { r.enabled = e }
                if let x = o.extra { r.metrics += x.filter { !r.metrics.contains($0) } }
                if let t = o.time { r.time = t }
            }
            return r.enabled ? r : nil
        }
    }

    static func dueDate(_ r: RoutineDef, day: String, missionStart: Date, tz: TimeZone) -> Date? {
        let cal = DayKey.calendar(tz)
        let start = DayKey.start(day, tz)
        let parts = (r.time ?? "08:00").split(separator: ":").compactMap { Int($0) }
        let due = cal.date(bySettingHour: parts.first ?? 8, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: start)!
        switch r.cadence {
        case "daily": return due
        case "weekly":
            // dow: 1 = Monday … 7 = Sunday. Calendar weekday: 1 = Sunday.
            let wd = cal.component(.weekday, from: start)
            let mondayBased = wd == 1 ? 7 : wd - 1
            return mondayBased == (r.dow ?? 1) ? due : nil
        case "everyNDays":
            let n = max(r.everyDays ?? 3, 1)
            let idx = DayKey.diff(day, DayKey.of(missionStart, tz), tz)
            return idx >= 0 && idx % n == 0 ? due : nil
        default:
            return nil   // event-triggered routines are created on demand
        }
    }

    static func promptId(_ person: String, _ routine: String, _ day: String) -> String { "\(person)|\(routine)|\(day)" }

    /// Derives prompt states for a day range. Explicit user actions (done/skipped/snoozed) override derived state.
    static func prompts(personId: String, routines: [RoutineDef], fromDay: String, toDay: String, obsTimes: [MetricId: [Date]],
                        explicit: [String: Prompt], now: Date, missionStart: Date, tz: TimeZone) -> [Prompt] {
        var out: [Prompt] = []
        for day in DayKey.range(from: fromDay, to: toDay, tz) {
            let dayStart = DayKey.start(day, tz)
            for r in routines {
                guard let due = dueDate(r, day: day, missionStart: missionStart, tz: tz), dayStart <= now else { continue }
                let id = promptId(personId, r.id, day)
                let deadline = due.addingTimeInterval(r.graceHours * 3600)
                if let e = explicit[id], e.state == .done || e.state == .skipped || (e.state == .snoozed && (e.snoozedUntil ?? .distantPast) > now) {
                    out.append(e); continue
                }
                let done = r.metrics.compactMap { m in obsTimes[m]?.filter { $0 >= dayStart && $0 <= deadline }.min() }.min()
                var p = Prompt(id: id, personId: personId, routineId: r.id, dueAt: due, state: .pending, completedAt: nil)
                if let done { p.state = .done; p.completedAt = done }
                else if now > deadline { p.state = .missed }
                out.append(p)
            }
        }
        return out
    }

    /// done / (done + missed) per routine over prompts due in the last `days` days, plus "overall".
    static func adherence(_ prompts: [Prompt], now: Date, days: Int = 14) -> [String: Double] {
        let since = now.addingTimeInterval(-Double(days) * 86400)
        var done: [String: Int] = [:], total: [String: Int] = [:]
        for p in prompts where p.dueAt >= since && (p.state == .done || p.state == .missed) {
            total[p.routineId, default: 0] += 1; total["overall", default: 0] += 1
            if p.state == .done { done[p.routineId, default: 0] += 1; done["overall", default: 0] += 1 }
        }
        var out: [String: Double] = [:]
        for (k, t) in total { out[k] = Double(done[k] ?? 0) / Double(max(t, 1)) }
        return out
    }

    static func onTime(_ p: Prompt) -> Bool {
        guard p.state == .done, let c = p.completedAt else { return false }
        return c <= p.dueAt.addingTimeInterval(2 * 3600)
    }
}

// MARK: - Quests and badges (PART 5.9)

struct QuestState: Identifiable, Hashable {
    var id: String { def.id }
    var def: QuestDef
    var progress: Double
    var target: Double
    var done: Bool { progress >= target }
}

struct BadgeState: Identifiable, Hashable {
    var id: String { def.id }
    var def: BadgeDef
    var earned: Bool
    var why: String
}

struct QuestSnapshot: Hashable {
    var quests: [QuestState]
    var xp: Int
    var level: Int
    var xpIntoLevel: Int
    var xpPerLevel: Int
    var streak: Int
    var badges: [BadgeState]
    var paused: Bool
}

enum QuestEngine {
    static func weekStart(_ day: String, tz: TimeZone) -> String {
        let cal = DayKey.calendar(tz)
        let wd = cal.component(.weekday, from: DayKey.start(day, tz))
        let back = wd == 1 ? 6 : wd - 2      // Monday-based weeks
        return DayKey.add(day, -back, tz)
    }

    /// Safety: exercise credit is capped per day; there is no credit for less sleep, fasting or weight loss,
    /// and quests pause while an escalation is unacknowledged.
    static func evaluate(config: AppConfig, daily: [MetricId: [DailyAggregate]], prompts: [Prompt], asOfDay: String,
                         missionStartDay: String, drillDone: Bool, anyBaselineActive: Bool, escalationUnacked: Bool, tz: TimeZone) -> QuestSnapshot {
        func dayMap(_ m: String) -> [String: Double] { Dictionary((daily[m] ?? []).map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a }) }
        let mood = dayMap("mood"), sleep = dayMap("sleep_hours"), water = dayMap("water_l"), ex = dayMap("exercise_min")
        let qf = config.quests
        let days = DayKey.range(from: min(missionStartDay, asOfDay), to: asOfDay, tz)

        func progress(_ q: QuestDef, periodDays: [String]) -> Double {
            switch q.kind {
            case "checkin": return Double(periodDays.filter { mood[$0] != nil }.count)
            case "sleep_window": return Double(periodDays.filter { (sleep[$0] ?? 0) >= 7 }.count)
            case "water": return Double(periodDays.filter { water[$0] != nil }.count)
            case "exercise": return periodDays.reduce(0) { $0 + min(ex[$1] ?? 0, q.cap ?? .infinity) }
            case "on_time":
                let set = Set(periodDays)
                return Double(prompts.filter { set.contains(DayKey.of($0.dueAt, tz)) && Scheduler.onTime($0) }.count)
            case "drill": return drillDone ? 1 : 0
            default: return 0
            }
        }

        // Current period progress.
        let ws = weekStart(asOfDay, tz: tz)
        let thisWeek = DayKey.range(from: ws, to: asOfDay, tz)
        let quests = qf.quests.map { q -> QuestState in
            let period: [String] = q.period == "daily" ? [asOfDay] : (q.period == "weekly" ? thisWeek : days)
            return QuestState(def: q, progress: min(progress(q, periodDays: period), q.target), target: q.target)
        }

        // XP is recomputed deterministically from history so it is always consistent with the data.
        var xp = 0
        for q in qf.quests {
            switch q.period {
            case "daily":
                for d in days where progress(q, periodDays: [d]) >= q.target { xp += q.xp }
            case "weekly":
                var w = weekStart(days.first ?? asOfDay, tz: tz)
                while w <= asOfDay {
                    let end = min(DayKey.add(w, 6, tz), asOfDay)
                    if progress(q, periodDays: DayKey.range(from: w, to: end, tz)) >= q.target { xp += q.xp }
                    w = DayKey.add(w, 7, tz)
                }
            default:
                if progress(q, periodDays: days) >= q.target { xp += q.xp }
            }
        }
        if escalationUnacked {
            // Withhold today's XP while an escalation is unacknowledged.
            for q in quests where q.def.period == "daily" && q.done { xp -= q.def.xp }
            xp = max(xp, 0)
        }

        // Check-in streak (gentle: today not yet done does not break it).
        var streak = 0
        var d = mood[asOfDay] != nil ? asOfDay : DayKey.add(asOfDay, -1, tz)
        while mood[d] != nil { streak += 1; d = DayKey.add(d, -1, tz) }

        let moodDays = days.filter { mood[$0] != nil }.count
        let last21 = DayKey.range(from: DayKey.add(asOfDay, -20, tz), to: asOfDay, tz)
        let goodNights = last21.filter { (sleep[$0] ?? 0) >= 7 }.count
        let badges: [BadgeState] = qf.badges.map { b in
            switch b.id {
            case "first_baseline": return BadgeState(def: b, earned: anyBaselineActive, why: b.criteria)
            case "week_one": return BadgeState(def: b, earned: moodDays >= 7, why: "\(min(moodDays, 7))/7 check-ins")
            case "radiation_aware": return BadgeState(def: b, earned: drillDone, why: b.criteria)
            case "steady_sleeper": return BadgeState(def: b, earned: goodNights >= 14, why: "\(goodNights)/14 nights in the last 21 days")
            case "full_log":
                let ok = days.count >= 30 && Double(moodDays) / Double(max(days.count, 1)) >= 0.9
                return BadgeState(def: b, earned: ok, why: "\(moodDays) of \(days.count) mission days logged")
            default: return BadgeState(def: b, earned: false, why: b.criteria)
            }
        }
        let per = max(qf.xpPerLevel, 1)
        return QuestSnapshot(quests: quests, xp: xp, level: xp / per + 1, xpIntoLevel: xp % per, xpPerLevel: per, streak: streak,
                             badges: badges, paused: escalationUnacked)
    }
}
