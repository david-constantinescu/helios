import Foundation

// All clinical ranges, guidance text, hazard explainers and dose numbers live in
// Resources/config/*.json with a `source` and `verified` flag. Nothing medical is hard-coded.

struct MetricDef: Codable, Hashable, Identifiable {
    var id: MetricId
    var label: String
    var unit: String
    var kind: String = "point"            // point | daily
    var group: String = "Other"
    var sanityMin: Double?
    var sanityMax: Double?
    var minSpread: Double = 1
    var direction: Direction = .both
    var regions: [String] = []
    var hazards: [String] = []
    var aggregation: String = "median"    // median | mean | sum | last | sleep | resting_hr | max
    var engine: String = "baseline"       // baseline | radiation | symptom | none
    var minLearningDays: Int?
    var decimals: Int = 0
    var scaleMin: Double?
    var scaleMax: Double?
    var howToMeasure: [String] = []
    var whyItMatters: String = ""
    var frequencyHint: String = ""
    var source: String = "TODO(verify)"
    var verified: Bool = false
    var manualEntry: Bool = true
    var alternateUnits: [String] = []
}

struct SymptomDef: Codable, Hashable, Identifiable {
    var code: String
    var label: String
    var region: String
    var hazards: [String] = []
    var redFlag: Bool = false
    var id: String { code }
}

struct MetricsFile: Codable {
    var metrics: [MetricDef]
    var symptoms: [SymptomDef]
}

struct EngineParams: Codable, Hashable {
    var watchZ: Double = 2.0
    var actZ: Double = 3.0
    var escalateZ: Double = 4.5
    var persistWatchDays: Int = 2
    var persistActDays: Int = 3
    var trendWatch: Double = 1.5
    var trendAct: Double = 2.5
    var minLearningDays: Int = 7
    var windowDays: Int = 21
    var staleDays: Int = 10
    var baselineLagDays: Int = 3
    var symptomLookbackDays: Int = 3
}

struct Band: Codable, Hashable {
    var level: String
    var min: Double
    var max: Double
}

struct RangeDef: Codable, Hashable {
    var unit: String
    var bands: [Band]
    var source: String
    var verified: Bool
}

struct AlwaysEscalateRule: Codable, Hashable {
    var metric: String
    var match: [String]?
    var minSeverity: Double?
    var above: Double?
    var below: Double?
    var reason: String
}

struct ReferenceRangesFile: Codable {
    var engine: EngineParams
    var ranges: [String: RangeDef]
    var alwaysEscalate: [AlwaysEscalateRule]
    var symptomLevels: [String: String]
}

struct HazardDef: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var icon: String
    var explainer: String
    var feeds: [String]
    var relatedRisks: [String] = []
    var countermeasures: [String] = []
    var link: String = ""
    var source: String
    var verified: Bool
}
struct HazardsFile: Codable { var hazards: [HazardDef] }

struct RegionDef: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var icon: String
    var function: String
    var hazards: [String]
    var source: String
    var verified: Bool
}
struct RegionsFile: Codable { var regions: [RegionDef] }

struct GuidanceBlock: Codable, Hashable {
    var whatItMayMean: [String] = []
    var whatYouCanDo: [String] = []
    var howToRemeasure: [String]? = nil
    var whenToEscalate: [String] = []
    var source: String = "TODO(verify)"
    var verified: Bool = false
}

struct PatternCond: Codable, Hashable {
    var metric: String?
    var dir: String?
    var days: Int?
    var anyOf: [PatternCond]?
    var all: [PatternCond]?
    var adherenceBelow: Double?
    var routine: String?
}

struct PatternDef: Codable, Hashable {
    var label: String
    var fires: PatternCond
    var raises: [String] = []
    var raisesHazards: [String] = []
    var whatItMayMean: [String] = []
    var whatYouCanDo: [String] = []
    var whenToEscalate: [String] = []
    var source: String = "TODO(verify)"
    var verified: Bool = false
}

struct PlaybookDef: Codable, Hashable {
    var label: String
    var summary: String = ""
    var steps: [String]
    var source: String
    var verified: Bool
}

struct GenericGuidance: Codable, Hashable {
    var whatYouCanDo: [String]
    var whenToEscalate: [String]
}

struct GuidanceFile: Codable {
    var metrics: [String: [String: GuidanceBlock]]
    var regions: [String: GuidanceBlock]
    var hazards: [String: GuidanceBlock]
    var patterns: [String: PatternDef]
    var playbooks: [String: PlaybookDef]
    var redFlags: [String]
    var generic: GenericGuidance
    var escalationPage: [String]
}

struct BudgetAlert: Codable, Hashable { var level: String; var at: Double }
struct DoseRateAlerts: Codable, Hashable { var watchMultiple: Double; var actMultiple: Double; var escalateMultiple: Double }
struct SpikeParams: Codable, Hashable { var k: Double; var f: Double; var minutes: Double }

