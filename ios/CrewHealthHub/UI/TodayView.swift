import SwiftUI

struct TodayView: View {
    @EnvironmentObject var app: AppState
    @Binding var showProfile: Bool
    @ObservedObject var hk = HealthSync.shared
    @ObservedObject var radio = RadiationBridge.shared
    @State private var done: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let s = app.snapshot {
                    hero(s)
                    changes(s)
                    tiles(s)
                    if let p = s.prompts.first(where: { $0.routineId == "daily_checkin" && $0.state != .done }) { checkInCard(p, s) }
                    steps(s)
                    if s.person.isHealthKitOwner && app.settings.hkEnabled { syncPill }
                } else {
                    VStack(spacing: 12) { ProgressView(); Text("Preparing your summary…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity).padding(.top, 120)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .ambient(app.snapshot?.overall.level.ambient ?? [.blue, .indigo])
        .navigationTitle("Today")
        .toolbar { ProfileToolbar(app: app, showProfile: $showProfile, showAdd: true) }
        .refreshable { await HealthSync.shared.syncAll(reason: "pull to refresh"); app.refresh() }
        .foregroundStyle(.white)
    }

    // MARK: Hero

    private func hero(_ s: PersonSnapshot) -> some View {
        let lvl = s.overall.level
        let flagged = s.regions.filter { $0.value.level >= .watch }.sorted { $0.value.level > $1.value.level }
        let okCount = s.regions.values.filter { $0.level == .ok }.count
        return VStack(alignment: .leading, spacing: 16) {
            // A mission that starts today says nothing useful; show the date instead (e.g. personal data).
            Text(s.missionDay > 1 ? "\(s.asOf.formatted(.dateTime.weekday(.wide))) · Mission day \(s.missionDay)"
                                  : s.asOf.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                StatusRing(level: lvl, fraction: lvl == .ok ? 1 : (lvl == .unknown ? 0.15 : 0.66))
                VStack(alignment: .leading, spacing: 4) {
                    Text(lvl.headline).font(.subheadline.weight(.semibold)).foregroundStyle(lvl.color)
                    Text(heroTitle(s, flagged: flagged.count)).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text("Compared with your own normal").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                ForEach(flagged.prefix(3), id: \.key) { id, st in
                    Button { app.bodyRegion = id; app.selectedTab = .body } label: { GlassChip(text: RegionStyle.short(id), color: st.level.color) }
                        .buttonStyle(.plain)
                }
                if okCount > 0 { GlassChip(text: "\(okCount) areas OK", color: .green) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(30)
        .accessibilityElement(children: .combine)
    }

    private func heroTitle(_ s: PersonSnapshot, flagged: Int) -> String {
        switch s.overall.level {
        case .unknown: return "Waiting for data"
        case .ok: return "Everything looks normal"
        case .watch: return flagged == 1 ? "1 change, nothing urgent" : "\(flagged) changes, nothing urgent"
        case .act: return "Something needs your attention"
        case .escalate: return "Contact your flight surgeon"
        }
    }

    // MARK: What changed

    @ViewBuilder private func changes(_ s: PersonSnapshot) -> some View {
        let items = s.changes.prefix(4)
        VStack(spacing: 10) {
            SectionLabel("What changed")
            if items.isEmpty {
                HStack(spacing: 12) {
                    IconTile(symbol: "checkmark", color: .green)
                    Text(s.overall.level == .unknown ? "Your normal is still being learned — keep measuring." : "Nothing changed since yesterday.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(16).glassSurface(24)
            } else {
                GlassList {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                        Button { open(c) } label: { ChangeRow(change: c, snapshot: s) }.buttonStyle(.plain)
                        if i < items.count - 1 { GlassDivider() }
                    }
                }
            }
        }
    }

    private func open(_ c: ChangeItem) {
        if let m = c.metric, m != "symptom", !m.hasPrefix("rad") { app.trendMetric = m; app.selectedTab = .trends }
        else if c.metric?.hasPrefix("rad") == true { app.selectedTab = .hazards }
        else { app.bodyRegion = c.regionId; app.selectedTab = .body }
    }

    // MARK: Tiles

    private func tiles(_ s: PersonSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            radiationTile(s)
            metricTile(s, "sleep_hours", "Sleep")
            metricTile(s, "heart_rate_resting", "Resting heart")
            metricTile(s, "mood", "Mood")
        }
    }

    private func radiationTile(_ s: PersonSnapshot) -> some View {
        let r = s.radiation
        let live = radio.state.isLive && !s.mission.isSimulated
        let rate = live ? (radio.lastSample?.rate ?? r?.smoothed ?? 0) : (r?.smoothed ?? 0)
        let lvl = r?.level ?? .unknown
        return Button { app.selectedTab = .hazards } label: {
            Tile(symbol: "atom", title: "Radiation", color: lvl >= .watch ? lvl.color : .green,
                 value: r?.hasData == true || live ? RadiationEngine.f3(rate) : "—", unit: "µSv/h",
                 caption: r?.hasData == true ? (lvl >= .act ? "Event in progress" : "\(RadiationEngine.f1(r?.cumulative_uSv ?? 0)) µSv this mission") : "No detector yet")
        }
        .buttonStyle(.plain)
    }

    private func metricTile(_ s: PersonSnapshot, _ id: MetricId, _ title: String) -> some View {
        let e = s.evals[id]
        let def = app.config.metric(id)!
        let lvl = e?.status.level ?? .unknown
        var value = "—", unit = def.unit == "1–5" ? "of 5" : def.unit
        if let v = e?.latest?.value {
            if id == "sleep_hours" { let h = Int(v), m = Int((v - Double(h)) * 60); value = "\(h) h \(m)"; unit = "min" }
            else { value = StatusEngine.fmt(v, def) }
        }
        let caption: String = {
            guard let e, let latest = e.latest?.value else { return "No data yet" }
            if e.baseline.state == .learning { return "No history yet" }
            guard e.baseline.state == .active else { return "Re-measure soon" }
            let d = latest - e.baseline.median
            if abs(d) < e.baseline.spread { return "Right on your usual" }
            let dirWord = d > 0 ? "above" : "below"
            let amount = id == "sleep_hours" ? String(format: "%.1f h", abs(d)) : "\(StatusEngine.fmt(abs(d), def))\(def.unit == "1–5" ? "" : " " + def.unit)"
            return "\(amount) \(dirWord) usual"
        }()
        return Button { app.trendMetric = id; app.selectedTab = .trends } label: {
            Tile(symbol: MetricStyle.symbol(id), title: title, color: lvl >= .watch ? lvl.color : MetricStyle.color(id),
                 value: value, unit: unit, caption: caption)
        }
        .buttonStyle(.plain)
    }

    // MARK: Check-in + next steps

    private func checkInCard(_ p: Prompt, _ s: PersonSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark").font(.headline).foregroundStyle(.white)
                .frame(width: 38, height: 38).background(Circle().fill(.blue.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily check-in").font(.headline)
                Text(p.dueAt < s.asOf ? "About a minute · due \(p.dueAt.formatted(date: .omitted, time: .shortened))" : "About a minute")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Start") { app.showCheckIn = true }.font(.subheadline.weight(.semibold)).glassButton(prominent: true)
        }
        .padding(14).glassSurface(24)
    }

    @ViewBuilder private func steps(_ s: PersonSnapshot) -> some View {
        if !s.actions.isEmpty {
            VStack(spacing: 10) {
                SectionLabel("Next steps")
                GlassList {
                    ForEach(Array(s.actions.enumerated()), id: \.element.id) { i, a in
                        Button {
                            withAnimation(.snappy) { if done.contains(a.text) { done.remove(a.text) } else { done.insert(a.text) } }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: done.contains(a.text) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(done.contains(a.text) ? .green : a.level.color)
                                    .contentTransition(.symbolEffect(.replace))
                                Text(a.text).font(.subheadline).multilineTextAlignment(.leading)
                                    .foregroundStyle(done.contains(a.text) ? .secondary : .primary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if i < s.actions.count - 1 { GlassDivider(inset: 48) }
                    }
                }
            }
        }
    }

    private var syncPill: some View {
        HStack(spacing: 8) {
            Circle().fill(hk.isObserving ? .green : .gray).frame(width: 8, height: 8)
                .shadow(color: .green, radius: hk.isObserving ? 4 : 0)
            Text(hk.isObserving ? "Apple Health · live" : "Apple Health").font(.footnote.weight(.semibold))
            if let d = hk.lastChangeAt { Text("· updated \(relativeText(d))").font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassCapsule()
    }
}

// MARK: - Pieces

struct ChangeRow: View {
    let change: ChangeItem
    let snapshot: PersonSnapshot
    private var title: String {
        if let m = change.metric, let def = AppConfig.shared.metric(m), m != "symptom" { return m.hasPrefix("rad") ? "Radiation" : def.label }
        if change.id.hasPrefix("p:") { return change.text.components(separatedBy: ":").first ?? "Pattern" }
        return change.text.components(separatedBy: " (").first?.replacingOccurrences(of: "You reported ", with: "").capitalized ?? "Symptom"
    }
    private var subtitle: String {
        if let m = change.metric, let e = snapshot.evals[m], e.baseline.state == .active, let v = e.latest?.value {
            let def = e.def
            let d = v - e.baseline.median
            let unit = def.unit == "1–5" ? (abs(d) >= 1.5 ? " points" : " point") : (def.unit == "steps" ? "" : " \(def.unit)")
            let amount = def.id == "sleep_hours" ? String(format: "%.1f h", abs(d)) : "\(StatusEngine.fmt(abs(d), def))\(unit)"
            let days = e.persistWatch >= 2 ? " · \(e.persistWatch) days" : ""
            return "\(amount) \(d >= 0 ? "above" : "below") your usual \(StatusEngine.fmt(e.baseline.median, def))\(days)"
        }
        if change.id.hasPrefix("p:") { return "Several signals moved together" }
        return change.text
    }
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: change.metric.map(MetricStyle.symbol) ?? RegionStyle.symbol(change.regionId),
                     color: change.metric.map(MetricStyle.color) ?? RegionStyle.color(change.regionId))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(1)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            if change.spark.count > 1 { Sparkline(values: change.spark, color: change.level.color).frame(width: 54, height: 24) }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(change.level.label)
    }
}

struct Tile: View {
    let symbol: String
    let title: String
    let color: Color
    let value: String
    let unit: String
    let caption: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.footnote.weight(.semibold)).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(unit).font(.footnote).foregroundStyle(.secondary)
            }
            Text(caption).font(.footnote).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(24)
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}
