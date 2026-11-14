import SwiftUI
import Charts

enum HazardStyle {
    static func symbol(_ id: String) -> String {
        ["radiation": "atom", "isolation": "person.crop.circle.badge.moon", "distance": "globe.americas.fill",
         "gravity": "arrow.down.to.line.compact", "closed_env": "aqi.medium"][id] ?? "shield"
    }
    static func color(_ id: String) -> Color {
        ["radiation": .yellow, "isolation": .indigo, "distance": .blue, "gravity": .pink, "closed_env": .teal][id] ?? .gray
    }
}

struct HazardsView: View {
    @EnvironmentObject var app: AppState
    @Binding var showProfile: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let s = app.snapshot {
                    Text(app.config.environment(s.mission.environment)?.label.uppercased() ?? "")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                    HabitatCard()
                    NavigationLink { RadiationDetail() } label: { RadiationHero() }.buttonStyle(.plain)
                    ForEach(app.config.hazards.filter { $0.id != "radiation" }) { h in
                        NavigationLink { HazardDetail(hazard: h) } label: { hazardRow(h, s) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .ambient([.orange, .indigo])
        .navigationTitle("Hazards")
        .toolbar { ProfileToolbar(app: app, showProfile: $showProfile) }
        .foregroundStyle(.white)
    }

    private func hazardRow(_ h: HazardDef, _ s: PersonSnapshot) -> some View {
        let st = s.hazards[h.id]
        let lvl = st?.level ?? .unknown
        let detail: String = {
            if lvl >= .watch, let r = st?.reasons.first {
                if let m = r.metric, let def = app.config.metric(m) { return "\(def.label) \(r.z.map { $0 > 0 ? "rising" : "falling" } ?? "changed")" }
                return r.text
            }
            let fed = h.feeds.compactMap { app.config.metric($0)?.label }.prefix(2).joined(separator: " and ")
            return lvl == .unknown ? "No data yet" : "\(fed) steady"
        }()
        return HStack(spacing: 12) {
            IconTile(symbol: HazardStyle.symbol(h.id), color: HazardStyle.color(h.id), size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.label).font(.body)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(lvl == .unknown ? "—" : lvl.label).font(.subheadline.weight(.semibold)).foregroundStyle(lvl == .ok ? .green : lvl.color)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .glassSurface(24)
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

/// The radiation card: live gauge, key numbers and a 24 h sparkline.
struct RadiationHero: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var bridge = RadiationBridge.shared
    @State private var recent: [RadSample] = []

    var body: some View {
        let s = app.snapshot
        let r = s?.radiation
        let live = bridge.state.isLive && s?.mission.isSimulated == false
        let rate = live ? (bridge.lastSample?.rate ?? r?.smoothed ?? 0) : (r?.smoothed ?? 0)
        let bg = r?.background ?? 0.1
        let lvl = r?.level ?? .unknown
        let color: Color = lvl == .ok || lvl == .unknown ? .green : lvl.color
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Space radiation", systemImage: "atom").font(.headline).foregroundStyle(.yellow)
                Spacer()
                StatusPill(level: lvl == .unknown ? .unknown : lvl)
            }
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 11)
                    Circle().trim(from: 0, to: min(max(log10(max(rate / max(bg, 1e-6), 1)) / 2, 0.06), 1))
                        .stroke(color.gradient, style: StrokeStyle(lineWidth: 11, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(r?.hasData == true || live ? RadiationEngine.f3(rate) : "—").font(.title3.bold()).monospacedDigit()
                        Text("µSv/h").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 100, height: 100)
                VStack(spacing: 9) {
                    kv("Background", r?.background.map { "\(RadiationEngine.f3($0)) µSv/h" } ?? "Measuring…")
                    kv("Mission dose", "\(RadiationEngine.f1(r?.cumulative_uSv ?? 0)) µSv")
                    kv("Detector", live ? (bridge.hello?.device ?? "Live") : (r?.hasData == true ? "Logged" : "Not connected"))
                }
            }
            if recent.count > 1 {
                Chart(recent, id: \.ts) { p in
                    AreaMark(x: .value("t", p.ts), y: .value("r", p.rate)).foregroundStyle(color.opacity(0.18).gradient)
                    LineMark(x: .value("t", p.ts), y: .value("r", p.rate)).foregroundStyle(color).interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 50)
            }
        }
        .padding(18)
        .glassSurface(30, tint: lvl >= .act ? lvl.color : nil)
        .onAppear(perform: load)
        .onChange(of: app.snapshot?.computedAt) { _, _ in load() }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit().lineLimit(1) }.font(.footnote)
    }

    private func load() {
        guard let s = app.snapshot else { return }
        let rows = (try? app.hub.repo.series(person: s.person.id, metric: "rad_dose_rate", from: s.asOf.addingTimeInterval(-86400), to: s.asOf.addingTimeInterval(60))) ?? []
        recent = rows.map { RadSample(ts: $0.0, rate: $0.1) }
    }
}

