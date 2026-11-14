import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Background tasks must be registered before launch finishes.
        HealthSync.registerBackgroundTasks()
        // HealthKit observer queries + background delivery must be registered at launch so that when iOS wakes
        // the app in the background for new Health data, there is a handler waiting for it.
        HealthSync.shared.start(reason: "launch")
        HealthSync.scheduleBackgroundRefresh()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        return true
    }
}

@main
struct CrewHealthHubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .tint(Color.accent)
                .onOpenURL { app.handle(url: $0) }
                .task {
                    app.handleLaunchArguments()
                    if Hub.shared.settings().hubEnabled { CrewHubLink.shared.connect() }
                    if let u = PendingLink.url { app.handle(url: u); PendingLink.url = nil }
                    if app.settings.onboarded && !ProcessInfo.processInfo.arguments.contains("-noNotify") { await NotificationRouter.shared.setUp() }
                }
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .active:
                // Foreground: catch up on anything that changed while we were away.
                Task { await HealthSync.shared.syncAll(reason: "foreground") }
                Hub.shared.refreshAll()
            case .background:
                HealthSync.scheduleBackgroundRefresh()
            default: break
            }
        }
    }
}

/// Global UI state. Snapshots are computed off the main thread by `Hub` and published here.
@MainActor
final class AppState: ObservableObject {
    @Published var currentPersonId: String?
    @Published private(set) var snapshot: PersonSnapshot?
    @Published private(set) var persons: [Person] = []
    @Published var settings: AppSettings
    @Published var selectedTab: Tab = .today
    @Published var showCheckIn = false
    @Published var showManualEntry = false
    @Published var manualMetric: MetricId?
    @Published var showImport = false
    @Published var debugScreen: String?
    @Published var bodyRegion: String?
    @Published var trendMetric: MetricId = "heart_rate_resting"
    @Published var announcement: String?
    private var lastLevels: [String: Level] = [:]

    enum Tab: Hashable { case today, body, trends, hazards, more }

    let hub = Hub.shared
    var config: AppConfig { hub.config }

