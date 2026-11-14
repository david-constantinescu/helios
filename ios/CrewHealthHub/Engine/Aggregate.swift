import Foundation

/// Daily aggregation (PART 5.2). Pure functions over observations of one person, metric and local day.
enum Aggregator {
    /// Night window: sleep that ends between 18:00 (previous day) and 18:00 is attributed to the day it ends on
    /// if it ends before `nightEndsHour`… in practice: anything ending at or after 18:00 belongs to the next day.
    static var nightBoundaryHour = 18

    static let nightMetrics: Set<String> = ["sleep_hours", "wrist_temp", "sleep_deep_h", "sleep_rem_h", "sleep_core_h", "sleep_awake_h", "in_bed_h", "breathing_disturbances"]

    /// The local day an observation is attributed to.
    static func dayOf(metric: MetricId, ts: Date, tz: TimeZone) -> String {
        if nightMetrics.contains(metric) {
            let cal = DayKey.calendar(tz)
            let hour = cal.component(.hour, from: ts)
            if hour >= nightBoundaryHour { return DayKey.of(cal.date(byAdding: .day, value: 1, to: ts)!, tz) }
        }
        return DayKey.of(ts, tz)
    }

    /// Total length (hours) of the union of intervals — overlapping sleep from several sources is not double-counted.
    static func unionHours(_ intervals: [(Date, Date)]) -> Double {
        let s = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        guard var cur = s.first else { return 0 }
        var total: TimeInterval = 0
        for iv in s.dropFirst() {
            if iv.0 <= cur.1 { cur.1 = max(cur.1, iv.1) }
            else { total += cur.1.timeIntervalSince(cur.0); cur = iv }
        }
        total += cur.1.timeIntervalSince(cur.0)
        return total / 3600
    }

    /// Resting HR derived from heart-rate samples when the device gives no daily value:
    /// 10th percentile of rest-context samples, else the lowest 5-minute median between 00:00 and 06:00.
    static func derivedRestingHR(_ hr: [Observation], tz: TimeZone) -> Double? {
        let rest = hr.filter { $0.context?.activity == "rest" || $0.context?.activity == "sleep" }.map(\.value)
        if rest.count >= 3 { return Stats.percentile(rest, 10) }
        let cal = DayKey.calendar(tz)
        let night = hr.filter { cal.component(.hour, from: $0.ts) < 6 }
        guard !night.isEmpty else { return rest.isEmpty ? nil : Stats.median(rest) }
        var buckets: [Int: [Double]] = [:]
        for o in night { buckets[Int(o.ts.timeIntervalSince1970 / 300), default: []].append(o.value) }
        return buckets.values.map { Stats.median($0) }.min()
    }

    /// Aggregates one day. `obs` must already be filtered to that day and to quality == ok.
    /// `heartRateForDerivation` is used only for resting HR when no direct value exists.
    static func aggregate(def: MetricDef, personId: String, day: String, obs: [Observation],
                          heartRateForDerivation: [Observation] = [], tz: TimeZone) -> DailyAggregate? {
        var values = obs.sorted { $0.ts < $1.ts }.map(\.value)
        var sources = Array(Set(obs.map { $0.source.device ?? $0.source.adapter })).sorted()
        var hasSim = obs.contains { $0.source.kind == .simulated }

        if def.aggregation == "resting_hr" && values.isEmpty {
            guard let v = derivedRestingHR(heartRateForDerivation, tz: tz) else { return nil }
            values = [v]
            sources = ["derived:heart_rate"]
            hasSim = heartRateForDerivation.contains { $0.source.kind == .simulated }
        }
        guard !values.isEmpty else { return nil }

        let value: Double
        switch def.aggregation {
        case "sum": value = values.reduce(0, +)
        case "mean": value = Stats.mean(values)
        case "last", "resting_hr": value = values.last!
        case "max": value = values.max()!
        case "sleep":
            let intervals = obs.compactMap { o -> (Date, Date)? in
                guard let s = o.context?.start else { return nil }
                return (s, o.ts)
            }
            if !intervals.isEmpty { value = unionHours(intervals) }
            else { value = values.reduce(0, +) }   // manual entries are already hours per night
        default: value = Stats.median(values)
        }
        return DailyAggregate(personId: personId, metric: def.id, day: day, n: values.count, mean: Stats.mean(values),
                              median: Stats.median(values), min: values.min()!, max: values.max()!, last: values.last!,
                              value: value, sources: sources, hasSimulated: hasSim)
    }
}
