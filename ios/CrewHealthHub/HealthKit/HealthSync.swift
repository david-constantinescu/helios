import Foundation
import HealthKit
import BackgroundTasks

/// Serialises syncs per type: if a sync is already running for a type, one more run is queued
/// so changes that arrive mid-sync are never lost.
actor SyncGate {
    private var running: Set<String> = []
    private var again: Set<String> = []
    func begin(_ id: String) -> Bool {
        if running.contains(id) { again.insert(id); return false }
        running.insert(id); return true
    }
    func end(_ id: String) -> Bool {
        if again.remove(id) != nil { return true }
        running.remove(id); return false
    }
}

/// Continuous, two-way Apple Health sync.
///
/// * Discrete types: `HKAnchoredObjectQuery` with a persisted anchor → only new/changed samples are fetched,
///   and **deleted** samples are removed locally (HK UUID is stored as the observation's external id).
/// * Cumulative types (steps, exercise): `HKStatisticsCollectionQuery` (cumulative sum de-duplicated across
///   iPhone + Watch), upserted per day.
/// * `HKObserverQuery` + `enableBackgroundDelivery(.immediate)` for every type, registered at launch, so
///   changes are pulled in while the app is open *and* when iOS wakes it in the background.
/// * Re-sync on foreground and from a BGAppRefreshTask as a safety net.
final class HealthSync: ObservableObject {
    static let shared = HealthSync()
    static let refreshTaskId = "org.spaceapps.crewhealthhub.refresh"

    struct TypeStatus: Hashable {
        var total = 0
        var lastSync: Date?
        var lastChange: Date?
        var lastAdded = 0
        var lastDeleted = 0
        var error: String?
        var backgroundDelivery = false
        var observing = false
    }
    struct LogLine: Identifiable, Hashable { let id = UUID(); let ts: Date; let text: String }

    let store = HKHealthStore()
    private let hub = Hub.shared
    private let gate = SyncGate()
    private var observers: [String: HKObserverQuery] = [:]
    private let stateLock = NSLock()

    @Published private(set) var status: [String: TypeStatus] = [:]
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var isObserving = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastChangeAt: Date?
    @Published private(set) var lastFullSyncAt: Date?

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Authorization

    func requestAuthorization() async throws {
        guard available else { throw NSError(domain: "hk", code: 1, userInfo: [NSLocalizedDescriptionKey: "Health data is not available on this device."]) }
        try await store.requestAuthorization(toShare: HKCatalog.shareTypes, read: HKCatalog.readTypes)
        note("Authorization sheet completed. (iOS never reveals read denials; types with no data simply show none.)")
    }

    /// Whether the user allowed *writing* a type (reading permission is intentionally hidden by iOS).
    func canWrite(_ t: HKSampleType) -> Bool { store.authorizationStatus(for: t) == .sharingAuthorized }

    // MARK: Lifecycle

    /// Registers observers and background delivery for every type, then performs a sync.
    /// Safe to call repeatedly; called from the app delegate at launch so background wakes are handled.
    func start(reason: String = "launch") {
        guard available, hub.settings().hkEnabled, hub.healthKitOwner() != nil else { return }
        stateLock.lock()
        let already = !observers.isEmpty
        stateLock.unlock()
        if !already {
            for spec in HKCatalog.all { register(spec) }
            DispatchQueue.main.async { self.isObserving = true }
            note("Observing \(HKCatalog.all.count) Health data types (foreground + background delivery).")
        }
        Task { await syncAll(reason: reason) }
    }

    func stop() {
        stateLock.lock()
        let qs = observers.values
        observers = [:]
        stateLock.unlock()
        for q in qs { store.stop(q) }
        store.disableAllBackgroundDelivery { _, _ in }
        DispatchQueue.main.async { self.isObserving = false }
        note("Stopped observing Health data.")
    }

    private func register(_ spec: HKSpec) {
        let q = HKObserverQuery(sampleType: spec.type, predicate: nil) { [weak self] _, completion, error in
            guard let self else { completion(); return }
            if let error {
                self.setStatus(spec.id) { $0.error = error.localizedDescription }
                completion(); return
            }
            Task {
                await self.sync(spec, reason: "observer")
                completion()     // tell HealthKit we processed the update (required for background delivery)
            }
        }
        stateLock.lock(); observers[spec.id] = q; stateLock.unlock()
        store.execute(q)
        setStatus(spec.id) { $0.observing = true }
        store.enableBackgroundDelivery(for: spec.type, frequency: .immediate) { [weak self] ok, err in
            self?.setStatus(spec.id) { s in s.backgroundDelivery = ok; if let err { s.error = "Background delivery: \(err.localizedDescription)" } }
        }
    }

