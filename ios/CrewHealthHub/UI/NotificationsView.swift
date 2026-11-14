import SwiftUI
import UserNotifications

struct NotificationsView: View {
    @AppStorage(NotificationPrefs.urgent) private var urgent = true
    @AppStorage(NotificationPrefs.watch) private var watch = true
    @AppStorage(NotificationPrefs.checkIn) private var checkIn = true
    @AppStorage(NotificationPrefs.habitat) private var habitat = true
    @State private var status: UNAuthorizationStatus = .notDetermined
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if status == .denied {
                Section {
                    Button("Turn on notifications in Settings") { openURL(URL(string: UIApplication.openNotificationSettingsURLString)!) }
                } footer: { Text("Notifications are off for Helios.") }
            }
            Section {
                Toggle("Urgent alerts", isOn: $urgent)
                Toggle("Changes to watch", isOn: $watch)
                Toggle("Daily check-in reminder", isOn: $checkIn)
                    .onChange(of: checkIn) { _, _ in NotificationRouter.shared.scheduleCheckIn() }
                Toggle("Habitat alerts from the hub", isOn: $habitat)
            } footer: {
                Text("Urgent alerts are time-sensitive, so they can break through Focus.")
            }
            Section {
                Link(destination: URL(string: "https://nasa.softhoarders.me/")!) {
                    Label("Alerts on any device", systemImage: "bell.badge")
                }
            } footer: {
                Text("Open nasa.softhoarders.me, add it to your Home Screen and allow notifications: the hub then pushes alerts even when Helios is closed.")
            }
        }
        .navigationTitle("Notifications")
        .task {
            status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if status == .notDetermined { await NotificationRouter.shared.setUp(); status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
        }
    }
}
