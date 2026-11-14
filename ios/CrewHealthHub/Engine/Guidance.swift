import Foundation

struct GuidanceItem: Identifiable, Hashable {
    var id: String
    var scope: String             // pattern | metric | symptom | radiation | region
    var refId: String
    var title: String
    var level: Level
    var regionIds: [String]
    var whatChanged: [String]
    var whatItMayMean: [String]
    var whatYouCanDo: [String]
    var howToRemeasure: [String]
    var whenToEscalate: [String]
    var sources: [String]
    var verified: Bool
    var tags: [String]
    var playbookId: String?
}

struct ActionItem: Identifiable, Hashable {
    var id: String { text }
    var text: String
    var level: Level
    var sourceItem: String
    var verified: Bool
}

/// Guidance engine (PART 5.8). Lookup order: pattern → metric × level → region/hazard default → generic.
/// Only `whatChanged` is generated (from reasons); all advice text comes verbatim from config.
enum GuidanceEngine {
    static func block(_ config: AppConfig, metric: MetricId, level: Level) -> GuidanceBlock? {
        guard let m = config.guidance.metrics[metric] else { return nil }
        var l = level
        while l >= .watch {
            if let b = m[l.name] { return b }
            l = Level(rawValue: l.rawValue - 1) ?? .unknown
        }
        return nil
    }

    static func build(config: AppConfig, evals: [MetricId: MetricEval], symptoms: [SymptomStatus], patterns: [FiredPattern],
                      radiation: RadiationResult?, escalationContact: String) -> [GuidanceItem] {
        var items: [GuidanceItem] = []
        let contact = escalationContact.isEmpty ? config.s("escalation.contact.default") : escalationContact

        func finalize(_ item: inout GuidanceItem) {
            if item.level >= .act {
                if item.whenToEscalate.isEmpty { item.whenToEscalate = config.guidance.generic.whenToEscalate }
                if !item.whenToEscalate.contains(contact) { item.whenToEscalate.append(contact) }
            }
            if item.whatYouCanDo.isEmpty { item.whatYouCanDo = config.guidance.generic.whatYouCanDo }
            if !item.verified && !item.tags.contains("draft") { item.tags.append("draft") }
        }

        // 1. Patterns.
        for p in patterns {
            var it = GuidanceItem(id: "pattern:\(p.id)", scope: "pattern", refId: p.id, title: p.def.label, level: .watch,
                                  regionIds: p.def.raises, whatChanged: [p.reason.text], whatItMayMean: p.def.whatItMayMean,
                                  whatYouCanDo: p.def.whatYouCanDo, howToRemeasure: [], whenToEscalate: p.def.whenToEscalate,
                                  sources: [p.def.source], verified: p.def.verified, tags: ["pattern"],
                                  playbookId: p.id == "sleep_debt" ? "sleep_reset" : (p.id == "countermeasure_lapse" ? "exercise_countermeasures" : nil))
            finalize(&it); items.append(it)
        }

        // 2. Symptoms (red flags bypass everything).
        for s in symptoms where s.level >= .watch {
            let rb = config.guidance.regions[s.region]
            var it = GuidanceItem(id: "symptom:\(s.code)", scope: "symptom", refId: s.code, title: s.redFlag ? "Red-flag symptom: \(s.label)" : "Symptom: \(s.label)",
                                  level: s.level, regionIds: [s.region], whatChanged: [s.reason.text],
                                  whatItMayMean: s.redFlag ? ["This symptom is on the red-flag list."] : [],
                                  whatYouCanDo: s.redFlag ? ["Stop what you are doing and rest.", "Follow mission emergency procedures."] : ((rb?.whatYouCanDo ?? []) + ["Log how it changes in your next check-in."]),
                                  howToRemeasure: [], whenToEscalate: s.redFlag ? [contact] : (rb?.whenToEscalate ?? []),
                                  sources: [rb?.source ?? "TODO(verify)"], verified: rb?.verified ?? false, tags: s.redFlag ? ["red_flag"] : [],
                                  playbookId: "illness_watch")
            finalize(&it); items.append(it)
        }

        // 3. Metrics × level.
        for (mid, e) in evals where e.status.level >= .watch {
            let def = e.def
            let (effLevel, _) = RollupEngine.effective(e.status)
            let b = block(config, metric: mid, level: e.status.level)
            let region = def.regions.first ?? "whole_body"
            let rb = config.guidance.regions[region]
            var it = GuidanceItem(id: "metric:\(mid)", scope: "metric", refId: mid, title: def.label, level: effLevel, regionIds: def.regions,
                                  whatChanged: e.status.reasons.filter { $0.code != "within_normal" }.map(\.text),
                                  whatItMayMean: b?.whatItMayMean ?? [], whatYouCanDo: b?.whatYouCanDo ?? rb?.whatYouCanDo ?? [],
                                  howToRemeasure: b?.howToRemeasure ?? def.howToMeasure,
                                  whenToEscalate: b?.whenToEscalate ?? rb?.whenToEscalate ?? [],
                                  sources: [b?.source ?? rb?.source ?? "TODO(verify)"], verified: b?.verified ?? false,
                                  tags: e.status.confidence == .low ? ["low_confidence"] : [], playbookId: mid == "sleep_hours" && e.status.level >= .act ? "sleep_reset" : nil)
            finalize(&it); items.append(it)
        }

        // 4. Radiation.
        if let r = radiation, r.hasData, r.level >= .watch {
            let pb = config.guidance.playbooks["radiation_event"]
            let hz = config.guidance.hazards["radiation"]
            let active = r.activeEvent != nil || r.level >= .act
            var it = GuidanceItem(id: "radiation", scope: "radiation", refId: "radiation", title: active ? "Radiation event" : "Radiation", level: r.level,
                                  regionIds: ["whole_body"], whatChanged: r.reasons.map(\.text),
                                  whatItMayMean: [config.radiation.labels["device"] ?? ""],
                                  whatYouCanDo: active ? (pb?.steps ?? []) : (hz?.whatYouCanDo ?? []),
                                  howToRemeasure: config.metric("rad_dose_rate")?.howToMeasure ?? [],
                                  whenToEscalate: hz?.whenToEscalate ?? [], sources: [pb?.source ?? config.radiation.source],
                                  verified: (pb?.verified ?? false) && config.radiation.verified, tags: ["radiation"], playbookId: "radiation_event")
            finalize(&it); items.append(it)
        }

        return items.sorted { a, b in a.level != b.level ? a.level > b.level : a.title < b.title }
    }

    /// At most `limit` distinct actions for the dashboard, highest level first.
    static func topActions(_ items: [GuidanceItem], limit: Int = 3) -> [ActionItem] {
        var out: [ActionItem] = []
        var seen = Set<String>()
        // First pass: the first action of each item; second pass: fill with further actions.
        for pass in 0..<2 {
            for it in items {
                let candidates = pass == 0 ? Array(it.whatYouCanDo.prefix(1)) : Array(it.whatYouCanDo.dropFirst())
                for a in candidates where !seen.contains(a) {
                    seen.insert(a); out.append(ActionItem(text: a, level: it.level, sourceItem: it.id, verified: it.verified))
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }
}
