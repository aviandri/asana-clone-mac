import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// Overdue / Today / Upcoming / Later / No date (SPEC-MAC §5), with inline add and a completed toggle.
@MainActor
struct MyTasksView: View {
    let scope: WorkspaceScope
    @Bindable var store: MyTasksStore
    @Binding var selection: String?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List(selection: $selection) {
            Section {
                AddTaskRow { title in
                    Task { await store.addTask(title: title) }
                }
                .id("addTask.myTasks") // stable: never re-created by task row changes
            }

            ForEach(store.groups) { group in
                Section(group.title) {
                    ForEach(group.taskIDs, id: \.self) { id in
                        if let task = scope.tasks[id] {
                            TaskRow(task: task, showProject: true, canEdit: scope.canEdit(task: task)) {
                                Task { await store.toggleComplete(id) }
                            }
                            .tag(id)
                        }
                    }
                    // Scoped to the task rows (not the List, so the add row and other reloads aren't
                    // swept into the transaction): a completed row lingers ~700 ms, then collapses.
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: scope.tasks.lingering)
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("Open in New Window") { openTaskWindow(id) }
                Button(scope.tasks[id]?.completed == true ? "Mark Incomplete" : "Mark Complete") {
                    Task { await store.toggleComplete(id) }
                }
                .disabled(!(scope.tasks[id].map { scope.canEdit(task: $0) } ?? false))
            }
        } primaryAction: { ids in
            if let id = ids.first { openTaskWindow(id) }
        }
        .overlay {
            if store.groups.isEmpty {
                switch store.phase {
                case .idle, .loading:
                    ProgressView()
                case .failed(let error):
                    ContentUnavailableView("Couldn't Load My Tasks", systemImage: "exclamationmark.triangle", description: Text(error.message))
                case .loaded:
                    ContentUnavailableView("Nothing on Your Plate", systemImage: "checkmark.circle", description: Text("Tasks assigned to you show up here."))
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ErrorBanner(error: store.lastError) { store.clearError() }
                .padding(.horizontal)
                .padding(.top, store.lastError == nil ? 0 : 8)
        }
        .navigationTitle("My Tasks")
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $store.showCompleted) {
                    Label("Show Completed", systemImage: "checkmark.circle.badge.questionmark")
                }
                .help("Show completed tasks")
            }
        }
        .task { await store.refresh() }
    }

    private func openTaskWindow(_ id: String) {
        openWindow(id: WindowID.task, value: TaskWindowRef(workspaceID: scope.id, taskID: id))
    }
}

/// One task row: complete toggle, title, project, due date, assignee (SPEC-MAC §5 `task.row.<id>`).
@MainActor
struct TaskRow: View {
    let task: TaskItem
    var showProject = false
    /// Read-only unless the caller knows the user may edit (commenters would get a 403 flip-back).
    var canEdit = false
    let onToggle: () -> Void

    var body: some View {
        let today = LocalDate.today()
        HStack(spacing: 8) {
            CompletionCheckbox(completed: task.completed, title: task.title, canEdit: canEdit, action: onToggle)

            CompletionTitle(title: task.title, completed: task.completed)

            if task.subtaskCount > 0 {
                Label("\(task.completedSubtaskCount)/\(task.subtaskCount)", systemImage: "list.bullet.indent")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(task.completedSubtaskCount) of \(task.subtaskCount) subtasks done")
            }
            if task.commentCount > 0 {
                Label("\(task.commentCount)", systemImage: "bubble.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(task.commentCount) comments")
            }

            Spacer(minLength: 8)

            if showProject, let project = task.project {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: project.color)).frame(width: 7, height: 7)
                    Text(project.name).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let due = task.dueDate {
                Text(Formatting.due(due, today: today))
                    .font(.caption)
                    .foregroundStyle(!task.completed && Formatting.isOverdue(due, today: today) ? Color.red : Color.secondary)
                    .accessibilityLabel("Due \(Formatting.due(due, today: today))")
            }
            if let assignee = task.assignee {
                Avatar(user: assignee, size: 18)
                    .help(assignee.name)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.row.\(task.id)")
    }
}
