import XCTest
@testable import CrewHealthHub

/// Importers run against an isolated in-memory Hub so tests never touch the app's real database.
final class ImporterTests: XCTestCase {
    var hub: Hub!
    var person: Person!

    override func setUpWithError() throws {
        hub = Hub(repo: try Repository.openDefault(inMemory: true), config: .shared)
        hub.tz = utc
        let m = Mission(id: "m", name: "Test", environment: "station", startDate: Date(timeIntervalSince1970: 1_700_000_000), plannedDays: 180, isSimulated: false)
        hub.save(m)
        person = Person(id: "p", displayName: "T", missionId: "m")
        hub.save(person)
    }

    func testCSVParserQuotesAndDelimiters() {
        let t = CSVParser.parse("\u{FEFF}date;\"Systolic (mmHg)\";Diastolic\r\n2026-01-02 08:00;120;80\r\n\"2026-01-03 08:00\";\"118\";\"76\"\r\n")
        XCTAssertEqual(t.headers, ["date", "Systolic (mmHg)", "Diastolic"])
        XCTAssertEqual(t.rows.count, 2)
        XCTAssertEqual(t.rows[1], ["2026-01-03 08:00", "118", "76"])
    }

    func testWideMappingAndDedupeOnReimport() throws {
        let csv = "Date,Systolic,Diastolic,Heart rate,Weight (lb)\n2026-01-02 08:00,120,80,62,165\n2026-01-03 08:00,118,76,60,164\n"
        let t = CSVParser.parse(csv)
        var m = CSVImporter.autoDetect(t)
        m.timeZone = utc
        XCTAssertEqual(m.format, .wide)
        XCTAssertEqual(m.tsColumn, 0)
        XCTAssertEqual(Set(m.wide.values.map(\.metric)), ["bp_sys", "bp_dia", "heart_rate", "weight"])
        let p1 = CSVImporter.toRaw(t, mapping: m, person: person, batchId: "b1")
        XCTAssertEqual(p1.raws.count, 8)
        let r1 = try hub.ingest.ingest(p1.raws)
        XCTAssertEqual(r1.inserted, 8)
        // Weight in lb converted to kg.
        let w = try hub.repo.observations(person: "p", metric: "weight", from: .distantPast, to: .distantFuture)
        XCTAssertEqual(w.first!.value, 74.84, accuracy: 0.01)
        // Re-import of the same file creates no duplicates.
        let p2 = CSVImporter.toRaw(t, mapping: m, person: person, batchId: "b2")
        XCTAssertEqual(try hub.ingest.ingest(p2.raws).inserted, 0)
        // Undo import removes exactly that batch.
        XCTAssertEqual(try hub.repo.deleteBatch("b1").count, 8)
    }

    func testLongFormatAndRejections() throws {
        let csv = "timestamp,metric,value,unit\n2026-01-02T08:00:00Z,glucose,5.5,mmol/L\n2026-01-02T09:00:00Z,heart_rate,400,bpm\nnot-a-date,mood,3,\n"
        let t = CSVParser.parse(csv)
        let m = CSVImporter.autoDetect(t)
        XCTAssertEqual(m.format, .long)
        let p = CSVImporter.toRaw(t, mapping: m, person: person, batchId: "b")
        XCTAssertEqual(p.raws.count, 2)
        XCTAssertEqual(p.skipped, 1)
        let r = try hub.ingest.ingest(p.raws)
        XCTAssertEqual(r.inserted, 1)
        XCTAssertEqual(r.rejected, 1)                // 400 bpm fails the sanity check
        let g = try hub.repo.observations(person: "p", metric: "glucose", from: .distantPast, to: .distantFuture)
        XCTAssertEqual(g.first!.value, 99.09, accuracy: 0.01)
    }

    func testNormalizedJSON() throws {
        let json = #"{"observations":[{"ts":"2026-01-02T08:00:00Z","metric":"spo2","value":97,"unit":"%"},{"ts":"2026-01-02T08:00:00Z","metric":"symptom","value":2,"context":{"symptom":"headache"}},{"metric":"mood"}]}"#
        let p = try CSVImporter.parseJSON(Data(json.utf8), person: person, batchId: "j")
        XCTAssertEqual(p.raws.count, 2)
        XCTAssertEqual(p.skipped, 1)
        XCTAssertEqual(p.raws[1].context?.symptom, "headache")
    }

