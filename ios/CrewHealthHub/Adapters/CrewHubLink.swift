import Foundation
import UIKit

/// Link to the Helios Hub (Raspberry Pi + Arduino sensors + OLED), the centre of the habitat.
///
/// * Sends the hub every observation on this iPhone (all people, incremental, acknowledged in batches) and each
///   person's latest analysis, so the hub's screen shows the same statuses as the app.
/// * Receives the habitat sensors (cabin air, pressure, CO₂, O₂, noise, light) and the radiation detector; radiation
///   flows into the same pipeline as a standalone detector.
/// * Alerts acknowledged on the hub with the joystick are recorded here.
/// Today the link runs over Wi-Fi / the internet (WebSocket); the protocol is transport-independent.
final class CrewHubLink: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    static let shared = CrewHubLink()

    enum State: Equatable {
        case off, connecting, connected, lost, rejected(String)
        var label: String {
            switch self {
            case .off: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .lost: return "Reconnecting…"
            case .rejected(let why): return why
            }
        }
    }

    struct Sensor: Identifiable { let id: String; let label: String; let unit: String; let decimals: Int; let symbol: String }
    static let sensors: [Sensor] = [
        Sensor(id: "cabin_temp", label: "Temperature", unit: "°C", decimals: 1, symbol: "thermometer.medium"),
        Sensor(id: "humidity", label: "Humidity", unit: "%", decimals: 0, symbol: "humidity.fill"),
        Sensor(id: "pressure", label: "Pressure", unit: "kPa", decimals: 1, symbol: "gauge.with.dots.needle.50percent"),
        Sensor(id: "co2", label: "CO₂", unit: "ppm", decimals: 0, symbol: "carbon.dioxide.cloud.fill"),
        Sensor(id: "o2", label: "Oxygen", unit: "%", decimals: 1, symbol: "aqi.medium"),
        Sensor(id: "noise", label: "Noise", unit: "dB", decimals: 0, symbol: "ear.fill"),
        Sensor(id: "light", label: "Light", unit: "lux", decimals: 0, symbol: "lightbulb.fill"),
    ]
    static let scenarios: [(id: String, label: String, symbol: String)] = [
        ("normal", "Normal day", "checkmark.circle"), ("co2", "CO₂ scrubber fault", "carbon.dioxide.cloud"),
        ("spike", "Radiation spike", "atom"), ("leak", "Pressure leak", "gauge.with.dots.needle.0percent"),
        ("heat", "Cooling failure", "thermometer.sun"), ("noise", "Loud fan", "speaker.wave.3"),
    ]

    @Published private(set) var state: State = .off
    @Published private(set) var hubName: String?
    @Published private(set) var values: [String: Double] = [:]
    @Published private(set) var levels: [String: Level] = [:]
    @Published private(set) var scenario = "normal"
    @Published private(set) var unoConnected = false
    @Published private(set) var lastEnvAt: Date?
    @Published private(set) var hubRecords = 0
    @Published private(set) var uploading = false
    @Published private(set) var history: [String: [Double]] = [:]     // last minutes, for sparklines

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var want = false
    private var backoff: TimeInterval = 1
    private var lastMessageAt = Date.distantPast
    private var watchdog: Timer?
    private var seq = 0
    private var inFlight: (seq: Int, personId: String, maxRowid: Int)?
    private var snapshotTimers: [String: Timer] = [:]
    private var lastSnapshotSent: [String: Date] = [:]
    private let work = DispatchQueue(label: "crewhub.link", qos: .utility)
    private var hub: Hub { Hub.shared }

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue.main)
        NotificationCenter.default.addObserver(forName: .hubSnapshotsChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, self.state == .connected else { return }
            let ids = (note.userInfo?["persons"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? self.hub.persons().map(\.id)
            ids.forEach { self.scheduleSnapshot($0) }
            self.pump()
        }
    }

    // MARK: Settings

    /// "helios.local", "192.168.1.42", "host:port" or a full ws:// / wss:// URL.
    static func url(from address: String) -> URL? {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return nil }
        if !a.contains("://") {
            // A local name or address uses the LAN port; anything else is the public, TLS-terminated address (Cloudflare).
            let host = a.split(separator: "/").first.map { String($0.split(separator: ":").first ?? "") } ?? a
            let local = host.hasSuffix(".local") || host == "localhost" || host.allSatisfy { $0.isNumber || $0 == "." }
            a = (local ? "ws://" : "wss://") + a
        }
        guard var c = URLComponents(string: a), let host = c.host, !host.isEmpty else { return nil }
        if c.port == nil && c.scheme == "ws" { c.port = 8765 }
        if c.path.isEmpty { c.path = "/" }
        return c.url
    }

    /// Stable per-install id so the hub can tell phones (and their people) apart.
    private var deviceId: String {
        let key = "crewhub.deviceId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private var cursorPrefix: String { "hub.cursor.\(hub.settings().hubURL.lowercased())." }

    // MARK: Connection

    func connect() {
        want = true
        backoff = 1
        open()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    func disconnect() {
        want = false
        watchdog?.invalidate(); watchdog = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        inFlight = nil
        state = .off
        RadiationBridge.shared.hubDisconnected()
    }

    /// Forget what was sent so everything is uploaded again (e.g. a new hub).
    func resend() {
        try? hub.repo.deleteKV(prefix: cursorPrefix)
        inFlight = nil
        pump()
    }

    private func open() {
        let s = hub.settings()
        guard let url = CrewHubLink.url(from: s.hubURL) else { state = .rejected("Enter the hub's address"); return }
        guard !s.hubCode.isEmpty else { state = .rejected("Enter the code shown on the hub"); return }
        var req = URLRequest(url: url)
        req.setValue("app://crew-health-hub", forHTTPHeaderField: "Origin")
        req.setValue("Bearer \(s.hubCode.uppercased())", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        state = state == .connected ? .lost : .connecting
        task?.cancel()
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 8 * 1024 * 1024
        task = t
        t.resume()
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .failure:
                if let r = t.response as? HTTPURLResponse, r.statusCode == 401 || r.statusCode == 403 {
                    self.state = .rejected(r.statusCode == 401 ? "Wrong hub code" : "The hub refused this app")
                    self.want = false
                    self.task = nil
                    return
                }
                self.reconnectLater()
            case .success(let msg):
                switch msg {
                case .string(let s): self.handle(s)
                case .data(let d): self.handle(String(decoding: d, as: UTF8.self))
                @unknown default: break
                }
                self.receive(t)
            }
        }
    }

    private func reconnectLater() {
        guard want else { return }
        if state == .connected { state = .lost }
        task = nil
        inFlight = nil
        RadiationBridge.shared.hubDisconnected()
        let delay = backoff
        backoff = min(backoff * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.want, self.task == nil else { return }
            self.open()
        }
    }

    private func tick() {
        guard want else { return }
        if state == .connected, Date().timeIntervalSince(lastMessageAt) > 12 {
            task?.cancel(with: .abnormalClosure, reason: nil)
            reconnectLater()
        }
        if state == .connected, inFlight == nil { pump() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        backoff = 1
        lastMessageAt = Date()
        send(["type": "client", "device_id": deviceId, "name": UIDevice.current.name, "app_version": SummaryBuilder.version])
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if webSocketTask === task { reconnectLater() }
    }

    private func send(_ obj: [String: Any]) {
        guard let t = task, let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        t.send(.string(s)) { _ in }
    }

    // MARK: Incoming

    private func handle(_ text: String) {
        guard let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let type = o["type"] as? String else { return }
        lastMessageAt = Date()
        switch type {
        case "hello":
            hubName = ((o["hub"] as? [String: Any])?["name"] as? String) ?? "Helios Hub"
            hubRecords = ((o["hub"] as? [String: Any])?["observations"] as? Int) ?? hubRecords
            state = .connected
            inFlight = nil
            hub.persons().forEach { scheduleSnapshot($0.id, now: true) }
            pump()
        case "env":
            let vals = (o["values"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            values = vals
            levels = (o["levels"] as? [String: String] ?? [:]).mapValues { Level(name: $0) }
            scenario = o["scenario"] as? String ?? "normal"
            unoConnected = ((o["uno"] as? [String: Any])?["connected"] as? Bool) ?? false
            lastEnvAt = Date()
            if NotificationPrefs.on(NotificationPrefs.habitat) {
                for (k, l) in levels where l >= .act {
                    let label = CrewHubLink.sensors.first { $0.id == k }?.label ?? (k == "rad_dose_rate" ? "Radiation" : k)
                    let v = vals[k].map { String(format: k == "rad_dose_rate" ? "%.3f" : "%.1f", $0) } ?? ""
                    NotificationRouter.shared.post(key: "hab|\(k)|\(l.rawValue)|\(Int(Date().timeIntervalSince1970 / 3600))",
                                                   title: "Habitat: \(label) \(l.label.lowercased())", body: "\(label) is \(v). Check the hub's Alerts page.",
                                                   urgent: l >= .escalate)
                }
            }
            for (k, v) in vals {
                var h = history[k] ?? []
                h.append(v)
                if h.count > 600 { h.removeFirst(h.count - 600) }
                history[k] = h
            }
        case "sample":
            let ts = (o["ts"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
            RadiationBridge.shared.ingestFromHub(ts: ts, rate: (o["dose_rate_uSv_h"] as? NSNumber)?.doubleValue,
                                                 cpm: (o["count_rate_cpm"] as? NSNumber)?.doubleValue,
                                                 cum: (o["dose_cum_uSv"] as? NSNumber)?.doubleValue, device: "\(hubName ?? "Helios Hub") sensors")
        case "upload_ack":
            hubRecords = (o["hub_total"] as? Int) ?? hubRecords
            if let f = inFlight, (o["seq"] as? Int) == f.seq {
                try? hub.repo.setKV(cursorPrefix + f.personId, Data(String(f.maxRowid).utf8))
                inFlight = nil
                pump()
            }
        case "ack_alert":
            guard (o["device_id"] as? String) == deviceId, let pid = o["person_id"] as? String, let key = o["key"] as? String else { return }
            if let item = hub.snapshot(pid)?.unacked.first(where: { $0.key == key }) {
                hub.acknowledge(item, personId: pid, note: "Acknowledged on the Helios Hub")
            }
        default: break      // heartbeat, scenario_ack, env_history
        }
    }

    // MARK: Commands

    func trigger(scenario name: String) { send(["type": "scenario", "name": name]) }

    // MARK: Upload (every observation, all people, incremental by row id)

    private func pump() {
        guard state == .connected, inFlight == nil else { return }
        let persons = hub.persons()
        let prefix = cursorPrefix
        work.async { [weak self] in
            guard let self else { return }
            for p in persons {
                let cursor = ((try? self.hub.repo.kv(prefix + p.id)) ?? nil).flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
                guard let rows = try? self.hub.repo.db.query(
                    "SELECT rowid, id, metric, ts, value, unit, device, kind, quality FROM observations WHERE person_id=? AND rowid>? ORDER BY rowid LIMIT 1000",
                    [.text(p.id), .int(Int64(cursor))]), !rows.isEmpty else { continue }
                let maxRowid = rows.compactMap { $0.int(0) }.max() ?? cursor
                let payload: [[Any]] = rows.compactMap { r in
                    guard r.string(8) != "rejected", let id = r.string(1), let m = r.string(2), let ts = r.double(3), let v = r.double(4) else { return nil }
                    return [id, m, ts, v, r.string(5) ?? "", r.string(6) ?? "", r.string(7) ?? ""]
                }
                DispatchQueue.main.async {
                    guard self.state == .connected, self.inFlight == nil else { return }
                    self.seq += 1
                    self.inFlight = (self.seq, p.id, maxRowid)
                    self.uploading = true
                    self.send(["type": "upload", "seq": self.seq, "person": ["id": p.id, "name": p.displayName, "role": p.role], "rows": payload])
                }
                return
            }
            DispatchQueue.main.async { self.uploading = false }
        }
    }

    // MARK: Snapshot (the app's analysis, for the hub's screen)

    private func scheduleSnapshot(_ personId: String, now: Bool = false) {
        let wait = now ? 0.1 : max(0.1, 3 - Date().timeIntervalSince(lastSnapshotSent[personId] ?? .distantPast))
        snapshotTimers[personId]?.invalidate()
        snapshotTimers[personId] = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            guard let self, self.state == .connected, let s = self.hub.snapshot(personId) else { return }
            self.lastSnapshotSent[personId] = Date()
            let current = self.hub.settings().currentPersonId ?? self.hub.persons().first?.id
            self.work.async {
                let payload = CrewHubLink.payload(s, daily: (try? self.hub.repo.allDaily(person: personId, to: s.evalDay)) ?? [:], current: current == personId)
                DispatchQueue.main.async { self.send(payload) }
            }
        }
    }

    static let shortLabels: [MetricId: String] = [
        "heart_rate_resting": "Resting HR", "heart_rate": "Heart rate", "hrv": "HRV", "spo2": "Oxygen", "resp_rate": "Breathing",
        "body_temp": "Body temp", "wrist_temp": "Wrist temp", "bp_sys": "Blood press", "sleep_hours": "Sleep", "activity_steps": "Steps",
        "exercise_min": "Exercise", "distance_km": "Distance", "vo2max": "VO2 max", "walking_hr": "Walking HR", "active_kcal": "Active cal",
        "resting_kcal": "Resting cal", "sleep_deep_h": "Deep sleep", "sleep_rem_h": "REM sleep", "sleep_core_h": "Core sleep",
        "sleep_awake_h": "Awake", "in_bed_h": "In bed", "workout_min": "Workouts", "stand_hours": "Stand hrs", "daylight_min": "Daylight",
        "mindful_min": "Mindful", "water_l": "Fluids", "diet_kcal": "Food cal", "breathing_disturbances": "Breath dist",
        "walking_speed": "Walk speed", "glucose": "Glucose", "weight": "Weight",
    ]

    static func level(_ l: Level) -> Int { l.rawValue - 1 }     // unknown -1, ok 0, watch 1, act 2, escalate 3

    static func payload(_ s: PersonSnapshot, daily: [MetricId: [DailyAggregate]], current: Bool) -> [String: Any] {
        var metrics: [String: Any] = [:]
        for (id, e) in s.evals {
            guard let latest = e.latest else { continue }
            var m: [String: Any] = ["label": e.def.label, "short": shortLabels[id] ?? e.def.label, "unit": e.def.unit,
                                    "decimals": e.def.decimals, "group": e.def.group, "value": latest.value, "day": latest.day,
                                    "level": level(e.status.level),
                                    "spark": (daily[id] ?? []).suffix(14).map { ($0.value * 1000).rounded() / 1000 }]
            if e.baseline.state == .active { m["usual"] = e.baseline.median }
            if id == "bp_sys", let dia = s.evals["bp_dia"]?.latest?.value { m["pair"] = dia }
            metrics[id] = m
        }
        var out: [String: Any] = [
            "type": "snapshot", "current": current, "as_of": ISO8601DateFormatter().string(from: s.asOf),
            "person": ["id": s.person.id, "name": s.person.displayName, "role": s.person.role],
            "mission": ["name": s.mission.name, "day": s.missionDay],
            "overall": ["level": level(s.overall.level), "title": s.summary],
            "alerts": s.unacked.map { ["key": $0.key, "text": $0.text] },
            "changes": s.changes.prefix(6).map { ["text": $0.text, "level": level($0.level), "metric": $0.metric ?? ""] },
            "metrics": metrics,
        ]
        if let r = s.radiation, r.hasData {
            out["radiation"] = ["rate": r.smoothed ?? r.current ?? 0, "background": r.background ?? 0, "level": level(r.level),
                                "cumulative_uSv": r.cumulative_uSv]
        }
        return out
    }
}
