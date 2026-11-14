import Foundation
import SwiftUI

/// Imports a personal Apple Health export (`export.zip` from Health › profile › Export All Health Data, or the
/// `export.xml` inside it) into the "me" person. Works on the simulator, where live HealthKit sync can't see your iPhone.
@MainActor
final class HealthFileImport: ObservableObject {
    static let shared = HealthFileImport()

    enum Phase: Equatable {
        case idle
        case unzipping(Double)
        case reading(seen: Int, kept: Int)
        case done(seen: Int, stored: Int, types: Int, from: Date?, to: Date?)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var historyDays = 3650
    private var token = CancelToken()
    private var importer: AppleHealthXMLImporter?

    var isBusy: Bool {
        switch phase { case .unzipping, .reading: return true; default: return false }
    }

    func cancel() { token.cancel(); importer?.cancelled = true }
    func reset() { if !isBusy { phase = .idle } }

    func start(url: URL, app: AppState) {
        guard !isBusy else { return }
        token = CancelToken()
        let token = self.token
        let me = HealthConnect.ensureOwner(app: app)
        let hub = app.hub
        // Avoid double counting: if live sync already reads this person's Health data, a file import would duplicate it.
        let liveRows = (try? hub.repo.count(person: me.id, adapter: "apple_health")) ?? 0
        if app.settings.hkEnabled && liveRows > 500 {
            phase = .failed("Live Apple Health sync is already reading this data on this iPhone, so importing the file would count it twice.")
            return
        }
        // Copy out of the security scope first (Files / AirDrop / Mail hand us temporary access).
        let scoped = url.startAccessingSecurityScopedResource()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)-\(url.lastPathComponent)")
        do { try FileManager.default.copyItem(at: url, to: work) }
        catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            phase = .failed("Couldn't open that file: \(error.localizedDescription)"); return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }

        let isZip = work.pathExtension.lowercased() == "zip"
        phase = isZip ? .unzipping(0) : .reading(seen: 0, kept: 0)
        let since = Date().addingTimeInterval(-Double(historyDays) * 86400)
        let batch = "health-export-\(newId().prefix(8))"
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var xml = work
            do {
                if isZip {
                    xml = try ZipExtractor.extractHealthExport(from: work, progress: { p in
                        Task { @MainActor in self.phase = .unzipping(p) }
                    }, isCancelled: { token.isCancelled })
                    try? FileManager.default.removeItem(at: work)
                }
                let imp = AppleHealthXMLImporter(person: me, since: since, batchId: batch) { s in
                    Task { @MainActor in self.phase = .reading(seen: s.recordsSeen, kept: s.recordsKept) }
                }
                await MainActor.run { self.importer = imp }
                let s = try imp.run(url: xml)
                try? FileManager.default.removeItem(at: xml)
                if token.isCancelled { await MainActor.run { self.phase = .idle }; return }
                hub.refresh([me.id], wait: true)
                let range = try? hub.repo.db.query("SELECT MIN(ts), MAX(ts) FROM observations WHERE person_id=? AND adapter='apple_health_file'", [.text(me.id)]).first
                let from = range?.double(0).map { Date(timeIntervalSince1970: $0) }
                let to = range?.double(1).map { Date(timeIntervalSince1970: $0) }
                await MainActor.run {
                    UserDefaults.standard.set(batch, forKey: "ui.lastImportBatch")
                    self.phase = .done(seen: s.recordsSeen, stored: s.inserted, types: s.byMetric.count, from: from, to: to)
                    app.reloadPersons()
                    app.select(person: me.id)
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: xml)
                await MainActor.run { self.phase = .idle }
            } catch {
                try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: xml)
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }
}

/// Thread-safe cancellation flag shared with the background import.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
