import Foundation

struct RadSample: Hashable {
    var ts: Date
    var rate: Double          // µSv/h
}

struct RadEvent: Hashable, Identifiable {
    var id: String { "rad|\(Int(start.timeIntervalSince1970))" }
    var start: Date
    var end: Date?
    var peak: Double
    var dose_uSv: Double
    var open: Bool { end == nil }
    var durationMin: Double { ((end ?? start).timeIntervalSince(start)) / 60 }
}

struct RadiationResult {
    var hasData: Bool
    var background: Double?
    var bgSpread: Double?
    var current: Double?
    var smoothed: Double?
    var events: [RadEvent]
    var cumulative_uSv: Double
    var unmonitoredMinutes: Double
    var deviceResets: Int
    var budget_uSv: Double?
    var percentUsed: Double?
    var projected_uSv: Double?
    var level: Level
    var reasons: [Reason]
    var lastSample: Date?
    var activeEvent: RadEvent? { events.last(where: { $0.open }) }
}

/// Radiation engine (PART 5.7). Pure function over a time-ordered sample list.
enum RadiationEngine {
    static func analyze(samples raw: [RadSample], deviceCumulative: [RadSample] = [], config: RadiationFile, budget: Double?,
                        missionStart: Date, plannedDays: Int, asOf: Date, staleDays: Int = 10) -> RadiationResult {
        let samples = raw.filter { $0.ts <= asOf }.sorted { $0.ts < $1.ts }
        guard let first = samples.first, let last = samples.last else {
            return RadiationResult(hasData: false, background: nil, bgSpread: nil, current: nil, smoothed: nil, events: [], cumulative_uSv: 0,
                                   unmonitoredMinutes: 0, deviceResets: 0, budget_uSv: budget, percentUsed: nil, projected_uSv: nil,
                                   level: .unknown, reasons: [Reason(code: "no_data", text: "No radiation data yet. Connect a detector or use simulated radiation.")], lastSample: nil)
        }
        let maxGap = config.maxGapMin * 60
        let tau = config.ewmaSeconds

        // 1. Cumulative dose by trapezoid rule; gaps larger than maxGap are "unmonitored", not interpolated.
        var cum = 0.0, unmonitored = 0.0
        for i in 1..<samples.count {
            let dt = samples[i].ts.timeIntervalSince(samples[i - 1].ts)
            if dt <= 0 { continue }
            if dt > maxGap { unmonitored += dt / 60; continue }
            cum += 0.5 * (samples[i].rate + samples[i - 1].rate) * dt / 3600
        }

        // 2. EWMA smoothing.
        var smooth: [Double] = []
        smooth.reserveCapacity(samples.count)
        for (i, s) in samples.enumerated() {
            if i == 0 { smooth.append(s.rate); continue }
            let dt = s.ts.timeIntervalSince(samples[i - 1].ts)
            let a = dt > maxGap ? 1.0 : 1 - exp(-max(dt, 0) / tau)
            smooth.append(smooth[i - 1] + a * (s.rate - smooth[i - 1]))
        }

        // 3. Background learning (needs a minimum span), recomputed from non-spike periods.
        let span = last.ts.timeIntervalSince(first.ts) / 60
        func robustBg(_ xs: [Double]) -> (Double, Double) {
            let m = Stats.median(xs)
            return (m, max(1.4826 * Stats.mad(xs, median: m), 0.1 * m))
        }
        var bg: Double? = nil, bgSpread: Double? = nil
        var events: [RadEvent] = []
        if span >= config.backgroundMinMinutes {
            var (b, s) = robustBg(samples.map(\.rate))
            for pass in 0..<2 {
                events = detectSpikes(samples: samples, smooth: smooth, bg: b, spread: s, p: config.spike, maxGap: maxGap)
                if pass == 0 {
                    let quiet = samples.filter { x in !events.contains { x.ts >= $0.start && x.ts <= ($0.end ?? last.ts) } }.map(\.rate)
                    if quiet.count >= 3 { (b, s) = robustBg(quiet) }
                }
            }
            bg = b; bgSpread = s
            // Dose accrued during each event.
            for i in events.indices {
                var d = 0.0
                for j in 1..<samples.count where samples[j].ts > events[i].start && samples[j].ts <= (events[i].end ?? last.ts) {
                    let dt = samples[j].ts.timeIntervalSince(samples[j - 1].ts)
                    if dt > 0 && dt <= maxGap { d += 0.5 * (samples[j].rate + samples[j - 1].rate) * dt / 3600 }
                }
                events[i].dose_uSv = d
            }
        }

        // 4. Device counter resets (cumulative decreasing) — we keep accumulating in the app and note it.
        var resets = 0
        let dc = deviceCumulative.sorted { $0.ts < $1.ts }
        if dc.count > 1 { for i in 1..<dc.count where dc[i].rate < dc[i - 1].rate { resets += 1 } }

        // 5. Budget and projection.
        var pct: Double?, projected: Double?
        let elapsedDays = max(asOf.timeIntervalSince(missionStart) / 86400, 1.0 / 24)
        let remainingDays = max(Double(plannedDays) - elapsedDays, 0)
        let dailyRate = cum / max(last.ts.timeIntervalSince(first.ts) / 86400, 1.0 / 24)
        projected = cum + dailyRate * remainingDays
        if let budget, budget > 0 { pct = cum / budget * 100 }

        // 6. Status mapping.
        var level = Level.ok
        var reasons: [Reason] = []
        let sm = smooth.last!
        let ageDays = asOf.timeIntervalSince(last.ts) / 86400
        if ageDays > Double(staleDays) {
            level = .unknown
            reasons.append(Reason(code: "stale", text: "No radiation data for \(Int(ageDays)) days."))
        } else if let bg, bg > 0 {
            let a = config.alerts.doseRate
            let mult = sm / bg
            if let ev = events.last(where: { $0.open }) {
                let sustainedExtreme = samples.suffix(while: { $0.ts >= asOf.addingTimeInterval(-config.spike.minutes * 60) }).allSatisfy { $0.rate >= a.escalateMultiple * bg }
                level = (mult >= a.escalateMultiple && sustainedExtreme) ? .escalate : .act
                reasons.append(Reason(code: "rad_spike", text: "Radiation event in progress since \(timeText(ev.start)): dose rate \(f3(sm)) µSv/h, about \(Int(mult.rounded()))× your background of \(f3(bg)) µSv/h.", metric: "rad_dose_rate", value: sm, baseline: bg))
            } else if mult >= a.actMultiple {
                level = .act
                reasons.append(Reason(code: "rad_rate", text: "Dose rate \(f3(sm)) µSv/h is \(Int(mult.rounded()))× background.", metric: "rad_dose_rate", value: sm, baseline: bg))
            } else if mult >= a.watchMultiple {
                level = .watch
                reasons.append(Reason(code: "rad_rate", text: "Dose rate \(f3(sm)) µSv/h is \(String(format: "%.1f", mult))× background — a notable rise.", metric: "rad_dose_rate", value: sm, baseline: bg))
            } else if let ev = events.last, let end = ev.end, asOf.timeIntervalSince(end) < 24 * 3600 {
                level = .watch
                reasons.append(Reason(code: "rad_recent", text: "A radiation event ended \(Int(asOf.timeIntervalSince(end) / 3600)) h ago (peak \(f3(ev.peak)) µSv/h, \(Int(ev.durationMin)) min, \(f1(ev.dose_uSv)) µSv). Dose logged.", metric: "rad_dose_rate"))
            } else {
                reasons.append(Reason(code: "rad_ok", text: "Dose rate \(f3(sm)) µSv/h is at your background level (\(f3(bg)) µSv/h).", metric: "rad_dose_rate", value: sm, baseline: bg))
            }
        } else {
            reasons.append(Reason(code: "rad_learning", text: "Learning background radiation (needs \(Int(config.backgroundMinMinutes)) minutes of data)."))
        }
        if let pct {
            for tier in config.alerts.budgetPercent.sorted(by: { $0.at < $1.at }) where pct >= tier.at {
                let l = Level(name: tier.level)
                if l > level { level = l }
                reasons.append(Reason(code: "rad_budget", text: "\(f1(pct))% of the mission dose budget used (tier \(tier.level)).", metric: "rad_dose_cum", value: cum))
            }
        }
        if unmonitored > 60 {
            reasons.append(Reason(code: "rad_gap", text: "\(Int(unmonitored / 60)) h of unmonitored time (gaps over \(Int(config.maxGapMin)) min are not filled in)."))
        }
        if resets > 0 { reasons.append(Reason(code: "rad_reset", text: "Device dose counter reset \(resets)×; the app kept accumulating.")) }

        return RadiationResult(hasData: true, background: bg, bgSpread: bgSpread, current: last.rate, smoothed: sm, events: events,
                               cumulative_uSv: cum, unmonitoredMinutes: unmonitored, deviceResets: resets, budget_uSv: budget,
                               percentUsed: pct, projected_uSv: projected, level: level, reasons: reasons, lastSample: last.ts)
    }