    init() {
        settings = Hub.shared.settings()
        reloadPersons()
        currentPersonId = settings.currentPersonId ?? persons.first?.id
        NotificationCenter.default.addObserver(forName: .hubSnapshotsChanged, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                self?.pull()
                for pid in (note.userInfo?["persons"] as? [String]) ?? [] {
                    if let s = Hub.shared.snapshot(pid) { NotificationRouter.shared.notify(for: s) }
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .openDeepLink, object: nil, queue: .main) { [weak self] note in
            guard let url = note.object as? URL else { return }
            Task { @MainActor in self?.handle(url: url); PendingLink.url = nil }
        }
        if let id = currentPersonId { hub.refresh([id]) }
    }

    var person: Person? { persons.first { $0.id == currentPersonId } }
    var mission: Mission? { person.flatMap { hub.mission($0.missionId) } }

    func reloadPersons() { persons = hub.persons() }

    func pull() {
        reloadPersons()
        if currentPersonId == nil || !persons.contains(where: { $0.id == currentPersonId }) { currentPersonId = settings.currentPersonId.flatMap { id in persons.first { $0.id == id }?.id } ?? persons.first?.id }
        guard let id = currentPersonId else { snapshot = nil; return }
        if let s = hub.snapshot(id) {
            announceChanges(s)
            snapshot = s
        } else { hub.refresh([id]) }
    }

    /// Concise VoiceOver announcements for region status changes (PART 8.6).
    private func announceChanges(_ s: PersonSnapshot) {
        var msgs: [String] = []
        for (rid, st) in s.regions {
            let key = "\(s.person.id)|\(rid)"
            if let prev = lastLevels[key], prev != st.level, st.level >= .watch {
                msgs.append("\(config.region(rid)?.label ?? rid) status changed to \(st.level.label)")
            }
            lastLevels[key] = st.level
        }
        if let m = msgs.first {
            announcement = m
            UIAccessibility.post(notification: .announcement, argument: msgs.joined(separator: ". "))
        }
    }

    func select(person id: String) {
        currentPersonId = id
        saveSettings { $0.currentPersonId = id }
        snapshot = hub.snapshot(id)
        hub.refresh([id])
    }

    func saveSettings(_ f: (inout AppSettings) -> Void) {
        var s = settings; f(&s); settings = s; hub.saveSettings(s)
    }

    func refresh() { if let id = currentPersonId { hub.refresh([id]) } }

    // MARK: Demo mode (PART 2.3 `?demo=1&seed=42&speed=…` → iOS deep link crewhealth://demo?seed=42&speed=86400)

    func handle(url: URL) {
        // "Open in Helios" from Files, AirDrop or Mail: an Apple Health export (.zip or export.xml).
        if url.isFileURL {
            HealthFileImport.shared.start(url: url, app: self)
            showImport = true
            return
        }
        guard url.scheme == "crewhealth" else { return }
        if url.host == "checkin" { showCheckIn = true; return }
        if url.host == "today" { selectedTab = .today; return }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ k: String) -> String? { q.first { $0.name == k }?.value }
        if url.host == "demo" { startDemo(seed: UInt32(v("seed") ?? "42") ?? 42, speed: Double(v("speed") ?? "86400") ?? 86400, scenario: v("scenario") ?? "full_mission") }
        #if DEBUG
        // Developer hooks used for automated verification on the simulator (debug builds only).
        let seeder = HealthSeeder.shared, sim = MissionSimulator.shared
        switch (url.host ?? "", url.path) {
        case ("hk", "/seed"): Task { _ = try? await seeder.seedHistory(days: Int(v("days") ?? "30") ?? 30) }
        case ("hk", "/live/start"): seeder.startLive()
        case ("hk", "/live/stop"): seeder.stopLive()
        case ("hk", "/delete-last"): Task { try? await seeder.deleteLast() }
        case ("hk", "/delete-seeded"): Task { _ = try? await seeder.deleteAllSeeded() }
        case ("hk", "/sync"): Task { await HealthSync.shared.syncAll(reason: "deep link") }
        case ("sim", "/play"): sim.play()
        case ("sim", "/pause"): sim.pause()
        case ("sim", "/jump"): sim.jump(toDay: Int(v("day") ?? "1") ?? 1)
        case ("sim", "/select"): if let id = sim.config?.personIds.first { select(person: id) }
        case ("person", "/hk"): if let o = hub.healthKitOwner() { select(person: o.id) }
        case ("sim", "/restart"): sim.restart()
        case ("radiation", "/connect"): RadiationBridge.shared.connect()
        case ("radiation", "/disconnect"): RadiationBridge.shared.disconnect()
        case ("radiation", "/simulated"): RadiationBridge.shared.useSimulated()
        case ("debug", "/manual-bp"):
            if let o = hub.healthKitOwner() {
                let ts = Date(), pair = newId()
                let src = SourceInfo(adapter: "manual", device: nil, kind: .manual)
                let raws = [RawObservation(personId: o.id, missionId: o.missionId, ts: ts, metric: "bp_sys", value: Double(v("sys") ?? "121") ?? 121, unit: "mmHg", source: src, context: ObsContext(activity: "rest", note: "debug write-back test", pairId: pair)),
                            RawObservation(personId: o.id, missionId: o.missionId, ts: ts, metric: "bp_dia", value: Double(v("dia") ?? "79") ?? 79, unit: "mmHg", source: src, context: ObsContext(activity: "rest", note: "debug write-back test", pairId: pair))]
                Task { _ = await ManualEntry.submit(raws, person: o) }
            }
        case ("debug", "/import-docs"):
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let f = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil))?.first(where: { ["zip", "xml"].contains($0.pathExtension.lowercased()) }) {
                HealthFileImport.shared.start(url: f, app: self); showImport = true
            }
        case ("debug", "/export"):
            if let s = snapshot, let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let j = SummaryBuilder.json(s, days: 30, sections: .init())
                let jd = (try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
                try? jd.write(to: docs.appendingPathComponent("summary.json"))
                try? SummaryBuilder.html(s, days: 30, sections: .init()).write(to: docs.appendingPathComponent("summary.html"), atomically: true, encoding: .utf8)
                try? SummaryBuilder.csv(s, days: 30).write(to: docs.appendingPathComponent("summary.csv"), atomically: true, encoding: .utf8)
            }
        case ("tab", _): selectedTab = ["today": .today, "body": .body, "trends": .trends, "hazards": .hazards, "more": .more][String(url.path.dropFirst())] ?? .today
        default: break
        }
        #endif
    }

    func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if args.contains("-demo") {
            startDemo(seed: 42, speed: 86400, scenario: "full_mission", day: Int(value("-day") ?? "44") ?? 44,
                      hour: Double(value("-hour") ?? "20") ?? 20, play: args.contains("-play"))
        }
        #if DEBUG
        // Review helpers: -tab body|trends|hazards, -screen data|guidance|quests|settings|about|crew|export|demo|profile|checkin
        if let t = value("-tab") { selectedTab = ["today": .today, "body": .body, "trends": .trends, "hazards": .hazards][t] ?? .today }
        if let r = value("-region") { bodyRegion = r }
        if let m = value("-metric") { trendMetric = m }
        if let h = value("-hub") {
            saveSettings { $0.hubURL = h; $0.hubCode = value("-hubCode") ?? $0.hubCode; $0.hubEnabled = true }
        }
        if args.contains("-ack") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let pid = self.currentPersonId else { return }
                for item in self.snapshot?.unacked ?? [] { self.hub.acknowledge(item, personId: pid, note: "review") }
                self.refresh()
            }
        }
        if args.contains("-importDocs") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.handle(url: URL(string: "crewhealth://debug/import-docs")!) }
        }
        if let sc = value("-screen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if sc == "checkin" { self.showCheckIn = true } else if sc == "entry" { self.showManualEntry = true } else { self.debugScreen = sc }
            }
        }
        #endif
    }

    func startDemo(seed: UInt32, speed: Double, scenario: String, day: Int = 44, hour: Double = 20, play: Bool = false) {
        let sim = MissionSimulator.shared
        sim.setup(scenario: scenario, seed: seed)
        sim.speed = MissionSimulator.Speed(rawValue: speed) ?? .dayPerSec
        saveSettings { $0.onboarded = true; $0.currentPersonId = sim.config?.personIds.first }
        reloadPersons()
        if let id = sim.config?.personIds.first { select(person: id) }
        if let m = sim.mission {
            sim.advance(to: min(m.startDate.addingTimeInterval(Double(day - 1) * 86400 + hour * 3600), Date())) {
                if let id = sim.config?.personIds.first { self.select(person: id) }
                if play { sim.play() }
            }
        }
    }
}

struct DebugScreen: Identifiable { let id: String }
