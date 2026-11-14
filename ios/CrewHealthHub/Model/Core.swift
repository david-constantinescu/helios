import Foundation

// MARK: - Core enums

typealias MetricId = String

enum Level: Int, Codable, Comparable, CaseIterable, Hashable {
    case unknown = 0, ok, watch, act, escalate

    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    init(name: String) {
        switch name {
        case "ok": self = .ok
        case "watch": self = .watch
        case "act": self = .act
        case "escalate": self = .escalate
        default: self = .unknown
        }
    }
    var name: String {
        switch self {
        case .unknown: return "unknown"
        case .ok: return "ok"
        case .watch: return "watch"
        case .act: return "act"
        case .escalate: return "escalate"
        }
    }
    var label: String {
        switch self {
        case .unknown: return "No data"
        case .ok: return "OK"
        case .watch: return "Watch"
        case .act: return "Act"
        case .escalate: return "Escalate"
        }
    }
    /// SF Symbol used alongside colour so status is never conveyed by colour alone.
    var symbol: String {
        switch self {
        case .unknown: return "questionmark.circle.fill"
        case .ok: return "checkmark.circle.fill"
        case .watch: return "eye.circle.fill"
        case .act: return "exclamationmark.triangle.fill"
        case .escalate: return "exclamationmark.octagon.fill"
        }
    }
}

enum Confidence: Int, Codable, Comparable {
    case low = 0, medium, high
    static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["low", "medium", "high"][rawValue] }
}

enum SourceKind: String, Codable { case device, manual, `import`, simulated }
enum Quality: String, Codable { case ok, suspect, rejected }
enum Direction: String, Codable { case high, low, both }

// MARK: - Entities

struct Units: Codable, Hashable {
    var temp: String = "C"          // C | F
    var glucose: String = "mg/dL"   // mg/dL | mmol/L
    var weight: String = "kg"       // kg | lb
}

struct Consent: Codable, Hashable {
    var shareStatus: Bool = true
    var shareMetrics: Bool = false
    var shareRadiation: Bool = true
}

struct Person: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var avatar: String?
    var role: String = "crew"       // crew | commander | observer
    var missionId: String
    var consent: Consent = Consent()
    var createdAt: Date = Date()
    var units: Units = Units()
    /// True for the person whose data comes from this iPhone's Apple Health store.
    var isHealthKitOwner: Bool = false
}

struct RadiationBudget: Codable, Hashable {
    var total_uSv: Double?
    var source: String = "TODO(verify): official mission/agency guidance"
    var verified: Bool = false
}

struct Mission: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var environment: String         // spacecraft | station | rover | lunar_base | mars_base
    var startDate: Date
    var plannedDays: Int
    var isSimulated: Bool
    var radiationBudget: RadiationBudget = RadiationBudget()
    /// For simulated missions: the simulated "now". nil means real time.
    var simNow: Date?
}

struct ObsContext: Codable, Hashable {
    var activity: String?       // rest | sleep | exercise | unknown
    var note: String?
    var fasting: Bool?
    var site: String?           // e.g. wrist_sleep
    var hrvType: String?        // SDNN | RMSSD
    var symptom: String?        // symptom code when metric == symptom
    var start: Date?            // interval start (sleep segments)
    var stage: String?          // sleep stage
    var pairId: String?         // BP pairing
}

struct SourceInfo: Codable, Hashable {
    var adapter: String
    var device: String?
    var kind: SourceKind
}

struct Observation: Codable, Identifiable, Hashable {
    var id: String
    var personId: String
    var missionId: String
    var ts: Date
    var metric: MetricId
    var value: Double
    var unit: String
    var source: SourceInfo
    var quality: Quality
    var qualityReason: String?
    var context: ObsContext?
    var importBatchId: String?
    var dedupeKey: String
    var externalId: String?
}

/// Un-normalised input from an adapter. Ingest validates, converts and stores it.
struct RawObservation {
    var personId: String
    var missionId: String
    var ts: Date
    var metric: MetricId
    var value: Double
    var unit: String
    var source: SourceInfo
    var context: ObsContext? = nil
    var importBatchId: String? = nil
    var externalId: String? = nil
    /// Overrides the hash-based dedupe key (e.g. "hk|<uuid>").
    var dedupeKey: String? = nil
    /// When true an existing row with the same dedupe key is replaced (e.g. daily statistics that change).
    var upsert: Bool = false
    /// Stable id to use when upserting.
    var stableId: String? = nil
}

