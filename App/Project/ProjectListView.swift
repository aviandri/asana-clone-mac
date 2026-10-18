import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// List view: sections with their tasks, inline add per section. Drag a row onto another row to put it
/// before that row (any section), or onto a section's "Add task" row to put it at the end.
@MainActor
struct ProjectListView: View {
    let scope: WorkspaceScope
    let store: ProjectStore
    @Binding var selection: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List(selection: $selection) {
            if store.hasUnsectionedTasks {
                sectionView(id: nil, title: "No section", section: nil)
            }
            ForEach(store.sections) { section in
                sectionView(id: section.id, title: section.name, section: section)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("Open in New Window") { openTaskWindow(id) }
                if store.canEdit {
                    Button(scope.tasks[id]?.completed == true ? "Mark Incomplete" : "Mark Complete") {
                        Task { await store.toggleComplete(id) }
                    }
                    Menu("Move to Section") {
                        ForEach(store.sections) { section in
                            Button(section.name) { Task { await store.move(taskID: id, toSection: section.id, before: nil) } }
                                .disabled(scope.tasks[id]?.sectionId == section.id)
                        }
                    }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { openTaskWindow(id) }
        }
        .overlay {
            if store.detail != nil, store.sections.isEmpty, !store.hasUnsectionedTasks {
                ContentUnavailableView("No Tasks Yet", systemImage: "checklist", description: Text(store.canEdit ? "Add a section, then add tasks to it." : "Nothing here yet."))
            }
        }
    }

    @ViewBuilder
    private func sectionView(id sectionID: String?, title: String, section: MekariProjectKit.Section?) -> some View {
        Section {
            let ids = store.taskIDs(in: sectionID)
            ForEach(ids, id: \.self) { id in
                if let task = scope.tasks[id] {
                    TaskRow(task: task, canEdit: store.canEdit) {
                        Task { await store.toggleComplete(id) }
                    }
                    .tag(id)
                    .taskDrag(task, enabled: store.canEdit)
                    .taskDrop(store: store, tasks: scope.tasks, section: sectionID, before: id)
                }
            }
            // Scoped to the task rows, not the List (see MyTasksView): the add row below stays out of it.
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: scope.tasks.lingering)
            if store.canEdit {
                AddTaskRow { title in
                    Task { await store.addTask(title: title, section: sectionID) }
                }
                .id("addTask.\(sectionID ?? "none")") // stable across row changes
                .taskDrop(store: store, tasks: scope.tasks, section: sectionID, before: nil)
            }
        } header: {
            Text(title)
                .modifier(SectionRenameModifier(store: store, section: section))
                .taskDrop(store: store, tasks: scope.tasks, section: sectionID, before: store.taskIDs(in: sectionID).first)
        }
    }

    private func openTaskWindow(_ id: String) {
        openWindow(id: WindowID.task, value: TaskWindowRef(workspaceID: scope.id, taskID: id))
    }
}
