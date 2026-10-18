import AppKit
import MekariProjectFeatures
import MekariProjectKit
import ServiceManagement
import SwiftUI

enum SettingsKey {
    static let showInMenuBar = "showInMenuBar"
    static let notificationsEnabled = "notificationsEnabled"
}

/// ⌘, (SPEC-MAC §5): server (sign out to change), menu bar, notifications, launch at login.
struct SettingsView: View {
    let session: AppSession

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountSettings(session: session)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.showInMenuBar) private var showInMenuBar = true
    @AppStorage(SettingsKey.notificationsEnabled) private var notificationsEnabled = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var needsApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Toggle("Show in menu bar", isOn: $showInMenuBar)
            Toggle("Notify me about new inbox items", isOn: $notificationsEnabled)
            if needsApproval {
                // Registered, but macOS wants the user's OK; a toggle would just flip back.
                LabeledContent("Launch at login") {
                    HStack {
                        Text("Needs approval in System Settings").foregroundStyle(.secondary)
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            } else {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            }
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .task {
            // The user may approve the login item in System Settings meanwhile (async sequence, no Combine).
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                refreshLoginItemStatus()
            }
        }
    }

    private func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        needsApproval = status == .requiresApproval
        launchAtLogin = status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let isEnabled = SMAppService.mainApp.status == .enabled
        guard enabled != isEnabled else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
            refreshLoginItemStatus()
        } catch {
            loginItemError = "Couldn’t change the login item: \(error.localizedDescription)"
            launchAtLogin = isEnabled
        }
    }
}

private struct AccountSettings: View {
    let session: AppSession

    var body: some View {
        Form {
            LabeledContent("Server", value: session.settings.serverURL?.absoluteString ?? "Not set")
            if let me = session.me {
                LabeledContent("Signed in as", value: "\(me.name) (\(me.email))")
                Button("Sign Out") { Task { await session.signOut() } }
            }
            Text("To use another server, sign out and enter its address on the sign-in screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
