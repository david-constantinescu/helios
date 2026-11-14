import SwiftUI

struct HowToMeasure: View {
    let metric: MetricDef
    @State private var open = false
    var body: some View {
        DisclosureGroup("How to measure", isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(metric.howToMeasure.enumerated()), id: \.offset) { i, s in Text("\(i + 1). \(s)").font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }
}

/// Manual entry for any metric (PART 6.3).
struct ManualEntryView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State private var metricId: MetricId = "bp_sys"
    @State private var value = ""
    @State private var value2 = ""
    @State private var unit = ""
    @State private var measuredNow = true
    @State private var when = Date()
    @State private var activity = "rest"
    @State private var fasting = false
    @State private var note = ""
    @State private var symptom = "headache"
    @State private var severity = 1
    @State private var message: String?
    @State private var saving = false

    private var metric: MetricDef { app.config.metric(metricId) ?? app.config.metrics[0] }
    private var isBP: Bool { metricId == "bp_sys" || metricId == "bp_dia" }
    private var units: [String] { [metric.unit] + metric.alternateUnits }

    private var validation: String? {
        if metricId == "symptom" { return nil }
        guard let v = Double(value.replacingOccurrences(of: ",", with: ".")) else { return value.isEmpty ? nil : "Enter a number" }
        guard let c = try? UnitConversion.toCanonical(v, unit: unit.isEmpty ? metric.unit : unit, metric: metric.id, canonical: metric.unit) else { return "Unsupported unit" }
        if let lo = metric.sanityMin, c < lo { return "Below the plausible limit (\(lo) \(metric.unit)) — check the reading" }
        if let hi = metric.sanityMax, c > hi { return "Above the plausible limit (\(hi) \(metric.unit)) — check the reading" }
        if isBP, let d = Double(value2), d >= v { return "Systolic should be higher than diastolic" }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Picker("Indicator", selection: $metricId) {
                    ForEach(app.config.metrics.filter { $0.manualEntry && $0.id != "bp_dia" }) { m in Text(m.id == "bp_sys" ? "Blood pressure" : m.label).tag(m.id) }
                }
            }
            if metricId == "symptom" {
                Section("Symptom") {
                    Picker("Symptom", selection: $symptom) { ForEach(app.config.symptoms) { Text($0.label + ($0.redFlag ? " ⚠︎" : "")).tag($0.code) } }
                    Picker("Severity", selection: $severity) { Text("Mild").tag(1); Text("Moderate").tag(2); Text("Severe").tag(3) }.pickerStyle(.segmented)
                }
            } else {
                Section(isBP ? "Reading (systolic / diastolic)" : "Reading") {
                    HStack {
                        TextField(isBP ? "Systolic" : metric.label, text: $value).keyboardType(.decimalPad).font(.title2.monospacedDigit())
                        if isBP { Text("/"); TextField("Diastolic", text: $value2).keyboardType(.decimalPad).font(.title2.monospacedDigit()) }
                        if units.count > 1 {
                            Picker("Unit", selection: $unit) { ForEach(units, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                        } else { Text(metric.unit).foregroundStyle(Color.dim) }
                    }
                    if let v = validation { Label(v, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.watch) }
                }
            }
            Section("When") {
                Toggle("I measured this now", isOn: $measuredNow)
                if !measuredNow { DatePicker("Measured at", selection: $when, in: ...Date()) }
            }
            if metricId != "symptom" {
                Section("Context") {
                    Picker("Activity", selection: $activity) { Text("Rest").tag("rest"); Text("After exercise").tag("exercise"); Text("Unknown").tag("unknown") }.pickerStyle(.segmented)
                    if metricId == "glucose" { Toggle("Fasting", isOn: $fasting) }
                    TextField("Note (optional)", text: $note)
                }
                Section { HowToMeasure(metric: metric) }
            }
            if app.person?.isHealthKitOwner == true && app.settings.hkEnabled && app.settings.hkWriteBack {
                Section { Label("Also saved to Apple Health", systemImage: "heart.text.square").font(.caption).foregroundStyle(Color.dim) }
            }
            if let message { Section { Text(message) } }
        }
        .navigationTitle("Add measurement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { app.manualMetric = nil; dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(saving || (metricId != "symptom" && (value.isEmpty || validation != nil)) || (isBP && value2.isEmpty))
            }
        }
        .onAppear {
            if let m = app.manualMetric { metricId = m == "bp_dia" ? "bp_sys" : m }
            unit = metric.unit
        }
        .onChange(of: metricId) { _, _ in unit = metric.unit; value = ""; value2 = "" }
    }

    private func save() async {
        guard let p = app.person else { return }
        saving = true
        defer { saving = false }
        let sim = app.mission?.isSimulated == true
        let ts = measuredNow ? (sim ? (app.snapshot?.asOf ?? Date()) : Date()) : when
        let src = SourceInfo(adapter: "manual", device: nil, kind: sim ? .simulated : .manual)
        var ctx = ObsContext(activity: activity, note: note.isEmpty ? nil : note, fasting: metricId == "glucose" ? fasting : nil)
        var raws: [RawObservation] = []
        if metricId == "symptom" {
            raws.append(RawObservation(personId: p.id, missionId: p.missionId, ts: ts, metric: "symptom", value: Double(severity), unit: "severity", source: src, context: ObsContext(symptom: symptom)))
        } else if isBP, let s = Double(value), let d = Double(value2) {
            ctx.pairId = newId()
            raws.append(RawObservation(personId: p.id, missionId: p.missionId, ts: ts, metric: "bp_sys", value: s, unit: unit, source: src, context: ctx))
            raws.append(RawObservation(personId: p.id, missionId: p.missionId, ts: ts, metric: "bp_dia", value: d, unit: unit, source: src, context: ctx))
        } else if let v = Double(value.replacingOccurrences(of: ",", with: ".")) {
            if metricId == "sleep_hours" { ctx.start = ts.addingTimeInterval(-v * 3600) }
            raws.append(RawObservation(personId: p.id, missionId: p.missionId, ts: ts, metric: metricId, value: v, unit: unit, source: src, context: ctx))
        }
        let (r, note) = await ManualEntry.submit(raws, person: p)
        if let r, r.inserted > 0 {
            message = "Saved. \(note ?? "")"
            value = ""; value2 = ""
            app.manualMetric = nil
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismiss()
        } else {
            message = r.map { "Not saved: \($0.rejectReasons.keys.joined(separator: ", "))" } ?? (note ?? "Not saved")
        }
    }
}