struct RadiationFile: Codable {
    var budget: RadiationBudget
    var alerts: RadiationAlerts
    var spike: SpikeParams
    var maxGapMin: Double
    var ewmaSeconds: Double
    var backgroundMinMinutes: Double
    var labels: [String: String]
    var shieldingTips: [String]
    var explainer: String
    var source: String
    var verified: Bool
    struct RadiationAlerts: Codable { var budgetPercent: [BudgetAlert]; var doseRate: DoseRateAlerts }
}

struct EnvironmentDef: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var icon: String
    var description: String
    var emphasis: [String]
    var routineOverrides: [String: RoutineOverride]
    struct RoutineOverride: Codable, Hashable { var cadence: String?; var enabled: Bool?; var extra: [String]?; var time: String? }
}
struct EnvironmentsFile: Codable { var environments: [EnvironmentDef] }

struct RoutineDef: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var cadence: String         // daily | weekly | everyNDays | after_event:exercise
    var time: String?
    var dow: Int?               // 1 = Monday
    var everyDays: Int?
    var metrics: [String]
    var estSeconds: Int = 60
    var enabled: Bool = true
    var graceHours: Double = 12
}
struct RoutinesFile: Codable { var routines: [RoutineDef] }

struct QuestDef: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var description: String
    var icon: String
    var period: String          // daily | weekly
    var kind: String            // checkin | sleep_window | water | exercise | on_time | drill
    var target: Double
    var cap: Double?
    var xp: Int
    var safetyNote: String?
}
struct BadgeDef: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var icon: String
    var criteria: String
}
struct QuestsFile: Codable { var quests: [QuestDef]; var badges: [BadgeDef]; var xpPerLevel: Int }

/// The full immutable configuration bundle.
final class AppConfig {
    let metrics: [MetricDef]
    let metricById: [MetricId: MetricDef]
    let symptoms: [SymptomDef]
    let symptomByCode: [String: SymptomDef]
    let ranges: ReferenceRangesFile
    let hazards: [HazardDef]
    let regions: [RegionDef]
    let guidance: GuidanceFile
    let radiation: RadiationFile
    let environments: [EnvironmentDef]
    let routines: [RoutineDef]
    let quests: QuestsFile
    let strings: [String: String]

