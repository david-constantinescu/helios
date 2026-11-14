import SwiftUI

/// About-a-minute daily check-in, in three steps.
struct CheckInView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State private var step = 0
    @State private var mood = 0
    @State private var stress = 2.0
    @State private var workload = 3.0
    @State private var sleepHours = 7.0
    @State private var sleepFromDevice: Double?
    @State private var sleepQuality = 4.0
    @State private var symptoms: [String: Int] = [:]
    @State private var measurements: [MetricId: String] = [:]
    @State private var submitting = false
    @State private var result: (Level, String)?

    private let faces: [(String, Color, String)] = [("face.dashed", .red, "Very low"), ("cloud.rain.fill", .orange, "Low"),
                                                    ("minus.circle.fill", .yellow, "Okay"), ("face.smiling", .green, "Good"), ("sun.max.fill", .cyan, "Great")]

    private var dueMetrics: [MetricDef] {
        guard let s = app.snapshot else { return [] }
        let routines = Scheduler.activeRoutines(config: app.config, environment: s.mission.environment)
        let due = s.prompts.filter { $0.state == .pending && $0.routineId != "daily_checkin" && $0.routineId != "sleep_review" }
        let ids = due.flatMap { p in routines.first { $0.id == p.routineId }?.metrics ?? [] }
        return Array(Set(ids)).compactMap { app.config.metric($0) }.filter(\.manualEntry).sorted { $0.label < $1.label }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let result { done(result) }
                    else if step == 0 { feelings }
                    else if step == 1 { sleepAndSymptoms }
                    else { measure }
                }
                .padding(20)
                .animation(.snappy, value: step)
            }
            .safeAreaInset(edge: .bottom) {
                if result == nil {
                    Button {
                        if step < 2 { withAnimation(.snappy) { step += 1 } } else { Task { await submit() } }
                    } label: {
                        Group { if submitting { ProgressView() } else { Text(step < 2 ? "Continue" : "Log check-in") } }
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 50)
                    }
                    .glassButton(prominent: true)
                    .disabled(step == 0 && mood == 0)
                    .padding(.horizontal, 20).padding(.bottom, 8)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { if step > 0 && result == nil { withAnimation { step -= 1 } } else { dismiss() } } label: {
                        Image(systemName: step > 0 && result == nil ? "chevron.left" : "xmark")
                    }
                    .accessibilityLabel(step > 0 ? "Back" : "Close")
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        ForEach(0..<3) { i in Capsule().fill(i == step ? Color.blue : .white.opacity(0.25)).frame(width: i == step ? 22 : 7, height: 7) }
                    }
                    .accessibilityLabel("Step \(step + 1) of 3")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .foregroundStyle(.white)
            .onAppear(perform: prefill)
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    // MARK: Steps

    private var feelings: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How are you feeling?").font(.largeTitle.bold())
                Text("Takes about a minute").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { i in
                    let f = faces[i - 1]
                    Button { withAnimation(.bouncy) { mood = i } } label: {
                        Image(systemName: f.0).font(.system(size: 28, weight: .semibold)).foregroundStyle(f.1)
                            .symbolEffect(.bounce, value: mood == i)
                            .frame(maxWidth: .infinity, minHeight: 66)
                            .background {
                                if mood == i { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(f.1.opacity(0.25)) }
                            }
                            .overlay { if mood == i { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(f.1, lineWidth: 2) } }
                    }
                    .buttonStyle(.plain)
                    .glassSurface(20, interactive: true)
                    .accessibilityLabel("Mood \(f.2)")
                    .accessibilityAddTraits(mood == i ? .isSelected : [])
                }
            }
            if mood > 0 { Text(faces[mood - 1].2).font(.headline).foregroundStyle(faces[mood - 1].1).transition(.opacity) }
            VStack(spacing: 18) {
                slider("Stress", $stress, ["Very calm", "Calm", "Some", "High", "Extreme"], .orange)
                Divider().overlay(.white.opacity(0.1))
                slider("Workload", $workload, ["Very light", "Light", "Normal", "Heavy", "Overwhelming"], .indigo)
            }
            .padding(18).glassSurface(24)
        }
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ labels: [String], _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.headline); Spacer(); Text(labels[Int(v.wrappedValue) - 1]).foregroundStyle(.secondary) }
            Slider(value: v, in: 1...5, step: 1).tint(tint)
        }
    }

    private var sleepAndSymptoms: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Last night").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "bed.double.fill").foregroundStyle(.purple)
                    Text("Asleep").font(.headline)
                    Spacer()
                    Text("\(Int(sleepHours)) h \(Int((sleepHours - Double(Int(sleepHours))) * 60)) min").font(.title3.bold()).monospacedDigit()
                }
                Slider(value: $sleepHours, in: 0...12, step: 0.25).tint(.purple)
                if sleepFromDevice != nil {
                    Label("From your Apple Watch", systemImage: "applewatch").font(.footnote).foregroundStyle(.secondary)
                }
                Divider().overlay(.white.opacity(0.1))
                slider("Sleep quality", $sleepQuality, ["Very poor", "Poor", "Fair", "Good", "Excellent"], .purple)
            }
            .padding(18).glassSurface(24)

            VStack(alignment: .leading, spacing: 12) {
                Text("Any symptoms?").font(.title3.bold())
                Text("Tap once for mild, again for moderate or severe.").font(.footnote).foregroundStyle(.secondary)
                FlowLayout(spacing: 8) {
                    ForEach(app.config.symptoms.filter { $0.code != "other" }) { sy in
                        let sev = symptoms[sy.code] ?? 0
                        Button { withAnimation(.snappy) { symptoms[sy.code] = sev >= 3 ? nil : sev + 1 } } label: {
                            HStack(spacing: 6) {
                                if sy.redFlag { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption) }
                                Text(sev == 0 ? sy.label : "\(sy.label) · \(["mild", "moderate", "severe"][sev - 1])")
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background { if sev > 0 { Capsule().fill(Color.orange.opacity(0.3)) } }
                            .overlay { if sev > 0 { Capsule().strokeBorder(.orange, lineWidth: 1) } }
                        }
                        .buttonStyle(.plain)
                        .glassCapsule()
                    }
                }
            }
        }
    }

    private var measure: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(dueMetrics.isEmpty ? "All set" : "Due today").font(.largeTitle.bold())
            if dueMetrics.isEmpty {
                Text("No measurements are scheduled for today. Tap Log check-in to finish.").foregroundStyle(.secondary)
            }
            ForEach(dueMetrics) { m in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        IconTile(symbol: MetricStyle.symbol(m.id), color: MetricStyle.color(m.id))
                        Text(m.label).font(.headline)
                        Spacer()
                        TextField("—", text: Binding(get: { measurements[m.id] ?? "" }, set: { measurements[m.id] = $0 }))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).font(.title3.bold()).frame(width: 90)
                        Text(m.unit).foregroundStyle(.secondary)
                    }
                    HowToMeasure(metric: m)
                }
                .padding(16).glassSurface(22)
            }
        }
    }

    private func done(_ r: (Level, String)) -> some View {
        VStack(spacing: 18) {
            Image(systemName: r.0 >= .escalate ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                .font(.system(size: 72)).foregroundStyle(r.0 >= .escalate ? .red : .green)
                .symbolEffect(.bounce, value: true)
                .padding(.top, 40)
            Text(r.0 >= .escalate ? "Please contact your flight surgeon" : "Logged").font(.largeTitle.bold())
            Text(r.1).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { dismiss() } label: { Text("Done").font(.headline).frame(maxWidth: .infinity).frame(height: 50) }
                .glassButton(prominent: true).padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Logic

    private func prefill() {
        guard let s = app.snapshot else { return }
        if let sl = s.evals["sleep_hours"]?.latest, sl.day == s.evalDay, !sl.sources.contains("manual") {
            sleepFromDevice = sl.value; sleepHours = (sl.value * 4).rounded() / 4
        }
    }

    private func submit() async {
        guard let p = app.person, let s = app.snapshot else { return }
        submitting = true
        defer { submitting = false }
        let now = s.mission.isSimulated ? s.asOf : Date()
        let src = SourceInfo(adapter: "manual", device: nil, kind: s.mission.isSimulated ? .simulated : .manual)
        func raw(_ m: String, _ v: Double, ctx: ObsContext? = nil, ts: Date? = nil) -> RawObservation {
            RawObservation(personId: p.id, missionId: p.missionId, ts: ts ?? now, metric: m, value: v, unit: app.config.metric(m)?.unit ?? "", source: src, context: ctx)
        }
        var raws: [RawObservation] = [raw("mood", Double(mood)), raw("stress", stress), raw("workload", workload), raw("sleep_quality", sleepQuality)]
        if sleepFromDevice == nil || abs((sleepFromDevice ?? 0) - sleepHours) > 0.2 {
            let wake = min(Calendar.current.startOfDay(for: now).addingTimeInterval(7 * 3600), now)
            raws.append(raw("sleep_hours", sleepHours, ctx: ObsContext(start: wake.addingTimeInterval(-sleepHours * 3600)), ts: wake))
        }
        for (code, sev) in symptoms { raws.append(raw("symptom", Double(sev), ctx: ObsContext(symptom: code))) }
        for (m, text) in measurements { if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { raws.append(raw(m, v)) } }
        let (r, note) = await ManualEntry.submit(raws, person: p)
        app.hub.setPrompt(Prompt(id: Scheduler.promptId(p.id, "daily_checkin", s.evalDay), personId: p.id, routineId: "daily_checkin", dueAt: now, state: .done, completedAt: now))
        app.hub.refresh([p.id], wait: true)
        app.pull()
        let red = symptoms.keys.contains { app.config.symptomByCode[$0]?.redFlag == true }
        let snap = app.snapshot
        var text = red ? "You reported a red-flag symptom." : ((snap?.overall.level ?? .ok) >= .watch ? (snap?.actions.first?.text ?? "Keep an eye on today's changes.") : "Nothing needs attention today.")
        if let note, note.contains("Apple Health") { text += "\n\(note)" }
        if (r?.rejected ?? 0) > 0 { text += "\nSome values looked implausible and weren't saved." }
        withAnimation(.snappy) { result = (red ? .escalate : (snap?.overall.level ?? .ok), text) }
    }
}
