import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// Board view: a column per section; drag cards between and within columns. A drop on a card puts the
/// task before it; a drop on the column's empty space or "Add task" puts it at the end.
struct ProjectBoardView: View {
    let scope: WorkspaceScope
    let store: ProjectStore
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                if store.hasUnsectionedTasks {
                    BoardColumn(scope: scope, store: store, sectionID: nil, title: "No section", section: nil, selection: $selection)
                }
                ForEach(store.sections) { section in
                    BoardColumn(scope: scope, store: store, sectionID: section.id, title: section.name, section: section, selection: $selection)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct BoardColumn: View {
    let scope: WorkspaceScope
    let store: ProjectStore
    let sectionID: String?
    let title: String
    let section: MekariProjectKit.Section?
    @Binding var selection: String?
    @State private var targeted = false

    var body: some View {
        let ids = store.taskIDs(in: sectionID)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Text("\(ids.count)").foregroundStyle(.secondary)
                Spacer()
            }
            .modifier(SectionRenameModifier(store: store, section: section))

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(ids, id: \.self) { id in
                        if let task = scope.tasks[id] {
                            BoardCard(scope: scope, task: task, isSelected: selection == id, canEdit: store.canEdit) {
                                Task { await store.toggleComplete(id) }
                            }
                            .onTapGesture { selection = id }
                            .taskDrag(task, enabled: store.canEdit)
                            .taskDrop(store: store, tasks: scope.tasks, section: sectionID, before: id)
                        }
                    }
                    if store.canEdit {
                        AddTaskRow { title in
                            Task { await store.addTask(title: title, section: sectionID) }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.6)))
                        .taskDrop(store: store, tasks: scope.tasks, section: sectionID, before: nil, isTargeted: $targeted)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? Color.accentColor : Color.clear, lineWidth: 2))
        )
        // Anywhere else in the column (header, blank space below the cards): drop at the end.
        // Cards and "Add task" are inner drop targets and win where they are.
        .contentShape(Rectangle())
        .taskDrop(store: store, tasks: scope.tasks, section: sectionID, before: nil, isTargeted: $targeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(ids.count) tasks")
    }
}

private struct BoardCard: View {
    let scope: WorkspaceScope
    let task: TaskItem
    let isSelected: Bool
    let canEdit: Bool
    let onToggle: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let today = LocalDate.today()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Button(action: onToggle) {
                    Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.completed ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
                .accessibilityLabel(task.completed ? "Mark \(task.title) incomplete" : "Mark \(task.title) complete")
                Text(task.title)
                    .strikethrough(task.completed)
                    .foregroundStyle(task.completed ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                if task.priority != Priority.none {
                    Text(task.priority.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(task.priority.tint)
                }
                if let due = task.dueDate {
                    Label(Formatting.due(due, today: today), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(!task.completed && Formatting.isOverdue(due, today: today) ? Color.red : Color.secondary)
                }
                if task.subtaskCount > 0 {
                    Label("\(task.completedSubtaskCount)/\(task.subtaskCount)", systemImage: "list.bullet.indent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let assignee = task.assignee { Avatar(user: assignee, size: 18).help(assignee.name) }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            openWindow(id: WindowID.task, value: TaskWindowRef(workspaceID: scope.id, taskID: task.id))
        })
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("task.row.\(task.id)")
    }
}
