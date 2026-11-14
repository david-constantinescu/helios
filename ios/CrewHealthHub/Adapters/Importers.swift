import Foundation
import HealthKit

// MARK: - Manual entry adapter (PART 6.3)

enum ManualEntry {
    /// Stores manual measurements. For the Apple Health owner (with write-back on), the samples are first saved to
    /// Health and stored locally under the HealthKit UUID, so the sync never duplicates them.
    static func submit(_ raws: [RawObservation], person: Person) async -> (IngestResult?, String?) {
        let hub = Hub.shared
        var raws = raws
        var note: String?
        let s = hub.settings()
        if person.isHealthKitOwner && s.hkEnabled && s.hkWriteBack {
            do {
                let written = try await HealthWriter.save(raws)
                var used = Set<String>()
                for i in raws.indices {
                    if let w = written.first(where: { $0.metric == raws[i].metric && !used.contains($0.uuid) }) {
                        used.insert(w.uuid)
                        raws[i].externalId = w.uuid
                        raws[i].dedupeKey = "hk|\(w.uuid)"
                        // The observer may import the same sample first; upserting lets the richer local row
                        // (notes, activity, BP pairing, kind = manual) replace that bare copy.
                        raws[i].upsert = true
                    }
                }
                if !written.isEmpty { note = "Saved to Apple Health too." }
            } catch {
                note = "Saved here; could not save to Apple Health (\(error.localizedDescription))."
            }
        }
        do { return (try hub.submit(raws, allowHistory: true), note) }
        catch { return (nil, error.localizedDescription) }
    }
}

// MARK: - CSV / JSON import adapter (PART 6.4)

struct CSVTable {
    var headers: [String]
    var rows: [[String]]
}

enum CSVParser {
    static func detectDelimiter(_ firstLine: String) -> Character {
        let c: [(Character, Int)] = [(",", firstLine.filter { $0 == "," }.count), (";", firstLine.filter { $0 == ";" }.count), ("\t", firstLine.filter { $0 == "\t" }.count)]
        return c.max { $0.1 < $1.1 }?.0 ?? ","
    }

    /// RFC-4180-style parser (quoted fields, escaped quotes, CRLF).
    static func parse(_ text: String, delimiter: Character? = nil) -> CSVTable {
        let clean = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let d = delimiter ?? detectDelimiter(String(clean.prefix { $0 != "\n" }))
        var rows: [[String]] = []
        var field = "", row: [String] = [], inQuotes = false
        var it = Array(clean)
        if it.last != "\n" { it.append("\n") }
        var i = 0
        while i < it.count {
            let ch = it[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < it.count && it[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(ch) }
            } else if ch == "\"" { inQuotes = true }
            else if ch == d { row.append(field); field = "" }
            else if ch == "\n" || ch == "\r\n" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).isEmpty) { rows.append(row) }
                row = []
            } else if ch != "\r" { field.append(ch) }
            i += 1
        }
        guard let header = rows.first else { return CSVTable(headers: [], rows: []) }
        return CSVTable(headers: header.map { $0.trimmingCharacters(in: .whitespaces) }, rows: Array(rows.dropFirst()))
    }
}

struct ColumnMapping: Hashable {
    enum Format: String, CaseIterable { case long, wide }
    var format: Format = .wide
    var tsColumn: Int?
    var metricColumn: Int?
    var valueColumn: Int?
    var unitColumn: Int?
    var wide: [Int: WideColumn] = [:]
    var timeZone: TimeZone = .current
    struct WideColumn: Hashable { var metric: MetricId; var unit: String }
}

