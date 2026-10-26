import AppKit
import MekariProjectFeatures
import MekariProjectKit
import SwiftUI
import UserNotifications

/// Local banners for new inbox items (SPEC-MAC §5), fed by `NotificationPoller.onNew`. Clicking one
/// opens its task. Permission is asked once, on the first sign-in.
@MainActor
final class LocalNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotifier()
    nonisolated static let askedKey = "askedNotificationPermission"
    nonisolated static let taskKey = "taskID"

    /// Opens a task (set by the App to route through the session and router).
    var onOpenTask: (String) -> Void = { _ in }
    /// UI tests never post or prompt (no system dialogs in the run).
    var isDisabled = false

    private var center: UNUserNotificationCenter { .current() }

    func install() {
        guard !isDisabled else { return }
        center.delegate = self
    }

    func requestPermissionIfNeeded() {
        guard !isDisabled, !UserDefaults.standard.bool(forKey: Self.askedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ notices: [NotificationPoller.LocalNotice]) {
        guard !isDisabled, UserDefaults.standard.object(forKey: SettingsKey.notificationsEnabled) as? Bool ?? true else { return }
        for notice in notices {
            let content = UNMutableNotificationContent()
            content.title = "Mekari Project"
            content.body = notice.title
            content.sound = .default
            if let taskID = notice.taskID { content.userInfo = [Self.taskKey: taskID] }
            center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let taskID = response.notification.request.content.userInfo[Self.taskKey] as? String else { return }
        await MainActor.run { onOpenTask(taskID) }
    }
}

/// Keeps the app running in the menu bar after the last window closes (when enabled), and installs
/// the notification delegate early so a click that launches the app is handled.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the App: opens a `mekariproject://` URL (deep links, SPEC-MAC §5).
    @MainActor static var onOpenURL: (URL) -> Void = { _ in }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Take URL events ourselves: SwiftUI only delivers them to a live scene's onOpenURL, so a link
        // with every window closed (menu-bar-only) or at cold launch would otherwise be lost.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: string) else { return }
        MainActor.assumeIsolated { AppDelegate.onOpenURL(url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { LocalNotifier.shared.install() }
    }

    /// Apps may have been installed or removed meanwhile: Open With ▸ looks them up again.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { OpenWithApps.clearCache() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: SettingsKey.showInMenuBar) as? Bool ?? true)
    }
}