struct RadiationDetail: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var bridge = RadiationBridge.shared
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                RadiationHero()
                if let r = app.snapshot?.radiation {
                    if let first = r.reasons.first { Text(first.text).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4) }
                    SectionLabel("Dose")
                    GlassList {
                        detailRow("This mission", "\(RadiationEngine.f1(r.cumulative_uSv)) µSv")
                        GlassDivider(inset: 16)
                        detailRow("Projected at mission end", r.projected_uSv.map { "\(RadiationEngine.f1($0)) µSv" } ?? "—")
                        GlassDivider(inset: 16)
                        detailRow("Budget", r.budget_uSv.map { "\(RadiationEngine.f1(r.percentUsed ?? 0))% of \(RadiationEngine.f1($0)) µSv" } ?? "Set in Settings")
                    }
                    if !r.events.isEmpty {
                        SectionLabel("Events")
                        GlassList {
                            ForEach(Array(r.events.reversed().enumerated()), id: \.element.id) { i, e in
                                HStack(spacing: 12) {
                                    IconTile(symbol: "bolt.fill", color: e.open ? .red : .orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(e.start.formatted(date: .abbreviated, time: .shortened) + (e.open ? " · now" : "")).font(.body)
                                        Text("Peak \(RadiationEngine.f3(e.peak)) µSv/h · \(Int(e.durationMin)) min · \(RadiationEngine.f1(e.dose_uSv)) µSv").font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                if i < r.events.count - 1 { GlassDivider() }
                            }
                        }
                    }
                }
                if let pb = app.config.guidance.playbooks["radiation_event"] {
                    SectionLabel("During an event")
                    GlassList {
                        ForEach(Array(pb.steps.enumerated()), id: \.offset) { i, s in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(i + 1)").font(.footnote.bold()).foregroundStyle(.yellow).frame(width: 22, height: 22).background(Circle().fill(.yellow.opacity(0.18)))
                                Text(s.cleanedStep).font(.subheadline)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            if i < pb.steps.count - 1 { GlassDivider(inset: 50) }
                        }
                    }
                }
                NavigationLink { RadiationSourceView() } label: {
                    Label(bridge.state.isLive ? "Detector: \(bridge.state.label)" : "Connect a detector", systemImage: "sensor.tag.radiowaves.forward")
                        .frame(maxWidth: .infinity).frame(height: 44)
                }
                .glassButton()
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .ambient([.yellow, .orange])
        .navigationTitle("Radiation")
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(.white)
    }

    private func detailRow(_ l: String, _ v: String) -> some View {
        HStack { Text(l); Spacer(); Text(v).foregroundStyle(.secondary).monospacedDigit() }.padding(.horizontal, 16).padding(.vertical, 13)
    }
}

struct HazardDetail: View {
    @EnvironmentObject var app: AppState
    let hazard: HazardDef
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let s = app.snapshot {
                    let st = s.hazards[hazard.id]
                    HStack(spacing: 14) {
                        IconTile(symbol: HazardStyle.symbol(hazard.id), color: HazardStyle.color(hazard.id), size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hazard.label).font(.title2.bold())
                            StatusPill(level: st?.level ?? .unknown)
                        }
                    }
                    Text(st.map { $0.level >= .watch ? ($0.reasons.first?.text ?? hazard.explainer) : hazard.explainer } ?? hazard.explainer)
                        .font(.body).foregroundStyle(.white.opacity(0.85))
                    SectionLabel("Signals")
                    GlassList {
                        let feeds = hazard.feeds.compactMap { app.config.metric($0) }
                        ForEach(Array(feeds.enumerated()), id: \.element.id) { i, m in
                            Button { app.trendMetric = m.id; app.selectedTab = .trends } label: {
                                HStack(spacing: 12) {
                                    IconTile(symbol: MetricStyle.symbol(m.id), color: MetricStyle.color(m.id), size: 30)
                                    Text(m.label).font(.body)
                                    Spacer()
                                    if let v = s.evals[m.id]?.latest?.value { Text(UnitConversion.format(v, metric: m, units: s.person.units)).foregroundStyle(.secondary).monospacedDigit() }
                                    let l = s.metricStatuses[m.id]?.level ?? .unknown
                                    Circle().fill(l == .unknown ? Color.gray.opacity(0.4) : (l == .ok ? .green : l.color)).frame(width: 9, height: 9)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 11).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if i < feeds.count - 1 { GlassDivider(inset: 58) }
                        }
                    }
                    if !hazard.countermeasures.isEmpty {
                        SectionLabel("Countermeasures")
                        GlassList {
                            ForEach(Array(hazard.countermeasures.enumerated()), id: \.offset) { i, c in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                                    Text(c).font(.subheadline)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 11)
                                if i < hazard.countermeasures.count - 1 { GlassDivider(inset: 44) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .ambient([HazardStyle.color(hazard.id), .indigo])
        .navigationTitle(hazard.label)
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(.white)
    }
}