    // MARK: Sync

    /// Clears every anchor and re-syncs. Dedupe keys make this idempotent; used when the history window grows.
    func reanchorAll(reason: String) async {
        try? hub.repo.deleteKV(prefix: "hk.anchor.")
        note("Anchors cleared (\(reason)); re-reading the full history window.")
        await syncAll(reason: reason)
    }

    /// Types with no stored rows get their anchor cleared before syncing, so data that becomes readable later
    /// (e.g. read permission granted after a first sync) is still backfilled.
    private func reanchorEmptyTypes() {
        guard let owner = hub.healthKitOwner() else { return }
        for spec in HKCatalog.all {
            var sql = "SELECT COUNT(*) FROM observations WHERE person_id=? AND adapter='apple_health' AND metric=?"
            var params: [SQLValue] = [.text(owner.id), .text(spec.metric)]
            if case let .symptom(code) = spec.kind { sql += " AND context LIKE ?"; params.append(.text("%\"symptom\":\"\(code)\"%")) }
            let n = (try? hub.repo.db.query(sql, params).first?.int(0)) ?? 0
            if n == 0 { try? hub.repo.setKV(anchorKey(spec), nil) }
        }
    }

    func syncAll(reason: String) async {
        guard available, hub.settings().hkEnabled else { return }
        if reason == "foreground" || reason == "permissions" || reason == "launch" || reason == "connected" { reanchorEmptyTypes() }
        await MainActor.run { isSyncing = true }
        await withTaskGroup(of: Void.self) { g in
            for spec in HKCatalog.all { g.addTask { await self.sync(spec, reason: reason) } }
        }
        await MainActor.run { isSyncing = false; lastFullSyncAt = Date() }
        try? hub.repo.setKV("hk.lastFullSync", Data("\(Date().timeIntervalSince1970)".utf8))
    }

    func sync(_ spec: HKSpec, reason: String) async {
        guard await gate.begin(spec.id) else { return }   // a run is in flight; it will re-run once more
        repeat {
            do {
                if spec.isCumulative { try await syncStatistics(spec, reason: reason) }
                else { try await syncAnchored(spec, reason: reason) }
            } catch {
                setStatus(spec.id) { $0.error = error.localizedDescription }
                note("⚠︎ \(spec.label): \(error.localizedDescription)")
            }
        } while await gate.end(spec.id)
    }

