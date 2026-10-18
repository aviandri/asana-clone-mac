import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// One project: List or Board (SPEC-MAC §5), starting on its default view. Read-only for COMMENTERs.
struct ProjectView: View {
    let session: AppSession
    let scope: WorkspaceScope
    @Bindable var store: ProjectStore
    @Binding var selection: String?

    @State private var addingSection = false
    @State private var newSectionName = ""

    var body: some View {
        Group {
            if store.detail != nil {
                switch store.viewMode {
                case .list:
                    ProjectListView(scope: scope, store: store, selection: $selection)
                case .board:
                    ProjectBoardView(scope: scope, store: store, selection: $selection)
                }
            } else if case .failed(let error) = store.phase {
                ContentUnavailableView(
                    error.code == .notFound ? "You Don't Have Access" : "Couldn't Load Project",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.code == .notFound ? "This project doesn't exist, or you can't see it." : error.message)
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(store.detail?.name ?? "Project")
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 6) {
                ErrorBanner(error: store.lastError) { store.clearError() }
                if store.detail != nil, !store.canEdit {
                    Label("You can view and comment, but not edit tasks in this project.", systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal)
            .padding(.top, store.lastError == nil && store.canEdit ? 0 : 8)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $store.viewMode) {
                    Label("List", systemImage: "list.bullet").tag(ProjectStore.ViewMode.list)
                    Label("Board", systemImage: "rectangle.split.3x1").tag(ProjectStore.ViewMode.board)
                }
                .pickerStyle(.segmented)
                .help("List or Board")
            }
            ToolbarItem {
                Toggle(isOn: $store.showCompleted) {
                    Label("Show Completed", systemImage: "checkmark.circle.badge.questionmark")
                }
                .help("Show completed tasks")
            }
            if store.canEdit {
                ToolbarItem {
                    Button {
                        newSectionName = ""
                        addingSection = true
                    } label: {
                        Label("Add Section", systemImage: "rectangle.stack.badge.plus")
                    }
                    .help("Add a section")
                }
            }
        }
        .alert("New Section", isPresented: $addingSection) {
            TextField("Section name", text: $newSectionName)
            Button("Add") {
                let name = newSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { Task { await store.addSection(name: name) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: session.generation) { await store.load() }
    }
}

/// Drag a task by its id (SPEC-MAC: drag payloads are task-id strings); off when read-only.
struct TaskDragModifier: ViewModifier {
    let taskID: String
    let title: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.draggable(taskID) {
                Label(title, systemImage: "checklist")
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            content
        }
    }
}

extension View {
    func taskDrag(_ task: TaskItem, enabled: Bool) -> some View {
        modifier(TaskDragModifier(taskID: task.id, title: task.title, enabled: enabled))
    }

    /// Drop a dragged task here: into `section`, before `before` (nil = at the end). Only tasks of this
    /// project are accepted (`DropRules`); other strings and other projects' tasks are refused.
    func taskDrop(store: ProjectStore, tasks: TaskCache, section: String?, before: String?, isTargeted: Binding<Bool>? = nil) -> some View {
        dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, DropRules.accepts(tasks[id], projectID: store.projectID, canEdit: store.canEdit, before: before) else {
                return false
            }
            Task { await store.move(taskID: id, toSection: section, before: before) }
            return true
        } isTargeted: { targeted in
            isTargeted?.wrappedValue = targeted
        }
    }
}

/// Which drops are moves. Drag payloads are plain strings, so text from other apps or a task from
/// another project's window could land here; only this project's tasks move, and only for editors.
enum DropRules {
    static func accepts(_ task: TaskItem?, projectID: String, canEdit: Bool, before: String?) -> Bool {
        guard canEdit, let task, task.projectId == projectID, task.id != before else { return false }
        return true
    }
}

/// The section header's rename flow (context menu → alert).
struct SectionRenameModifier: ViewModifier {
    let store: ProjectStore
    let section: MekariProjectKit.Section?
    @State private var renaming = false
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if let section, store.canEdit {
                    Button("Rename Section…") {
                        name = section.name
                        renaming = true
                    }
                }
            }
            .alert("Rename Section", isPresented: $renaming) {
                TextField("Section name", text: $name)
                Button("Rename") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let section, !trimmed.isEmpty, trimmed != section.name {
                        Task { await store.renameSection(section.id, to: trimmed) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
    }
}
