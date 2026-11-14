import SwiftUI

/// Data page row for the Helios Hub.
struct CrewHubRow: View {
    @ObservedObject var link = CrewHubLink.shared
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu").font(.title2).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom)))
            VStack(alignment: .leading, spacing: 3) {
                Text(link.hubName ?? "Helios Hub").font(.headline)
                Text(CrewHubView.statusLine(link)).font(.subheadline).foregroundStyle(link.state == .connected ? .green : .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Connect to the Raspberry Pi hub, see the habitat sensors it reads, and drive demo scenarios on its sensor board.
struct CrewHubView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var link = CrewHubLink.shared
    @State private var address = ""
    @State private var code = ""
    @FocusState private var focused: Bool

    static func statusLine(_ link: CrewHubLink) -> String {
        switch link.state {
        case .connected: return link.uploading ? "Live · sending your data…" : "Live · \(link.hubRecords.formatted()) records on the hub"
        default: return link.state.label
        }
    }

    private var connected: Bool { link.state == .connected }

    var body: some View {
        List {
            Section {
                CrewHubRow()
            } footer: {
                Text("The hub keeps a copy of everything on this iPhone, shows it on its screen and reads the habitat's sensors.")
            }

            Section {
                TextField("Address", text: $address, prompt: Text("nasa.softhoarders.me"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($focused)
                TextField("Hub code", text: $code, prompt: Text("Code on the hub's screen"))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().focused($focused)
                    .font(.body.monospaced())
                if link.state == .off || isRejected {
                    Button("Connect") { connect() }.disabled(address.isEmpty || code.count < 4)
                } else {
                    Button("Disconnect", role: .destructive) {
                        app.saveSettings { $0.hubEnabled = false }
                        link.disconnect()
                    }
                }
            } header: { Text("Connection") } footer: {
                Text("nasa.softhoarders.me works from anywhere; helios.local works on the same Wi-Fi. The code is on the hub's Connect page.")
            }

            if connected {
                Section("Habitat") {
                    if link.values.isEmpty {
                        Label("Waiting for the sensor board…", systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                    ForEach(CrewHubLink.sensors.filter { link.values[$0.id] != nil }) { s in
                        HabitatRow(sensor: s, value: link.values[s.id], level: link.levels[s.id] ?? .ok)
                    }
                    if let r = link.values["rad_dose_rate"] {
                        HStack {
                            Label { Text("Radiation") } icon: { Image(systemName: "atom").foregroundStyle(.yellow) }
                            Spacer()
                            Text(String(format: "%.3f µSv/h", r)).monospacedDigit().foregroundStyle((link.levels["rad_dose_rate"] ?? .ok).color)
                        }
                    }
                }
                Section {
                    ForEach(CrewHubLink.scenarios, id: \.id) { sc in
                        Button { link.trigger(scenario: sc.id) } label: {
                            HStack {
                                Label(sc.label, systemImage: sc.symbol).foregroundStyle(.primary)
                                Spacer()
                                if link.scenario == sc.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                } header: { Text("Demo scenarios") } footer: {
                    Text("Runs on the hub's sensor board, so the hub's screen, the joystick and this app all react together.")
                }
                Section {
                    LabeledContent("Sensor board", value: link.unoConnected ? "Connected" : "Not found")
                    Button("Send everything again") { link.resend() }
                }
            }
        }
        .navigationTitle("Helios Hub")
        .onAppear { address = app.settings.hubURL; code = app.settings.hubCode }
    }

    private var isRejected: Bool { if case .rejected = link.state { return true }; return false }

    private func connect() {
        focused = false
        let a = address.trimmingCharacters(in: .whitespaces), c = code.trimmingCharacters(in: .whitespaces).uppercased()
        app.saveSettings { $0.hubURL = a; $0.hubCode = c; $0.hubEnabled = true }
        link.connect()
    }
}

struct HabitatRow: View {
    let sensor: CrewHubLink.Sensor
    let value: Double?
    let level: Level
    var body: some View {
        HStack {
            Label { Text(sensor.label) } icon: { Image(systemName: sensor.symbol).foregroundStyle(.cyan) }
            Spacer()
            Text(value.map { String(format: "%.\(sensor.decimals)f %@", $0, sensor.unit) } ?? "—")
                .monospacedDigit().foregroundStyle(level >= .watch ? level.color : .primary)
            if level >= .watch { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(level.color) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Hazards tab: live cabin air from the hub.
struct HabitatCard: View {
    @ObservedObject var link = CrewHubLink.shared
    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        if link.state == .connected, !link.values.isEmpty {
            NavigationLink { CrewHubView() } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Habitat", systemImage: "cpu").font(.headline).foregroundStyle(.cyan)
                        Spacer()
                        let worst = CrewHubLink.sensors.compactMap { link.levels[$0.id] }.max() ?? .ok
                        Text(worst == .ok ? "All normal" : worst.label).font(.subheadline.weight(.semibold))
                            .foregroundStyle(worst == .ok ? .green : worst.color)
                    }
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                        ForEach(CrewHubLink.sensors.filter { $0.id != "light" && link.values[$0.id] != nil }) { s in
                            let lvl = link.levels[s.id] ?? .ok
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.label).font(.caption).foregroundStyle(.secondary)
                                Text(String(format: "%.\(s.decimals)f", link.values[s.id] ?? 0) + " " + s.unit)
                                    .font(.title3.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(lvl >= .watch ? lvl.color : .white)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
                .glassSurface(24)
            }
            .buttonStyle(.plain)
        }
    }
}