struct ImportPreset: Identifiable, Hashable {
    let id: String
    let label: String
    let note: String
    let mapping: (CSVTable) -> ColumnMapping
    static func == (a: ImportPreset, b: ImportPreset) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum CSVImporter {
    /// Header aliases → (metric, unit). Matching is case-insensitive "contains".
    static let aliases: [(String, MetricId, String)] = [
        ("resting heart", "heart_rate_resting", "bpm"), ("resting hr", "heart_rate_resting", "bpm"),
        ("heart rate variability", "hrv", "ms"), ("hrv", "hrv", "ms"),
        ("systolic", "bp_sys", "mmHg"), ("sys", "bp_sys", "mmHg"), ("diastolic", "bp_dia", "mmHg"), ("dia", "bp_dia", "mmHg"),
        ("heart rate", "heart_rate", "bpm"), ("pulse", "heart_rate", "bpm"), ("heart_rate", "heart_rate", "bpm"), ("bpm", "heart_rate", "bpm"),
        ("glucose (mmol", "glucose", "mmol/L"), ("mmol", "glucose", "mmol/L"), ("glucose", "glucose", "mg/dL"),
        ("temperature (f", "body_temp", "F"), ("temperature", "body_temp", "C"), ("temp", "body_temp", "C"),
        ("spo2", "spo2", "%"), ("oxygen", "spo2", "%"), ("respiratory", "resp_rate", "breaths/min"),
        ("minutes asleep", "sleep_hours", "min"), ("sleep (min", "sleep_hours", "min"), ("sleep", "sleep_hours", "h"),
        ("steps", "activity_steps", "count"), ("very active minutes", "exercise_min", "min"), ("exercise", "exercise_min", "min"), ("active minutes", "exercise_min", "min"),
        ("weight (lb", "weight", "lb"), ("weight", "weight", "kg"), ("mass", "weight", "kg"),
        ("mood", "mood", "1–5"), ("stress", "stress", "1–5"), ("water", "water_l", "L"),
        ("cpm", "rad_cpm", "CPM"), ("cps", "rad_cpm", "CPS"), ("nsv/h", "rad_dose_rate", "nSv/h"), ("usv/h", "rad_dose_rate", "µSv/h"),
        ("µsv/h", "rad_dose_rate", "µSv/h"), ("usv_h", "rad_dose_rate", "µSv/h"), ("dose rate", "rad_dose_rate", "µSv/h"), ("dose", "rad_dose_cum", "µSv"),
        ("co2", "cabin_co2", "ppm"),
    ]
    static let tsNames = ["timestamp", "datetime", "date time", "time", "date", "ts", "start"]

    static func match(header: String) -> (MetricId, String)? {
        let h = header.lowercased()
        if let exact = AppConfig.shared.metricById[h] { return (exact.id, exact.unit) }
        for (k, m, u) in aliases where h.contains(k) { return (m, u) }
        return nil
    }

    static func autoDetect(_ t: CSVTable) -> ColumnMapping {
        var m = ColumnMapping()
        let lower = t.headers.map { $0.lowercased() }
        m.tsColumn = tsNames.lazy.compactMap { n in lower.firstIndex { $0 == n } ?? lower.firstIndex { $0.contains(n) } }.first
        if let mi = lower.firstIndex(where: { $0 == "metric" || $0 == "type" }), let vi = lower.firstIndex(where: { $0 == "value" }) {
            m.format = .long; m.metricColumn = mi; m.valueColumn = vi; m.unitColumn = lower.firstIndex { $0 == "unit" }
            return m
        }
        m.format = .wide
        for (i, h) in t.headers.enumerated() where i != m.tsColumn {
            if let (metric, unit) = match(header: h) { m.wide[i] = .init(metric: metric, unit: unit) }
        }
        return m
    }

    static let presets: [ImportPreset] = [
        ImportPreset(id: "auto", label: "Auto-detect", note: "Detects timestamp and metric columns from headers.", mapping: autoDetect),
        ImportPreset(id: "fitbit-export", label: "Fitbit data export (daily CSV)", note: "Columns differ by export version — TODO(verify) against a real export.", mapping: autoDetect),
        ImportPreset(id: "withings-bp-csv", label: "Withings blood pressure CSV", note: "Date, Systolic, Diastolic, Heart rate.", mapping: autoDetect),
        ImportPreset(id: "generic-glucometer-csv", label: "Glucometer CSV", note: "Timestamp and glucose (mg/dL or mmol/L).", mapping: autoDetect),
        ImportPreset(id: "radiation-log-csv", label: "Radiation log CSV", note: "Timestamp with CPM and/or µSv/h. CPM is never converted to dose without a calibration.", mapping: autoDetect),
    ]

    static let dateFormats = ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss",
                              "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm",
                              "dd/MM/yyyy HH:mm", "dd.MM.yyyy HH:mm", "yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy", "yyyy/MM/dd HH:mm:ss"]