    func testAppleHealthXMLFixture() throws {
        guard let url = Bundle(for: ImporterTests.self).url(forResource: "apple-health-small", withExtension: "xml") else { return XCTFail("fixture missing") }
        // Route the importer's submissions into the isolated hub.
        let since = DayKey.start("2026-01-01", utc)
        var collected: [RawObservation] = []
        let imp = AppleHealthXMLImporter(person: person, since: since, batchId: "ah") { _ in }
        imp.sink = { collected += $0 }
        let s = try imp.run(url: url)
        XCTAssertEqual(s.recordsSeen, 21)
        let r = try hub.ingest.ingest(collected)
        XCTAssertGreaterThan(r.inserted, 0)
        func vals(_ m: String) -> [Double] { ((try? hub.repo.observations(person: "p", metric: m, from: .distantPast, to: .distantFuture)) ?? []).map(\.value) }
        XCTAssertEqual(vals("spo2"), [97])                        // fraction 0.97 → 97 %
        XCTAssertEqual(vals("heart_rate").count, 1)               // 3 samples in one 5-min bucket → 1 median
        XCTAssertEqual(vals("heart_rate").first, 57)
        XCTAssertEqual(vals("heart_rate_resting"), [58])          // duplicate record deduplicated
        XCTAssertEqual(vals("body_temp").first ?? 0, 37.0, accuracy: 0.01)
        XCTAssertEqual(vals("glucose").first ?? 0, 93.68, accuracy: 0.01)
        XCTAssertEqual(vals("weight").first ?? 0, 74.84, accuracy: 0.01)
        XCTAssertEqual(vals("sleep_hours").count, 3)              // in-bed and awake are not sleep
        XCTAssertTrue(vals("heart_rate").allSatisfy { $0 != 70 }) // older than the selected history window
        // Overlapping sleep from two sources is merged: 23:00–04:00 (5 h) + 04:20–06:20 (2 h) = 7 h.
        let sleepObs = try hub.repo.observations(person: "p", metric: "sleep_hours", from: .distantPast, to: .distantFuture)
        let agg = Aggregator.aggregate(def: AppConfig.shared.metric("sleep_hours")!, personId: "p", day: "2026-11-09", obs: sleepObs, tz: utc)
        XCTAssertEqual(agg?.value ?? 0, 7.0, accuracy: 0.001)
    }

    // MARK: Apple Health export.zip

    func testZipExtractorZip64AndDataDescriptors() throws {
        let bundle = Bundle(for: ImporterTests.self)
        let original = try Data(contentsOf: bundle.url(forResource: "apple-health-small", withExtension: "xml")!)
        for name in ["health-export-zip64", "health-export-descriptor"] {
            let zip = try XCTUnwrap(bundle.url(forResource: name, withExtension: "zip"), name)
            let entries = try ZipExtractor.entries(of: zip)
            XCTAssertEqual(entries.count, 2, name)
            let xml = try ZipExtractor.extractHealthExport(from: zip)
            XCTAssertEqual(try Data(contentsOf: xml), original, "\(name): extracted export.xml must match byte for byte")
            try? FileManager.default.removeItem(at: xml)
        }
    }

    /// A real export compresses ~20:1; the inflater must keep draining output after the last input chunk.
    func testHighlyCompressedExportExtractsCompletely() throws {
        let zip = try XCTUnwrap(Bundle(for: ImporterTests.self).url(forResource: "health-export-large", withExtension: "zip"))
        let entry = try XCTUnwrap(ZipExtractor.entries(of: zip).first { $0.name.hasSuffix("/export.xml") })
        XCTAssertGreaterThan(entry.size, entry.compressedSize * 10)
        let xml = try ZipExtractor.extractHealthExport(from: zip)
        defer { try? FileManager.default.removeItem(at: xml) }
        let data = try Data(contentsOf: xml)
        XCTAssertEqual(UInt64(data.count), entry.size)
        XCTAssertTrue(String(decoding: data.suffix(14), as: UTF8.self).hasSuffix("</HealthData>\n"))
    }

    func testNotAZipFails() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("not.zip")
        try Data("hello world, not a zip".utf8).write(to: tmp)
        XCTAssertThrowsError(try ZipExtractor.entries(of: tmp))
    }

    func testStepsFromTwoSourcesAreNotDoubleCounted() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="en_US">
         <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2026-11-09 09:00:00 +0000" endDate="2026-11-09 10:00:00 +0000" value="3000"/>
         <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2026-11-09 12:00:00 +0000" endDate="2026-11-09 13:00:00 +0000" value="3000"/>
         <Record type="HKQuantityTypeIdentifierStepCount" sourceName="Watch" unit="count" startDate="2026-11-09 09:00:00 +0000" endDate="2026-11-09 10:00:00 +0000" value="3200"/>
         <Record type="HKQuantityTypeIdentifierStepCount" sourceName="Watch" unit="count" startDate="2026-11-09 12:00:00 +0000" endDate="2026-11-09 13:00:00 +0000" value="3300"/>
        </HealthData>
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("steps.xml")
        try Data(xml.utf8).write(to: url)
        var collected: [RawObservation] = []
        let imp = AppleHealthXMLImporter(person: person, since: DayKey.start("2026-01-01", utc), batchId: "s") { _ in }
        imp.sink = { collected += $0 }
        _ = try imp.run(url: url)
        let steps = collected.filter { $0.metric == "activity_steps" }
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.value, 6500)          // the Watch's total, not 12 500
        XCTAssertEqual(steps.first?.source.device, "Watch")
    }
}
