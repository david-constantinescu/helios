import AppIntents
import Foundation

/// "Start daily check-in" — for the Action button, Shortcuts, Siri and Spotlight.
struct StartCheckInIntent: AppIntent {
    static let title: LocalizedStringResource = "Start daily check-in"
    static let description = IntentDescription("Opens Helios on today's check-in.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .openDeepLink, object: URL(string: "crewhealth://checkin")!)
        PendingLink.url = URL(string: "crewhealth://checkin")
        return .result()
    }
}

/// A link that arrived before the UI was ready (cold launch from the Action button or a notification).
enum PendingLink { @MainActor static var url: URL? }

struct HeliosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartCheckInIntent(),
                    phrases: ["Start my \(.applicationName) check-in", "Daily check-in in \(.applicationName)", "Check in with \(.applicationName)"],
                    shortTitle: "Daily check-in", systemImageName: "checklist")
    }
}