    static func parseDate(_ s: String, tz: TimeZone) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let n = Double(t) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: t) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: t) { return d }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        for fmt in dateFormats { f.dateFormat = fmt; if let d = f.date(from: t) { return d.addingTimeInterval(fmt.count <= 10 ? 12 * 3600 : 0) } }
        return nil
    }

    struct Preview { var raws: [RawObservation]; var errors: [String]; var skipped: Int }

    static func toRaw(_ t: CSVTable, mapping m: ColumnMapping, person: Person, batchId: String, adapter: String = "csv_import") -> Preview {
        var out: [RawObservation] = [], errors: [String] = [], skipped = 0
        let src = SourceInfo(adapter: adapter, device: nil, kind: .import)
        for (ri, row) in t.rows.enumerated() {
            guard let tc = m.tsColumn, tc < row.count, let ts = parseDate(row[tc], tz: m.timeZone) else {
                if errors.count < 20 { errors.append("Row \(ri + 2): unreadable timestamp") }; skipped += 1; continue
            }
            func num(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
            switch m.format {
            case .long:
                guard let mc = m.metricColumn, let vc = m.valueColumn, mc < row.count, vc < row.count,
                      let v = num(row[vc]) else { skipped += 1; continue }
                let name = row[mc].trimmingCharacters(in: .whitespaces)
                let metric = AppConfig.shared.metricById[name]?.id ?? match(header: name)?.0 ?? name
                let unit = m.unitColumn.flatMap { $0 < row.count ? row[$0] : nil } ?? AppConfig.shared.metric(metric)?.unit ?? ""
                out.append(RawObservation(personId: person.id, missionId: person.missionId, ts: ts, metric: metric, value: v, unit: unit, source: src, importBatchId: batchId))
            case .wide:
                let pair = "\(batchId)-\(ri)"
                for (ci, w) in m.wide where ci < row.count {
                    guard let v = num(row[ci]) else { continue }
                    var ctx: ObsContext? = nil
                    if w.metric == "bp_sys" || w.metric == "bp_dia" { ctx = ObsContext(pairId: pair) }
                    if w.metric == "sleep_hours" {
                        let hours = w.unit == "min" ? v / 60 : v
                        ctx = ObsContext(start: ts.addingTimeInterval(-hours * 3600))
                    }
                    out.append(RawObservation(personId: person.id, missionId: person.missionId, ts: ts, metric: w.metric, value: v, unit: w.unit,
                                              source: src, context: ctx, importBatchId: batchId))
                }
            }
        }
        return Preview(raws: out, errors: errors, skipped: skipped)
    }

    /// JSON: the app's normalized-observations format (array, or {"observations": [...]}) — also accepts a full app export.
    static func parseJSON(_ data: Data, person: Person, batchId: String) throws -> Preview {
        let obj = try JSONSerialization.jsonObject(with: data)
        let arr: [[String: Any]] = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["observations"] as? [[String: Any]]) ?? []
        var out: [RawObservation] = [], errors: [String] = [], skipped = 0
        for (i, o) in arr.enumerated() {
            guard let metric = o["metric"] as? String, let value = (o["value"] as? Double) ?? (o["value"] as? NSNumber)?.doubleValue,
                  let tsS = (o["ts"] as? String) ?? (o["timestamp"] as? String), let ts = parseDate(tsS, tz: .current) else {
                skipped += 1; if errors.count < 20 { errors.append("Item \(i): missing metric/value/ts") }; continue
            }
            var ctx: ObsContext? = nil
            if let c = o["context"] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: c) {
                let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
                ctx = try? dec.decode(ObsContext.self, from: d)
            }
            out.append(RawObservation(personId: person.id, missionId: person.missionId, ts: ts, metric: metric, value: value,
                                      unit: (o["unit"] as? String) ?? AppConfig.shared.metric(metric)?.unit ?? "",
                                      source: SourceInfo(adapter: "json_import", device: o["device"] as? String, kind: .import),
                                      context: ctx, importBatchId: batchId))
        }
        return Preview(raws: out, errors: errors, skipped: skipped)
    }
}

// MARK: - Apple Health export.xml file adapter (PART 6.5) — streaming SAX parse, never loads the file into memory.

final class AppleHealthXMLImporter: NSObject, XMLParserDelegate {
    struct Summary { var recordsSeen = 0; var recordsKept = 0; var inserted = 0; var rejected = 0; var byMetric: [String: Int] = [:] }

