import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

@main
struct MekariProjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session: AppSession
    @State private var router: AppRouter
    @State private var wiring: SessionWiring
    @AppStorage(SettingsKey.showInMenuBar) private var showInMenuBar = true

    init() {
        let session = AppBootstrap.makeSession()
        let router = AppRouter()
        _session = State(initialValue: session)
        _router = State(initialValue: router)
        // Session-driven wiring at App level: works with only the menu bar open, too.
        _wiring = State(initialValue: SessionWiring(session: session, router: router))
        let notifier = LocalNotifier.shared
        notifier.isDisabled = AppBootstrap.isUITest()
        // A banner click opens its task, switching workspace if needed (like a deep link).
        notifier.onOpenTask = { id in Task { await router.follow(.task(id: id), in: session) } }
        // Once per launch, at the App level: a task window restored on its own needs a session too.
        Task { await session.start() }
    }

    var body: some Scene {
        // One main window in v1 (SPEC-MAC §4: one current workspace per app).
        Window("Mekari Project", id: WindowID.main) {
            RootView(session: session, router: router)
        }
        // mekariproject:// links always go to the main window (opening it if closed), never a Task window.
        .handlesExternalEvents(matching: [DeepLink.scheme])
        .defaultSize(width: 1120, height: 720)
        .commands { AppCommands(session: session, router: router) }

        // ⌘O / double-click: a task in its own window, sharing the scope's TaskDetailStore.
        WindowGroup("Task", id: WindowID.task, for: TaskWindowRef.self) { $ref in
            TaskWindowView(session: session, ref: $ref)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 520, height: 700)

        // Unread count, due today / overdue, quick add (SPEC-MAC §5). "Show in menu bar" in Settings.
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarContent(session: session, router: router)
        } label: {
            MenuBarLabel(session: session, router: router)
        }
        .menuBarExtraStyle(.window)

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

    static func isUITest(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(uiTestArgument)
    }

    static func makeSession(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppSession {
        if isUITest(arguments: arguments) {
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
