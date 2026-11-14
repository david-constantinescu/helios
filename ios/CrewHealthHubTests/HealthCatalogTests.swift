import XCTest
import HealthKit
@testable import CrewHealthHub

/// Guards for the Apple Health type catalog. An incompatible unit or a non-cumulative type in a statistics query
/// raises an Objective-C exception at runtime — only on a device with real data — so check every spec here.
final class HealthCatalogTests: XCTestCase {
    func testEveryQuantityUnitIsCompatibleWithItsType() {
        for spec in HKCatalog.all {
            switch spec.kind {
            case let .quantity(unit, _, _), let .cumulative(unit, _):
                let qt = spec.type as! HKQuantityType
                XCTAssertTrue(qt.is(compatibleWith: unit), "\(spec.id): \(unit.unitString) is not compatible")
            default: break
            }
        }
    }

    func testCumulativeSpecsAreCumulativeTypes() {
        for spec in HKCatalog.all where spec.isCumulative {
            XCTAssertEqual((spec.type as! HKQuantityType).aggregationStyle, .cumulative, spec.id)
        }
    }

    func testNewTypesAreReadOnlyAndKnownToConfig() {
        let cfg = AppConfig.shared
        for spec in HKCatalog.tracked {
            XCTAssertFalse(spec.shareable, "\(spec.id) must be read-only")
            let def = cfg.metric(spec.metric)
            XCTAssertNotNil(def, "\(spec.metric) missing from metrics.json")
            XCTAssertEqual(def?.engine, "track", spec.metric)
            XCTAssertEqual(def?.manualEntry, false, spec.metric)
        }
        for m in HKCatalog.sleepStageMetric.values { XCTAssertNotNil(cfg.metric(m), m) }
        XCTAssertEqual(Set(HKCatalog.all.map(\.id)).count, HKCatalog.all.count, "duplicate spec ids")
        XCTAssertGreaterThan(HKCatalog.all.count, 80)
    }

    func testExportUnitFactors() {
        XCTAssertEqual(UnitConversion.exportFactor("mi", to: "km")!, 1.609344, accuracy: 1e-9)
        XCTAssertEqual(UnitConversion.exportFactor("kJ", to: "kcal")!, 0.239005736, accuracy: 1e-9)
        XCTAssertEqual(UnitConversion.exportFactor("g", to: "mg")!, 1000, accuracy: 1e-9)
        XCTAssertEqual(UnitConversion.exportFactor("km/hr", to: "m/s")!, 1 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(UnitConversion.exportFactor("in", to: "cm")!, 2.54, accuracy: 1e-9)
        XCTAssertEqual(UnitConversion.exportFactor("count", to: "floors"), 1)
        XCTAssertNil(UnitConversion.exportFactor("kg", to: "km"))
    }

    func testExportImportOfTrackedRecords() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="en_US">
         <Record type="HKQuantityTypeIdentifierDistanceWalkingRunning" sourceName="iPhone" unit="mi" startDate="2026-11-09 09:00:00 +0000" endDate="2026-11-09 10:00:00 +0000" value="1"/>
         <Record type="HKQuantityTypeIdentifierDistanceWalkingRunning" sourceName="iPhone" unit="mi" startDate="2026-11-09 12:00:00 +0000" endDate="2026-11-09 13:00:00 +0000" value="2"/>
         <Record type="HKQuantityTypeIdentifierActiveEnergyBurned" sourceName="Watch" unit="kJ" startDate="2026-11-09 12:00:00 +0000" endDate="2026-11-09 13:00:00 +0000" value="418.4"/>
         <Record type="HKQuantityTypeIdentifierBodyFatPercentage" sourceName="Scale" unit="%" startDate="2026-11-09 07:00:00 +0000" endDate="2026-11-09 07:00:00 +0000" value="0.18"/>
         <Record type="HKQuantityTypeIdentifierVO2Max" sourceName="Watch" unit="mL/min·kg" startDate="2026-11-09 07:00:00 +0000" endDate="2026-11-09 07:00:00 +0000" value="44.5"/>
         <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Watch" value="HKCategoryValueSleepAnalysisAsleepDeep" startDate="2026-11-09 01:00:00 +0000" endDate="2026-11-09 02:30:00 +0000"/>
         <Record type="HKCategoryTypeIdentifierMindfulSession" sourceName="Watch" value="HKCategoryValueNotApplicable" startDate="2026-11-09 08:00:00 +0000" endDate="2026-11-09 08:10:00 +0000"/>
         <Record type="HKCategoryTypeIdentifierAppleStandHour" sourceName="Watch" value="HKCategoryValueAppleStandHourStood" startDate="2026-11-09 08:00:00 +0000" endDate="2026-11-09 09:00:00 +0000"/>
         <Record type="HKCategoryTypeIdentifierAppleStandHour" sourceName="Watch" value="HKCategoryValueAppleStandHourIdle" startDate="2026-11-09 09:00:00 +0000" endDate="2026-11-09 10:00:00 +0000"/>
         <Workout workoutActivityType="HKWorkoutActivityTypeTraditionalStrengthTraining" duration="45" durationUnit="min" sourceName="Watch" startDate="2026-11-09 17:00:00 +0000" endDate="2026-11-09 17:45:00 +0000"/>
        </HealthData>
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tracked-\(UUID().uuidString).xml")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let person = Person(id: "t", displayName: "T", avatar: nil, role: "crew", missionId: "m")
        let imp = AppleHealthXMLImporter(person: person, since: .distantPast, batchId: "b", onProgress: { _ in })
        var got: [RawObservation] = []
        imp.sink = { got += $0 }
        _ = try imp.run(url: url)
        func values(_ m: String) -> [Double] { got.filter { $0.metric == m }.map(\.value) }

        XCTAssertEqual(values("distance_km").first ?? 0, 3 * 1.609344, accuracy: 0.001, "miles summed per day and converted")
        XCTAssertEqual(values("active_kcal").first ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(values("body_fat"), [18], "fraction exported with % becomes a percentage")
        XCTAssertEqual(values("vo2max"), [44.5])
        XCTAssertEqual(values("sleep_deep_h"), [1.5])
        XCTAssertEqual(values("sleep_hours"), [1.5], "deep sleep still counts as sleep")
        XCTAssertEqual(values("mindful_min"), [10])
        XCTAssertEqual(values("stand_hours"), [1], "idle hours are not stand hours")
        XCTAssertEqual(values("workout_min"), [45])
        XCTAssertEqual(got.first { $0.metric == "workout_min" }?.context?.activity, "Traditional Strength Training")
        for o in got { XCTAssertEqual(o.unit, AppConfig.shared.metric(o.metric)?.unit, o.metric) }
    }
}