    /// TODO(verify): identifiers and units against a real export.
    static let map: [String: (MetricId, Double)] = [
        "HKQuantityTypeIdentifierHeartRate": ("heart_rate", 1), "HKQuantityTypeIdentifierRestingHeartRate": ("heart_rate_resting", 1),
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": ("hrv", 1), "HKQuantityTypeIdentifierOxygenSaturation": ("spo2", 1),
        "HKQuantityTypeIdentifierRespiratoryRate": ("resp_rate", 1), "HKQuantityTypeIdentifierBloodPressureSystolic": ("bp_sys", 1),
        "HKQuantityTypeIdentifierBloodPressureDiastolic": ("bp_dia", 1), "HKQuantityTypeIdentifierBodyTemperature": ("body_temp", 1),
        "HKQuantityTypeIdentifierAppleSleepingWristTemperature": ("wrist_temp", 1), "HKQuantityTypeIdentifierBloodGlucose": ("glucose", 1),
        "HKQuantityTypeIdentifierStepCount": ("activity_steps", 1), "HKQuantityTypeIdentifierAppleExerciseTime": ("exercise_min", 1),
        "HKQuantityTypeIdentifierBodyMass": ("weight", 1), "HKQuantityTypeIdentifierDietaryWater": ("water_l", 0.001),
        "HKCategoryTypeIdentifierSleepAnalysis": ("sleep_hours", 1),
    ]
    /// Every other type Apple Health records, from the same catalog the live sync uses (type identifier → spec).
    static let tracked: [String: HKSpec] = Dictionary(HKCatalog.tracked.map { ($0.type.identifier, $0) }, uniquingKeysWith: { a, _ in a })
    static let sleepStageValues: [String: String] = ["HKCategoryValueSleepAnalysisAsleepDeep": "deep", "HKCategoryValueSleepAnalysisAsleepREM": "rem",
                                                     "HKCategoryValueSleepAnalysisAsleepCore": "core", "HKCategoryValueSleepAnalysisAwake": "awake",
                                                     "HKCategoryValueSleepAnalysisInBed": "in_bed"]
    /// Frequent point types are stored as 5-minute medians.
    static let downsampled: Set<MetricId> = ["heart_rate", "noise_db", "headphone_db"]
    static let asleepValues: Set<String> = ["HKCategoryValueSleepAnalysisAsleep", "HKCategoryValueSleepAnalysisAsleepUnspecified",
                                            "HKCategoryValueSleepAnalysisAsleepCore", "HKCategoryValueSleepAnalysisAsleepDeep", "HKCategoryValueSleepAnalysisAsleepREM"]

    private let person: Person
    private let since: Date
    private let batchId: String
    private let onProgress: (Summary) -> Void
    private var buffer: [RawObservation] = []
    private var hrBuckets: [MetricId: [Int: [Double]]] = [:]     // 5-minute buckets (downsampled for storage)
    private var hrSource: [MetricId: [Int: String]] = [:]
    /// Steps / exercise: per day, per source totals. iPhone and Watch both record steps, so summing every record
    /// double-counts; we keep the larger single-source total per day (what Apple Health shows, approximately).
    private var dailyTotals: [String: [String: [String: Double]]] = [:]   // metric → day → source → sum
    private(set) var summary = Summary()
    /// Where parsed observations go. Defaults to the app's hub; tests inject their own sink.
    var sink: (([RawObservation]) -> Void)? = nil
    private let df: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"; return f }()
    var cancelled = false

    init(person: Person, since: Date, batchId: String, onProgress: @escaping (Summary) -> Void) {
        self.person = person; self.since = since; self.batchId = batchId; self.onProgress = onProgress
    }

