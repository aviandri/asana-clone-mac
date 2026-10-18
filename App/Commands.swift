import AppKit
import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// The task selected in the focused list or inspector, for ⌘O.
struct SelectedTaskKey: FocusedValueKey { typealias Value = String }

extension FocusedValues {
    var selectedTaskID: String? {
        get { self[SelectedTaskKey.self] }
        set { self[SelectedTaskKey.self] = newValue }
    }
}

/// Menu bar commands. Workspace shortcuts live here (not on the sidebar menu's buttons) so ⌘1…⌘9
/// work from anywhere in the main window.
struct AppCommands: Commands {
    let session: AppSession
    @FocusedValue(\.selectedTaskID) private var selectedTaskID
    @Environment(\.openWindow) private var openWindow

    private var signedIn: Bool {
        if case .signedIn = session.state { return true }
        return false
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Task in New Window") {
                if let id = selectedTaskID, let workspaceID = session.current?.id {
                    openWindow(id: WindowID.task, value: TaskWindowRef(workspaceID: workspaceID, taskID: id))
                }
            }
            .keyboardShortcut("o")
            .disabled(selectedTaskID == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Refresh") { Task { await session.scope?.refresh() } }
                .keyboardShortcut("r")
                .disabled(session.scope == nil)
        }

        CommandMenu("Workspace") {
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
                    if let url = session.webURL(path: "/workspace/settings") { NSWorkspace.shared.open(url) }
                }
            }
        }

        CommandGroup(after: .appSettings) {
            Button("Sign Out") { Task { await session.signOut() } }
                .disabled(!signedIn)
        }
    }
}
