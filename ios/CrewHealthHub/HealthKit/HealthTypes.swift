import Foundation
import HealthKit

/// How a HealthKit type maps onto the app's canonical metrics.
/// TODO(verify): identifiers and units against a real device export (docs/verify-register.md).
enum HKKind {
    case quantity(unit: HKUnit, metric: MetricId, scale: Double)
    case cumulative(unit: HKUnit, metric: MetricId)
    case sleep
    case symptom(code: String)
    case stateOfMind
    /// One observation (value 1) per category sample, e.g. notifications; `values` limits which category values count.
    case events(metric: MetricId, values: Set<Int>?)
    /// Category samples whose length matters (e.g. mindful sessions), stored as minutes.
    case duration(metric: MetricId)
    case workout
}

struct HKSpec: Identifiable {
    let id: String
    let label: String
    let type: HKSampleType
    let kind: HKKind
    /// Whether the app may write this type (requesting share for a read-only type crashes).
    let shareable: Bool

    var metric: MetricId {
        switch kind {
        case .quantity(_, let m, _), .cumulative(_, let m): return m
        case .sleep: return "sleep_hours"
        case .symptom: return "symptom"
        case .stateOfMind: return "mood"
        case .events(let m, _), .duration(let m): return m
        case .workout: return "workout_min"
        }
    }
    var isCumulative: Bool { if case .cumulative = kind { return true }; return false }
}

enum HKCatalog {
    static let simulatedKey = "CrewHealthHub.simulated"
    static let bpm = HKUnit.count().unitDivided(by: .minute())

