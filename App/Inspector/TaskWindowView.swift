import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// The value a task window is opened with: the task and the workspace it was opened in. Task requests
/// carry the app's current workspace header, so a window from another workspace mustn't load or edit
/// until the user switches back.
struct TaskWindowRef: Codable, Hashable {
    var workspaceID: String
    var taskID: String
}

/// A task in its own window (⌘O / double-click). Reuses the scope's cached TaskDetailStore, so edits
/// show up in the main window too.
@MainActor
struct TaskWindowView: View {
    let session: AppSession
    @Binding var ref: TaskWindowRef?

    var body: some View {
        Group {
            if case .restoring = session.state {
                ProgressView("Signing in…")
            } else if let ref, let scope = session.scope, scope.id == ref.workspaceID {
                TaskInspectorView(session: session, scope: scope, store: scope.taskDetail(ref.taskID), onOpenTask: { id in
                    self.ref = TaskWindowRef(workspaceID: ref.workspaceID, taskID: id)
                })
                .id("\(scope.id)/\(ref.taskID)")
                .disabled(session.isSwitching)
                // ⌘O / ⇧⌘O act on this window's task.
                .focusedSceneValue(\.selectedTaskID, ref.taskID)
                .focusedSceneValue(\.currentProjectID, scope.tasks[ref.taskID]?.projectId)
                .navigationTitle(scope.tasks[ref.taskID]?.title ?? "Task")
            } else if let ref, session.scope != nil {
                OtherWorkspaceView(session: session, workspaceID: ref.workspaceID)
            } else {
                ContentUnavailableView("Not Signed In", systemImage: "person.crop.circle.badge.questionmark", description: Text("Sign in in the main window to open tasks."))
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }
}

/// Shown in a task window after the app switched away from the task's workspace.
@MainActor
private struct OtherWorkspaceView: View {
    let session: AppSession
    let workspaceID: String

    var body: some View {
        if let workspace = session.all.first(where: { $0.id == workspaceID }) {
            ContentUnavailableView {
                Label("This Task Is in Another Workspace", systemImage: "rectangle.2.swap")
            } description: {
                Text("It belongs to \(workspace.name), but \(session.current?.name ?? "another workspace") is open now.")
            } actions: {
                Button("Switch to \(workspace.name)") {
                    Task { await session.switchWorkspace(to: workspace.id) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView("You Don't Have Access", systemImage: "lock", description: Text("You're no longer a member of this task's workspace."))
        }
    }
}
