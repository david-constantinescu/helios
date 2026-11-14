import SwiftUI
import UniformTypeIdentifiers

struct SourceChip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }
}

struct InventoryList: View {
    @EnvironmentObject var app: AppState
    @State private var rows: [Repository.InventoryRow] = []
    @State private var rejected: [Repository.RejectedRow] = []
    var body: some View {
        Group {
            if rows.isEmpty { Text(app.config.s("empty.sources")).font(.caption).foregroundStyle(Color.dim) }
            ForEach(rows, id: \.metric) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(app.config.metric(r.metric)?.label ?? r.metric).font(.subheadline); Spacer(); Text("\(r.count)").monospacedDigit() }
                    Text("\(r.first.formatted(date: .abbreviated, time: .omitted)) – \(r.last.formatted(date: .abbreviated, time: .omitted)) · \(r.sources)\(r.suspect > 0 ? " · \(r.suspect) suspect" : "")")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
            }
            if !rejected.isEmpty {
                DisclosureGroup("Rejected by quality checks (\(rejected.count))") {
                    ForEach(rejected, id: \.self) { r in
                        Text("\(r.ts.formatted(date: .abbreviated, time: .shortened)) · \(r.metric) \(String(format: "%g", r.value)) \(r.unit) — \(r.reason)").font(.caption2)
                    }
                }.font(.caption)
            }
        }
        .onAppear(perform: load)
        .onChange(of: app.snapshot?.computedAt) { _, _ in load() }
    }
    private func load() {
        guard let p = app.currentPersonId else { return }
        rows = (try? app.hub.repo.inventory(person: p)) ?? []
        rejected = (try? app.hub.repo.rejected(person: p, limit: 50)) ?? []
    }
}

// MARK: - Simulator panel

