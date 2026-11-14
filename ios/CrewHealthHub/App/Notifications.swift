import Foundation
import UserNotifications

/// Local notifications for scheduled routines (PART 8.6). In-app prompts on Today are always the fallback.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func requestAndSchedule(environment: String) async -> Bool {
        let c = UNUserNotificationCenter.current()
        let ok = (try? await c.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard ok else { return false }
        schedule(environment: environment)
        return true
    }

    func schedule(environment: String) {
        let c = UNUserNotificationCenter.current()
        c.removeAllPendingNotificationRequests()
        for r in Scheduler.activeRoutines(config: .shared, environment: environment) {
            let parts = (r.time ?? "08:00").split(separator: ":").compactMap { Int($0) }
            var dc = DateComponents(); dc.hour = parts.first ?? 8; dc.minute = parts.count > 1 ? parts[1] : 0
            switch r.cadence {
            case "daily": break
            case "weekly": dc.weekday = ((r.dow ?? 1) % 7) + 1     // Monday=1 → Calendar weekday 2
            default: continue
            }
            let content = UNMutableNotificationContent()
            content.title = r.label
            content.body = "About \(max(1, r.estSeconds / 60)) min. Open Helios to measure and log."
            content.sound = .default
            c.add(UNNotificationRequest(identifier: "routine.\(r.id)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))
        }
    }

    func cancelAll() { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
}

// MARK: - Alerts (escalations, changes to watch, habitat) and the daily check-in reminder

enum NotificationPrefs {
    static let urgent = "notify.urgent", watch = "notify.watch", checkIn = "notify.checkin", habitat = "notify.habitat"
    static func on(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

extension NotificationRouter {
    /// Asks once (after onboarding) and sets up the daily check-in reminder.
    func setUp() async {
        let c = UNUserNotificationCenter.current()
        let status = await c.notificationSettings().authorizationStatus
        if status == .notDetermined { _ = try? await c.requestAuthorization(options: [.alert, .sound, .badge]) }
        scheduleCheckIn()
    }

    func scheduleCheckIn(hour: Int = 8) {
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: ["checkin.daily"])
        guard NotificationPrefs.on(NotificationPrefs.checkIn) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Daily check-in"
        content.body = "One minute: how you slept, your mood and any symptoms."
        content.sound = .default
        content.userInfo = ["open": "crewhealth://checkin"]
        var dc = DateComponents(); dc.hour = hour
        c.add(UNNotificationRequest(identifier: "checkin.daily", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))
    }

    /// Posts once per key (an escalation, a change, a habitat level), never again for the same key.
    func post(key: String, title: String, body: String, urgent: Bool, open: String = "crewhealth://today") {
        let seenKey = "notify.seen"
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        guard !seen.contains(key) else { return }
        seen.insert(key)
        UserDefaults.standard.set(Array(seen.suffix(500)), forKey: seenKey)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = urgent ? .defaultCritical : .default
        content.interruptionLevel = urgent ? .timeSensitive : .active
        content.threadIdentifier = urgent ? "urgent" : "changes"
        content.userInfo = ["open": open]
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { st in
            guard st.authorizationStatus == .authorized || st.authorizationStatus == .provisional || st.authorizationStatus == .ephemeral else { return }
            center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }

    /// Called with each new analysis: new escalations and new "watch" changes become notifications.
    func notify(for s: PersonSnapshot) {
        let name = s.person.displayName
        if NotificationPrefs.on(NotificationPrefs.urgent) {
            for e in s.unacked {
                post(key: "esc|\(s.person.id)|\(e.key)", title: "\(name): contact your flight surgeon", body: e.text, urgent: true)
            }
        }
        if NotificationPrefs.on(NotificationPrefs.watch) {
            for c in s.changes where c.level >= .watch && c.level != c.previous && c.level < .escalate {
                post(key: "chg|\(s.person.id)|\(c.id)|\(s.evalDay)|\(c.level.rawValue)", title: "\(name): \(c.level.label.lowercased())", body: c.text, urgent: false)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let s = response.notification.request.content.userInfo["open"] as? String, let url = URL(string: s) {
            await MainActor.run { NotificationCenter.default.post(name: .openDeepLink, object: url) }
        }
    }
}

extension Notification.Name {
    static let openDeepLink = Notification.Name("helios.openDeepLink")
}
