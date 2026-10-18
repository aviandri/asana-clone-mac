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
        .taskListActions(open: openTaskWindow) { menu(for: $0) }
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
                    .taskRowActions(open: { openTaskWindow(id) }) { menu(for: id) }
                    .taskDrag(task, enabled: store.canEdit)
                    .taskDrop(store: store, tasks: scope.tasks, section: sectionID, before: id)
                }
            }
            if store.canEdit {
                AddTaskRow { title in
                    Task { await store.addTask(title: title, section: sectionID) }
                }
                .taskDrop(store: store, tasks: scope.tasks, section: sectionID, before: nil)
            }
        } header: {
            Text(title)
                .modifier(SectionRenameModifier(store: store, section: section))
                .taskDrop(store: store, tasks: scope.tasks, section: sectionID, before: store.taskIDs(in: sectionID).first)
        }
    }

    @ViewBuilder private func menu(for id: String) -> some View {
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

    private func openTaskWindow(_ id: String) {
        openWindow(id: WindowID.task, value: TaskWindowRef(workspaceID: scope.id, taskID: id))
    }
}

/// "Add task" inline field (Return adds; stays focused for the next one).
@MainActor
struct AddTaskRow: View {
    var placeholder = "Add task"
    let onAdd: (String) -> Void
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(placeholder, text: $title)
                .textFieldStyle(.plain)
                .focused($focused)
                .accessibilityLabel("New task title")
                .onSubmit {
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    title = ""
                    onAdd(trimmed)
                    focused = true
                }
        }
        .selectionDisabled()
    }
}
