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
    /// The section the add bar (below the List) adds to; nil when the bar is closed.
    @State private var addTarget: AddTarget?

    private struct AddTarget: Equatable {
        let sectionID: String?
        let title: String
    }

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
        // The add field lives here, outside the List's recycled rows (see AddTaskRow).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.canEdit, let target = addTarget, isOpen(target) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 8) {
                        AddTaskRow(placeholder: "Add task to \(target.title)", focusOnAppear: true) { title in
                            Task { await store.addTask(title: title, section: target.sectionID) }
                        }
                        Button("Done") { addTarget = nil }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .onExitCommand { addTarget = nil }
                }
                .background(.bar)
                .id(target.sectionID ?? "none")
            }
        }
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
            if store.canEdit {
                Button {
                    addTarget = AddTarget(sectionID: sectionID, title: title)
                } label: {
                    Label("Add task", systemImage: "plus")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .selectionDisabled()
                .accessibilityIdentifier("project.addTask.\(sectionID ?? "none")")
                .taskDrop(store: store, tasks: scope.tasks, section: sectionID, before: nil)
            }
        } header: {
            Text(title)
                .modifier(SectionRenameModifier(store: store, section: section))
                .taskDrop(store: store, tasks: scope.tasks, section: sectionID, before: store.taskIDs(in: sectionID).first)
        }
    }

    /// The bar closes by itself if its section went away (renamed is fine, deleted is not).
    private func isOpen(_ target: AddTarget) -> Bool {
        guard let id = target.sectionID else { return true }
        return store.sections.contains { $0.id == id }
    }

    private func openTaskWindow(_ id: String) {
        openWindow(id: WindowID.task, value: TaskWindowRef(workspaceID: scope.id, taskID: id))
    }
}

/// "Add task" field: Return adds and keeps focus for the next one.
///
/// Never put this inside a `List` row (rc1 QA crash). List row updates re-bind a row's text field, and
/// SwiftUI pushed the cleared value into the recycled field editor mid-update. NSTextView undo
/// registration then threw NSRangeException, which unwound through AttributeGraph/Observation and
/// corrupted memory seconds later. My Tasks and the project list host it outside their Lists; the
/// Board's columns are not table rows.
@MainActor
struct AddTaskRow: View {
    var placeholder = "Add task"
    var focusOnAppear = false
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
                .accessibilityIdentifier("addTask.field")
                .onSubmit(submit)
        }
        .onAppear { if focusOnAppear { focused = true } }
    }

    private func submit() {
        let submitted = title
        let trimmed = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        // Clear on the next main-actor turn, after the insert's list update rather than inside it,
        // and only if nothing new was typed meanwhile.
        Task { @MainActor in
            if title == submitted { title = "" }
            focused = true
        }
    }
}
