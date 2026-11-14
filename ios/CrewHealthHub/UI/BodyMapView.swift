import SwiftUI
import Charts

/// Body: a quiet figure with one status dot per system, and the systems as an inset grouped list (Apple Health style).
struct BodyMapView: View {
    @EnvironmentObject var app: AppState
    @Binding var showProfile: Bool

    /// Dot positions on the figure, as fractions of its frame.
    static let anchors: [String: CGPoint] = [
        "brain": CGPoint(x: 0.50, y: 0.063), "eyes": CGPoint(x: 0.585, y: 0.107), "lungs": CGPoint(x: 0.39, y: 0.33),
        "heart": CGPoint(x: 0.60, y: 0.33), "gut": CGPoint(x: 0.50, y: 0.52), "immune_skin": CGPoint(x: 0.83, y: 0.46),
        "bones_muscle": CGPoint(x: 0.39, y: 0.80),
    ]

    private func level(_ id: String) -> Level { app.snapshot?.regions[id]?.level ?? .unknown }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, -6)
                figure
                systems
            }
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Body")
        .toolbar { ProfileToolbar(app: app, showProfile: $showProfile) }
        .navigationDestination(item: Binding(get: { app.bodyRegion.map { RegionSel(id: $0) } }, set: { app.bodyRegion = $0?.id })) { sel in
            RegionDetailView(regionId: sel.id)
        }
        .foregroundStyle(.white)
    }

    private var subtitle: String {
        let regions = app.snapshot?.regions ?? [:]
        let ok = regions.values.filter { $0.level == .ok }.count
        let watch = regions.values.filter { $0.level >= .watch }.count
        if regions.isEmpty { return "Waiting for data" }
        return watch == 0 ? "All \(ok) systems normal" : "\(ok) normal · \(watch) to \(watch == 1 ? "watch" : "watch")"
    }

    // MARK: Figure

    private var figure: some View {
        let whole = level("whole_body")
        return GeometryReader { g in
            let h = g.size.height, w = h * 0.52
            ZStack(alignment: .topLeading) {
                Image(systemName: "figure.stand")
                    .resizable().scaledToFit()
                    .foregroundStyle(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
                    .frame(width: w, height: h)
                    .shadow(color: whole >= .watch ? whole.color.opacity(0.55) : .clear, radius: 18)
                    .accessibilityHidden(true)
                ForEach(Array(BodyMapView.anchors.keys.sorted()), id: \.self) { id in
                    let p = BodyMapView.anchors[id]!
                    let lvl = level(id)
                    Button { app.bodyRegion = id } label: {
                        ZStack {
                            if lvl >= .watch { Circle().fill(lvl.color.opacity(0.28)).frame(width: 26, height: 26) }
                            Circle().fill(dotColor(lvl)).frame(width: lvl >= .watch ? 12 : 9, height: lvl >= .watch ? 12 : 9)
                                .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1.5))
                        }
                        .frame(width: 44, height: 44).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .position(x: p.x * w, y: p.y * h)
                    .accessibilityLabel("\(app.config.region(id)?.label ?? id): \(lvl == .unknown ? "no data" : lvl.label)")
                }
            }
            .frame(width: w, height: h)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 330)
    }

    private func dotColor(_ l: Level) -> Color {
        switch l { case .unknown: return Color(white: 0.4); case .ok: return .green; default: return l.color }
    }

    // MARK: Systems list

    private var systems: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("SYSTEMS").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 36)
            VStack(spacing: 0) {
                let regions = app.config.regions.sorted { level($0.id) > level($1.id) }
                ForEach(Array(regions.enumerated()), id: \.element.id) { i, r in
                    Button { app.bodyRegion = r.id } label: { systemRow(r.id, r.label) }.buttonStyle(.plain)
                    if i < regions.count - 1 { Divider().overlay(Color(white: 0.25)).padding(.leading, 58) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.11)))
            .padding(.horizontal, 16)
        }
    }

    private func systemRow(_ id: String, _ label: String) -> some View {
        let lvl = level(id)
        return HStack(spacing: 12) {
            Image(systemName: RegionStyle.symbol(id)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(RegionStyle.color(id).gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.body)
                Text(detail(id)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(lvl == .unknown ? "No data" : (lvl == .ok ? "Normal" : lvl.label)).font(.subheadline)
                .foregroundStyle(lvl >= .watch ? lvl.color : .secondary)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// One line per system: the reason when something changed, otherwise its key readings.
    private func detail(_ id: String) -> String {
        guard let s = app.snapshot else { return "" }
        if let st = s.regions[id], st.level >= .watch, let r = st.reasons.first { return r.text }
        if id == "whole_body", let r = s.radiation, r.hasData { return "Radiation \(RadiationEngine.f3(r.smoothed ?? r.current ?? 0)) µSv/h" }
        let ms = app.config.metrics(inRegion: id).filter { s.evals[$0.id]?.latest != nil }.prefix(2)
        let parts = ms.compactMap { m -> String? in
            guard let v = s.evals[m.id]?.latest?.value else { return nil }
            return "\(CrewHubLink.shortLabels[m.id] ?? m.label) \(StatusEngine.fmt(v, m))\(StatusEngine.unitText(m))"
        }
        return parts.isEmpty ? "No recent data" : parts.joined(separator: " · ")
    }
}

struct RegionSel: Identifiable, Hashable { let id: String }

struct StatusPill: View {
    let level: Level
    var body: some View {
        Text(level == .unknown ? "No data" : level.label)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(level.color.opacity(0.2)))
            .foregroundStyle(level.color)
            .accessibilityLabel("Status \(level.label)")
    }
}

// MARK: - System detail

struct RegionDetailView: View {
    @EnvironmentObject var app: AppState
    let regionId: String
    @State private var series: [DailyAggregate] = []

    private var snapshot: PersonSnapshot? { app.snapshot }
    private var metrics: [MetricDef] {
        guard let s = snapshot else { return [] }
        return app.config.metrics(inRegion: regionId).filter { s.evals[$0.id]?.latest != nil }
            .sorted { (s.evals[$0.id]?.status.level ?? .unknown) > (s.evals[$1.id]?.status.level ?? .unknown) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let r = app.config.region(regionId), let s = snapshot {
                    let st = s.regions[regionId]
                    let lvl = st?.level ?? .unknown
                    VStack(alignment: .leading, spacing: 6) {
                        Text(lvl == .unknown ? "NO DATA" : (lvl == .ok ? "NORMAL" : lvl.label.uppercased()))
                            .font(.footnote.weight(.semibold)).foregroundStyle(lvl >= .watch ? lvl.color : .green)
                        Text(lvl >= .watch ? (st?.reasons.first?.text ?? r.function) : r.function)
                            .font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                        Text(historyLine(s)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)

                    if let m = metrics.first, let e = s.evals[m.id] { chartCard(m, e) }
                    let rest = Array(metrics.dropFirst().prefix(6))
                    if !rest.isEmpty {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(rest) { m in tile(m, s) }
                        }
                    }
                    actions(s)
                    HStack(spacing: 10) {
                        if let first = app.config.metrics(inRegion: regionId).first(where: \.manualEntry) {
                            Button { app.manualMetric = first.id; app.showManualEntry = true } label: {
                                Text("Measure now").font(.headline).frame(maxWidth: .infinity).frame(height: 48)
                            }
                            .glassButton(prominent: true)
                        }
                        if let m = metrics.first {
                            Button { app.trendMetric = m.id; app.bodyRegion = nil; app.selectedTab = .trends } label: {
                                Text("See trends").font(.headline).frame(maxWidth: .infinity).frame(height: 48)
                            }
                            .glassButton()
                        }
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(app.config.region(regionId)?.label ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(.white)
        .task(id: "\(regionId)|\(snapshot?.computedAt.timeIntervalSince1970 ?? 0)") { load() }
    }

    private func historyLine(_ s: PersonSnapshot) -> String {
        guard let first = (try? app.hub.repo.db.query("SELECT MIN(ts) FROM observations WHERE person_id=?", [.text(s.person.id)]).first?.double(0)) ?? nil else {
            return "Compared with your own history."
        }
        let days = Int(s.asOf.timeIntervalSince1970 - first) / 86400
        let span = days >= 730 ? "\(days / 365) years" : (days >= 60 ? "\(days / 30) months" : "\(max(days, 1)) days")
        return "Compared with your normal from \(span) of data."
    }

    private func load() {
        guard let p = app.person, let m = metrics.first, let s = snapshot else { return }
        let from = DayKey.add(s.evalDay, -13, app.hub.tz)
        series = (try? app.hub.repo.daily(person: p.id, metric: m.id, from: from, to: s.evalDay)) ?? []
    }

    private func chartCard(_ m: MetricDef, _ e: MetricEval) -> some View {
        let lvl = e.status.level
        let tint = MetricStyle.color(m.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.label).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Spacer()
                Text("14 days").font(.footnote).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(e.latest.map { StatusEngine.fmt($0.value, m) } ?? "—").font(.system(size: 34, weight: .bold, design: .rounded))
                Text(StatusEngine.unitText(m)).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if e.baseline.state == .active {
                    Text("usual \(StatusEngine.fmt(e.baseline.median, m)) ± \(StatusEngine.fmt(e.baseline.spread, m))")
                        .font(.footnote).foregroundStyle(lvl >= .watch ? lvl.color : .secondary)
                }
            }
            Chart {
                if e.baseline.state == .active, let first = series.first, let last = series.last {
                    RectangleMark(xStart: .value("From", DayKey.start(first.day, app.hub.tz)), xEnd: .value("To", DayKey.start(last.day, app.hub.tz)),
                                  yStart: .value("Low", e.baseline.median - e.baseline.spread), yEnd: .value("High", e.baseline.median + e.baseline.spread))
                        .foregroundStyle(.white.opacity(0.08))
                }
                ForEach(series, id: \.day) { a in
                    LineMark(x: .value("Day", DayKey.start(a.day, app.hub.tz)), y: .value(m.label, a.value))
                        .foregroundStyle(tint).interpolationMethod(.catmullRom).lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                if let a = series.last {
                    PointMark(x: .value("Day", DayKey.start(a.day, app.hub.tz)), y: .value(m.label, a.value)).foregroundStyle(tint)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisValueLabel().foregroundStyle(Color.secondary) } }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 96)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.11)))
    }

    private func tile(_ m: MetricDef, _ s: PersonSnapshot) -> some View {
        let e = s.evals[m.id]
        let lvl = e?.status.level ?? .unknown
        let caption: String = {
            guard let e, e.baseline.state == .active, let v = e.latest?.value else { return "No history yet" }
            let d = v - e.baseline.median
            if abs(d) < e.baseline.spread * 0.5 { return "Steady" }
            return "\(StatusEngine.fmt(abs(d), m)) \(d > 0 ? "above" : "below") usual"
        }()
        return VStack(alignment: .leading, spacing: 4) {
            Text(CrewHubLink.shortLabels[m.id] ?? m.label).font(.footnote.weight(.semibold)).foregroundStyle(MetricStyle.color(m.id)).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(e?.latest.map { StatusEngine.fmt($0.value, m) } ?? "—").font(.title2.bold()).monospacedDigit()
                Text(StatusEngine.unitText(m)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(caption).font(.footnote).foregroundStyle(lvl >= .watch ? lvl.color : .secondary).lineLimit(1)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.11)))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func actions(_ s: PersonSnapshot) -> some View {
        let items = s.guidance.filter { $0.regionIds.contains(regionId) }
        let fromGuidance = Array(items.flatMap(\.whatYouCanDo).prefix(3))
        let list = fromGuidance.isEmpty ? Array((app.config.guidance.regions[regionId]?.whatYouCanDo ?? []).prefix(3)) : fromGuidance
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("WHAT YOU CAN DO").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                ForEach(Array(list.enumerated()), id: \.offset) { i, a in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(i + 1)").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                        Text(a.cleanedStep).font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    if i < list.count - 1 { Divider().overlay(Color(white: 0.25)).padding(.leading, 40) }
                }
            }
            .padding(.bottom, 4)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.11)))
        }
    }
}
