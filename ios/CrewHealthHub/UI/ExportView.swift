import SwiftUI
import UIKit

/// Builds the flight-surgeon summary (PART 8.4 Export) from a snapshot: JSON (schema crew-health-summary/1),
/// printable HTML (A4 one-pager + appendix) and CSV of daily aggregates.
enum SummaryBuilder {
    struct Sections: Hashable { var status = true, baselines = true, deviations = true, radiation = true, symptoms = true, adherence = true, notes = true }
    static let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"

    static func json(_ s: PersonSnapshot, days: Int, sections: Sections, consentFiltered: Bool = false) -> [String: Any] {
        let hub = Hub.shared, cfg = hub.config
        let from = s.asOf.addingTimeInterval(-Double(days) * 86400)
        var out: [String: Any] = [
            "schema": "crew-health-summary/1", "generatedAt": Date().iso, "appVersion": version,
            "person": ["id": s.person.id, "name": s.person.displayName],
            "mission": ["name": s.mission.name, "day": s.missionDay, "environment": s.mission.environment, "isSimulated": s.mission.isSimulated],
            "period": ["from": from.iso, "to": s.asOf.iso],
            "simulatedData": s.hasSimulated,
        ]
        if sections.status {
            out["overall"] = ["level": s.overall.level.name, "counts": s.overall.counts ?? [:], "summary": s.summary]
            out["regions"] = s.regions.mapValues { ["level": $0.level.name, "confidence": $0.confidence.label] }
        }
        if sections.baselines || sections.deviations {
            out["metrics"] = s.evals.values.filter { $0.latest != nil }.sorted { $0.def.id < $1.def.id }.map { e -> [String: Any] in
                var d: [String: Any] = ["id": e.def.id, "label": e.def.label, "unit": e.def.unit, "level": e.status.level.name, "confidence": e.status.confidence.label]
                if sections.baselines { d["baseline"] = ["median": e.baseline.median.isUsable ? e.baseline.median.rounded(to: 2) : NSNull(), "spread": e.baseline.spread.rounded(to: 2), "state": e.baseline.state.rawValue, "nDays": e.baseline.nDays] }
                if let l = e.latest { d["latest"] = ["value": l.value.rounded(to: 2), "day": l.day] }
                if sections.deviations { d["reasons"] = e.status.reasons.map(\.text) }
                return d
            }
            out["patterns"] = s.patterns.map { ["id": $0.id, "label": $0.def.label, "firedOn": s.evalDay] }
        }
        if sections.radiation, let r = s.radiation {
            out["radiation"] = ["label": cfg.radiation.labels["device"] ?? "demonstration of device integration", "cumulative_uSv": r.cumulative_uSv.rounded(to: 2),
                                "budget_uSv": r.budget_uSv ?? NSNull(), "percentUsed": r.percentUsed ?? NSNull(), "background_uSv_h": r.background ?? NSNull(),
                                "unmonitoredMinutes": Int(r.unmonitoredMinutes), "level": r.level.name,
                                "events": r.events.filter { $0.start >= from }.map { ["start": $0.start.iso, "peak_uSv_h": $0.peak.rounded(to: 3), "durationMin": Int($0.durationMin), "dose_uSv": $0.dose_uSv.rounded(to: 2)] }]
        }
        if sections.symptoms {
            let obs = (try? hub.repo.observations(person: s.person.id, metric: "symptom", from: from, to: s.asOf.addingTimeInterval(60))) ?? []
            out["symptoms"] = obs.map { ["ts": $0.ts.iso, "symptom": $0.context?.symptom ?? "other", "severity": Int($0.value)] }
        }
        if sections.adherence { out["adherence"] = ["promptsDone": (s.adherence["overall"] ?? 0).rounded(to: 2), "byRoutine": s.adherence.mapValues { $0.rounded(to: 2) }] }
        if sections.notes {
            let notes = ((try? hub.repo.observations(person: s.person.id, metrics: cfg.metrics.map(\.id), from: from, to: s.asOf.addingTimeInterval(60))) ?? []).compactMap { o -> [String: Any]? in
                guard let n = o.context?.note, !n.isEmpty, o.context?.note != "Apple Health State of Mind" else { return nil }
                return ["ts": o.ts.iso, "metric": o.metric, "note": n]
            }
            out["notes"] = notes
        }
        let acks = (try? hub.repo.list("ack", person: s.person.id, as: EscalationAck.self, since: from)) ?? []
        out["escalationsAcknowledged"] = acks.map { ["key": $0.key, "at": $0.acknowledgedAt.iso, "note": $0.note] }
        return out
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func html(_ s: PersonSnapshot, days: Int, sections: Sections) -> String {
        let cfg = Hub.shared.config
        let col: [Level: String] = [.ok: "#1b9e6b", .watch: "#b8860b", .act: "#d2691e", .escalate: "#c0392b", .unknown: "#6b7280"]
        func chip(_ l: Level) -> String { "<span class='chip' style='background:\(col[l]!)'>\(l.label)</span>" }
        var h = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Crew health summary</title><style>
        @page { size: A4; margin: 14mm; }
        body { font: 11px -apple-system, system-ui, sans-serif; color: #111; }
        h1 { font-size: 18px; margin: 0 0 4px; } h2 { font-size: 13px; margin: 14px 0 4px; border-bottom: 1px solid #ccc; }
        table { width: 100%; border-collapse: collapse; } td, th { text-align: left; padding: 3px 4px; border-bottom: 1px solid #eee; vertical-align: top; }
        .chip { color: #fff; border-radius: 8px; padding: 1px 6px; font-weight: 600; font-size: 10px; }
        .muted { color: #555; } .banner { border: 2px solid #0a84ff; padding: 6px; margin: 6px 0; font-weight: 700; }
        .warn { border: 1px solid #b8860b; padding: 6px; margin: 6px 0; } .appendix { page-break-before: always; }
        </style></head><body>
        <h1>Crew health summary — \(esc(s.person.displayName))</h1>
        <div class="muted">\(esc(s.mission.name)) · day \(s.missionDay) of \(s.mission.plannedDays) · \(esc(cfg.environment(s.mission.environment)?.label ?? s.mission.environment)) · last \(days) days · generated \(Date().formatted()) · app v\(version)</div>
        """
        if sections.status {
            h += "<h2>Status overview</h2><p>\(chip(s.overall.level)) \(esc(s.summary))</p><table><tr><th>Region</th><th>Status</th><th>Main reason</th></tr>"
            for r in cfg.regions { let st = s.regions[r.id]; h += "<tr><td>\(esc(r.label))</td><td>\(chip(st?.level ?? .unknown))</td><td>\(esc(st?.reasons.first?.text ?? ""))</td></tr>" }
            h += "</table>"
            if !s.patterns.isEmpty { h += "<p><b>Patterns:</b> \(s.patterns.map { esc($0.def.label) }.joined(separator: ", "))</p>" }
        }
        if sections.baselines || sections.deviations {
            h += "<h2>Baselines vs current</h2><table><tr><th>Indicator</th><th>Usual</th><th>Latest</th><th>Status</th><th>Why</th></tr>"
            for e in s.evals.values.filter({ $0.latest != nil }).sorted(by: { $0.status.level != $1.status.level ? $0.status.level > $1.status.level : $0.def.label < $1.def.label }) {
                let usual = e.baseline.state == .active ? "\(StatusEngine.fmt(e.baseline.median, e.def)) ± \(StatusEngine.fmt(e.baseline.spread, e.def))" : e.baseline.state.rawValue
                h += "<tr><td>\(esc(e.def.label)) (\(esc(e.def.unit)))</td><td>\(usual)</td><td>\(StatusEngine.fmt(e.latest!.value, e.def)) <span class='muted'>\(e.latest!.day)</span></td><td>\(chip(e.status.level))</td><td>\(sections.deviations ? esc(e.status.reasons.first?.text ?? "") : "")</td></tr>"
            }
            h += "</table>"
        }
        if sections.radiation, let r = s.radiation {
            h += "<h2>Radiation</h2><p><i>\(esc(cfg.radiation.labels["device"] ?? ""))</i></p>"
            h += "<p>Cumulative \(RadiationEngine.f1(r.cumulative_uSv)) µSv\(r.budget_uSv.map { " of \(RadiationEngine.f1($0)) µSv budget (\(RadiationEngine.f1(r.percentUsed ?? 0))%)" } ?? " (no budget set)") · background \(r.background.map { RadiationEngine.f3($0) } ?? "–") µSv/h · \(chip(r.level))</p>"
            if !r.events.isEmpty {
                h += "<table><tr><th>Event start</th><th>Peak µSv/h</th><th>Duration</th><th>Dose µSv</th></tr>"
                for e in r.events { h += "<tr><td>\(e.start.formatted())</td><td>\(RadiationEngine.f3(e.peak))</td><td>\(Int(e.durationMin)) min</td><td>\(RadiationEngine.f1(e.dose_uSv))</td></tr>" }
                h += "</table>"
            }
        }
        let j = json(s, days: days, sections: sections)
        if sections.symptoms, let sy = j["symptoms"] as? [[String: Any]] {
            h += "<h2>Symptoms</h2>" + (sy.isEmpty ? "<p class='muted'>None reported.</p>" : "<table>" + sy.map { "<tr><td>\(esc("\($0["ts"] ?? "")"))</td><td>\(esc(cfg.symptomByCode["\($0["symptom"] ?? "")"]?.label ?? "\($0["symptom"] ?? "")"))</td><td>severity \($0["severity"] ?? "")</td></tr>" }.joined() + "</table>")
        }
        if sections.adherence { h += "<h2>Adherence</h2><p>Scheduled prompts completed (14 days): \(Int((s.adherence["overall"] ?? 0) * 100))%</p>" }
        if sections.notes, let n = j["notes"] as? [[String: Any]], !n.isEmpty {
            h += "<h2>Notes</h2><table>" + n.map { "<tr><td>\(esc("\($0["ts"] ?? "")"))</td><td>\(esc("\($0["metric"] ?? "")"))</td><td>\(esc("\($0["note"] ?? "")"))</td></tr>" }.joined() + "</table>"
        }
        h += "<div class='appendix'><h2>Appendix: guidance shown to the crew member</h2>"
        for g in s.guidance { h += "<p><b>\(esc(g.title))</b> \(chip(g.level))<br>\(g.whatYouCanDo.map(esc).joined(separator: "<br>"))</p>" }
        h += "</div></body></html>"
        return h
    }

    static func csv(_ s: PersonSnapshot, days: Int) -> String {
        let hub = Hub.shared
        let from = DayKey.add(s.evalDay, -days)
        var out = "person,metric,day,value,unit,n,mean,median,min,max,sources,simulated\n"
        for m in hub.config.metrics {
            for a in (try? hub.repo.daily(person: s.person.id, metric: m.id, from: from, to: s.evalDay)) ?? [] {
                out += "\(s.person.displayName),\(m.id),\(a.day),\(a.value.rounded(to: 3)),\(m.unit),\(a.n),\(a.mean.rounded(to: 3)),\(a.median.rounded(to: 3)),\(a.min.rounded(to: 3)),\(a.max.rounded(to: 3)),\"\(a.sources.joined(separator: ";"))\",\(a.hasSimulated)\n"
            }
        }
        return out
    }

    static func write(_ name: String, _ content: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

struct ExportView: View {
    @EnvironmentObject var app: AppState
    @State private var days = 14
    @State private var sections = SummaryBuilder.Sections()
    @State private var files: [URL] = []

    var body: some View {
        Form {
            Section("Who and when") {
                Picker("Crew member", selection: Binding(get: { app.currentPersonId ?? "" }, set: { app.select(person: $0) })) {
                    ForEach(app.persons) { Text($0.displayName).tag($0.id) }
                }
                Picker("Period", selection: $days) { Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30); Text("Mission").tag(app.snapshot?.missionDay ?? 180) }.pickerStyle(.segmented)
            }
            Section("Sections") {
                Toggle("Status overview", isOn: $sections.status)
                Toggle("Baselines vs current", isOn: $sections.baselines)
                Toggle("Deviations and patterns", isOn: $sections.deviations)
                Toggle("Radiation log and dose", isOn: $sections.radiation)
                Toggle("Symptoms", isOn: $sections.symptoms)
                Toggle("Adherence", isOn: $sections.adherence)
                Toggle("Notes", isOn: $sections.notes)
            }
            Section {
                Button { build() } label: { Label("Generate summary", systemImage: "doc.richtext") }.buttonStyle(.borderedProminent)
                if !files.isEmpty {
                    ForEach(files, id: \.self) { u in
                        ShareLink(item: u) { Label("Share \(u.pathExtension.uppercased()) — \(u.lastPathComponent)", systemImage: "square.and.arrow.up") }
                    }
                    Button { printHTML() } label: { Label("Print / save as PDF", systemImage: "printer") }
                }
            } footer: {
                Text("Files are created on this iPhone; you choose who receives them.")
            }
        }
        .navigationTitle("Flight-surgeon export")
    }

    private func build() {
        guard let s = app.snapshot else { return }
        let stamp = DayKey.of(s.asOf)
        let base = "crew-health-\(s.person.displayName.lowercased().replacingOccurrences(of: " ", with: "-"))-\(stamp)"
        let j = SummaryBuilder.json(s, days: days, sections: sections)
        let jd = (try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        files = [SummaryBuilder.write("\(base).json", String(decoding: jd, as: UTF8.self)),
                 SummaryBuilder.write("\(base).html", SummaryBuilder.html(s, days: days, sections: sections)),
                 SummaryBuilder.write("\(base)-daily.csv", SummaryBuilder.csv(s, days: days))]
    }

    private func printHTML() {
        guard let s = app.snapshot else { return }
        let pc = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil); info.jobName = "Crew health summary"; info.outputType = .general
        pc.printInfo = info
        pc.printFormatter = UIMarkupTextPrintFormatter(markupText: SummaryBuilder.html(s, days: days, sections: sections))
        pc.present(animated: true)
    }
}

// MARK: - Crew (consent-based)

struct CrewView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        List {
            if let me = app.person {
                Section("Your sharing (\(me.displayName))") {
                    Toggle("Share status with crew", isOn: consent(\.shareStatus))
                    Toggle("Share health values", isOn: consent(\.shareMetrics))
                    Toggle("Share radiation dose", isOn: consent(\.shareRadiation))
                }
            }
            let missionIds = Set(app.persons.map(\.missionId))
            ForEach(Array(missionIds).sorted(), id: \.self) { mid in
                let m = app.hub.mission(mid)
                Section(m?.name ?? mid) {
                    ForEach(app.persons.filter { $0.missionId == mid }) { p in
                        let s = app.hub.snapshot(p.id)
                        Button { app.select(person: p.id); app.selectedTab = .today } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(p.displayName).font(.headline)
                                    Text(p.role).font(.caption).foregroundStyle(Color.dim)
                                    Spacer()
                                    if p.consent.shareStatus || p.id == app.currentPersonId { StatusChip(level: s?.overall.level ?? .unknown) }
                                    else { Text("Not shared").font(.caption).foregroundStyle(Color.dim) }
                                }
                                if p.consent.shareStatus, let s {
                                    Text(s.summary).font(.caption).foregroundStyle(Color.dim)
                                    if p.consent.shareMetrics {
                                        ForEach(s.changes.prefix(2)) { c in Text("• \(c.text)").font(.caption2).foregroundStyle(Color.dim).lineLimit(2) }
                                    }
                                    if p.consent.shareRadiation, let r = s.radiation, r.hasData {
                                        Text("Radiation: \(RadiationEngine.f1(r.cumulative_uSv)) µSv cumulative").font(.caption2).foregroundStyle(Color.dim)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .onAppear { if s == nil { app.hub.refresh([p.id]) } }
                    }
                }
            }
            Section { Text("Commanders see only what each crew member has chosen to share. Health values stay hidden unless sharing is on.").font(.caption).foregroundStyle(Color.dim) }
        }
        .navigationTitle("Crew")
    }

    private func consent(_ k: WritableKeyPath<Consent, Bool>) -> Binding<Bool> {
        Binding(get: { app.person?.consent[keyPath: k] ?? false }, set: { v in
            guard var p = app.person else { return }
            p.consent[keyPath: k] = v; app.hub.save(p); app.reloadPersons()
        })
    }
}
