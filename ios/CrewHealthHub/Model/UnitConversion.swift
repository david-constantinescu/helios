import Foundation

/// Canonical units (PART 3.3) and conversions. Factors marked TODO(verify) are listed in docs/verify-register.md.
enum UnitConversion {
    enum ConvError: Error, LocalizedError {
        case unsupported(String, String)
        var errorDescription: String? {
            if case let .unsupported(u, m) = self { return "Unit \(u) is not supported for \(m)" }
            return nil
        }
    }

    // TODO(verify): standard factor ≈ 18.016 (molar mass of glucose 180.16 g/mol / 10)
    static let glucoseMmolToMg = 18.016
    static let kPaToMmHg = 7.50062
    static let lbToKg = 0.453592
    // TODO(verify): approximate; µR/h → µSv/h depends on radiation type. Use only for labelled imports.
    static let uRhToUSvh = 0.01

    static func normalizedUnit(_ u: String) -> String {
        let s = u.trimmingCharacters(in: .whitespaces).lowercased()
        switch s {
        case "bpm", "count/min", "beats/min", "/min": return "bpm"
        case "ms", "msec", "millisecond", "milliseconds": return "ms"
        case "mmhg": return "mmHg"
        case "kpa": return "kPa"
        case "mg/dl": return "mg/dL"
        case "mmol/l", "mmol<180.1558800000541>/l": return "mmol/L"
        case "c", "°c", "degc", "celsius": return "C"
        case "f", "°f", "degf", "fahrenheit": return "F"
        case "%", "percent", "pct": return "%"
        case "fraction", "ratio": return "fraction"
        case "h", "hr", "hrs", "hour", "hours": return "h"
        case "min", "mins", "minute", "minutes", "min/day": return "min"
        case "s", "sec", "seconds": return "s"
        case "kg", "kilogram", "kilograms": return "kg"
        case "lb", "lbs", "pound", "pounds": return "lb"
        case "µsv/h", "usv/h", "μsv/h", "usvh", "usv_h": return "uSv/h"
        case "nsv/h": return "nSv/h"
        case "msv/h": return "mSv/h"
        case "µr/h", "ur/h", "μr/h": return "uR/h"
        case "µsv", "usv", "μsv": return "uSv"
        case "msv": return "mSv"
        case "cpm": return "CPM"
        case "cps": return "CPS"
        case "breaths/min", "brpm", "rpm": return "breaths/min"
        case "ppm": return "ppm"
        case "count", "steps", "count/day": return "count"
        case "l", "liter", "litre", "liters", "litres": return "L"
        case "ml": return "mL"
        case "", "scale", "1-5", "1–5", "score", "severity": return "scale"
        default: return u
        }
    }

    /// Converts `value` in `unit` to the canonical unit of `metric`. Returns (value, canonicalUnit).
    static func toCanonical(_ value: Double, unit rawUnit: String, metric: MetricId, canonical: String) throws -> Double {
        let u = normalizedUnit(rawUnit)
        let c = normalizedUnit(canonical)
        if u == c { return value }
        switch (metric, u) {
        case ("bp_sys", "kPa"), ("bp_dia", "kPa"): return value * kPaToMmHg
        case ("glucose", "mmol/L"): return value * glucoseMmolToMg
        case ("body_temp", "F"), ("wrist_temp", "F"), ("cabin_temp", "F"): return (value - 32) * 5 / 9
        case ("spo2", "fraction"): return value * 100
        case ("spo2", "scale"), ("spo2", "count"): return value <= 1.0 ? value * 100 : value
        case ("sleep_hours", "min"): return value / 60
        case ("sleep_hours", "s"): return value / 3600
        case ("exercise_min", "h"): return value * 60
        case ("exercise_min", "s"): return value / 60
        case ("weight", "lb"): return value * lbToKg
        case ("rad_dose_rate", "nSv/h"): return value / 1000
        case ("rad_dose_rate", "mSv/h"): return value * 1000
        case ("rad_dose_rate", "uR/h"): return value * uRhToUSvh
        case ("rad_dose_cum", "mSv"): return value * 1000
        case ("rad_cpm", "CPS"): return value * 60
        case ("water_l", "mL"): return value / 1000
        default:
            // Scale metrics and counts accept unit-less input.
            if c == "scale" || c == "count" { return value }
            throw ConvError.unsupported(rawUnit, metric)
        }
    }

