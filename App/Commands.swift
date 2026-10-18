import AppKit
import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// The task selected in the focused list or inspector, for ⌘O.
struct SelectedTaskKey: FocusedValueKey { typealias Value = String }

/// What ⇧⌘O opens for the focused window: its task, else its project, else My Tasks.
struct BrowserLinkKey: FocusedValueKey { typealias Value = URL }

extension FocusedValues {
    var selectedTaskID: String? {
        get { self[SelectedTaskKey.self] }
        set { self[SelectedTaskKey.self] = newValue }
    }

    var browserLink: URL? {
        get { self[BrowserLinkKey.self] }
        set { self[BrowserLinkKey.self] = newValue }
    }
}

/// Menu bar commands. Workspace shortcuts live here (not on the sidebar menu's buttons) so ⌘1…⌘9
/// work from anywhere in the main window.
///
/// Items that depend on session state are small Views: on macOS 14 a `Commands` body isn't re-run
/// when @Observable state changes, so a `.disabled(session.scope == nil)` read here stayed as it was
/// at launch (before sign-in) and ⇧⌘O silently did nothing (rc1 QA S1). View bodies are observed.
@MainActor
struct AppCommands: Commands {
    let session: AppSession
    let router: AppRouter

    var body: some Commands {
        CommandGroup(after: .newItem) {
            OpenTaskWindowButton(session: session)
        }

        CommandGroup(after: .toolbar) {
            RefreshButton(session: session)
        }

        CommandGroup(after: .textEditing) {
            SearchButton(session: session, router: router)
        }

        CommandGroup(after: .saveItem) {
            OpenInBrowserButton(session: session)
        }

        CommandMenu("Workspace") {
            WorkspaceMenuItems(session: session)
        }

        CommandGroup(after: .appSettings) {
            SignOutButton(session: session)
        }
    }
}

/// ⇧⌘O. The focused window publishes its link (`browserLink`); with no window focused (menu bar
/// only) it falls back to the current workspace's My Tasks. Disabled when no link can be built.
@MainActor
enum OpenInBrowser {
    /// Replaced in UI tests (no real browser on the CI host).
    static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    static func target(focused: URL?, session: AppSession) -> URL? {
        if let focused { return focused }
        guard session.scope != nil else { return nil }
        return session.webURL(path: "/my-tasks")
    }

    /// The command itself: opens the target, or reports that there was none.
    @discardableResult
    static func perform(focused: URL?, session: AppSession) -> Bool {
        guard let url = target(focused: focused, session: session) else { return false }
        open(url)
        return true
    }
}

@MainActor
private struct OpenInBrowserButton: View {
    let session: AppSession
    @FocusedValue(\.browserLink) private var browserLink

    var body: some View {
        Button("Open in Browser") {
            OpenInBrowser.perform(focused: browserLink, session: session)
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(OpenInBrowser.target(focused: browserLink, session: session) == nil)
    }
}

@MainActor
private struct OpenTaskWindowButton: View {
    let session: AppSession
    @FocusedValue(\.selectedTaskID) private var selectedTaskID
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Task in New Window") {
            if let id = selectedTaskID, let workspaceID = session.current?.id {
                openWindow(id: WindowID.task, value: TaskWindowRef(workspaceID: workspaceID, taskID: id))
            }
        }
        .keyboardShortcut("o")
        .disabled(selectedTaskID == nil || session.current == nil)
    }
}

@MainActor
private struct RefreshButton: View {
    let session: AppSession

    var body: some View {
        Button("Refresh") { Task { await session.scope?.refresh() } }
            .keyboardShortcut("r")
            .disabled(session.scope == nil)
    }
}

@MainActor
private struct SearchButton: View {
    let session: AppSession
    let router: AppRouter

    var body: some View {
        Button("Search…") {
            router.openMainWindow()
            router.showSearch = true
        }
        .keyboardShortcut("k")
        .disabled(session.scope == nil)
    }
}

@MainActor
private struct WorkspaceMenuItems: View {
    let session: AppSession

    var body: some View {
        ForEach(Array(session.all.prefix(9).enumerated()), id: \.element.id) { index, workspace in
            // A Toggle draws the native checkmark on the current workspace.
            Toggle(workspace.name, isOn: Binding(
                get: { workspace.id == session.current?.id },
                set: { on in if on { Task { await session.switchWorkspace(to: workspace.id) } } }
            ))
            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        }
        if session.all.count > 9 {
            ForEach(session.all.dropFirst(9)) { workspace in
                Button(workspace.name) { Task { await session.switchWorkspace(to: workspace.id) } }
            }
        }
        if session.isAdmin {
            Divider()
            Button("Open Workspace Settings in Browser") {
                if let url = session.webURL(path: "/workspace/settings") { OpenInBrowser.open(url) }
            }
        }
    }
}

@MainActor
private struct SignOutButton: View {
    let session: AppSession

    var body: some View {
        Button("Sign Out") { Task { await session.signOut() } }
            .disabled(!isSignedIn)
    }

    private var isSignedIn: Bool {
        if case .signedIn = session.state { return true }
        return false
    }
}