    init(bundle: Bundle = .main) throws {
        func load<T: Decodable>(_ name: String, _ type: T.Type) throws -> T {
            guard let url = bundle.url(forResource: name, withExtension: "json") else {
                throw NSError(domain: "config", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing config \(name).json"])
            }
            do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
            catch { throw NSError(domain: "config", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(name).json: \(error)"]) }
        }
        let mf = try load("metrics", MetricsFile.self)
        metrics = mf.metrics
        metricById = Dictionary(uniqueKeysWithValues: mf.metrics.map { ($0.id, $0) })
        symptoms = mf.symptoms
        symptomByCode = Dictionary(uniqueKeysWithValues: mf.symptoms.map { ($0.code, $0) })
        ranges = try load("reference_ranges", ReferenceRangesFile.self)
        hazards = try load("hazards", HazardsFile.self).hazards
        regions = try load("regions", RegionsFile.self).regions
        guidance = try load("guidance", GuidanceFile.self)
        radiation = try load("radiation", RadiationFile.self)
        environments = try load("environments", EnvironmentsFile.self).environments
        routines = try load("routines", RoutinesFile.self).routines
        quests = try load("quests", QuestsFile.self)
        strings = try load("strings.en", [String: String].self)
    }

    static let shared: AppConfig = {
        do { return try AppConfig() } catch { fatalError("Config failed to load: \(error)") }
    }()

    func metric(_ id: MetricId) -> MetricDef? { metricById[id] }
    func s(_ key: String, _ args: [String: String] = [:]) -> String {
        var t = strings[key] ?? key
        for (k, v) in args { t = t.replacingOccurrences(of: "{\(k)}", with: v) }
        return t
    }
    func metrics(inRegion r: String) -> [MetricDef] { metrics.filter { $0.regions.contains(r) } }
    func region(_ id: String) -> RegionDef? { regions.first { $0.id == id } }
    func hazard(_ id: String) -> HazardDef? { hazards.first { $0.id == id } }
    func environment(_ id: String) -> EnvironmentDef? { environments.first { $0.id == id } }
}

// MARK: - Lenient decoding (synthesized Decodable ignores default values)

extension KeyedDecodingContainer {
    func v<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

extension MetricDef {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        unit = try c.decode(String.self, forKey: .unit)
        kind = try c.v(.kind, "point")
        group = try c.v(.group, "Other")
        sanityMin = try c.decodeIfPresent(Double.self, forKey: .sanityMin)
        sanityMax = try c.decodeIfPresent(Double.self, forKey: .sanityMax)
        minSpread = try c.v(.minSpread, 1)
        direction = try c.v(.direction, .both)
        regions = try c.v(.regions, [])
        hazards = try c.v(.hazards, [])
        aggregation = try c.v(.aggregation, "median")
        engine = try c.v(.engine, "baseline")
        minLearningDays = try c.decodeIfPresent(Int.self, forKey: .minLearningDays)
        decimals = try c.v(.decimals, 0)
        scaleMin = try c.decodeIfPresent(Double.self, forKey: .scaleMin)
        scaleMax = try c.decodeIfPresent(Double.self, forKey: .scaleMax)
        howToMeasure = try c.v(.howToMeasure, [])
        whyItMatters = try c.v(.whyItMatters, "")
        frequencyHint = try c.v(.frequencyHint, "")
        source = try c.v(.source, "TODO(verify)")
        verified = try c.v(.verified, false)
        manualEntry = try c.v(.manualEntry, true)
        alternateUnits = try c.v(.alternateUnits, [])
    }
}

extension SymptomDef {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        label = try c.decode(String.self, forKey: .label)
        region = try c.decode(String.self, forKey: .region)
        hazards = try c.v(.hazards, [])
        redFlag = try c.v(.redFlag, false)
    }
}

extension EngineParams {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = EngineParams.defaults
        watchZ = try c.v(.watchZ, z.watchZ); actZ = try c.v(.actZ, z.actZ); escalateZ = try c.v(.escalateZ, z.escalateZ)
        persistWatchDays = try c.v(.persistWatchDays, z.persistWatchDays); persistActDays = try c.v(.persistActDays, z.persistActDays)
        trendWatch = try c.v(.trendWatch, z.trendWatch); trendAct = try c.v(.trendAct, z.trendAct)
        minLearningDays = try c.v(.minLearningDays, z.minLearningDays); windowDays = try c.v(.windowDays, z.windowDays)
        staleDays = try c.v(.staleDays, z.staleDays); baselineLagDays = try c.v(.baselineLagDays, z.baselineLagDays)
        symptomLookbackDays = try c.v(.symptomLookbackDays, z.symptomLookbackDays)
    }
    static let defaults = EngineParams(watchZ: 2.0, actZ: 3.0, escalateZ: 4.5, persistWatchDays: 2, persistActDays: 3, trendWatch: 1.5, trendAct: 2.5, minLearningDays: 7, windowDays: 21, staleDays: 10, baselineLagDays: 3, symptomLookbackDays: 3)
}

extension GuidanceBlock {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        whatItMayMean = try c.v(.whatItMayMean, [])
        whatYouCanDo = try c.v(.whatYouCanDo, [])
        howToRemeasure = try c.decodeIfPresent([String].self, forKey: .howToRemeasure)
        whenToEscalate = try c.v(.whenToEscalate, [])
        source = try c.v(.source, "TODO(verify)")
        verified = try c.v(.verified, false)
    }
}

extension PatternDef {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        fires = try c.decode(PatternCond.self, forKey: .fires)
        raises = try c.v(.raises, []); raisesHazards = try c.v(.raisesHazards, [])
        whatItMayMean = try c.v(.whatItMayMean, []); whatYouCanDo = try c.v(.whatYouCanDo, [])
        whenToEscalate = try c.v(.whenToEscalate, [])
        source = try c.v(.source, "TODO(verify)"); verified = try c.v(.verified, false)
    }
}

extension PlaybookDef {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        summary = try c.v(.summary, "")
        steps = try c.decode([String].self, forKey: .steps)
        source = try c.v(.source, "TODO(verify)"); verified = try c.v(.verified, false)
    }
}

extension RoutineDef {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        cadence = try c.decode(String.self, forKey: .cadence)
        time = try c.decodeIfPresent(String.self, forKey: .time)
        dow = try c.decodeIfPresent(Int.self, forKey: .dow)
        everyDays = try c.decodeIfPresent(Int.self, forKey: .everyDays)
        metrics = try c.decode([String].self, forKey: .metrics)
        estSeconds = try c.v(.estSeconds, 60)
        enabled = try c.v(.enabled, true)
        graceHours = try c.v(.graceHours, 12)
    }
}

extension HazardDef {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); label = try c.decode(String.self, forKey: .label)
        icon = try c.v(.icon, "circle"); explainer = try c.v(.explainer, "")
        feeds = try c.v(.feeds, []); relatedRisks = try c.v(.relatedRisks, []); countermeasures = try c.v(.countermeasures, [])
        link = try c.v(.link, ""); source = try c.v(.source, "TODO(verify)"); verified = try c.v(.verified, false)
    }
}
