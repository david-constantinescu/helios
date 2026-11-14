import SwiftUI

// MARK: - Guidance

struct GuidanceView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        List {
            if let s = app.snapshot, !s.guidance.isEmpty {
                ForEach(s.guidance) { item in
                    Section {
                        NavigationLink { GuidanceDetail(item: item) } label: {
                            HStack(spacing: 12) {
                                IconTile(symbol: item.scope == "radiation" ? "atom" : (item.refId.isEmpty ? "lightbulb.fill" : MetricStyle.symbol(item.refId)),
                                         color: item.level.color, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.headline)
                                    Text(item.whatYouCanDo.first ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            } else {
                Section {
                    Label("Nothing needs your attention right now.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
            Section("Learn") {
                NavigationLink { EscalationInfoView() } label: { Label { Text("When to call the flight surgeon") } icon: { IconTile(symbol: "phone.fill", color: .red, size: 29) } }
                NavigationLink { LearnView() } label: { Label { Text("About each measurement") } icon: { IconTile(symbol: "book.fill", color: .blue, size: 29) } }
            }
            Section("Playbooks") {
                ForEach(app.config.guidance.playbooks.sorted { $0.key < $1.key }, id: \.key) { id, def in
                    NavigationLink { PlaybookView(id: id, def: def) } label: {
                        VStack(alignment: .leading, spacing: 2) { Text(def.label); Text(def.summary).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Guidance")
    }
}

struct GuidanceDetail: View {
    @EnvironmentObject var app: AppState
    let item: GuidanceItem
    var body: some View {
        List {
            Section {
                HStack { Text(item.title).font(.title3.bold()); Spacer(); StatusPill(level: item.level) }
                ForEach(item.whatChanged, id: \.self) { Text($0).font(.subheadline) }
            }
            section("What it may mean", item.whatItMayMean, "questionmark.circle")
            section("What you can do", item.whatYouCanDo, "checkmark.circle")
            section("How to re-measure", item.howToRemeasure, "ruler")
            section("When to call", item.whenToEscalate, "phone")
            if let pb = item.playbookId, let def = app.config.guidance.playbooks[pb] {
                Section { NavigationLink("Open \(def.label)") { PlaybookView(id: pb, def: def) } }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }
    @ViewBuilder private func section(_ t: String, _ items: [String], _ icon: String) -> some View {
        if !items.isEmpty {
            Section(t) { ForEach(items, id: \.self) { Label($0, systemImage: icon).font(.subheadline) } }
        }
    }
}

struct EscalationInfoView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        List {
            Section("Your contact") {
                Text(app.settings.escalationContact.isEmpty ? app.config.s("escalation.contact.default") : app.settings.escalationContact)
            }
            Section("When to call") { ForEach(app.config.guidance.escalationPage, id: \.self) { Text($0).font(.subheadline) } }
            Section("Call right away for") {
                ForEach(app.config.guidance.redFlags, id: \.self) { c in
                    Label(app.config.symptomByCode[c]?.label ?? c, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("When to call")
    }
}

struct LearnView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        List {
            let groups = Dictionary(grouping: app.config.metrics.filter { $0.engine != "symptom" }, by: \.group).sorted { $0.key < $1.key }
            ForEach(groups, id: \.key) { g in
                Section(g.key) {
                    ForEach(g.value) { m in
                        NavigationLink {
                            List {
                                Section { Text(m.whyItMatters) }
                                Section("How to measure") { ForEach(Array(m.howToMeasure.enumerated()), id: \.offset) { i, s in Text("\(i + 1). \(s)") } }
                                Section("How often") { Text(m.frequencyHint) }
                            }
                            .navigationTitle(m.label)
                        } label: {
                            Label { Text(m.label) } icon: { IconTile(symbol: MetricStyle.symbol(m.id), color: MetricStyle.color(m.id), size: 29) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Measurements")
    }
}

struct PlaybookView: View {
    @EnvironmentObject var app: AppState
    let id: String
    let def: PlaybookDef
    @State private var checked: Set<Int> = []
    var body: some View {
        List {
            Section { Text(def.summary).foregroundStyle(.secondary) }
            Section {
                ForEach(Array(def.steps.enumerated()), id: \.offset) { i, s in
                    Button {
                        withAnimation(.snappy) { if checked.contains(i) { checked.remove(i) } else { checked.insert(i) } }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: checked.contains(i) ? "checkmark.circle.fill" : "circle").font(.title3)
                                .foregroundStyle(checked.contains(i) ? .green : .secondary).contentTransition(.symbolEffect(.replace))
                            Text(s.cleanedStep).foregroundStyle(.primary)
                        }
                    }
                }
            }
            if id == "radiation_event", let pid = app.currentPersonId {
                let done = app.settings.drillDone.contains(pid)
                Section {
                    Button {
                        app.saveSettings { if !$0.drillDone.contains(pid) { $0.drillDone.append(pid) } }; app.refresh()
                    } label: { Label(done ? "Drill completed" : "Mark drill as done", systemImage: done ? "checkmark.seal.fill" : "shield.lefthalf.filled") }
                    .disabled(done || checked.count < def.steps.count)
                } footer: { if !done { Text("Tick every step to complete the shielding-drill quest.") } }
            }
        }
        .navigationTitle(def.label)
    }
}

// MARK: - Quests

struct QuestsView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        List {
            if let s = app.snapshot {
                let q = s.quests
                Section {
                    HStack(spacing: 18) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.12), lineWidth: 10)
                            Circle().trim(from: 0, to: Double(q.xpIntoLevel) / Double(max(q.xpPerLevel, 1)))
                                .stroke(Color.orange.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
                            VStack(spacing: 0) { Text("\(q.level)").font(.title.bold()); Text("level").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .frame(width: 84, height: 84)
                        VStack(alignment: .leading, spacing: 6) {
                            Label("\(q.streak)-day streak", systemImage: "flame.fill").font(.headline).foregroundStyle(.orange)
                            Text("\(q.xp) XP").foregroundStyle(.secondary)
                            if q.paused { Text("Paused until the alert is acknowledged").font(.footnote).foregroundStyle(.red) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("This week") {
                    ForEach(q.quests) { qs in
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().stroke(.white.opacity(0.12), lineWidth: 5)
                                Circle().trim(from: 0, to: qs.progress / max(qs.target, 1))
                                    .stroke(qs.done ? Color.green : .blue, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                                Image(systemName: qs.done ? "checkmark" : qs.def.icon).font(.footnote.weight(.semibold))
                            }
                            .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(qs.def.label)
                                Text(qs.def.description).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(qs.progress))/\(Int(qs.target))").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section("Badges") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92))], spacing: 14) {
                        ForEach(q.badges) { b in
                            VStack(spacing: 6) {
                                Image(systemName: b.def.icon).font(.title2).foregroundStyle(b.earned ? .orange : .secondary)
                                    .frame(width: 54, height: 54).background(Circle().fill(b.earned ? Color.orange.opacity(0.2) : Color.white.opacity(0.06)))
                                Text(b.def.label).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                            }
                            .opacity(b.earned ? 1 : 0.55)
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(b.earned ? "earned" : b.why)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("Quests")
    }
}
