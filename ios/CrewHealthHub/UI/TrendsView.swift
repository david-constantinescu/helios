import SwiftUI
import Charts

struct TrendsView: View {
    @EnvironmentObject var app: AppState
    @Binding var showProfile: Bool
    @StateObject private var model = TrendModel()
    @State private var rangeDays = 30
    @State private var showRaw = false
    @State private var showTable = false
    @State private var compare: [MetricId] = []
    @State private var selected: Date?

    private let quick: [MetricId] = ["heart_rate_resting", "hrv", "sleep_hours", "mood", "spo2", "bp_sys", "exercise_min", "weight", "stress", "body_temp", "rad_dose_rate"]
    private var metric: MetricDef { app.config.metric(app.trendMetric) ?? app.config.metrics[0] }
    private var tint: Color { MetricStyle.color(metric.id) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                chips
                heroCard
                if showTable { table }
                details
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .ambient([tint, .blue])
        .navigationTitle("Trends")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Raw samples", isOn: $showRaw)
                    Toggle("Data table", isOn: $showTable)
                    Menu("Compare with") {
                        ForEach(app.config.metrics.filter { $0.engine == "baseline" && $0.id != metric.id }) { m in
                            Button { if compare.contains(m.id) { compare.removeAll { $0 == m.id } } else if compare.count < 2 { compare.append(m.id) } } label: {
                                Label(m.label, systemImage: compare.contains(m.id) ? "checkmark" : "plus")
                            }
                        }
                    }
                    if !compare.isEmpty { Button("Clear comparison") { compare = [] } }
                    Menu("All indicators") {
                        ForEach(indicatorGroups, id: \.0) { group, metrics in
                            Menu(group) { ForEach(metrics) { m in Button(m.label) { app.trendMetric = m.id } } }
                        }
                    }
                    if let url = csvURL() { ShareLink(item: url) { Label("Export CSV", systemImage: "square.and.arrow.up") } }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Chart options")
            }
            ProfileToolbar(app: app, showProfile: $showProfile)
        }
        .foregroundStyle(.white)
        .onAppear(perform: reload)
        .onChange(of: app.trendMetric) { _, _ in compare = []; showRaw = metric.engine == "radiation"; reload() }
        .onChange(of: showRaw) { _, _ in reload() }
        .onChange(of: compare) { _, _ in reload() }
        .onChange(of: app.snapshot?.computedAt) { _, _ in reload() }
    }

    /// Indicators that have data for this person, grouped like the Health app.
    private var indicatorGroups: [(String, [MetricDef])] {
        let s = app.snapshot
        let withData = app.config.metrics.filter { m in
            m.engine != "symptom" && (s?.evals[m.id]?.latest != nil || (m.engine == "radiation" && s?.radiation?.hasData == true))
        }
        return Dictionary(grouping: withData, by: \.group).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private func reload() {
        guard let p = app.person, let s = app.snapshot else { return }
        model.load(person: p, metric: metric, asOf: s.asOf, missionStart: s.mission.startDate, includeRaw: showRaw || metric.engine == "radiation",
                   compare: compare.compactMap { app.config.metric($0) })
    }

    // MARK: Pieces

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(quick, id: \.self) { id in
                    Button { withAnimation(.snappy) { app.trendMetric = id } } label: {
                        GlassChip(text: shortName(id), selected: id == metric.id)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func shortName(_ id: MetricId) -> String {
        ["heart_rate_resting": "Resting HR", "hrv": "HRV", "sleep_hours": "Sleep", "mood": "Mood", "spo2": "Oxygen", "bp_sys": "Blood pressure",
         "exercise_min": "Exercise", "weight": "Weight", "stress": "Stress", "body_temp": "Temperature", "rad_dose_rate": "Radiation"][id] ?? (app.config.metric(id)?.label ?? id)
    }

    private var latestText: (String, String, String, Color) {
        guard let e = app.snapshot?.evals[metric.id], let v = e.latest?.value else {
            if metric.engine == "radiation", let r = app.snapshot?.radiation, r.hasData {
                return (RadiationEngine.f3(r.smoothed ?? 0), "µSv/h", r.reasons.first?.text ?? "", r.level >= .watch ? r.level.color : .green)
            }
            return ("—", metric.unit, "No data yet", .secondary)
        }
        let lvl = e.status.level
        var caption = "Within your normal"
        if e.baseline.state == .learning { caption = "No history yet" }
        else if e.baseline.state == .active {
            let d = v - e.baseline.median
            if abs(d) >= e.baseline.spread {
                caption = "\(d > 0 ? "+" : "−")\(StatusEngine.fmt(abs(d), metric)) vs your usual" + (e.persistWatch >= 2 ? " · \(e.persistWatch) days" : "")
            }
        }
        return (StatusEngine.fmt(v, metric), metric.unit == "1–5" ? "of 5" : metric.unit, caption, lvl >= .watch ? lvl.color : .green)
    }

    private var visibleLength: TimeInterval {
        let total = model.domain.upperBound.timeIntervalSince(model.domain.lowerBound)
        return min(Double(rangeDays) * 86400, max(total, 86400))
    }

    private var heroCard: some View {
        let (value, unit, caption, captionColor) = latestText
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.label.uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(unit).font(.title3).foregroundStyle(.secondary)
                    }
                    Text(caption).font(.footnote.weight(.medium)).foregroundStyle(captionColor)
                }
                Spacer()
                Picker("Range", selection: $rangeDays) { Text("W").tag(7); Text("M").tag(30); Text("3M").tag(90); Text("All").tag(10000) }
                    .pickerStyle(.segmented).frame(width: 150)
            }
            Group {
                if model.points.isEmpty && model.raw.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No data for this indicator yet").font(.subheadline).foregroundStyle(.secondary)
                        if metric.manualEntry {
                            Button("Add a measurement") { app.manualMetric = metric.id; app.showManualEntry = true }.glassButton(prominent: true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else if compare.isEmpty { chart.frame(height: 240) } else { compareChart.frame(height: 240) }
            }
            HStack(spacing: 16) {
                legend(Color.blue.opacity(0.4), "Your normal", rect: true)
                legend(tint, "Daily value", rect: false)
                if !model.events.isEmpty { legend(.orange, "Events", rect: false) }
            }
        }
        .padding(18)
        .glassSurface(30)
    }

    private func legend(_ c: Color, _ t: String, rect: Bool) -> some View {
        HStack(spacing: 6) {
            if rect { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 14, height: 8) } else { Capsule().fill(c).frame(width: 14, height: 3) }
            Text(t).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(model.bands) { b in
                AreaMark(x: .value("Day", b.date), yStart: .value("Low", b.median - 2 * b.spread), yEnd: .value("High", b.median + 2 * b.spread))
                    .foregroundStyle(Color.blue.opacity(0.22)).interpolationMethod(.monotone)
            }
            ForEach(model.bands) { b in
                LineMark(x: .value("Day", b.date), y: .value("Usual", b.median), series: .value("S", "usual"))
                    .foregroundStyle(Color.cyan.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            ForEach(model.raw) { r in
                PointMark(x: .value("Time", r.date), y: .value("Raw", r.value)).symbolSize(6).foregroundStyle(.white.opacity(0.35))
            }
            ForEach(model.points) { p in
                LineMark(x: .value("Day", p.date), y: .value(metric.label, p.value), series: .value("S", "value"))
                    .foregroundStyle(tint.gradient).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
            }
            if let last = model.points.last {
                PointMark(x: .value("Day", last.date), y: .value(metric.label, last.value)).symbolSize(80).foregroundStyle(tint)
            }
            ForEach(model.events) { e in
                RuleMark(x: .value("Event", e.date)).foregroundStyle(Color.orange.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let sel = selected, let p = nearest(sel) {
                RuleMark(x: .value("Selected", p.date)).foregroundStyle(.white.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(UnitConversion.format(p.value, metric: metric, units: app.person?.units ?? Units())).font(.caption.bold())
                            Text(p.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(8).glassSurface(12)
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleLength)
        .chartScrollPosition(initialX: model.domain.upperBound.addingTimeInterval(-visibleLength))
        .chartYScale(domain: model.yDomain)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(.secondary) } }
        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)); AxisValueLabel().foregroundStyle(.secondary) } }
        .id("\(metric.id)-\(rangeDays)-\(model.domain.upperBound.timeIntervalSince1970)")
        .accessibilityLabel("\(metric.label) chart")
    }

    private func nearest(_ d: Date) -> TrendPoint? { model.points.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) } }

    private var compareChart: some View {
        Chart {
            RectangleMark(yStart: .value("−2", -2), yEnd: .value("+2", 2)).foregroundStyle(Color.blue.opacity(0.12))
            ForEach(model.zLines) { z in
                LineMark(x: .value("Day", z.date), y: .value("z", z.z), series: .value("Metric", z.metric)).foregroundStyle(by: .value("Metric", z.metric))
            }
        }
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleLength)
        .chartScrollPosition(initialX: model.domain.upperBound.addingTimeInterval(-visibleLength))
    }

    @ViewBuilder private var details: some View {
        if let e = app.snapshot?.evals[metric.id], e.latest != nil {
            VStack(spacing: 10) {
                SectionLabel("About this trend")
                GlassList {
                    row("Your usual", e.baseline.state == .active ? "\(StatusEngine.fmt(e.baseline.median, metric)) ± \(StatusEngine.fmt(e.baseline.spread, metric)) \(metric.unit == "1–5" ? "" : metric.unit)" : (e.baseline.state == .learning ? "No history yet" : "Needs new data"))
                    GlassDivider(inset: 16)
                    row("Trend", e.slopePerDay.map { "\($0 >= 0 ? "+" : "−")\(StatusEngine.fmt(abs($0 * 7), metric)) / week" } ?? "—",
                        color: (e.slopeNorm ?? 0) >= 1.5 ? .yellow : nil)
                    GlassDivider(inset: 16)
                    row("Source", e.latest?.sources.first?.replacingOccurrences(of: "derived:heart_rate", with: "From heart rate") ?? "—")
                    GlassDivider(inset: 16)
                    row("Status", e.status.level.label, color: e.status.level.color)
                }
                if let r = e.status.reasons.first(where: { $0.code != "within_normal" && $0.code != "learning" }) {
                    Text(r.text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                }
                if e.baseline.state == .active {
                    Button(e.baseline.locked ? "Unlock baseline" : "Lock as pre-mission baseline") {
                        if e.baseline.locked { app.hub.unlockBaseline(person: e.baseline.personId, metric: metric.id) } else { app.hub.lockBaseline(e.baseline) }
                    }
                    .font(.footnote).glassButton()
                }
            }
        }
    }

    private func row(_ l: String, _ v: String, color: Color? = nil) -> some View {
        HStack { Text(l); Spacer(); Text(v).foregroundStyle(color ?? .secondary).monospacedDigit() }
            .font(.body).padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var table: some View {
        GlassList {
            ForEach(Array(model.points.suffix(min(rangeDays, 60)).reversed().enumerated()), id: \.element.id) { i, p in
                HStack {
                    Text(p.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline)
                    Spacer()
                    Text(UnitConversion.format(p.value, metric: metric, units: app.person?.units ?? Units())).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                if i < min(rangeDays, 60, model.points.count) - 1 { GlassDivider(inset: 16) }
            }
        }
    }

    private func csvURL() -> URL? {
        guard !model.points.isEmpty else { return nil }
        var csv = "date,\(metric.id),unit,simulated,readings,sources\n"
        for p in model.points { csv += "\(DayKey.of(p.date)),\(p.value),\(metric.unit),\(p.simulated),\(p.n),\"\(p.sources)\"\n" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(metric.id)-trend.csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
