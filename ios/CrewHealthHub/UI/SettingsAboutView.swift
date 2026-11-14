import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var confirmText = ""
    @State private var showDelete = false
    @State private var rebuilding: Double?
    @State private var exportURL: URL?
    @State private var budgetText = ""

    var body: some View {
        Form {
            if var p = app.person {
                Section("You") {
                    TextField("Name", text: Binding(get: { p.displayName }, set: { p.displayName = $0; app.hub.save(p); app.reloadPersons() }))
                    Picker("Temperature", selection: Binding(get: { p.units.temp }, set: { p.units.temp = $0; app.hub.save(p); app.reloadPersons() })) { Text("°C").tag("C"); Text("°F").tag("F") }
                    Picker("Glucose", selection: Binding(get: { p.units.glucose }, set: { p.units.glucose = $0; app.hub.save(p); app.reloadPersons() })) { Text("mg/dL").tag("mg/dL"); Text("mmol/L").tag("mmol/L") }
                    Picker("Weight", selection: Binding(get: { p.units.weight }, set: { p.units.weight = $0; app.hub.save(p); app.reloadPersons() })) { Text("kg").tag("kg"); Text("lb").tag("lb") }
                }
            }
            if var m = app.mission {
                Section("Mission") {
                    TextField("Mission name", text: Binding(get: { m.name }, set: { m.name = $0; app.hub.save(m); app.refresh() }))
                    Picker("Environment", selection: Binding(get: { m.environment }, set: { m.environment = $0; app.hub.save(m); app.refresh() })) {
                        ForEach(app.config.environments) { Label($0.label, systemImage: $0.icon).tag($0.id) }
                    }
                    Stepper("Length: \(m.plannedDays) days", value: Binding(get: { m.plannedDays }, set: { m.plannedDays = $0; app.hub.save(m); app.refresh() }), in: 7...1000, step: 7)
                    HStack {
                        TextField("Radiation dose budget (µSv)", text: $budgetText).keyboardType(.decimalPad)
                        Button("Save") { m.radiationBudget.total_uSv = Double(budgetText); app.hub.save(m); app.refresh() }.disabled(budgetText.isEmpty)
                    }
                }
                .onAppear { budgetText = m.radiationBudget.total_uSv.map { String(format: "%g", $0) } ?? "" }
            }
            Section {
                TextField(app.config.s("escalation.contact.default"), text: Binding(get: { app.settings.escalationContact }, set: { v in app.saveSettings { $0.escalationContact = v } }), axis: .vertical)
                Toggle("Measurement reminders", isOn: Binding(get: { app.settings.notificationsEnabled }, set: { v in
                    app.saveSettings { $0.notificationsEnabled = v }
                    if v { Task { let ok = await NotificationRouter.shared.requestAndSchedule(environment: app.mission?.environment ?? "station"); if !ok { app.saveSettings { $0.notificationsEnabled = false } } } }
                    else { NotificationRouter.shared.cancelAll() }
                }))
            } header: { Text("Alerts") } footer: { Text("Shown whenever something needs the flight surgeon.") }

            Section("Your data") {
                Button("Export all data") {
                    if let d = try? app.hub.repo.exportAll() {
                        let u = FileManager.default.temporaryDirectory.appendingPathComponent("crew-health-export.json")
                        try? d.write(to: u); exportURL = u
                    }
                }
                if let u = exportURL { ShareLink(item: u) { Label("Share export", systemImage: "square.and.arrow.up") } }
                Button("Delete all data", role: .destructive) { showDelete = true }
            }

            Section {
                DisclosureGroup("Advanced") {
                    let e = app.settings.engine ?? app.config.ranges.engine
                    stepper("Watch at", e.watchZ, 1...5, 0.5) { v in var x = e; x.watchZ = v; return x }
                    stepper("Act at", e.actZ, 1.5...6, 0.5) { v in var x = e; x.actZ = v; return x }
                    stepper("Baseline window", Double(e.windowDays), 7...60, 1) { v in var x = e; x.windowDays = Int(v); return x }
                    Button("Reset sensitivity") { app.saveSettings { $0.engine = nil }; app.hub.refreshAll() }
                    if let r = rebuilding { ProgressView("Rebuilding…", value: r) }
                    Button("Rebuild from raw data") {
                        guard let pid = app.currentPersonId else { return }
                        rebuilding = 0
                        DispatchQueue.global().async {
                            app.hub.rebuild(person: pid) { v in DispatchQueue.main.async { rebuilding = v } }
                            DispatchQueue.main.async { rebuilding = nil }
                        }
                    }
                    Toggle("Pause demo on alerts", isOn: Binding(get: { app.settings.autoPauseOnEscalate }, set: { v in app.saveSettings { $0.autoPauseOnEscalate = v } }))
                    Toggle("Developer mode", isOn: Binding(get: { app.settings.devMode }, set: { v in app.saveSettings { $0.devMode = v } }))
                }
            } footer: { Text("Sensitivity values are engineering defaults, not clinical thresholds.") }
        }
        .navigationTitle("Settings")
        .alert("Delete all data?", isPresented: $showDelete) {
            TextField("Type DELETE", text: $confirmText)
            Button("Delete everything", role: .destructive) {
                guard confirmText == "DELETE" else { return }
                MissionSimulator.shared.pause(); HealthSync.shared.stop(); RadiationBridge.shared.disconnect()
                app.hub.deleteEverything()
                app.saveSettings { $0 = AppSettings() }
                app.reloadPersons(); app.pull()
                confirmText = ""
            }
            Button("Cancel", role: .cancel) { confirmText = "" }
        } message: { Text("This permanently removes everything stored in this app on this iPhone. Apple Health is not touched. Type DELETE to confirm.") }
    }

    private func stepper(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ step: Double, _ f: @escaping (Double) -> EngineParams) -> some View {
        Stepper("\(label): \(String(format: step < 1 ? "%.1f" : "%.0f", value))", value: Binding(get: { value }, set: { v in app.saveSettings { $0.engine = f(v) }; app.hub.refreshAll() }), in: range, step: step)
    }
}

