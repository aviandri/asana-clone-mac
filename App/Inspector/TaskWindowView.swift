import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// A task in its own window (⌘O / double-click). Reuses the scope's cached TaskDetailStore, so edits
/// show up in the main window too.
struct TaskWindowView: View {
    let session: AppSession
    @Binding var taskID: String?

    var body: some View {
        Group {
            if let scope = session.scope, let id = taskID {
                TaskInspectorView(scope: scope, store: scope.taskDetail(id), onOpenTask: { taskID = $0 })
                    .id("\(scope.id)/\(id)")
                    .navigationTitle(scope.tasks[id]?.title ?? "Task")
            } else {
                ContentUnavailableView("No Task", systemImage: "checklist", description: Text("Sign in to open tasks."))
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }
}
