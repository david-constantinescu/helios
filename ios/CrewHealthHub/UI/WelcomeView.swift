import SwiftUI
import UniformTypeIdentifiers

/// First run: two clear paths — your own Apple Health data, or a ready-to-explore demo mission.
struct WelcomeView: View {
    @EnvironmentObject var app: AppState
    @State private var working: String?
    @State private var error: String?
    @State private var appear = false
    @State private var picking = false

    var body: some View {
        ZStack {
            AmbientBackground(colors: [.blue, .pink]).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 16) {
                    Image("HeliosMark").resizable().scaledToFit().foregroundStyle(.white)
                        .padding(26).frame(width: 128, height: 100)
                        .glassSurface(30)
                    Text("Helios").font(.largeTitle.bold())
                    Text("Your own flight surgeon,\nwhen Earth is too far to call.")
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .opacity(appear ? 1 : 0).offset(y: appear ? 0 : 16)
                Spacer()
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 14) {
                        feature("heart.fill", .pink, "Learns your normal from Apple Health")
                        feature("eye.fill", .yellow, "Spots changes early and tells you why")
                        feature("lock.fill", .cyan, "Stays on your iPhone and your Helios Hub")
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassSurface(26)

                    Button { Task { await connectHealth() } } label: {
                        HStack(spacing: 8) {
                            if working == "health" { ProgressView().tint(.black) } else { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                            Text("Connect Apple Health")
                        }
                        .font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).frame(height: 54)
                        .background(Capsule().fill(.white))
                    }
                    .disabled(working != nil)

                    Button { startDemo() } label: {
                        HStack(spacing: 8) {
                            if working == "demo" { ProgressView() }
                            Text(working == "demo" ? "Preparing mission…" : "Explore the demo mission")
                        }
                        .font(.headline).frame(maxWidth: .infinity).frame(height: 54)
                    }
                    .foregroundStyle(.white)
                    .glassCapsule()
                    .disabled(working != nil)

                    Button { picking = true } label: {
                        Label("Use my Health export file", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 40)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .disabled(working != nil)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
                .opacity(appear ? 1 : 0).offset(y: appear ? 0 : 30)
            }
        }
        .foregroundStyle(.white)
        .onAppear { withAnimation(.spring(duration: 0.9)) { appear = true } }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .xml]) { r in
            guard case let .success(url) = r else { return }
            let me = HealthConnect.ensureOwner(app: app)
            app.saveSettings { $0.onboarded = true; $0.currentPersonId = me.id }
            HealthFileImport.shared.start(url: url, app: app)
            app.showImport = true
        }
        .alert("Apple Health", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }

    private func feature(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color).frame(width: 28)
            Text(text).font(.body)
        }
    }

    private func connectHealth() async {
        working = "health"
        defer { working = nil }
        let me = HealthConnect.ensureOwner(app: app)
        do {
            try await HealthSync.shared.requestAuthorization()
            app.saveSettings { $0.hkEnabled = true; $0.onboarded = true; $0.currentPersonId = me.id }
            HealthSync.shared.start(reason: "connected")
            app.reloadPersons()
            app.select(person: me.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startDemo() {
        working = "demo"
        let sim = MissionSimulator.shared
        sim.setup(scenario: "full_mission", seed: 42, environment: "station")
        sim.speed = .dayPerSec
        app.saveSettings { $0.onboarded = true; $0.currentPersonId = sim.config?.personIds.first }
        // Start at an interesting point of the storyline: heart strain building (day 44).
        if let m = sim.mission {
            sim.advance(to: min(m.startDate.addingTimeInterval(43 * 86400 + 20 * 3600), Date())) {
                app.reloadPersons()
                if let id = sim.config?.personIds.first { app.select(person: id) }
                app.selectedTab = .today
                working = nil
            }
        }
    }
}

/// Shared helpers for connecting Apple Health from anywhere in the app.
enum HealthConnect {
    /// Returns the person whose data comes from this iPhone, creating a mission and person if needed.
    @MainActor
    static func ensureOwner(app: AppState) -> Person {
        let hub = app.hub
        if let o = hub.healthKitOwner() { return o }
        if var p = app.persons.first(where: { !(hub.mission($0.missionId)?.isSimulated ?? true) }) {
            p.isHealthKitOwner = true; hub.save(p); app.reloadPersons(); return p
        }
        let mid = "mission-\(newId().prefix(8))"
        hub.save(Mission(id: mid, name: "My mission", environment: "station", startDate: Calendar.current.startOfDay(for: Date()),
                         plannedDays: 180, isSimulated: false))
        let p = Person(id: "person-\(newId().prefix(8))", displayName: "David", avatar: nil, missionId: mid, isHealthKitOwner: true)
        hub.save(p)
        app.reloadPersons()
        return p
    }
}
