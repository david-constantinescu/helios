import Foundation
import HealthKit

/// Writes manual measurements back to Apple Health so both stay in sync. The returned HealthKit UUIDs are
/// used as dedupe keys, so when the anchored query reads the same sample back it is not duplicated.
enum HealthWriter {
    struct Written { let metric: MetricId; let uuid: String }

    /// Returns nil when the type is not writable or the user did not allow writing it.
    static func save(_ raws: [RawObservation]) async throws -> [Written] {
        let sync = HealthSync.shared
        let store = sync.store
        var objects: [HKObject] = []
        var written: [Written] = []
        let meta: [String: Any] = [HKMetadataKeyWasUserEntered: true]

        // Blood pressure is saved as a correlation of the pair.
        let sys = raws.first { $0.metric == "bp_sys" }, dia = raws.first { $0.metric == "bp_dia" }
        if let sys, let dia,
           sync.canWrite(HKQuantityType(.bloodPressureSystolic)), sync.canWrite(HKQuantityType(.bloodPressureDiastolic)) {
            let s = HKQuantitySample(type: HKQuantityType(.bloodPressureSystolic), quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: sys.value), start: sys.ts, end: sys.ts, metadata: meta)
            let d = HKQuantitySample(type: HKQuantityType(.bloodPressureDiastolic), quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: dia.value), start: dia.ts, end: dia.ts, metadata: meta)
            objects.append(HKCorrelation(type: HKCorrelationType(.bloodPressure), start: sys.ts, end: sys.ts, objects: [s, d], metadata: meta))
            written += [Written(metric: "bp_sys", uuid: s.uuid.uuidString), Written(metric: "bp_dia", uuid: d.uuid.uuidString)]
        }

        for r in raws where r.metric != "bp_sys" && r.metric != "bp_dia" {
            if r.metric == "symptom", let code = r.context?.symptom,
               let spec = HKCatalog.all.first(where: { if case let .symptom(c) = $0.kind { return c == code }; return false }),
               let ct = spec.type as? HKCategoryType, sync.canWrite(ct) {
                let sev: HKCategoryValueSeverity = r.value >= 3 ? .severe : (r.value >= 2 ? .moderate : .mild)
                let o = HKCategorySample(type: ct, value: sev.rawValue, start: r.ts, end: r.ts, metadata: meta)
                objects.append(o); written.append(Written(metric: r.metric, uuid: o.uuid.uuidString))
            } else if r.metric == "sleep_hours", sync.canWrite(HKCategoryType(.sleepAnalysis)) {
                let start = r.context?.start ?? r.ts.addingTimeInterval(-r.value * 3600)
                let o = HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, start: start, end: r.ts, metadata: meta)
                objects.append(o); written.append(Written(metric: r.metric, uuid: o.uuid.uuidString))
            } else if r.metric == "mood" {
                if #available(iOS 18.0, *), sync.canWrite(HKSampleType.stateOfMindType()) {
                    let valence = max(-1, min(1, (r.value - 3) / 2))
                    let o = HKStateOfMind(date: r.ts, kind: .dailyMood, valence: valence, labels: [], associations: [], metadata: meta)
                    objects.append(o); written.append(Written(metric: r.metric, uuid: o.uuid.uuidString))
                }
            } else if let spec = HKCatalog.spec(metric: r.metric), spec.shareable, case let .quantity(unit, _, scale) = spec.kind,
                      let qt = spec.type as? HKQuantityType, sync.canWrite(qt) {
                let o = HKQuantitySample(type: qt, quantity: HKQuantity(unit: unit, doubleValue: r.value / scale), start: r.ts, end: r.ts, metadata: meta)
                objects.append(o); written.append(Written(metric: r.metric, uuid: o.uuid.uuidString))
            }
        }
        guard !objects.isEmpty else { return [] }
        try await store.save(objects)
        return written
    }
}

/// Developer/demo tool: writes clearly-tagged synthetic samples into the (empty) simulator Health store so that
/// continuous sync can be demonstrated end-to-end. Every sample carries `CrewHealthHub.simulated = true`, which
/// the importer maps to `source.kind = simulated`, so the SIMULATED badge stays honest.
final class HealthSeeder: ObservableObject {
    static let shared = HealthSeeder()
    @Published private(set) var liveRunning = false
    @Published private(set) var lastWritten: String = ""
    @Published private(set) var busy = false
    private var timer: Timer?
    private var lastObjects: [HKObject] = []
    private var tick = 0
    private var rng = SeededRandom(seed: 7)
    private var store: HKHealthStore { HealthSync.shared.store }
    private let meta: [String: Any] = [HKCatalog.simulatedKey: true]

