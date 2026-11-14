import SwiftUI
import Charts

struct TrendPoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let value: Double
    let simulated: Bool
    let n: Int
    let sources: String
}
struct BandPoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let median: Double
    let spread: Double
}
struct RawPoint: Identifiable, Hashable { let id: String; let date: Date; let value: Double; let quality: Quality; let source: String }
struct EventPoint: Identifiable, Hashable { let id: String; let date: Date; let label: String; let level: Level }
struct ZPoint: Identifiable, Hashable { var id: String { "\(metric)|\(date.timeIntervalSince1970)" }; let metric: String; let date: Date; let z: Double }

@MainActor
final class TrendModel: ObservableObject {
    @Published var points: [TrendPoint] = []
    @Published var bands: [BandPoint] = []
    @Published var raw: [RawPoint] = []
    @Published var events: [EventPoint] = []
    @Published var zLines: [ZPoint] = []
    @Published var domain: ClosedRange<Date> = Date().addingTimeInterval(-30 * 86400)...Date()
    @Published var yDomain: ClosedRange<Double> = 0...1

    func load(person: Person, metric: MetricDef, asOf: Date, missionStart: Date, includeRaw: Bool, compare: [MetricDef]) {
        let hub = Hub.shared
        let tz = hub.tz
        let params = hub.engineParams()
        let evalDay = DayKey.of(asOf, tz)
        let series = (try? hub.repo.daily(person: person.id, metric: metric.id, to: evalDay)) ?? []
        let start = min(missionStart, series.first.map { DayKey.start($0.day, tz) } ?? missionStart)
        domain = start...max(asOf, start.addingTimeInterval(86400))
        points = series.map { TrendPoint(date: DayKey.start($0.day, tz).addingTimeInterval(12 * 3600), value: $0.value, simulated: $0.hasSimulated, n: $0.n, sources: $0.sources.joined(separator: ", ")) }
        bands = TrendModel.rollingBands(metric, series, params: params, tz: tz)
        if includeRaw {
            let obs = (try? hub.repo.observations(person: person.id, metric: metric.id, from: start, to: asOf.addingTimeInterval(60))) ?? []
            let pts = obs.map { (x: $0.ts.timeIntervalSince1970, y: $0.value) }
            let keep = Set(Stats.lttb(pts, threshold: 2000).map(\.x))
            raw = obs.filter { keep.contains($0.ts.timeIntervalSince1970) }.map { RawPoint(id: $0.id, date: $0.ts, value: $0.value, quality: $0.quality, source: $0.source.device ?? $0.source.adapter) }
        } else { raw = [] }
        var ev: [EventPoint] = ((try? hub.repo.list("event", person: person.id, as: EventMarker.self)) ?? []).filter { $0.ts <= asOf }
            .map { EventPoint(id: $0.id, date: $0.ts, label: $0.label, level: .act) }
        let sym = (try? hub.repo.observations(person: person.id, metric: "symptom", from: start, to: asOf)) ?? []
        ev += sym.map { EventPoint(id: $0.id, date: $0.ts, label: hub.config.symptomByCode[$0.context?.symptom ?? ""]?.label ?? "Symptom", level: $0.value >= 2 ? .act : .watch) }
        events = ev
        // Tight y-domain around the data and the personal band (padding 15 %), so changes are visible.
        var ys = points.map(\.value) + raw.map(\.value)
        ys += bands.flatMap { [$0.median - 2 * $0.spread, $0.median + 2 * $0.spread] }
        if let lo = ys.min(), let hi = ys.max() {
            let pad = max((hi - lo) * 0.15, metric.minSpread)
            yDomain = (lo - pad)...(hi + pad)
        }
        // Compare mode: robust z-score of each metric against its own rolling baseline.
        zLines = []
        for m in [metric] + compare where !compare.isEmpty {
            let s = m.id == metric.id ? series : ((try? hub.repo.daily(person: person.id, metric: m.id, to: evalDay)) ?? [])
            let b = Dictionary(TrendModel.rollingBands(m, s, params: params, tz: tz).map { (DayKey.of($0.date, tz), $0) }, uniquingKeysWith: { a, _ in a })
            for a in s { if let bb = b[a.day] { zLines.append(ZPoint(metric: m.label, date: DayKey.start(a.day, tz).addingTimeInterval(12 * 3600), z: (a.value - bb.median) / bb.spread)) } }
        }
    }

    /// Baseline as it was on each day (so the band shows what "normal" meant at the time).
    static func rollingBands(_ m: MetricDef, _ series: [DailyAggregate], params: EngineParams, tz: TimeZone) -> [BandPoint] {
        series.compactMap { a in
            let b = BaselineEngine.compute(def: m, personId: a.personId, series: series, evalDay: a.day, params: params, tz: tz)
            guard b.state == .active, b.median.isUsable else { return nil }
            return BandPoint(date: DayKey.start(a.day, tz).addingTimeInterval(12 * 3600), median: b.median, spread: b.spread)
        }
    }
}