    /// Spike: smoothed (and raw) ≥ bg + k·spread AND ≥ f·bg, held for at least `minutes`. Gaps break a candidate.
    static func detectSpikes(samples: [RadSample], smooth: [Double], bg: Double, spread: Double, p: SpikeParams, maxGap: TimeInterval) -> [RadEvent] {
        var events: [RadEvent] = []
        var candStart: Date? = nil
        var confirmed = false
        var peak = 0.0
        for (i, s) in samples.enumerated() {
            // Both the smoothed and the raw rate must be elevated, so EWMA hold-over cannot stretch a one-sample blip into an event.
            let thr = max(bg + p.k * spread, p.f * bg)
            let cond = smooth[i] >= thr && s.rate >= thr
            if i > 0 && s.ts.timeIntervalSince(samples[i - 1].ts) > maxGap {
                if confirmed, let st = candStart { events.append(RadEvent(start: st, end: samples[i - 1].ts, peak: peak, dose_uSv: 0)) }
                candStart = nil; confirmed = false; peak = 0
            }
            if cond {
                if candStart == nil { candStart = s.ts; peak = 0 }
                peak = max(peak, s.rate)
                if !confirmed, let st = candStart, s.ts.timeIntervalSince(st) >= p.minutes * 60 { confirmed = true }
            } else if candStart != nil {
                if confirmed { events.append(RadEvent(start: candStart!, end: s.ts, peak: peak, dose_uSv: 0)) }
                candStart = nil; confirmed = false; peak = 0
            }
        }
        if confirmed, let st = candStart { events.append(RadEvent(start: st, end: nil, peak: peak, dose_uSv: 0)) }
        return events
    }

    static func f3(_ v: Double) -> String { String(format: v < 1 ? "%.3f" : (v < 10 ? "%.2f" : "%.1f"), v) }
    static func f1(_ v: Double) -> String { String(format: "%.1f", v) }
    static func timeText(_ d: Date) -> String { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f.string(from: d) }
}

extension Array {
    /// Trailing elements while the predicate holds.
    func suffix(while pred: (Element) -> Bool) -> ArraySlice<Element> {
        var i = endIndex
        while i > startIndex && pred(self[index(before: i)]) { i = index(before: i) }
        return self[i..<endIndex]
    }
}