    // MARK: Apple Health export units → canonical (exports use the person's preferred units)

    private static let si: [String: (String, Double)] = [
        "km": ("len", 1000), "m": ("len", 1), "cm": ("len", 0.01), "mm": ("len", 0.001), "mi": ("len", 1609.344),
        "ft": ("len", 0.3048), "in": ("len", 0.0254), "yd": ("len", 0.9144),
        "kg": ("mass", 1), "g": ("mass", 0.001), "mg": ("mass", 1e-6), "mcg": ("mass", 1e-9), "µg": ("mass", 1e-9),
        "lb": ("mass", 0.45359237), "oz": ("mass", 0.028349523125), "st": ("mass", 6.35029318),
        "kcal": ("energy", 1), "Cal": ("energy", 1), "kJ": ("energy", 0.239005736), "cal": ("energy", 0.001),
        "s": ("time", 1), "min": ("time", 60), "hr": ("time", 3600), "h": ("time", 3600), "ms": ("time", 0.001), "d": ("time", 86400),
        "m/s": ("speed", 1), "km/hr": ("speed", 1 / 3.6), "mi/hr": ("speed", 0.44704), "ft/s": ("speed", 0.3048),
        "L": ("vol", 1), "mL": ("vol", 0.001), "fl_oz_us": ("vol", 0.0295735295625), "cup_us": ("vol", 0.2365882365),
        "L/min": ("flow", 1), "mL/min": ("flow", 0.001),
        "%": ("pct", 1), "dBASPL": ("db", 1), "dB": ("db", 1), "IU": ("iu", 1),
        "mL/min·kg": ("vo2", 1), "ml/(kg*min)": ("vo2", 1), "mL/kg/min": ("vo2", 1),
        "kcal/hr·kg": ("met", 1), "kcal/(kg*hr)": ("met", 1), "METs": ("met", 1),
        "mcS": ("cond", 1), "µS": ("cond", 1), "S": ("cond", 1e6),
    ]
    private static let countLike: Set<String> = ["count", "floors", "index", "", "/h", "count/min"]

    /// Factor that converts a value in an export `unit` to the metric's canonical unit, or nil if the units are incompatible.
    static func exportFactor(_ unit: String, to canonical: String) -> Double? {
        if unit == canonical { return 1 }
        if countLike.contains(canonical) && countLike.contains(unit) { return 1 }
        guard let (d1, f1) = si[unit], let (d2, f2) = si[canonical], d1 == d2 else { return nil }
        return f1 / f2
    }

    /// SpO2 values from Apple Health arrive as a fraction 0–1. Detect and convert.
    static func spo2Percent(_ v: Double) -> Double { v <= 1.0 ? v * 100 : v }

    // MARK: display

    static func display(_ value: Double, metric: MetricDef, units: Units) -> (Double, String) {
        let tempMetrics: Set<String> = ["body_temp", "cabin_temp", "wrist_temp"]
        if tempMetrics.contains(metric.id) && units.temp == "F" {
            return (value * 9 / 5 + 32, "°F")
        }
        if metric.id == "glucose" && units.glucose == "mmol/L" { return (value / glucoseMmolToMg, "mmol/L") }
        if metric.id == "weight" && units.weight == "lb" { return (value / lbToKg, "lb") }
        return (value, metric.unit)
    }

    static func format(_ value: Double, metric: MetricDef, units: Units, withUnit: Bool = true) -> String {
        let (v, u) = display(value, metric: metric, units: units)
        var dec = metric.decimals
        if metric.id == "glucose" && units.glucose == "mmol/L" { dec = 1 }
        let s = String(format: "%.\(dec)f", v)
        if !withUnit || u == "scale" || u.isEmpty { return s }
        if u == "1–5" { return "\(s)/5" }
        return "\(s) \(u)"
    }
}