    private var historyStart: Date {
        Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(hub.settings().hkHistoryDays) * 86400))
    }

    private func anchorKey(_ spec: HKSpec) -> String { "hk.anchor.\(spec.id)" }

    private func loadAnchor(_ spec: HKSpec) -> HKQueryAnchor? {
        guard let d = try? hub.repo.kv(anchorKey(spec)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: d)
    }
    private func saveAnchor(_ a: HKQueryAnchor?, _ spec: HKSpec) {
        guard let a, let d = try? NSKeyedArchiver.archivedData(withRootObject: a, requiringSecureCoding: true) else { return }
        try? hub.repo.setKV(anchorKey(spec), d)
    }

    private func anchoredQuery(_ type: HKSampleType, predicate: NSPredicate?, anchor: HKQueryAnchor?, limit: Int) async throws
        -> ([HKSample], [HKDeletedObject], HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { cont in
            let q = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: limit) { _, samples, deleted, newAnchor, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: (samples ?? [], deleted ?? [], newAnchor)) }
            }
            store.execute(q)
        }
    }

    /// Incremental sync from the saved anchor, in batches; also applies deletions.
    private func syncAnchored(_ spec: HKSpec, reason: String) async throws {
        guard let owner = hub.healthKitOwner() else { return }
        let batch = 5000
        var anchor = loadAnchor(spec)
        let predicate = HKQuery.predicateForSamples(withStart: historyStart, end: nil, options: [])
        var added = 0, deletedCount = 0, rejected = 0
        while true {
            let (samples, deleted, newAnchor) = try await anchoredQuery(spec.type, predicate: predicate, anchor: anchor, limit: batch)
            let raws = samples.flatMap { HealthSync.convert($0, spec: spec, owner: owner) }
            if !raws.isEmpty {
                let r = try hub.submit(raws, allowHistory: true)
                added += r.inserted; rejected += r.rejected
            }
            if !deleted.isEmpty {
                let rows = try hub.repo.deleteByExternalIds(deleted.map { $0.uuid.uuidString })
                deletedCount += rows.count
                hub.removed(rows)
            }
            // Persist the anchor only after the batch is safely stored: a crash re-fetches, and dedupe makes that idempotent.
            saveAnchor(newAnchor, spec)
            anchor = newAnchor
            if samples.count < batch { break }
        }
        var sql = "SELECT COUNT(*) FROM observations WHERE person_id=? AND adapter='apple_health' AND metric=?"
        var params: [SQLValue] = [.text(owner.id), .text(spec.metric)]
        if case let .symptom(code) = spec.kind { sql += " AND context LIKE ?"; params.append(.text("%\"symptom\":\"\(code)\"%")) }
        let total = (try? hub.repo.db.query(sql, params).first?.int(0)) ?? 0
        setStatus(spec.id) { s in
            s.lastSync = Date(); s.total = total
            s.lastAdded = added; s.lastDeleted = deletedCount; s.error = nil
            if added + deletedCount > 0 { s.lastChange = Date() }
        }
        if added + deletedCount > 0 {
            DispatchQueue.main.async { self.lastChangeAt = Date() }
            note("\(spec.label): +\(added) new\(deletedCount > 0 ? ", −\(deletedCount) deleted" : "")\(rejected > 0 ? ", \(rejected) rejected by QC" : "") (\(reason))")
        }
    }

    /// Daily cumulative statistics (steps, exercise minutes), de-duplicated across iPhone + Watch by HealthKit.
    /// An anchored query on the raw samples tells us *which* days changed: new samples → refresh from the
    /// earliest changed day; any deletion (no date available) → refresh the whole history window.
    private func syncStatistics(_ spec: HKSpec, reason: String) async throws {
        guard let owner = hub.healthKitOwner(), case let .cumulative(unit, metric) = spec.kind,
              let qtype = spec.type as? HKQuantityType else { return }
        let cal = Calendar.current
        let now = Date()
        var anchor = loadAnchor(spec)
        let firstRun = anchor == nil
        var earliest: Date? = nil
        var sawDeletion = false
        var changed = 0
        while true {
            let (samples, deleted, newAnchor) = try await anchoredQuery(spec.type, predicate: HKQuery.predicateForSamples(withStart: historyStart, end: nil, options: []),
                                                                        anchor: anchor, limit: 10000)
            if let m = samples.map(\.startDate).min() { earliest = min(earliest ?? m, m) }
            if !deleted.isEmpty { sawDeletion = true }
            changed += samples.count + deleted.count
            anchor = newAnchor
            if samples.count < 10000 { break }
        }
        guard firstRun || changed > 0 || reason == "full resync" else {
            setStatus(spec.id) { s in s.lastSync = Date(); s.error = nil }
            return
        }
        let start = (firstRun || sawDeletion) ? historyStart : max(historyStart, cal.startOfDay(for: earliest ?? now))
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: [])
        let ownBundle = Bundle.main.bundleIdentifier ?? ""

        let collection: HKStatisticsCollection = try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: qtype, quantitySamplePredicate: predicate,
                                                options: [.cumulativeSum, .separateBySource],
                                                anchorDate: cal.startOfDay(for: now), intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, coll, err in
                if let err { cont.resume(throwing: err) } else if let coll { cont.resume(returning: coll) }
                else { cont.resume(throwing: NSError(domain: "hk", code: 2, userInfo: [NSLocalizedDescriptionKey: "No statistics"])) }
            }
            store.execute(q)
        }
        var raws: [RawObservation] = []
        var empty: [String] = []
        collection.enumerateStatistics(from: start, to: now) { stat, _ in
            let day = DayKey.of(stat.startDate, self.hub.tz)
            let key = "hkstat|\(metric)|\(day)"
            guard let sum = stat.sumQuantity() else { empty.append(key); return }
            let sources = stat.sources ?? []
            let ours = sources.contains { $0.bundleIdentifier == ownBundle }
            let others = sources.filter { $0.bundleIdentifier != ownBundle }.map(\.name)
            raws.append(RawObservation(personId: owner.id, missionId: owner.missionId, ts: stat.startDate.addingTimeInterval(12 * 3600),
                                       metric: metric, value: sum.doubleValue(for: unit), unit: AppConfig.shared.metric(metric)?.unit ?? "count",
                                       source: SourceInfo(adapter: "apple_health", device: others.first ?? (ours ? "Helios seeder" : nil),
                                                          kind: ours && others.isEmpty ? .simulated : .device),
                                       externalId: key, dedupeKey: key, upsert: true, stableId: "hkstat-\(metric)-\(day)"))
        }
        let r = try hub.submit(raws, allowHistory: true)
        if !empty.isEmpty { hub.removed(try hub.repo.deleteByExternalIds(empty)) }
        saveAnchor(anchor, spec)     // only after the day totals are stored
        let total = (try? hub.repo.db.query("SELECT COUNT(*) FROM observations WHERE person_id=? AND adapter='apple_health' AND metric=?",
                                            [.text(owner.id), .text(metric)]).first?.int(0)) ?? 0
        setStatus(spec.id) { s in
            s.lastSync = Date(); s.total = total; s.lastAdded = r.inserted; s.error = nil
            if changed > 0 { s.lastChange = Date() }
        }
        if changed > 0 {
            DispatchQueue.main.async { self.lastChangeAt = Date() }
            note("\(spec.label): \(raws.count) day total(s) refreshed from \(DayKey.of(start)) (\(changed) sample change(s), \(reason))")
        }
    }

    // MARK: Conversion

    static func convert(_ sample: HKSample, spec: HKSpec, owner: Person) -> [RawObservation] {
        let meta = sample.metadata ?? [:]
        let simulated = (meta[HKCatalog.simulatedKey] as? Bool) == true || (meta[HKCatalog.simulatedKey] as? NSNumber)?.boolValue == true
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        let fromUs = sample.sourceRevision.source.bundleIdentifier == ownBundle
        let device = sample.device?.name ?? sample.sourceRevision.source.name
        let userEntered = (meta[HKMetadataKeyWasUserEntered] as? Bool) == true || (meta[HKMetadataKeyWasUserEntered] as? NSNumber)?.boolValue == true
        let kind: SourceKind = simulated ? .simulated : ((fromUs || userEntered) ? .manual : .device)
        let src = SourceInfo(adapter: "apple_health", device: device, kind: kind)
        let uuid = sample.uuid.uuidString
        func raw(_ metric: MetricId, _ value: Double, _ unit: String, ts: Date, ctx: ObsContext? = nil, key: String? = nil) -> RawObservation {
            RawObservation(personId: owner.id, missionId: owner.missionId, ts: ts, metric: metric, value: value, unit: unit,
                           source: src, context: ctx, externalId: uuid, dedupeKey: key ?? "hk|\(uuid)")
        }
        func canon(_ m: MetricId) -> String { AppConfig.shared.metric(m)?.unit ?? "" }

        switch spec.kind {
        case let .quantity(unit, metric, scale):
            guard let q = sample as? HKQuantitySample, q.quantity.is(compatibleWith: unit) else { return [] }
            let v = q.quantity.doubleValue(for: unit) * scale
            let canonicalUnit = AppConfig.shared.metric(metric)?.unit ?? ""
            var ctx: ObsContext? = nil
            if metric == "heart_rate", let mc = meta[HKMetadataKeyHeartRateMotionContext] as? NSNumber {
                ctx = ObsContext(activity: mc.intValue == HKHeartRateMotionContext.sedentary.rawValue ? "rest" :
                                    (mc.intValue == HKHeartRateMotionContext.active.rawValue ? "exercise" : "unknown"))
            }
            if metric == "hrv" { ctx = ObsContext(hrvType: "SDNN") }
            if metric == "wrist_temp" { ctx = ObsContext(site: "wrist_sleep") }
            // Overnight measures are attributed by their end time.
            let ts = metric == "wrist_temp" ? q.endDate : q.startDate
            return [raw(metric, v, canonicalUnit, ts: ts, ctx: ctx)]

        case .sleep:
            guard let c = sample as? HKCategorySample else { return [] }
            // Only asleep stages count towards sleep per night; each stage (and in-bed / awake) also gets its own total.
            let stages: [Int: String] = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: "asleep",
                                         HKCategoryValueSleepAnalysis.asleepCore.rawValue: "core",
                                         HKCategoryValueSleepAnalysis.asleepDeep.rawValue: "deep",
                                         HKCategoryValueSleepAnalysis.asleepREM.rawValue: "rem",
                                         HKCategoryValueSleepAnalysis.awake.rawValue: "awake",
                                         HKCategoryValueSleepAnalysis.inBed.rawValue: "in_bed"]
            guard let stage = stages[c.value] else { return [] }
            let hours = c.endDate.timeIntervalSince(c.startDate) / 3600
            guard hours > 0 else { return [] }
            let ctx = ObsContext(start: c.startDate, stage: stage)
            var out: [RawObservation] = []
            if stage != "awake" && stage != "in_bed" { out.append(raw("sleep_hours", hours, "h", ts: c.endDate, ctx: ctx)) }
            if let m = HKCatalog.sleepStageMetric[stage] { out.append(raw(m, hours, "h", ts: c.endDate, ctx: ctx, key: "hk|\(uuid)|\(stage)")) }
            return out

        case let .symptom(code):
            guard let c = sample as? HKCategorySample else { return [] }
            let sev: Double
            switch c.value {
            case HKCategoryValueSeverity.notPresent.rawValue: return []
            case HKCategoryValueSeverity.mild.rawValue: sev = 1
            case HKCategoryValueSeverity.moderate.rawValue: sev = 2
            case HKCategoryValueSeverity.severe.rawValue: sev = 3
            default: sev = 1
            }
            return [raw("symptom", sev, "severity", ts: c.startDate, ctx: ObsContext(symptom: code))]

        case .stateOfMind:
            if #available(iOS 18.0, *), let s = sample as? HKStateOfMind {
                let mood = min(5, max(1, 3 + 2 * s.valence))
                return [raw("mood", mood.rounded(to: 1), "1–5", ts: s.startDate, ctx: ObsContext(note: "Apple Health State of Mind"))]
            }
            return []

        case let .events(metric, values):
            guard let c = sample as? HKCategorySample, values?.contains(c.value) ?? true else { return [] }
            return [raw(metric, 1, canon(metric), ts: c.startDate)]

        case let .duration(metric):
            let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60
            guard minutes > 0 else { return [] }
            return [raw(metric, minutes, canon(metric), ts: sample.endDate, ctx: ObsContext(start: sample.startDate))]

        case .workout:
            guard let w = sample as? HKWorkout, w.duration > 0 else { return [] }
            return [raw("workout_min", w.duration / 60, "min", ts: w.endDate,
                        ctx: ObsContext(activity: HealthSync.workoutName(w.workoutActivityType), start: w.startDate))]

        case .cumulative:
            return []
        }
    }

    static func workoutName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .swimming: return "Swimming"
        case .rowing: return "Rowing"
        case .elliptical: return "Elliptical"
        case .yoga: return "Yoga"
        case .stairClimbing, .stairs: return "Stairs"
        case .hiking: return "Hiking"
        case .coreTraining: return "Core training"
        case .mindAndBody: return "Mind and body"
        case .flexibility, .cooldown: return "Flexibility"
        default: return "Workout"
        }
    }

    // MARK: Reset / maintenance

    /// Forgets anchors and Health-sourced rows, then re-imports everything in the history window.
    func resetAndResync() async {
        guard let owner = hub.healthKitOwner() else { return }
        try? hub.repo.deleteKV(prefix: "hk.")
        _ = try? hub.repo.deleteObservations(person: owner.id, adapter: "apple_health")
        hub.rebuild(person: owner.id)
        note("Anchors cleared; re-importing the last \(hub.settings().hkHistoryDays) days from Health.")
        await syncAll(reason: "full resync")
    }

    // MARK: Background refresh (safety net in addition to HealthKit background delivery)

    static func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { task in
            HealthSync.scheduleBackgroundRefresh()
            let work = Task {
                await HealthSync.shared.syncAll(reason: "background refresh")
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleBackgroundRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    // MARK: Helpers

    private func setStatus(_ id: String, _ f: @escaping (inout TypeStatus) -> Void) {
        DispatchQueue.main.async {
            var s = self.status[id] ?? TypeStatus()
            f(&s)
            self.status[id] = s
        }
    }

    func note(_ text: String) {
        DispatchQueue.main.async {
            self.log.insert(LogLine(ts: Date(), text: text), at: 0)
            if self.log.count > 200 { self.log.removeLast(self.log.count - 200) }
        }
    }
}
