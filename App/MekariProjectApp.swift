import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

@main
struct MekariProjectApp: App {
    @State private var session = AppBootstrap.makeSession()

    var body: some Scene {
        // One main window in v1 (SPEC-MAC §4: one current workspace per app).
        Window("Mekari Project", id: WindowID.main) {
            RootView(session: session)
        }
        .defaultSize(width: 1120, height: 720)
        .commands { AppCommands(session: session) }

        // ⌘O / double-click: a task in its own window, sharing the scope's TaskDetailStore.
        WindowGroup("Task", id: WindowID.task, for: String.self) { $taskID in
            TaskWindowView(session: session, taskID: taskID)
        }
        .defaultSize(width: 520, height: 700)

        Settings {
            SettingsView(session: session)
        }
    }
}

enum WindowID {
    static let main = "main"
    static let task = "task"
}

/// Builds the root session: the live API normally, `FakeMekariAPI` for UI tests (`-UITestFakeAPI`,
/// signed in as alice; add `-UITestSignedOut` to start at the sign-in window).
@MainActor
enum AppBootstrap {
    static let uiTestArgument = "-UITestFakeAPI"
    static let uiTestSignedOutArgument = "-UITestSignedOut"

    static func makeSession(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppSession {
        if arguments.contains(uiTestArgument) {
            return AppSession.uiTest(signedIn: !arguments.contains(uiTestSignedOutArgument))
        }
        let settings = UserDefaultsServerSettings()
        return AppSession(
            settings: settings,
            // One server per install (SPEC-MAC §4); changing it requires signing out, which clears the token.
            tokens: KeychainTokenStore(account: "session"),
            apiFactory: { url, tokens in LiveMekariAPI(baseURL: url, tokens: tokens) }
        )
    }
}
