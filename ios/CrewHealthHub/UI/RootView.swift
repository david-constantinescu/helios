import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            if !app.settings.onboarded || app.persons.isEmpty {
                WelcomeView()
            } else {
                MainTabs()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $app.showImport) { ImportProgressView() }
    }
}

// MARK: - Tabs

struct MainTabs: View {
    @EnvironmentObject var app: AppState
    @State private var showProfile = false

    private var isDemo: Bool { app.mission?.isSimulated == true }

    var body: some View {
        TabView(selection: $app.selectedTab) {
            Tab("Today", systemImage: "heart.text.square.fill", value: AppState.Tab.today) {
                NavigationStack { TodayView(showProfile: $showProfile) }.demoInset(isDemo)
            }
            Tab("Body", systemImage: "figure.stand", value: AppState.Tab.body) {
                NavigationStack { BodyMapView(showProfile: $showProfile) }.demoInset(isDemo)
            }
            Tab("Trends", systemImage: "chart.xyaxis.line", value: AppState.Tab.trends) {
                NavigationStack { TrendsView(showProfile: $showProfile) }.demoInset(isDemo)
            }
            Tab("Hazards", systemImage: "shield.lefthalf.filled", value: AppState.Tab.hazards) {
                NavigationStack { HazardsView(showProfile: $showProfile) }.demoInset(isDemo)
            }
        }
        .modifier(DemoAccessory(enabled: isDemo))
        .sheet(isPresented: $showProfile) { ProfileView() }
        .sheet(item: Binding(get: { app.debugScreen.map { DebugScreen(id: $0) } }, set: { app.debugScreen = $0?.id })) { d in
            if d.id == "profile" { ProfileView() }
            else {
                NavigationStack {
                    Group {
                        switch d.id {
                        case "data": DataView()
                        case "guidance": GuidanceView()
                        case "quests": QuestsView()
                        case "settings": SettingsView()
                        case "about": AboutView()
                        case "crew": CrewView()
                        case "export": ExportView()
                        case "demo": SimulatorPanel()
                        case "radiation": RadiationSourceView()
                        case "hub": CrewHubView()
                        default: Text(d.id)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $app.showCheckIn) { CheckInView() }
        .sheet(isPresented: $app.showManualEntry) { NavigationStack { ManualEntryView() } }
        .fullScreenCover(item: Binding(get: { app.snapshot?.unacked.first.map { EscalationSheetItem(item: $0) } }, set: { _ in })) { e in
            AlertView(item: e.item)
        }
    }
}

/// iOS 26: the demo controls live in the tab bar's bottom accessory, like Music's mini player.
struct DemoAccessory: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            // Always attached, toggled with isEnabled, so switching people never rebuilds the TabView.
            content
                .tabViewBottomAccessory(isEnabled: enabled) { DemoPlayer(compact: true) }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else if #available(iOS 26.0, *), enabled {
            content
                .tabViewBottomAccessory { DemoPlayer(compact: true) }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

extension View {
    /// Pre-iOS 26 fallback: a floating glass player pinned above the tab bar.
    @ViewBuilder
    func demoInset(_ enabled: Bool) -> some View {
        if #available(iOS 26.0, *) { self }
        else if enabled {
            self.safeAreaInset(edge: .bottom) { DemoPlayer(compact: false).padding(.horizontal, 16).padding(.bottom, 6) }
        } else { self }
    }
}

/// Toolbar shared by the primary screens: avatar (profile, sources, settings) on the trailing edge.
struct ProfileToolbar: ToolbarContent {
    @ObservedObject var app: AppState
    @Binding var showProfile: Bool
    var showAdd = false
    var body: some ToolbarContent {
        if showAdd {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { app.showCheckIn = true } label: { Label("Daily check-in", systemImage: "checklist") }
                    Button { app.manualMetric = nil; app.showManualEntry = true } label: { Label("Add a measurement", systemImage: "plus.circle") }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Log")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showProfile = true } label: {
                Text(String(app.person?.displayName.prefix(1) ?? "?"))
                    .font(.headline)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Profile, data sources and settings")
        }
    }
}

// MARK: - Demo player (mission simulator)

struct DemoPlayer: View {
    @ObservedObject var sim = MissionSimulator.shared
    var compact: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").font(.subheadline.weight(.semibold)).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mission day \(sim.simDay + 1)").font(.subheadline.weight(.semibold))
                Text(sim.autoPausedReason != nil ? "Paused for an alert" : (sim.running ? "Playing · \(sim.speed.label)" : "Demo mission"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                Picker("Speed", selection: $sim.speed) { ForEach(MissionSimulator.Speed.allCases) { Text($0.label).tag($0) } }
                Section("Jump to") {
                    Button("Day 27 · short sleep") { sim.jump(toDay: 26) }
                    Button("Day 44 · heart strain") { sim.jump(toDay: 43) }
                    Button("Day 60 · radiation event") { sim.jump(toDay: 59) }
                    Button("Day 95 · isolation") { sim.jump(toDay: 94) }
                    Button("Day 122 · exercise lapse") { sim.jump(toDay: 121) }
                }
                Section("Trigger now") {
                    Button { sim.inject("spike") } label: { Label("Radiation spike", systemImage: "atom") }
                    Button { sim.inject("short_sleep") } label: { Label("Short sleep", systemImage: "bed.double") }
                    Button { sim.inject("mood_dip") } label: { Label("Mood dip", systemImage: "cloud.rain") }
                }
                Button("Restart mission", role: .destructive) { sim.restart() }
            } label: {
                Image(systemName: "forward.fill").font(.body.weight(.semibold)).frame(width: 36, height: 36)
            }
            .accessibilityLabel("Demo options")
            Button { sim.running ? sim.pause() : sim.play() } label: {
                Image(systemName: sim.running ? "pause.fill" : "play.fill").font(.title3.weight(.semibold)).frame(width: 36, height: 36)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(sim.running ? "Pause demo" : "Play demo")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 14 : 16)
        .padding(.vertical, compact ? 0 : 10)
        .modifier(PlayerGlass(compact: compact))
    }
}

private struct PlayerGlass: ViewModifier {
    let compact: Bool
    func body(content: Content) -> some View {
        if compact { content } else { content.glassCapsule() }
    }
}

// MARK: - Profile sheet (replaces the old "More" tab)

struct ProfileView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @ObservedObject var hk = HealthSync.shared
    @ObservedObject var hub = CrewHubLink.shared

    /// "Built from 3 years of Apple Health · 412,880 records": the profile starts from everything already imported.
    private var profileLine: String {
        guard let p = app.person, let r = try? app.hub.repo.db.query("SELECT COUNT(*), MIN(ts) FROM observations WHERE person_id=?", [.text(p.id)]).first,
              let n = r.int(0), n > 0, let first = r.double(1) else { return app.mission.map { $0.name } ?? "" }
        let days = Int(Date().timeIntervalSince1970 - first) / 86400
        let span = days >= 730 ? "\(days / 365) years" : (days >= 60 ? "\(days / 30) months" : "\(max(days, 1)) days")
        let source = p.isHealthKitOwner ? "Apple Health" : "data"
        return "Built from \(span) of \(source) · \(n.formatted()) records"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 6) {
                        Text(String(app.person?.displayName.prefix(1) ?? "?"))
                            .font(.system(size: 36, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 84, height: 84)
                            .background(Circle().fill(Color.indigo.gradient))
                        Text(app.person?.displayName ?? "—").font(.title2.bold())
                        Text(profileLine).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    if app.persons.count > 1 {
                        Picker("Viewing", selection: Binding(get: { app.currentPersonId ?? "" }, set: { app.select(person: $0) })) {
                            ForEach(app.persons) { p in
                                Text(p.isHealthKitOwner ? "\(p.displayName) (me)" : p.displayName).tag(p.id)
                            }
                        }
                    }
                }
                Section {
                    NavigationLink { DataView() } label: {
                        HStack {
                            Label { Text("Data") } icon: { IconTile(symbol: "heart.text.square.fill", color: .pink, size: 29) }
                            Spacer()
                            if app.settings.hkEnabled { Text(hk.isObserving ? "Live" : "On").foregroundStyle(.green) }
                        }
                    }
                    NavigationLink { CrewHubView() } label: {
                        HStack {
                            Label { Text("Helios Hub") } icon: { Image("HeliosMark").resizable().scaledToFit().foregroundStyle(.white).padding(5).frame(width: 29, height: 29).background(RoundedRectangle(cornerRadius: 7).fill(.black)) }
                            Spacer()
                            if hub.state == .connected { Text("Live").foregroundStyle(.green) }
                        }
                    }
                    NavigationLink { NotificationsView() } label: { Label { Text("Notifications") } icon: { IconTile(symbol: "bell.badge.fill", color: .red, size: 29) } }
                    NavigationLink { SimulatorPanel() } label: { Label { Text("Demo mission") } icon: { IconTile(symbol: "sparkles", color: .cyan, size: 29) } }
                }
                Section("Care") {
                    NavigationLink { GuidanceView() } label: { Label { Text("Guidance") } icon: { IconTile(symbol: "lightbulb.fill", color: .yellow, size: 29) } }
                    NavigationLink { QuestsView() } label: { Label { Text("Quests") } icon: { IconTile(symbol: "trophy.fill", color: .orange, size: 29) } }
                    NavigationLink { CrewView() } label: { Label { Text("Crew") } icon: { IconTile(symbol: "person.3.fill", color: .indigo, size: 29) } }
                    NavigationLink { ExportView() } label: { Label { Text("Share with flight surgeon") } icon: { IconTile(symbol: "square.and.arrow.up", color: .green, size: 29) } }
                }
                Section {
                    NavigationLink { SettingsView() } label: { Label { Text("Settings") } icon: { IconTile(symbol: "gearshape.fill", color: .gray, size: 29) } }
                    NavigationLink { AboutView() } label: { Label { Text("About") } icon: { IconTile(symbol: "info.circle.fill", color: .gray, size: 29) } }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Escalation (full screen, sticky until acknowledged)

struct EscalationSheetItem: Identifiable { let item: EscalationItem; var id: String { item.key } }

struct AlertView: View {
    @EnvironmentObject var app: AppState
    let item: EscalationItem
    @State private var note = ""
    @State private var showContact = false

    private var isRadiation: Bool { item.key.hasPrefix("radiation") }

    var body: some View {
        ZStack {
            AmbientBackground(colors: [.red, .orange]).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: isRadiation ? "atom" : "cross.case.fill")
                        .font(.system(size: 42, weight: .semibold)).foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                        .frame(width: 88, height: 88).glassCircle(tint: .red)
                        .padding(.top, 40)
                    Text(isRadiation ? "RADIATION EVENT" : "NEEDS ATTENTION").font(.footnote.weight(.bold)).tracking(0.6).foregroundStyle(.red)
                    Text(isRadiation ? "Move to the shelter" : "Contact your flight surgeon")
                        .font(.largeTitle.bold()).multilineTextAlignment(.center)
                    Text(item.text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 8)

                    if isRadiation, let r = app.snapshot?.radiation {
                        HStack(spacing: 10) {
                            stat(RadiationEngine.f3(r.smoothed ?? 0), "µSv/h now", .red)
                            stat(r.background.map { "\(Int(((r.smoothed ?? 0) / max($0, 1e-6)).rounded()))×" } ?? "–", "background", .white)
                            stat(r.activeEvent.map { "\(Int(Date(timeIntervalSince1970: app.snapshot?.asOf.timeIntervalSince1970 ?? 0).timeIntervalSince($0.start) / 60)) min" } ?? "–", "elapsed", .white)
                        }
                    }

                    if isRadiation, let pb = app.config.guidance.playbooks["radiation_event"] {
                        GlassList {
                            ForEach(Array(pb.steps.prefix(4).enumerated()), id: \.offset) { i, s in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text("\(i + 1)").font(.footnote.bold()).foregroundStyle(.red)
                                        .frame(width: 24, height: 24).background(Circle().fill(.red.opacity(0.2)))
                                    Text(s.cleanedStep).font(.subheadline)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                if i < min(pb.steps.count, 4) - 1 { GlassDivider(inset: 52) }
                            }
                        }
                    }

                    TextField("Optional note — who you contacted, when", text: $note)
                        .padding(14).glassSurface(18)

                    VStack(spacing: 10) {
                        Button { showContact = true } label: {
                            Label("Contact flight surgeon", systemImage: "phone.fill").font(.headline).frame(maxWidth: .infinity).frame(height: 44)
                        }
                        .glassButton(prominent: true, tint: .red)
                        Button {
                            if let pid = app.currentPersonId { app.hub.acknowledge(item, personId: pid, note: note) }
                        } label: {
                            Text("I’ve reported this").font(.headline).frame(maxWidth: .infinity).frame(height: 44)
                        }
                        .glassButton()
                    }
                    .padding(.bottom, 30)
                }
                .padding(.horizontal, 20)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .alert("How to reach them", isPresented: $showContact) { Button("OK") {} } message: {
            Text(app.settings.escalationContact.isEmpty ? app.config.s("escalation.contact.default") : app.settings.escalationContact)
        }
    }

    private func stat(_ v: String, _ l: String, _ c: Color) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title2.bold()).foregroundStyle(c).monospacedDigit()
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12).glassSurface(20)
    }
}
