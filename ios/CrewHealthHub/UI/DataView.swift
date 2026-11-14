import SwiftUI
import UniformTypeIdentifiers

/// One place for everything data: live Apple Health, importing your Health export, devices and files.
struct DataView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var hk = HealthSync.shared
    @ObservedObject var importer = HealthFileImport.shared
    @ObservedObject var seeder = HealthSeeder.shared
    @ObservedObject var radio = RadiationBridge.shared
    @State private var picking = false
    @State private var connecting = false
    @State private var error: String?
    @State private var confirmDisconnect = false

    private var simulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        List {
            // Helios Hub (Raspberry Pi)
            Section {
                NavigationLink { CrewHubView() } label: { CrewHubRow() }
            }

            // Live Apple Health
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "heart.fill").font(.title2).foregroundStyle(.pink)
                        .frame(width: 48, height: 48).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Apple Health").font(.headline)
                        Text(liveStatus).font(.subheadline).foregroundStyle(app.settings.hkEnabled && hk.isObserving ? .green : .secondary)
                    }
                }
                .padding(.vertical, 4)
                if app.settings.hkEnabled {
                    Button { Task { await hk.syncAll(reason: "manual") } } label: {
                        Label(hk.isSyncing ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(hk.isSyncing)
                } else {
                    Button { Task { await connect() } } label: { Label(connecting ? "Connecting…" : "Connect Apple Health", systemImage: "link") }
                        .disabled(connecting)
                }
            } footer: {
                Text(simulator
                     ? "The simulator has its own empty Health store. To see your real data here, import your Health export below."
                     : "Reads your iPhone and Apple Watch data on this device and keeps it up to date in the background.")
            }

            // Personal export
            Section {
                switch importer.phase {
                case .idle:
                    Button { picking = true } label: { Label("Import Health export…", systemImage: "square.and.arrow.down") }
                case .unzipping(let p):
                    progressRow("Unpacking export…", p)
                case .reading(let seen, let kept):
                    HStack {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text("Reading your records…")
                            Text("\(seen.formatted()) read · \(kept.formatted()) kept").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        Button("Cancel", role: .cancel) { importer.cancel() }.font(.footnote)
                    }
                case .done(let seen, let stored, let types, let from, let to):
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Imported", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                        Text("\(stored.formatted()) readings across \(types) types from \(seen.formatted()) records.").font(.subheadline)
                        if let from, let to { Text("\(from.formatted(date: .abbreviated, time: .omitted)) – \(to.formatted(date: .abbreviated, time: .omitted))").font(.footnote).foregroundStyle(.secondary) }
                    }
                    Button("Import another file") { importer.reset(); picking = true }
                case .failed(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline)
                    Button("Try again") { importer.reset(); picking = true }
                }
                Picker("History", selection: $importer.historyDays) { Text("Last year").tag(365); Text("Last 2 years").tag(730); Text("Everything").tag(3650) }
                    .disabled(importer.isBusy)
            } header: { Text("Your Health export") } footer: {
                Text("On your iPhone: Health › your picture › Export All Health Data, then AirDrop or save the file and open it here. Both export.zip and export.xml work. It stays on your iPhone and your Helios Hub.")
            }

            // Devices & files
            Section("Devices and files") {
                NavigationLink { RadiationSourceView() } label: {
                    HStack {
                        Label { Text("Radiation detector") } icon: { IconTile(symbol: "atom", color: .yellow, size: 29) }
                        Spacer()
                        if radio.state.isLive { Text("Live").foregroundStyle(.green) }
                    }
                }
                NavigationLink { FileImportView() } label: { Label { Text("Spreadsheet or JSON file") } icon: { IconTile(symbol: "tablecells", color: .green, size: 29) } }
                Button { app.manualMetric = nil; app.showManualEntry = true } label: {
                    Label { Text("Add a measurement").foregroundStyle(.primary) } icon: { IconTile(symbol: "plus", color: .blue, size: 29) }
                }
            }

            Section { DisclosureGroup("Data on this iPhone") { InventoryList() } }

            // Advanced
            Section {
                DisclosureGroup("Advanced") {
                    if app.settings.hkEnabled {
                        Toggle("Save my measurements to Health", isOn: Binding(get: { app.settings.hkWriteBack }, set: { v in app.saveSettings { $0.hkWriteBack = v } }))
                        Picker("Live sync history", selection: Binding(get: { app.settings.hkHistoryDays }, set: { v in
                            let grew = v > app.settings.hkHistoryDays
                            app.saveSettings { $0.hkHistoryDays = v }
                            if grew { Task { await hk.reanchorAll(reason: "history window extended") } }
                        })) { Text("1 year").tag(365); Text("2 years").tag(730); Text("Everything").tag(3650) }
                        NavigationLink("Data types and sync log") { HealthTypesView() }
                        Button("Disconnect Apple Health", role: .destructive) { confirmDisconnect = true }
                    }
                    if let b = UserDefaults.standard.string(forKey: "ui.lastImportBatch") {
                        Button("Remove last imported file", role: .destructive) {
                            _ = app.hub.undoImport(batchId: b); UserDefaults.standard.removeObject(forKey: "ui.lastImportBatch"); importer.reset()
                        }
                    }
                    if simulator && app.settings.hkEnabled {
                        Button(seeder.busy ? "Writing…" : "Add sample data to the simulator's Health") { Task { _ = try? await seeder.seedHistory() } }
                        Button(seeder.liveRunning ? "Stop live heart-rate stream" : "Stream live heart rate") { seeder.liveRunning ? seeder.stopLive() : seeder.startLive() }
                    }
                }
            }
        }
        .navigationTitle("Data")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .xml, UTType(filenameExtension: "xml") ?? .xml]) { r in
            if case let .success(url) = r { importer.start(url: url, app: app) }
        }
        .alert("Apple Health", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
        .confirmationDialog("Stop reading Apple Health?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { hk.stop(); app.saveSettings { $0.hkEnabled = false } }
        } message: { Text("Data already here stays. You can reconnect any time.") }
    }

    private var liveStatus: String {
        guard app.settings.hkEnabled else { return "Not connected" }
        if hk.isSyncing { return "Syncing…" }
        let n = hk.status.values.reduce(0) { $0 + $1.total }
        return hk.isObserving ? "Live · \(n.formatted()) readings" : "Connected"
    }

    private func progressRow(_ t: String, _ p: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(t); Spacer(); Button("Cancel", role: .cancel) { importer.cancel() }.font(.footnote) }
            ProgressView(value: p)
        }
    }

    private func connect() async {
        connecting = true; defer { connecting = false }
        let me = HealthConnect.ensureOwner(app: app)
        do {
            try await hk.requestAuthorization()
            app.saveSettings { $0.hkEnabled = true }
            hk.start(reason: "connected")
            app.select(person: me.id)
        } catch { self.error = error.localizedDescription }
    }
}

