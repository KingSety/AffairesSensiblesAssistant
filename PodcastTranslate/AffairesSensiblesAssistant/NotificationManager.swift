import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    static let assistantThread = "home.ai"
    static let assistantCategory = "home.ai.ready"

    static let summaryThread = "episode.summary"
    static let summaryCategory = "episode.summary.ready"

    static func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared

        let assistantCategory = UNNotificationCategory(
            identifier: self.assistantCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let summaryCategory = UNNotificationCategory(
            identifier: self.summaryCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([assistantCategory, summaryCategory])
    }

    static func requestAuthorizationIfEnabledSetting() {
        let enabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        guard enabled else { return }
        requestAuthorization()
    }

    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            // The user can change this later in SettingsView or system Settings
        }
    }

    static func handleSettingChange(enabled: Bool) {
        if enabled {
            requestAuthorization()
        } else {
            clearDelivered(forThreadIdentifier: assistantThread)
            clearDelivered(forThreadIdentifier: summaryThread)
        }
    }

    static func notifyAssistantResultsReady(query: String) {
        scheduleIfAllowed(
            title: "Results are ready",
            body: "Your podcast assistant found similar episodes for: \"\(query)\"!",
            category: assistantCategory,
            thread: assistantThread
        )
    }

    static func notifyEpisodeSummaryReady(episodeTitle: String) {
        scheduleIfAllowed(
            title: "Summary ready",
            body: "The summary for \"\(episodeTitle)\" is ready!",
            category: summaryCategory,
            thread: summaryThread
        )
    }

    static func clearDeliveredForHomeAssistant() {
        clearDelivered(forThreadIdentifier: assistantThread)
    }

    static func clearDeliveredForEpisodeSummary() {
        clearDelivered(forThreadIdentifier: summaryThread)
    }

    private static func scheduleIfAllowed(
        title: String,
        body: String,
        category: String,
        thread: String
    ) {
        let userEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        guard userEnabled else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            #if canImport(UIKit)
            let appIsActive = UIApplication.shared.applicationState == .active
            guard !appIsActive else { return }
            #endif

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = category
            content.threadIdentifier = thread

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: trigger
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    private static func clearDelivered(forThreadIdentifier thread: String) {
        let center = UNUserNotificationCenter.current()

        center.getDeliveredNotifications { notes in
            let ids = notes
                .filter { $0.request.content.threadIdentifier == thread }
                .map { $0.request.identifier }
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }

        center.getPendingNotificationRequests { requests in
            let ids = requests
                .filter { $0.content.threadIdentifier == thread }
                .map { $0.identifier }
            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