    func run(url: URL) throws -> Summary {
        guard let stream = InputStream(url: url) else { throw NSError(domain: "import", code: 1, userInfo: [NSLocalizedDescriptionKey: AppConfig.shared.s("error.file")]) }
        let parser = XMLParser(stream: stream)
        parser.shouldResolveExternalEntities = false     // never fetch external entities / DTDs
        parser.delegate = self
        parser.parse()
        flushHR(); flushTotals(); flush()
        if let e = parser.parserError, summary.recordsSeen == 0 { throw e }
        return summary
    }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        if cancelled { parser.abortParsing(); return }
        if el == "Workout" { workout(a); return }
        guard el == "Record", let type = a["type"] else { return }
        summary.recordsSeen += 1
        if let spec = AppleHealthXMLImporter.tracked[type] { trackedRecord(spec, a); return }
        guard let (metric, scale) = AppleHealthXMLImporter.map[type], let sd = a["startDate"].flatMap(df.date(from:)),
              let ed = a["endDate"].flatMap(df.date(from:)), ed >= since else { return }
        let device = a["sourceName"]
        let src = SourceInfo(adapter: "apple_health_file", device: device, kind: .import)
        var value: Double, unit: String, ts = sd
        var ctx: ObsContext? = nil
        if metric == "sleep_hours" {
            guard let v = a["value"] else { return }
            let hours = ed.timeIntervalSince(sd) / 3600
            if let stage = AppleHealthXMLImporter.sleepStageValues[v], let m = HKCatalog.sleepStageMetric[stage], hours > 0 {
                append(m, hours, "h", ts: ed, src: src, ctx: ObsContext(start: sd, stage: stage))
            }
            guard AppleHealthXMLImporter.asleepValues.contains(v) else { return }
            value = hours; unit = "h"; ts = ed; ctx = ObsContext(start: sd)
        } else {
            guard let v = a["value"].flatMap(Double.init) else { return }
            value = v * scale; unit = a["unit"] ?? ""
            if metric == "spo2" { value = UnitConversion.spo2Percent(value); unit = "%" }
            if metric == "water_l" { unit = "L" }
            if metric == "weight" && unit == "lb" { unit = "lb" }
            if metric == "body_temp" || metric == "wrist_temp" { unit = unit.lowercased().contains("f") ? "F" : "C" }
            if metric == "glucose" { unit = unit.contains("mmol") ? "mmol/L" : "mg/dL" }
            if metric == "exercise_min" { unit = "min" }
            if metric == "activity_steps" { unit = "count" }
            if metric == "hrv" { ctx = ObsContext(hrvType: "SDNN") }
            if metric == "wrist_temp" { ts = ed }
            if metric == "activity_steps" || metric == "exercise_min" {
                let day = DayKey.of(sd, TimeZone.current)
                dailyTotals[metric, default: [:]][day, default: [:]][device ?? "?", default: 0] += value
                summary.recordsKept += 1
                return
            }
            if metric == "heart_rate" { bucket(metric, value, sd, device); return }
        }
        summary.recordsKept += 1
        summary.byMetric[metric, default: 0] += 1
        buffer.append(RawObservation(personId: person.id, missionId: person.missionId, ts: ts, metric: metric, value: value, unit: unit,
                                     source: src, context: ctx, importBatchId: batchId))
        if buffer.count >= 2000 { flush() }
    }

    private func append(_ metric: MetricId, _ value: Double, _ unit: String, ts: Date, src: SourceInfo, ctx: ObsContext? = nil) {
        summary.recordsKept += 1
        summary.byMetric[metric, default: 0] += 1
        buffer.append(RawObservation(personId: person.id, missionId: person.missionId, ts: ts, metric: metric, value: value, unit: unit,
                                     source: src, context: ctx, importBatchId: batchId))
        if buffer.count >= 2000 { flush() }
    }

    private func bucket(_ metric: MetricId, _ value: Double, _ ts: Date, _ device: String?) {
        let b = Int(ts.timeIntervalSince1970 / 300)
        hrBuckets[metric, default: [:]][b, default: []].append(value); hrSource[metric, default: [:]][b] = device
        summary.recordsKept += 1
        if hrBuckets.values.reduce(0, { $0 + $1.count }) > 2000 { flushHR() }
    }

    /// Everything beyond the core metrics: quantities (converted from the export's units), daily totals, events and durations.
    private func trackedRecord(_ spec: HKSpec, _ a: [String: String]) {
        guard let sd = a["startDate"].flatMap(df.date(from:)), let ed = a["endDate"].flatMap(df.date(from:)), ed >= since else { return }
        let metric = spec.metric
        let canonical = AppConfig.shared.metric(metric)?.unit ?? ""
        let device = a["sourceName"]
        let src = SourceInfo(adapter: "apple_health_file", device: device, kind: .import)
        switch spec.kind {
        case let .quantity(_, _, scale):
            guard let v = a["value"].flatMap(Double.init) else { return }
            var value: Double
            let unit = a["unit"] ?? ""
            if canonical == "°C" { value = unit.contains("F") ? (v - 32) * 5 / 9 : v }
            else {
                guard let f = UnitConversion.exportFactor(unit, to: canonical) else { summary.rejected += 1; return }
                value = v * f * scale
            }
            if AppleHealthXMLImporter.downsampled.contains(metric) { bucket(metric, value, sd, device); return }
            append(metric, value, canonical, ts: sd, src: src)
        case .cumulative:
            guard let v = a["value"].flatMap(Double.init), let f = UnitConversion.exportFactor(a["unit"] ?? "", to: canonical) else { return }
            dailyTotals[metric, default: [:]][DayKey.of(sd, TimeZone.current), default: [:]][device ?? "?", default: 0] += v * f
            summary.recordsKept += 1
        case .events:
            if metric == "stand_hours" && a["value"]?.hasSuffix("Stood") != true { return }
            append(metric, 1, canonical, ts: sd, src: src)
        case .duration:
            let minutes = ed.timeIntervalSince(sd) / 60
            guard minutes > 0 else { return }
            append(metric, minutes, canonical, ts: ed, src: src, ctx: ObsContext(start: sd))
        default: return
        }
    }

    private func workout(_ a: [String: String]) {
        summary.recordsSeen += 1
        guard let sd = a["startDate"].flatMap(df.date(from:)), let ed = a["endDate"].flatMap(df.date(from:)), ed >= since else { return }
        var minutes = a["duration"].flatMap(Double.init) ?? ed.timeIntervalSince(sd) / 60
        switch a["durationUnit"] { case "s": minutes /= 60; case "hr", "h": minutes *= 60; default: break }
        guard minutes > 0 else { return }
        let raw = (a["workoutActivityType"] ?? "Workout").replacingOccurrences(of: "HKWorkoutActivityType", with: "")
        let name = raw.reduce(into: "") { s, c in if c.isUppercase && !s.isEmpty { s += " " }; s.append(c) }
        append("workout_min", minutes, "min", ts: ed, src: SourceInfo(adapter: "apple_health_file", device: a["sourceName"], kind: .import),
               ctx: ObsContext(activity: name, start: sd))
    }

    private func flushHR() {
        for (metric, buckets) in hrBuckets {
            let unit = AppConfig.shared.metric(metric)?.unit ?? "bpm"
            for (b, vals) in buckets {
                buffer.append(RawObservation(personId: person.id, missionId: person.missionId, ts: Date(timeIntervalSince1970: Double(b) * 300 + 150),
                                             metric: metric, value: Stats.median(vals), unit: unit,
                                             source: SourceInfo(adapter: "apple_health_file", device: hrSource[metric]?[b], kind: .import), importBatchId: batchId))
                summary.byMetric[metric, default: 0] += 1
            }
        }
        hrBuckets = [:]; hrSource = [:]
        if buffer.count >= 2000 { flush() }
    }

    private func flushTotals() {
        for (metric, days) in dailyTotals {
            for (day, bySource) in days {
                guard let best = bySource.max(by: { $0.value < $1.value }) else { continue }
                let key = "file|\(metric)|\(day)"
                buffer.append(RawObservation(personId: person.id, missionId: person.missionId,
                                             ts: DayKey.start(day, TimeZone.current).addingTimeInterval(12 * 3600), metric: metric,
                                             value: metric == "activity_steps" ? best.value.rounded() : (best.value * 1000).rounded() / 1000,
                                             unit: AppConfig.shared.metric(metric)?.unit ?? "count",
                                             source: SourceInfo(adapter: "apple_health_file", device: best.key, kind: .import),
                                             importBatchId: batchId, dedupeKey: key, upsert: true, stableId: "file-\(metric)-\(day)"))
                summary.byMetric[metric, default: 0] += 1
                if buffer.count >= 2000 { flush() }
            }
        }
        dailyTotals = [:]
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        if let sink { sink(buffer) }
        else if let r = try? Hub.shared.submit(buffer, allowHistory: true) { summary.inserted += r.inserted; summary.rejected += r.rejected }
        buffer = []
        onProgress(summary)
    }
}