/// Per-type counts, background-delivery state and the live sync log (advanced).
struct HealthTypesView: View {
    @ObservedObject var hk = HealthSync.shared
    var body: some View {
        List {
            Section {
                ForEach(HKCatalog.all) { spec in
                    let st = hk.status[spec.id]
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.label)
                            Text(st?.lastSync == nil ? "Waiting" : ((st?.total ?? 0) == 0 ? "No data (or not allowed)" : "Synced \(relativeText(st?.lastSync))"))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(st?.total ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: st?.backgroundDelivery == true ? "bell.badge.fill" : "bell.slash").foregroundStyle(st?.backgroundDelivery == true ? .green : .secondary)
                    }
                }
            } footer: { Text("iOS doesn't tell apps when read access is denied, so a type with no data may simply be off in Settings › Health › Data Access.") }
            Section("Sync log") {
                ForEach(hk.log.prefix(50)) { l in
                    VStack(alignment: .leading, spacing: 2) { Text(l.text).font(.footnote); Text(l.ts.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Data types")
    }
}

/// Shown when a Health export is opened from Files, AirDrop or Mail.
struct ImportProgressView: View {
    @ObservedObject var importer = HealthFileImport.shared
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 54)).foregroundStyle(color).symbolEffect(.pulse, isActive: importer.isBusy)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).monospacedDigit()
            if case .unzipping(let p) = importer.phase { ProgressView(value: p).padding(.horizontal, 30) }
            Button(importer.isBusy ? "Cancel" : "Done") { if importer.isBusy { importer.cancel() } else { importer.reset(); dismiss() } }
                .font(.headline).glassButton(prominent: !importer.isBusy)
        }
        .padding(28)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(importer.isBusy)
    }
    private var icon: String {
        switch importer.phase { case .done: return "checkmark.circle.fill"; case .failed: return "exclamationmark.triangle.fill"; default: return "heart.text.square.fill" }
    }
    private var color: Color {
        switch importer.phase { case .done: return .green; case .failed: return .orange; default: return .pink }
    }
    private var title: String {
        switch importer.phase {
        case .idle: return "Ready"
        case .unzipping: return "Unpacking your Health export"
        case .reading: return "Reading your records"
        case .done: return "Your data is in"
        case .failed: return "Couldn't import"
        }
    }
    private var detail: String {
        switch importer.phase {
        case .idle: return ""
        case .unzipping(let p): return "\(Int(p * 100))%"
        case .reading(let seen, let kept): return "\(seen.formatted()) records read · \(kept.formatted()) kept"
        case .done(_, let stored, let types, _, _): return "\(stored.formatted()) readings across \(types) types. Your baselines are building now."
        case .failed(let m): return m
        }
    }
}