    private func q(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ v: Double, _ start: Date, _ end: Date? = nil, extra: [String: Any] = [:]) -> HKQuantitySample? {
        let t = HKQuantityType(id)
        guard HealthSync.shared.canWrite(t) else { return nil }
        return HKQuantitySample(type: t, quantity: HKQuantity(unit: unit, doubleValue: v), start: start, end: end ?? start, metadata: meta.merging(extra) { a, _ in a })
    }

    /// Writes `days` of history ending now. The last 3 days show shorter sleep and a higher resting heart rate.
    func seedHistory(days: Int = 30) async throws -> Int {
        await MainActor.run { busy = true }
        defer { Task { @MainActor in self.busy = false } }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var objs: [HKObject] = []
        let bpm = HKCatalog.bpm
        for d in stride(from: days, through: 1, by: -1) {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            let strain = d <= 3
            // Night heart rate (sedentary context) and daytime heart rate.
            for i in 0..<18 {
                let t = day.addingTimeInterval(Double(i) * 20 * 60)
                objs += [q(.heartRate, bpm, rng.normal(strain ? 64 : 56, 2.5), t, extra: [HKMetadataKeyHeartRateMotionContext: NSNumber(value: HKHeartRateMotionContext.sedentary.rawValue)])].compactMap { $0 }
            }
            for i in 0..<24 {
                let t = day.addingTimeInterval(8 * 3600 + Double(i) * 30 * 60)
                objs += [q(.heartRate, bpm, rng.normal(74, 7), t)].compactMap { $0 }
            }
            for i in 0..<3 { objs += [q(.heartRateVariabilitySDNN, .secondUnit(with: .milli), rng.normal(strain ? 38 : 52, 5), day.addingTimeInterval(Double(2 + i) * 3600))].compactMap { $0 } }
            for i in 0..<3 { objs += [q(.oxygenSaturation, .percent(), min(1, rng.normal(0.975, 0.006)), day.addingTimeInterval(Double(1 + i) * 3600))].compactMap { $0 } }
            objs += [q(.respiratoryRate, bpm, rng.normal(14, 0.8), day.addingTimeInterval(3 * 3600))].compactMap { $0 }
            if d % 2 == 0 { objs += [q(.bodyTemperature, .degreeCelsius(), rng.normal(36.6, 0.12), day.addingTimeInterval(8 * 3600))].compactMap { $0 } }
            if d % 3 == 0 { objs += [q(.bloodGlucose, HKUnit(from: "mg/dL"), rng.normal(94, 7), day.addingTimeInterval(7.75 * 3600))].compactMap { $0 } }
            if d % 7 == 0 { objs += [q(.bodyMass, .gramUnit(with: .kilo), rng.normal(74, 0.25), day.addingTimeInterval(7 * 3600))].compactMap { $0 } }
            for i in 0..<4 { objs += [q(.dietaryWater, .liter(), 0.5, day.addingTimeInterval(Double(9 + i * 3) * 3600))].compactMap { $0 } }
            for h in 8..<21 { objs += [q(.stepCount, .count(), Double(Int(rng.uniform(250, 950))), day.addingTimeInterval(Double(h) * 3600), day.addingTimeInterval(Double(h) * 3600 + 3000))].compactMap { $0 } }
            if d % 3 == 0, HealthSync.shared.canWrite(HKQuantityType(.bloodPressureSystolic)) {
                let t = day.addingTimeInterval(8.5 * 3600)
                if let s = q(.bloodPressureSystolic, .millimeterOfMercury(), rng.normal(118, 4), t), let di = q(.bloodPressureDiastolic, .millimeterOfMercury(), rng.normal(76, 3), t) {
                    objs.append(HKCorrelation(type: HKCorrelationType(.bloodPressure), start: t, end: t, objects: [s, di], metadata: meta))
                }
            }
            // Sleep: night ending on `day`, with stages. Short nights during the strain period.
            if HealthSync.shared.canWrite(HKCategoryType(.sleepAnalysis)) {
                var t = day.addingTimeInterval(-(strain ? 0.5 : 1.25) * 3600 + rng.normal(0, 900))
                let end = day.addingTimeInterval((strain ? 5.0 : 6.6) * 3600 + rng.normal(0, 900))
                let stages: [HKCategoryValueSleepAnalysis] = [.asleepCore, .asleepDeep, .asleepCore, .asleepREM, .awake, .asleepCore, .asleepREM]
                var k = 0
                while t < end {
                    let len = min(Double(Int(rng.uniform(35, 80))) * 60, end.timeIntervalSince(t))
                    let st = stages[k % stages.count]
                    objs.append(HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: st.rawValue, start: t, end: t.addingTimeInterval(st == .awake ? min(len, 600) : len), metadata: meta))
                    t = t.addingTimeInterval(st == .awake ? min(len, 600) : len); k += 1
                }
            }
            if #available(iOS 18.0, *), HealthSync.shared.canWrite(HKSampleType.stateOfMindType()) {
                objs.append(HKStateOfMind(date: day.addingTimeInterval(20 * 3600), kind: .dailyMood, valence: max(-1, min(1, rng.normal(strain ? -0.1 : 0.4, 0.2))),
                                          labels: [], associations: [], metadata: meta))
            }
            if d == 10, HealthSync.shared.canWrite(HKCategoryType(.headache)) {
                objs.append(HKCategorySample(type: HKCategoryType(.headache), value: HKCategoryValueSeverity.mild.rawValue, start: day.addingTimeInterval(15 * 3600), end: day.addingTimeInterval(17 * 3600), metadata: meta))
            }
        }
        for chunk in stride(from: 0, to: objs.count, by: 500) {
            try await store.save(Array(objs[chunk..<min(chunk + 500, objs.count)]))
        }
        await MainActor.run { lastWritten = "Seeded \(objs.count) samples over \(days) days" }
        HealthSync.shared.note("Seeder wrote \(objs.count) tagged samples into Health (\(days) days).")
        return objs.count
    }

    /// Writes a fresh heart-rate sample every 10 s (and SpO₂ every minute) to show live sync.
    func startLive() {
        guard timer == nil else { return }
        tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.writeLive() }
        liveRunning = true
        writeLive()
    }

    func stopLive() { timer?.invalidate(); timer = nil; liveRunning = false }

    private func writeLive() {
        tick += 1
        var objs: [HKObject] = []
        let now = Date()
        if let hr = q(.heartRate, HKCatalog.bpm, rng.normal(64, 3).rounded(), now, extra: [HKMetadataKeyHeartRateMotionContext: NSNumber(value: HKHeartRateMotionContext.sedentary.rawValue)]) { objs.append(hr) }
        if tick % 6 == 1, let o = q(.oxygenSaturation, .percent(), min(1, rng.normal(0.975, 0.005)), now) { objs.append(o) }
        guard !objs.isEmpty else { return }
        store.save(objs) { [weak self] ok, err in
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    self.lastObjects = objs
                    let hr = (objs.first as? HKQuantitySample)?.quantity.doubleValue(for: HKCatalog.bpm) ?? 0
                    self.lastWritten = "Wrote heart rate \(Int(hr)) bpm at \(DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .medium))"
                } else { self.lastWritten = "Write failed: \(err?.localizedDescription ?? "?")" }
            }
        }
    }

    /// Deletes the most recently written live samples to demonstrate deletion sync.
    func deleteLast() async throws {
        guard !lastObjects.isEmpty else { return }
        try await store.delete(lastObjects)
        let n = lastObjects.count
        lastObjects = []
        await MainActor.run { lastWritten = "Deleted the last \(n) sample(s) from Health" }
    }

    /// Removes every sample tagged as simulated by this seeder.
    func deleteAllSeeded() async throws -> Int {
        await MainActor.run { busy = true }
        defer { Task { @MainActor in self.busy = false } }
        stopLiveOnMain()
        var n = 0
        let pred = HKQuery.predicateForObjects(withMetadataKey: HKCatalog.simulatedKey, allowedValues: [true])
        for spec in HKCatalog.all where spec.shareable && HealthSync.shared.canWrite(spec.type) {
            n += (try? await store.deleteObjects(of: spec.type, predicate: pred)) ?? 0
        }
        if HealthSync.shared.canWrite(HKQuantityType(.bloodPressureSystolic)) {
            n += (try? await store.deleteObjects(of: HKCorrelationType(.bloodPressure), predicate: pred)) ?? 0
        }
        await MainActor.run { lastWritten = "Deleted \(n) seeded samples from Health" }
        HealthSync.shared.note("Seeder deleted \(n) tagged samples from Health.")
        return n
    }
    private func stopLiveOnMain() { DispatchQueue.main.async { self.stopLive() } }
}

/// Small seedable PRNG (mulberry32) used by the simulator and seeder.
struct SeededRandom {
    private var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next() -> Double {
        state &+= 0x6D2B79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4294967296.0
    }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    mutating func normal(_ mean: Double, _ sd: Double) -> Double {
        let u1 = max(next(), 1e-12), u2 = next()
        return mean + sd * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
