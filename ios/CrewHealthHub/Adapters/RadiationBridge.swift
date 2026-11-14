import Foundation

/// Radiation adapter (PART 6.7): connects to the local Helios bridge over WebSocket (JSON lines),
/// reconnects with exponential backoff (1 s → 30 s), detects heartbeat loss (5 s), and can fall back to a
/// simulated 1 Hz source. Raw 1 Hz samples are kept in memory for the live chart; one-minute medians are
/// persisted as observations so the radiation engine (and cumulative dose) work across launches.
/// On a real iPhone, use the Mac's LAN address instead of 127.0.0.1 (the simulator shares the Mac's localhost).
final class RadiationBridge: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    static let shared = RadiationBridge()

    enum State: Equatable {
        case idle, searching, connected(String), lost, simulated, error(String)
        var label: String {
            switch self {
            case .idle: return "Not connected"
            case .searching: return "Searching…"
            case .connected(let d): return "Connected: \(d)"
            case .lost: return "Connection lost — retrying"
            case .simulated: return "Using simulated radiation"
            case .error(let e): return e
            }
        }
        var isLive: Bool { if case .connected = self { return true }; return self == .simulated }
    }

    struct Hello: Hashable { var bridge: String; var version: String; var device: String; var serial: String?; var drivers: [String]; var simulated: Bool = false }

    @Published private(set) var state: State = .idle
    @Published private(set) var hello: Hello?
    @Published private(set) var live: [RadSample] = []      // last 15 minutes at ~1 Hz
    @Published private(set) var lastSample: RadSample?
    @Published private(set) var lastCPM: Double?
    @Published private(set) var battery: Double?
    @Published private(set) var notFoundYet = false
    @Published private(set) var persistedCount = 0

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var wantConnected = false
    private var backoff: TimeInterval = 1
    private var lastMessageAt = Date.distantPast
    private var watchdog: Timer?
    private var simTimer: Timer?
    private var minuteBuffer: [Double] = []
    private var minuteCPM: [Double] = []
    private var lastCum: Double?
    private var currentMinute: Int = 0
    private var simSpikeStart: Date?
    private var rng = SeededRandom(seed: 99)

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue.main)
    }

    /// The person radiation samples are recorded for: the Apple Health owner, else the current non-simulated person.
    private var target: Person? {
        let hub = Hub.shared
        if let p = hub.healthKitOwner() { return p }
        return hub.persons().first { p in !(hub.mission(p.missionId)?.isSimulated ?? true) }
    }

    // MARK: Bridge connection

    func connect() {
        stopSimulated()
        wantConnected = true
        backoff = 1
        notFoundYet = false
        open()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.wantConnected else { return }
            if case .connected = self.state {} else { self.notFoundYet = true }
        }
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkHeartbeat() }
    }

    func disconnect() {
        wantConnected = false
        watchdog?.invalidate(); watchdog = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        flushMinute()
        state = .idle
    }

    private func open() {
        let s = Hub.shared.settings()
        guard let url = URL(string: s.bridgeURL) else { state = .error("Invalid bridge URL"); return }
        var req = URLRequest(url: url)
        req.setValue("app://crew-health-hub", forHTTPHeaderField: "Origin")
        if !s.bridgeToken.isEmpty { req.setValue("Bearer \(s.bridgeToken)", forHTTPHeaderField: "Authorization") }
        state = .searching
        task?.cancel()
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .failure:
                self.scheduleReconnect()
            case .success(let msg):
                switch msg {
                case .string(let s): s.split(separator: "\n").forEach { self.handle(String($0)) }
                case .data(let d): String(decoding: d, as: UTF8.self).split(separator: "\n").forEach { self.handle(String($0)) }
                @unknown default: break
                }
                self.receive(t)
            }
        }
    }

    private func scheduleReconnect() {
        guard wantConnected else { return }
        if case .connected = state { state = .lost } else if state != .lost { state = .searching }
        task = nil
        let delay = backoff
        backoff = min(backoff * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantConnected, self.task == nil else { return }
            self.open()
        }
    }

    private func checkHeartbeat() {
        guard wantConnected, case .connected = state else { return }
        if Date().timeIntervalSince(lastMessageAt) > 5 {
            task?.cancel(with: .abnormalClosure, reason: nil)
            scheduleReconnect()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        backoff = 1
        lastMessageAt = Date()
        webSocketTask.send(.string(#"{"type":"subscribe","hz":1}"#)) { _ in }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if webSocketTask === task { scheduleReconnect() }
    }

    /// Parses one JSON line from the bridge (protocol in PART 6.7).
    func handle(_ line: String) {
        guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let type = o["type"] as? String else { return }
        lastMessageAt = Date()
        switch type {
        case "hello":
            let h = Hello(bridge: o["bridge"] as? String ?? "bridge", version: o["version"] as? String ?? "?", device: o["device"] as? String ?? "detector",
                          serial: o["serial"] as? String, drivers: o["drivers"] as? [String] ?? [],
                          simulated: (o["simulated"] as? Bool) ?? ((o["device"] as? String)?.localizedCaseInsensitiveContains("simulated") ?? false))
            hello = h
            state = .connected(h.device)
            notFoundYet = false
        case "sample":
            let ts = (o["ts"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
            let rate = (o["dose_rate_uSv_h"] as? NSNumber)?.doubleValue
            let cpm = (o["count_rate_cpm"] as? NSNumber)?.doubleValue ?? (o["count_rate_cps"] as? NSNumber).map { $0.doubleValue * 60 }
            battery = (o["battery"] as? NSNumber)?.doubleValue
            if (o["quality"] as? String) == "ok" || o["quality"] == nil { ingestLive(ts: ts, rate: rate, cpm: cpm, cum: (o["dose_cum_uSv"] as? NSNumber)?.doubleValue) }
        case "error":
            if (o["code"] as? String) == "device_lost" { state = .lost } else { state = .error(o["message"] as? String ?? "Bridge error") }
        default: break   // heartbeat, spectrum (not used yet)
        }
    }

    // MARK: Live samples → persistence

    private func ingestLive(ts: Date, rate: Double?, cpm: Double?, cum: Double?) {
        if let rate {
            let s = RadSample(ts: ts, rate: rate)
            lastSample = s
            live.append(s)
            let cutoff = ts.addingTimeInterval(-15 * 60)
            if let i = live.firstIndex(where: { $0.ts >= cutoff }), i > 0 { live.removeFirst(i) }
        }
        if let cpm { lastCPM = cpm }
        let minute = Int(ts.timeIntervalSince1970 / 60)
        if minute != currentMinute { flushMinute(); currentMinute = minute }
        if let rate { minuteBuffer.append(rate) }
        if let cpm { minuteCPM.append(cpm) }
        if let cum { lastCum = cum }
    }

    private func flushMinute() {
        guard let p = target, !(minuteBuffer.isEmpty && minuteCPM.isEmpty) else { minuteBuffer = []; minuteCPM = []; return }
        let ts = Date(timeIntervalSince1970: Double(currentMinute) * 60 + 30)
        let device = state == .simulated ? "Simulated detector" : (hello?.device ?? "detector")
        // Honesty: anything coming from a simulated detector (in-app or the bridge's simulated driver) is labelled simulated.
        let simulated = state == .simulated || hello?.simulated == true
        let src = SourceInfo(adapter: "radiation_bridge", device: device, kind: simulated ? .simulated : .device)
        var raws: [RawObservation] = []
        if !minuteBuffer.isEmpty { raws.append(RawObservation(personId: p.id, missionId: p.missionId, ts: ts, metric: "rad_dose_rate", value: Stats.median(minuteBuffer), unit: "µSv/h", source: src)) }
        if !minuteCPM.isEmpty { raws.append(RawObservation(personId: p.id, missionId: p.missionId, ts: ts, metric: "rad_cpm", value: Stats.median(minuteCPM), unit: "CPM", source: src)) }
        if let c = lastCum { raws.append(RawObservation(personId: p.id, missionId: p.missionId, ts: ts, metric: "rad_dose_cum", value: c, unit: "µSv", source: src)) }
        minuteBuffer = []; minuteCPM = []
        let n = raws.count
        DispatchQueue.global(qos: .utility).async {
            _ = try? Hub.shared.submit(raws, allowHistory: true)
            DispatchQueue.main.async { self.persistedCount += n }
        }
    }

    // MARK: Helios Hub (the Pi forwards its detector over the hub link)

    /// Samples from the Helios Hub's detector. Ignored while this adapter is connected to its own bridge.
    func ingestFromHub(ts: Date, rate: Double?, cpm: Double?, cum: Double?, device: String) {
        if wantConnected || state == .simulated { return }
        if hello?.bridge != "crew-hub" || !state.isLive {
            hello = Hello(bridge: "crew-hub", version: "1.0", device: device, serial: nil, drivers: ["arduino"], simulated: false)
            state = .connected(device)
        }
        lastMessageAt = Date()
        ingestLive(ts: ts, rate: rate, cpm: cpm, cum: cum)
    }

    func hubDisconnected() {
        guard hello?.bridge == "crew-hub", !wantConnected else { return }
        flushMinute()
        hello = nil
        state = .idle
    }

    // MARK: Simulated detector (fallback when no hardware/bridge)

    func useSimulated() {
        disconnect()
        state = .simulated
        hello = Hello(bridge: "in-app", version: "1.0", device: "Simulated detector", serial: nil, drivers: ["simulated"], simulated: true)
        simTimer?.invalidate()
        simTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.simTick() }
        // Pre-fill 40 minutes of background so the engine can learn it right away.
        let now = Date()
        for i in stride(from: 40 * 60, to: 0, by: -10) {
            ingestLive(ts: now.addingTimeInterval(-Double(i)), rate: 0.10 + rng.normal(0, 0.006), cpm: 18 + rng.normal(0, 3), cum: nil)
        }
    }

    func stopSimulated() {
        simTimer?.invalidate(); simTimer = nil
        if state == .simulated { flushMinute(); state = .idle }
        simSpikeStart = nil
    }

    /// Triggers an illustrative spike in the simulated detector (ramp 20 min ×80, then decay).
    func triggerSimulatedSpike() { simSpikeStart = Date() }

    private func simTick() {
        let now = Date()
        var r = 0.10 + rng.normal(0, 0.006)
        if let s = simSpikeStart {
            let dt = now.timeIntervalSince(s) / 60 * 10   // compressed: 1 real minute = 10 event minutes
            r += dt < 20 ? 8 * dt / 20 : 8 * exp(-(dt - 20) / 120)
            if dt > 700 { simSpikeStart = nil }
        }
        ingestLive(ts: now, rate: max(0.001, r), cpm: max(0, r * 180 + rng.normal(0, 3)), cum: nil)
    }
}