struct SimulatorPanel: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var sim = MissionSimulator.shared
    @State private var scenario = "full_mission"
    @State private var seed = 42
    @State private var jumpDay = 60.0

    var body: some View {
        Form {
            Section {
                Text("A ready-made 180-day mission with David to explore every part of the app.").font(.subheadline).foregroundStyle(.secondary)
            }
            Section("New demo mission") {
                Picker("Scenario", selection: $scenario) { ForEach(MissionSimulator.scenarios, id: \.id) { Text($0.label).tag($0.id) } }
                Stepper("Seed: \(seed)", value: $seed, in: 1...9999)
                Button(sim.config == nil ? "Create demo mission" : "Replace with new mission") {
                    sim.setup(scenario: scenario, seed: UInt32(seed), environment: app.mission?.environment ?? "station")
                    app.reloadPersons()
                    if let id = sim.config?.personIds.first { app.select(person: id) }
                }
            }
            if let c = sim.config {
                Section("Playback · day \(sim.simDay + 1) of \(c.days)") {
                    HStack {
                        Button { sim.running ? sim.pause() : sim.play() } label: { Label(sim.running ? "Pause" : "Play", systemImage: sim.running ? "pause.fill" : "play.fill") }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        if sim.busy { ProgressView() }
                    }
                    Picker("Speed", selection: $sim.speed) { ForEach(MissionSimulator.Speed.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                    if let r = sim.autoPausedReason { Text(r).font(.caption).foregroundStyle(Color.escalate) }
                    Toggle("Auto-pause on escalation", isOn: Binding(get: { app.settings.autoPauseOnEscalate }, set: { v in app.saveSettings { $0.autoPauseOnEscalate = v } }))
                    VStack(alignment: .leading) {
                        Text("Jump to day \(Int(jumpDay))")
                        Slider(value: $jumpDay, in: 1...Double(c.days), step: 1)
                        Button("Jump") { sim.jump(toDay: Int(jumpDay)) }.disabled(Int(jumpDay) <= sim.simDay)
                    }
                    Button("Restart from day 0") { sim.restart() }
                }
                Section("Inject event now") {
                    Button("Radiation spike") { sim.inject("spike") }
                    Button("Short sleep (3 nights)") { sim.inject("short_sleep") }
                    Button("Mood dip (5 days)") { sim.inject("mood_dip") }
                }
                Section { Button("Remove demo mission", role: .destructive) { sim.remove(); app.reloadPersons(); app.pull() } }
            }
        }
        .navigationTitle("Demo mission")
    }
}

// MARK: - File import (CSV / JSON / Apple Health export.xml)

struct FileImportView: View {
    @EnvironmentObject var app: AppState
    @State private var picking = false
    @State private var table: CSVTable?
    @State private var mapping = ColumnMapping()
    @State private var preset = "auto"
    @State private var preview: CSVImporter.Preview?
    @State private var fileName = ""
    @State private var message: String?
    @State private var lastBatch: String? = UserDefaults.standard.string(forKey: "ui.lastImportBatch")   // UI pref only, not health data
    @State private var xmlProgress: String?
    @State private var xmlImporter: AppleHealthXMLImporter?
    @State private var historyDays = 365

    var body: some View {
        Form {
            Section {
                Text(app.config.s("import.privacy")).font(.caption)
                Button { picking = true } label: { Label("Choose file…", systemImage: "folder") }
                Text("CSV/TSV, the app's JSON, or Apple Health export.xml. For an Apple Health .zip, tap it in Files to expand it first, then pick export.xml.").font(.caption2).foregroundStyle(Color.dim)
            }
            if let t = table {
                Section("Mapping · \(fileName)") {
                    Picker("Preset", selection: $preset) { ForEach(CSVImporter.presets) { Text($0.label).tag($0.id) } }
                    Text(CSVImporter.presets.first { $0.id == preset }?.note ?? "").font(.caption2).foregroundStyle(Color.dim)
                    Picker("Format", selection: $mapping.format) { Text("Wide (one column per metric)").tag(ColumnMapping.Format.wide); Text("Long (metric/value)").tag(ColumnMapping.Format.long) }
                    Picker("Timestamp column", selection: Binding(get: { mapping.tsColumn ?? -1 }, set: { mapping.tsColumn = $0 < 0 ? nil : $0 })) {
                        Text("—").tag(-1); ForEach(t.headers.indices, id: \.self) { Text(t.headers[$0]).tag($0) }
                    }
                    Picker("Time zone", selection: Binding(get: { mapping.timeZone.identifier }, set: { mapping.timeZone = TimeZone(identifier: $0) ?? .current })) {
                        ForEach([TimeZone.current.identifier, "UTC"], id: \.self) { Text($0).tag($0) }
                    }
                    if mapping.format == .wide {
                        ForEach(t.headers.indices, id: \.self) { i in
                            if i != mapping.tsColumn { columnPicker(t, i) }
                        }
                    } else {
                        Picker("Metric column", selection: Binding(get: { mapping.metricColumn ?? -1 }, set: { mapping.metricColumn = $0 < 0 ? nil : $0 })) { Text("—").tag(-1); ForEach(t.headers.indices, id: \.self) { Text(t.headers[$0]).tag($0) } }
                        Picker("Value column", selection: Binding(get: { mapping.valueColumn ?? -1 }, set: { mapping.valueColumn = $0 < 0 ? nil : $0 })) { Text("—").tag(-1); ForEach(t.headers.indices, id: \.self) { Text(t.headers[$0]).tag($0) } }
                        Picker("Unit column", selection: Binding(get: { mapping.unitColumn ?? -1 }, set: { mapping.unitColumn = $0 < 0 ? nil : $0 })) { Text("—").tag(-1); ForEach(t.headers.indices, id: \.self) { Text(t.headers[$0]).tag($0) } }
                    }
                    Button("Preview") { runPreview() }
                }
                Section("First rows") {
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.headers.joined(separator: " | ")).font(.caption2.bold().monospaced())
                            ForEach(Array(t.rows.prefix(20).enumerated()), id: \.offset) { _, r in Text(r.joined(separator: " | ")).font(.caption2.monospaced()) }
                        }
                    }
                }
            }
            if let p = preview {
                Section("Validation summary") {
                    LabeledValue(label: "Observations ready", value: "\(p.raws.count)")
                    LabeledValue(label: "Rows skipped", value: "\(p.skipped)")
                    let byMetric = Dictionary(grouping: p.raws, by: \.metric).mapValues(\.count)
                    ForEach(byMetric.sorted { $0.key < $1.key }, id: \.key) { k, v in LabeledValue(label: app.config.metric(k)?.label ?? k, value: "\(v)") }
                    ForEach(p.errors, id: \.self) { Text($0).font(.caption2).foregroundStyle(Color.watch) }
                    Button("Import \(p.raws.count) observations") { commit(p) }.disabled(p.raws.isEmpty).buttonStyle(.borderedProminent)
                }
            }
            if let xmlProgress {
                Section("Apple Health export") {
                    Text(xmlProgress).font(.caption)
                    if xmlImporter != nil { Button("Cancel", role: .destructive) { xmlImporter?.cancelled = true } }
                }
            }
            if let message { Section { Text(message) } }
            if let b = lastBatch {
                Section { Button("Undo last import", role: .destructive) {
                    let n = app.hub.undoImport(batchId: b)
                    message = "Removed \(n) imported observations."
                    lastBatch = nil; UserDefaults.standard.removeObject(forKey: "ui.lastImportBatch")
                } }
            }
            Section("Apple Health export options") {
                Stepper("Import last \(historyDays) days", value: $historyDays, in: 30...3650, step: 30)
            }
        }
        .navigationTitle("Spreadsheet import")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .json, .xml, .zip, .plainText, .data]) { r in
            if case let .success(url) = r { open(url) }
        }
        .onChange(of: preset) { _, _ in if let t = table { mapping = CSVImporter.autoDetect(t); preview = nil } }
    }

    private func wideBinding(_ t: CSVTable, _ i: Int) -> Binding<String> {
        Binding(get: { mapping.wide[i]?.metric ?? "" }, set: { v in
            if v.isEmpty { mapping.wide[i] = nil; return }
            var unit = app.config.metric(v)?.unit ?? ""
            if let m = CSVImporter.match(header: t.headers[i]), m.0 == v { unit = m.1 }
            mapping.wide[i] = ColumnMapping.WideColumn(metric: v, unit: unit)
        })
    }

    private func columnPicker(_ t: CSVTable, _ i: Int) -> some View {
        Picker(t.headers[i], selection: wideBinding(t, i)) {
            Text("Ignore").tag("")
            ForEach(app.config.metrics) { m in Text(m.label).tag(m.id) }
        }
        .font(.caption)
    }

    private func open(_ url: URL) {
        message = nil; preview = nil; table = nil; xmlProgress = nil
        fileName = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        let ext = url.pathExtension.lowercased()
        guard let p = app.person else { return }
        let batch = "import-\(newId().prefix(8))"
        if ext == "xml" || ext == "zip" {
            // Apple Health exports go through the dedicated importer (zip support, step de-duplication).
            if scoped { url.stopAccessingSecurityScopedResource() }
            HealthFileImport.shared.start(url: url, app: app)
            app.showImport = true
            return
        }
        if false {
            // Copy to a temp location so the streaming parse can run in the background.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.copyItem(at: url, to: tmp)
            if scoped { url.stopAccessingSecurityScopedResource() }
            let since = Date().addingTimeInterval(-Double(historyDays) * 86400)
            let imp = AppleHealthXMLImporter(person: p, since: since, batchId: batch) { s in
                DispatchQueue.main.async { xmlProgress = "Records seen \(s.recordsSeen) · kept \(s.recordsKept) · stored \(s.inserted)" }
            }
            xmlImporter = imp
            xmlProgress = "Reading \(url.lastPathComponent)…"
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let s = try imp.run(url: tmp)
                    DispatchQueue.main.async {
                        xmlImporter = nil
                        xmlProgress = "Done: \(s.recordsSeen) records seen, \(s.recordsKept) kept, \(s.inserted) new observations, \(s.rejected) rejected."
                        lastBatch = batch; UserDefaults.standard.set(batch, forKey: "ui.lastImportBatch")
                    }
                } catch {
                    DispatchQueue.main.async { xmlImporter = nil; xmlProgress = nil; message = app.config.s("error.file") + " (\(error.localizedDescription))" }
                }
                try? FileManager.default.removeItem(at: tmp)
            }
            return
        }
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { message = app.config.s("error.file"); return }
        if ext == "json" {
            do { preview = try CSVImporter.parseJSON(data, person: p, batchId: batch) } catch { message = "Invalid JSON: \(error.localizedDescription)" }
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        let t = CSVParser.parse(text, delimiter: ext == "tsv" ? "\t" : nil)
        guard !t.headers.isEmpty else { message = app.config.s("error.file"); return }
        table = t
        mapping = CSVImporter.autoDetect(t)
    }

    private func runPreview() {
        guard let t = table, let p = app.person else { return }
        preview = CSVImporter.toRaw(t, mapping: mapping, person: p, batchId: "import-\(newId().prefix(8))")
    }

    private func commit(_ p: CSVImporter.Preview) {
        guard let batch = p.raws.first?.importBatchId else { return }
        do {
            let r = try app.hub.submit(p.raws, allowHistory: true)
            message = "Imported \(r.inserted) new observations · \(r.duplicates) duplicates skipped · \(r.rejected) rejected\(r.rejectReasons.isEmpty ? "" : " (" + r.rejectReasons.map { "\($0.key): \($0.value)" }.joined(separator: "; ") + ")")."
            lastBatch = batch; UserDefaults.standard.set(batch, forKey: "ui.lastImportBatch")
            preview = nil; table = nil
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Radiation sensor

struct RadiationSourceView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var radio = RadiationBridge.shared
    var body: some View {
        Form {
            Section("Status") {
                HStack { Text(radio.state.label); Spacer(); if radio.state == .searching { ProgressView() } }
                if let h = radio.hello { LabeledValue(label: "Device", value: h.device); LabeledValue(label: "Bridge", value: "\(h.bridge) \(h.version)") }
                if let s = radio.lastSample { LabeledValue(label: "Dose rate", value: "\(RadiationEngine.f3(s.rate)) µSv/h") }
                if let c = radio.lastCPM { LabeledValue(label: "Count rate", value: "\(Int(c)) CPM") }
                if let b = radio.battery { LabeledValue(label: "Battery", value: "\(Int(b * 100))%") }
                LabeledValue(label: "Minute records stored", value: "\(radio.persistedCount)")
            }
            Section("Bridge") {
                TextField("ws://127.0.0.1:8765", text: Binding(get: { app.settings.bridgeURL }, set: { v in app.saveSettings { $0.bridgeURL = v } }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                SecureField("Shared token (optional)", text: Binding(get: { app.settings.bridgeToken }, set: { v in app.saveSettings { $0.bridgeToken = v } }))
                if radio.state.isLive && radio.state != .simulated { Button("Disconnect", role: .destructive) { radio.disconnect() } }
                else { Button("Connect to bridge") { radio.connect() } }
                if radio.notFoundYet {
                    Text(app.config.s("error.bridge")).font(.caption).foregroundStyle(Color.watch)
                    Button("Use a demo detector") { radio.useSimulated() }
                }
            }
            Section("Demo detector") {
                if radio.state == .simulated {
                    Button("Trigger a spike") { radio.triggerSimulatedSpike() }
                    Button("Stop demo detector", role: .destructive) { radio.stopSimulated() }
                } else { Button("Use a demo detector") { radio.useSimulated() } }
            }
            Section("How to start the bridge") {
                Text("On the Mac running the simulator:").font(.caption)
                Text("cd bridge && pip install -r requirements.txt\npython bridge.py --driver simulated").font(.caption.monospaced()).textSelection(.enabled)
                Text("Radiacode (USB): python bridge.py --driver radiacode --usb\nGQ GMC: python bridge.py --driver gmc --port /dev/tty.usbserial-XXXX").font(.caption.monospaced()).textSelection(.enabled)
                Text("The iOS Simulator reaches the Mac at 127.0.0.1. On a real iPhone, run the bridge with --host 0.0.0.0 and enter the Mac's LAN address here.").font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .navigationTitle("Radiation detector")
    }
}