struct AboutView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image("HeliosMark").resizable().scaledToFit().foregroundStyle(.white).padding(14)
                        .frame(width: 96, height: 80).background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black))
                    Text("Helios").font(.title2.bold())
                    Text(app.config.s("app.tagline")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("Version \(SummaryBuilder.version)").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            Section("How it works") {
                Label("Learns your own normal from about a week of data", systemImage: "person.fill.checkmark")
                Label("Flags changes that last or trend, not one-off readings", systemImage: "chart.line.uptrend.xyaxis")
                Label("Explains every status in plain language", systemImage: "text.bubble")
                Label("Your data stays on your iPhone and your Helios Hub", systemImage: "lock.fill")
            }
            Section("Sources") {
                Text("NASA Human Research Program — Five Hazards of Human Spaceflight").font(.subheadline)
                Text("Canadian Space Agency — Monitoring Radiation for Astronaut Health").font(.subheadline)
                Text("Apple HealthKit").font(.subheadline)
            }
            Section {
                NavigationLink("Hardware roadmap") { HardwareRoadmapView() }
            } footer: { Text("Built for the NASA Space Apps Challenge 2026. MIT licence. Apple frameworks only.") }
        }
        .navigationTitle("About")
    }
}

/// Appendix A — documentation only (no hardware is implemented).
struct HardwareRoadmapView: View {
    var body: some View {
        List {
            Section { Text("A compact station for a habitat or rover that bundles the measurements this app already understands. Each module would plug into the existing adapters.").font(.subheadline) }
            Section("Modules") {
                Label("Compute hub with touchscreen", systemImage: "cpu")
                Label("Vitals bay: blood pressure, oximeter, thermometer, glucometer", systemImage: "heart.text.square")
                Label("Personal dosimetry dock", systemImage: "atom")
                Label("Wearable dock (no cloud)", systemImage: "applewatch")
                Label("Cabin air node: CO₂, temperature, humidity", systemImage: "aqi.medium")
                Label("NFC crew badges and status light", systemImage: "person.badge.key")
            }
            Section("Phases") {
                Text("Now — software, adapters and one real radiation detector").font(.subheadline)
                Text("Next — commercial Bluetooth medical devices and wearable docks").font(.subheadline)
                Text("Later — flight-qualified hardware and clinical validation").font(.subheadline)
            }
        }
        .navigationTitle("Hardware roadmap")
    }
}