    static let all: [HKSpec] = {
        var s: [HKSpec] = [
            HKSpec(id: "heartRate", label: "Heart rate", type: HKQuantityType(.heartRate), kind: .quantity(unit: bpm, metric: "heart_rate", scale: 1), shareable: true),
            HKSpec(id: "restingHeartRate", label: "Resting heart rate", type: HKQuantityType(.restingHeartRate), kind: .quantity(unit: bpm, metric: "heart_rate_resting", scale: 1), shareable: false),
            HKSpec(id: "hrvSDNN", label: "Heart-rate variability (SDNN)", type: HKQuantityType(.heartRateVariabilitySDNN), kind: .quantity(unit: .secondUnit(with: .milli), metric: "hrv", scale: 1), shareable: true),
            HKSpec(id: "oxygenSaturation", label: "Blood oxygen", type: HKQuantityType(.oxygenSaturation), kind: .quantity(unit: .percent(), metric: "spo2", scale: 100), shareable: true),
            HKSpec(id: "respiratoryRate", label: "Respiratory rate", type: HKQuantityType(.respiratoryRate), kind: .quantity(unit: bpm, metric: "resp_rate", scale: 1), shareable: true),
            HKSpec(id: "bpSystolic", label: "Blood pressure (systolic)", type: HKQuantityType(.bloodPressureSystolic), kind: .quantity(unit: .millimeterOfMercury(), metric: "bp_sys", scale: 1), shareable: true),
            HKSpec(id: "bpDiastolic", label: "Blood pressure (diastolic)", type: HKQuantityType(.bloodPressureDiastolic), kind: .quantity(unit: .millimeterOfMercury(), metric: "bp_dia", scale: 1), shareable: true),
            HKSpec(id: "bodyTemperature", label: "Body temperature", type: HKQuantityType(.bodyTemperature), kind: .quantity(unit: .degreeCelsius(), metric: "body_temp", scale: 1), shareable: true),
            HKSpec(id: "bloodGlucose", label: "Blood glucose", type: HKQuantityType(.bloodGlucose), kind: .quantity(unit: HKUnit(from: "mg/dL"), metric: "glucose", scale: 1), shareable: true),
            HKSpec(id: "bodyMass", label: "Body mass", type: HKQuantityType(.bodyMass), kind: .quantity(unit: .gramUnit(with: .kilo), metric: "weight", scale: 1), shareable: true),
            HKSpec(id: "dietaryWater", label: "Water", type: HKQuantityType(.dietaryWater), kind: .quantity(unit: .liter(), metric: "water_l", scale: 1), shareable: true),
            HKSpec(id: "stepCount", label: "Steps", type: HKQuantityType(.stepCount), kind: .cumulative(unit: .count(), metric: "activity_steps"), shareable: true),
            HKSpec(id: "exerciseTime", label: "Exercise minutes", type: HKQuantityType(.appleExerciseTime), kind: .cumulative(unit: .minute(), metric: "exercise_min"), shareable: false),
            HKSpec(id: "sleepAnalysis", label: "Sleep", type: HKCategoryType(.sleepAnalysis), kind: .sleep, shareable: true),
            HKSpec(id: "sym.headache", label: "Symptom: headache", type: HKCategoryType(.headache), kind: .symptom(code: "headache"), shareable: true),
            HKSpec(id: "sym.nausea", label: "Symptom: nausea", type: HKCategoryType(.nausea), kind: .symptom(code: "nausea"), shareable: true),
            HKSpec(id: "sym.dizziness", label: "Symptom: dizziness", type: HKCategoryType(.dizziness), kind: .symptom(code: "dizziness"), shareable: true),
            HKSpec(id: "sym.chest", label: "Symptom: chest tightness or pain", type: HKCategoryType(.chestTightnessOrPain), kind: .symptom(code: "chest_pain"), shareable: true),
            HKSpec(id: "sym.breath", label: "Symptom: shortness of breath", type: HKCategoryType(.shortnessOfBreath), kind: .symptom(code: "shortness_of_breath"), shareable: true),
            HKSpec(id: "sym.fatigue", label: "Symptom: fatigue", type: HKCategoryType(.fatigue), kind: .symptom(code: "fatigue"), shareable: true),
            HKSpec(id: "sym.back", label: "Symptom: lower back pain", type: HKCategoryType(.lowerBackPain), kind: .symptom(code: "back_joint_pain"), shareable: true),
            HKSpec(id: "sym.fever", label: "Symptom: fever", type: HKCategoryType(.fever), kind: .symptom(code: "fever_chills"), shareable: true),
            HKSpec(id: "sym.cough", label: "Symptom: coughing", type: HKCategoryType(.coughing), kind: .symptom(code: "cough"), shareable: true),
            HKSpec(id: "sym.mood", label: "Symptom: mood changes", type: HKCategoryType(.moodChanges), kind: .symptom(code: "mood_anxiety"), shareable: true),
            HKSpec(id: "sym.palpitations", label: "Symptom: rapid or fluttering heartbeat", type: HKCategoryType(.rapidPoundingOrFlutteringHeartbeat), kind: .symptom(code: "palpitations"), shareable: true),
        ]
        s += tracked
        if #available(iOS 16.0, *) {
            s.append(HKSpec(id: "wristTemperature", label: "Sleeping wrist temperature", type: HKQuantityType(.appleSleepingWristTemperature),
                            kind: .quantity(unit: .degreeCelsius(), metric: "wrist_temp", scale: 1), shareable: false))
        }
        if #available(iOS 18.0, *) {
            s.append(HKSpec(id: "stateOfMind", label: "State of Mind (mood)", type: HKSampleType.stateOfMindType(), kind: .stateOfMind, shareable: true))
        }
        return s
    }()

    // MARK: Everything else Apple Health records that is useful to show (read-only; engine "track").

    private static func q(_ id: HKQuantityTypeIdentifier, _ label: String, _ unit: HKUnit, _ metric: MetricId, scale: Double = 1) -> HKSpec {
        HKSpec(id: id.rawValue, label: label, type: HKQuantityType(id), kind: .quantity(unit: unit, metric: metric, scale: scale), shareable: false)
    }
    private static func sum(_ id: HKQuantityTypeIdentifier, _ label: String, _ unit: HKUnit, _ metric: MetricId) -> HKSpec {
        HKSpec(id: id.rawValue, label: label, type: HKQuantityType(id), kind: .cumulative(unit: unit, metric: metric), shareable: false)
    }
    private static func ev(_ id: HKCategoryTypeIdentifier, _ label: String, _ metric: MetricId, values: Set<Int>? = nil) -> HKSpec {
        HKSpec(id: id.rawValue, label: label, type: HKCategoryType(id), kind: .events(metric: metric, values: values), shareable: false)
    }

    static let kcal = HKUnit.kilocalorie()
    static let vo2Unit = HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
    static let metUnit = HKUnit.kilocalorie().unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))
    static let mps = HKUnit.meter().unitDivided(by: .second())

    static let tracked: [HKSpec] = {
        let s: [HKSpec] = [
            // Heart
            q(.walkingHeartRateAverage, "Walking heart rate", bpm, "walking_hr"),
            q(.heartRateRecoveryOneMinute, "Heart-rate recovery", bpm, "hr_recovery"),
            q(.vo2Max, "Cardio fitness (VO₂ max)", vo2Unit, "vo2max"),
            q(.atrialFibrillationBurden, "AFib history", .percent(), "afib_burden", scale: 100),
            q(.peripheralPerfusionIndex, "Perfusion index", .percent(), "perfusion_index", scale: 100),
            ev(.highHeartRateEvent, "High heart-rate notifications", "hr_high_events"),
            ev(.lowHeartRateEvent, "Low heart-rate notifications", "hr_low_events"),
            ev(.irregularHeartRhythmEvent, "Irregular rhythm notifications", "irregular_rhythm"),
            ev(.lowCardioFitnessEvent, "Low cardio fitness notifications", "low_fitness_events"),
            // Breathing
            q(.appleSleepingBreathingDisturbances, "Breathing disturbances", .count(), "breathing_disturbances"),
            ev(.sleepApneaEvent, "Sleep apnea notifications", "sleep_apnea_events"),
            q(.forcedVitalCapacity, "Forced vital capacity", .liter(), "fvc"),
            q(.forcedExpiratoryVolume1, "FEV₁", .liter(), "fev1"),
            q(.peakExpiratoryFlowRate, "Peak expiratory flow", HKUnit.liter().unitDivided(by: .minute()), "pef"),
            sum(.inhalerUsage, "Inhaler usage", .count(), "inhaler_uses"),
            // Body
            q(.bodyFatPercentage, "Body fat", .percent(), "body_fat", scale: 100),
            q(.bodyMassIndex, "Body mass index", .count(), "bmi"),
            q(.leanBodyMass, "Lean body mass", .gramUnit(with: .kilo), "lean_mass"),
            q(.height, "Height", .meterUnit(with: .centi), "height_cm"),
            q(.waistCircumference, "Waist circumference", .meterUnit(with: .centi), "waist_cm"),
            q(.basalBodyTemperature, "Basal body temperature", .degreeCelsius(), "basal_temp"),
            // Activity
            sum(.activeEnergyBurned, "Active energy", kcal, "active_kcal"),
            sum(.basalEnergyBurned, "Resting energy", kcal, "resting_kcal"),
            sum(.distanceWalkingRunning, "Walking + running distance", .meterUnit(with: .kilo), "distance_km"),
            sum(.distanceCycling, "Cycling distance", .meterUnit(with: .kilo), "cycling_km"),
            sum(.distanceSwimming, "Swimming distance", .meter(), "swim_m"),
            sum(.flightsClimbed, "Flights climbed", .count(), "flights"),
            sum(.appleStandTime, "Stand minutes", .minute(), "stand_min"),
            sum(.timeInDaylight, "Time in daylight", .minute(), "daylight_min"),
            q(.physicalEffort, "Physical effort", metUnit, "effort"),
            ev(.appleStandHour, "Stand hours", "stand_hours", values: [HKCategoryValueAppleStandHour.stood.rawValue]),
            HKSpec(id: "workouts", label: "Workouts", type: HKWorkoutType.workoutType(), kind: .workout, shareable: false),
            HKSpec(id: HKCategoryTypeIdentifier.mindfulSession.rawValue, label: "Mindful minutes", type: HKCategoryType(.mindfulSession),
                   kind: .duration(metric: "mindful_min"), shareable: false),
            // Mobility
            q(.walkingSpeed, "Walking speed", mps, "walking_speed"),
            q(.walkingStepLength, "Step length", .meterUnit(with: .centi), "step_length"),
            q(.walkingAsymmetryPercentage, "Walking asymmetry", .percent(), "walking_asymmetry", scale: 100),
            q(.walkingDoubleSupportPercentage, "Double support time", .percent(), "double_support", scale: 100),
            q(.stairAscentSpeed, "Stair speed: up", mps, "stair_up_speed"),
            q(.stairDescentSpeed, "Stair speed: down", mps, "stair_down_speed"),
            q(.sixMinuteWalkTestDistance, "Six-minute walk", .meter(), "six_min_walk"),
            q(.appleWalkingSteadiness, "Walking steadiness", .percent(), "walking_steadiness", scale: 100),
            sum(.numberOfTimesFallen, "Falls", .count(), "falls"),
            // Hearing & environment
            q(.environmentalAudioExposure, "Environmental sound", .decibelAWeightedSoundPressureLevel(), "noise_db"),
            q(.headphoneAudioExposure, "Headphone audio", .decibelAWeightedSoundPressureLevel(), "headphone_db"),
            ev(.environmentalAudioExposureEvent, "Loud environment notifications", "loud_noise_events"),
            q(.uvExposure, "UV exposure", .count(), "uv_index"),
            ev(.handwashingEvent, "Handwashing", "handwashing"),
            // Nutrition
            sum(.dietaryEnergyConsumed, "Dietary energy", kcal, "diet_kcal"),
            sum(.dietaryProtein, "Protein", .gram(), "protein_g"),
            sum(.dietaryCarbohydrates, "Carbohydrates", .gram(), "carbs_g"),
            sum(.dietaryFatTotal, "Total fat", .gram(), "fat_g"),
            sum(.dietarySugar, "Sugar", .gram(), "sugar_g"),
            sum(.dietaryFiber, "Fibre", .gram(), "fiber_g"),
            sum(.dietarySodium, "Sodium", .gramUnit(with: .milli), "sodium_mg"),
            sum(.dietaryPotassium, "Potassium", .gramUnit(with: .milli), "potassium_mg"),
            sum(.dietaryCalcium, "Calcium", .gramUnit(with: .milli), "calcium_mg"),
            sum(.dietaryVitaminD, "Vitamin D", .gramUnit(with: .micro), "vitamin_d_mcg"),
            sum(.dietaryIron, "Iron", .gramUnit(with: .milli), "iron_mg"),
            sum(.dietaryCaffeine, "Caffeine", .gramUnit(with: .milli), "caffeine_mg"),
            sum(.numberOfAlcoholicBeverages, "Alcoholic drinks", .count(), "alcohol_drinks"),
            q(.bloodAlcoholContent, "Blood alcohol", .percent(), "bac", scale: 100),
            // Other
            sum(.insulinDelivery, "Insulin delivery", .internationalUnit(), "insulin_iu"),
            q(.electrodermalActivity, "Electrodermal activity", .siemenUnit(with: .micro), "eda"),
        ]
        return s
    }()

    /// Sleep stage → metric for the per-stage totals (asleep stages also count towards `sleep_hours`).
    static let sleepStageMetric: [String: MetricId] = ["deep": "sleep_deep_h", "rem": "sleep_rem_h", "core": "sleep_core_h",
                                                        "awake": "sleep_awake_h", "in_bed": "in_bed_h"]

    static var readTypes: Set<HKObjectType> { Set(all.map(\.type)) }
    static var shareTypes: Set<HKSampleType> { Set(all.filter(\.shareable).map(\.type)) }
    static func spec(metric: MetricId) -> HKSpec? { all.first { $0.metric == metric && !$0.isCumulative } }
}