struct DailyAggregate: Codable, Hashable {
    var personId: String
    var metric: MetricId
    var day: String             // yyyy-MM-dd in the person's time zone
    var n: Int
    var mean: Double
    var median: Double
    var min: Double
    var max: Double
    var last: Double
    /// The representative value for the day, chosen per metric rules (sum, median, last …).
    var value: Double
    var sources: [String]
    var hasSimulated: Bool
    var key: String { "\(personId)|\(metric)|\(day)" }
}

enum BaselineState: String, Codable { case learning, active, stale }

struct Baseline: Codable, Hashable {
    var personId: String
    var metric: MetricId
    var state: BaselineState
    var windowDays: Int
    var nDays: Int
    var median: Double
    var mad: Double
    var spread: Double
    var updatedAt: Date
    var sourceMix: [String]
    var note: String?
    var locked: Bool = false
    var key: String { "\(personId)|\(metric)" }
}

struct Reason: Codable, Hashable {
    var code: String
    var text: String
    var metric: MetricId?
    var value: Double?
    var baseline: Double?
    var z: Double?
    var slopePerDay: Double?
}

enum StatusScope: String, Codable { case metric, region, hazard, overall }

struct StatusResult: Codable, Hashable {
    var personId: String
    var scope: StatusScope
    var id: String
    var level: Level
    var confidence: Confidence
    var reasons: [Reason]
    var computedAt: Date
    var dataThrough: String?
    var counts: [String: Int]? = nil
}

enum EventKind: String, Codable { case radiation_spike, exercise, short_sleep, symptom, stressor, note }

struct EventMarker: Codable, Identifiable, Hashable {
    var id: String
    var personId: String
    var ts: Date
    var end: Date?
    var kind: EventKind
    var label: String
    var peak: Double?
    var open: Bool = false
}

enum PromptState: String, Codable { case pending, done, snoozed, skipped, missed }

struct Prompt: Codable, Identifiable, Hashable {
    var id: String
    var personId: String
    var routineId: String
    var dueAt: Date
    var state: PromptState
    var completedAt: Date?
    var snoozedUntil: Date?
}

struct QuestProgress: Codable, Identifiable, Hashable {
    var id: String
    var personId: String
    var questId: String
    var periodStart: String
    var progress: Double
    var target: Double
    var completedAt: Date?
}

struct BadgeAward: Codable, Identifiable, Hashable {
    var id: String
    var personId: String
    var badgeId: String
    var awardedAt: Date
    var why: String
}

/// An escalation the user must acknowledge (sticky until acknowledged).
struct EscalationAck: Codable, Hashable {
    var personId: String
    var key: String         // e.g. "metric:spo2" or "symptom:chest_pain|<day>"
    var acknowledgedAt: Date
    var note: String
}

// MARK: - Day keys

enum DayKey {
    private static var cache: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    static func formatter(_ tz: TimeZone) -> DateFormatter {
        lock.lock(); defer { lock.unlock() }
        if let f = cache[tz.identifier] { return f }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        cache[tz.identifier] = f
        return f
    }
    static func calendar(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c
    }
    static func of(_ d: Date, _ tz: TimeZone = .current) -> String { formatter(tz).string(from: d) }
    static func start(_ day: String, _ tz: TimeZone = .current) -> Date { formatter(tz).date(from: day) ?? Date.distantPast }
    static func add(_ day: String, _ n: Int, _ tz: TimeZone = .current) -> String {
        let d = calendar(tz).date(byAdding: .day, value: n, to: start(day, tz))!
        return of(d, tz)
    }
    static func diff(_ a: String, _ b: String, _ tz: TimeZone = .current) -> Int {
        calendar(tz).dateComponents([.day], from: start(b, tz), to: start(a, tz)).day ?? 0
    }
    static func range(from: String, to: String, _ tz: TimeZone = .current) -> [String] {
        var out: [String] = []; var d = from
        while d <= to && out.count < 5000 { out.append(d); d = add(d, 1, tz) }
        return out
    }
}

extension Date {
    var iso: String { ISO8601DateFormatter().string(from: self) }
}

func newId() -> String { UUID().uuidString.lowercased() }
