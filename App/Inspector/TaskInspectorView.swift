import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// The task inspector (SPEC-MAC §5): every v1 field editable in place, subtasks, followers,
/// comments and activity with a composer. Text fields commit on Return or when focus leaves.
struct TaskInspectorView: View {
    let scope: WorkspaceScope
    @Bindable var store: TaskDetailStore
    /// Open another task (subtask / parent) in the same inspector or window.
    var onOpenTask: (String) -> Void = { _ in }

    var body: some View {
        Group {
            if let task = store.task {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ErrorBanner(error: store.lastError) { store.clearError() }
                        header(task)
                        fields(task)
                        DescriptionEditor(text: task.description ?? "", canEdit: store.canEdit) { text in
                            Task { await store.setDescription(text.isEmpty ? nil : text) }
                        }
                        SubtasksSection(store: store, subtasks: task.subtasks, onOpenTask: onOpenTask)
                        FollowersSection(scope: scope, store: store, followers: task.followers)
                        Divider()
                        StoriesSection(stories: store.stories, me: scope.me, canDelete: { $0.author.id == scope.me.id }) { id in
                            Task { await store.deleteComment(id) }
                        }
                    }
                    .padding(16)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    CommentComposerView(composer: store.composer)
                        .padding(12)
                        .background(.bar)
                }
            } else if case .failed(let error) = store.phase {
                ContentUnavailableView(
                    error.code == .notFound ? "You Don't Have Access" : "Couldn't Load Task",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.code == .notFound ? "This task doesn't exist, or it's in a workspace you're not in." : error.message)
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.inspector")
        .task { await store.load() }
    }

    @ViewBuilder private func header(_ task: TaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let parent = task.parent {
                Button {
                    onOpenTask(parent.id)
                } label: {
                    Label(parent.title, systemImage: "arrow.turn.left.up")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .help("Open the parent task")
            }
            HStack {
                Button {
                    Task { await store.toggleComplete() }
                } label: {
                    Label(task.completed ? "Completed" : "Mark Complete", systemImage: task.completed ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .tint(task.completed ? .green : nil)
                .buttonStyle(.bordered)
                .disabled(!store.canEdit)
                Spacer()
                if !store.canEdit {
                    Label("Read only", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("You can comment, but not edit tasks in this project.")
                }
            }
            CommitTextField(value: task.title, placeholder: "Task name", font: .title2.weight(.semibold), canEdit: store.canEdit) { title in
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { Task { await store.setTitle(trimmed) } }
            }
            .accessibilityLabel("Task name")
        }
    }

    @ViewBuilder private func fields(_ task: TaskDetail) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                fieldLabel("Assignee")
                AssigneeField(scope: scope, assignee: task.assignee, canEdit: store.canEdit) { user in
                    Task { await store.setAssignee(user) }
                }
            }
            GridRow {
                fieldLabel("Due date")
                DueDateField(date: task.dueDate, canEdit: store.canEdit) { date in
                    Task { await store.setDueDate(date) }
                }
            }
            GridRow {
                fieldLabel("Priority")
                Picker("Priority", selection: Binding(
                    get: { task.priority },
                    set: { priority in Task { await store.setPriority(priority) } }
                )) {
                    ForEach(Priority.allCases, id: \.self) { priority in
                        Text(priority.label).tag(priority)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!store.canEdit)
            }
            if let project = task.project {
                GridRow {
                    fieldLabel("Project")
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: project.color)).frame(width: 8, height: 8)
                        Text(project.name)
                    }
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

/// A text field that edits a local copy and calls `commit` on Return or when it loses focus.
/// Follows outside changes while it isn't being edited.
struct CommitTextField: View {
    let value: String
    var placeholder = ""
    var font: Font = .body
    var canEdit = true
    let commit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .disabled(!canEdit)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commitIfChanged() } }
            .onSubmit(commitIfChanged)
    }

    private func commitIfChanged() {
        if text != value { commit(text) }
    }
}

/// Multi-line description; commits when focus leaves the editor.
struct DescriptionEditor: View {
    let text: String
    let canEdit: Bool
    let commit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Description").font(.headline)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty && !focused {
                        Text("What is this task about?")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .focused($focused)
                .disabled(!canEdit)
                .accessibilityLabel("Description")
                .onAppear { draft = text }
                .onChange(of: text) { _, new in if !focused { draft = new } }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused, draft != text { commit(draft) }
                }
        }
    }
}

struct AssigneeField: View {
    let scope: WorkspaceScope
    let assignee: UserSummary?
    let canEdit: Bool
    let onChange: (UserSummary?) -> Void
    @State private var picking = false

    var body: some View {
        Button {
            picking = true
        } label: {
            HStack(spacing: 6) {
                Avatar(user: assignee, size: 20)
                Text(assignee?.name ?? "No assignee")
                    .foregroundStyle(assignee == nil ? .secondary : .primary)
            }
        }
        .buttonStyle(.borderless)
        .disabled(!canEdit)
        .accessibilityLabel(assignee.map { "Assignee: \($0.name)" } ?? "Assign")
        .popover(isPresented: $picking, arrowEdge: .leading) {
            UserPickerView(search: scope.userSearch(), selectedID: assignee?.id, allowsNone: true) { user in
                picking = false
                if user?.id != assignee?.id { onChange(user) }
            }
        }
    }
}

struct DueDateField: View {
    let date: LocalDate?
    let canEdit: Bool
    let onChange: (LocalDate?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let date {
                DatePicker("Due date", selection: Binding(
                    get: { date.date() },
                    set: { new in
                        let local = LocalDate(new)
                        if local != date { onChange(local) }
                    }
                ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                Text(Formatting.due(date, today: .today()))
                    .font(.caption)
                    .foregroundStyle(Formatting.isOverdue(date, today: .today()) ? .red : .secondary)
                Button("Clear due date", systemImage: "xmark.circle.fill") { onChange(nil) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            } else {
                Button("Add due date") { onChange(.today()) }
                    .buttonStyle(.borderless)
            }
        }
        .disabled(!canEdit)
    }
}

struct SubtasksSection: View {
    let store: TaskDetailStore
    let subtasks: [TaskItem]
    let onOpenTask: (String) -> Void
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Subtasks").font(.headline)
            ForEach(subtasks) { subtask in
                HStack(spacing: 8) {
                    Button {
                        Task { await store.toggleSubtask(subtask.id) }
                    } label: {
                        Image(systemName: subtask.completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(subtask.completed ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canEdit)
                    .accessibilityLabel(subtask.completed ? "Mark \(subtask.title) incomplete" : "Mark \(subtask.title) complete")
                    Button(subtask.title) { onOpenTask(subtask.id) }
                        .buttonStyle(.plain)
                        .strikethrough(subtask.completed)
                        .foregroundStyle(subtask.completed ? .secondary : .primary)
                    Spacer()
                    if let assignee = subtask.assignee { Avatar(user: assignee, size: 16) }
                }
                .accessibilityIdentifier("task.row.\(subtask.id)")
            }
            if store.canEdit {
                HStack(spacing: 8) {
                    Image(systemName: "plus").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Add subtask", text: $newTitle)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !title.isEmpty else { return }
                            newTitle = ""
                            Task { await store.addSubtask(title: title) }
                        }
                }
            }
        }
    }
}

struct FollowersSection: View {
    let scope: WorkspaceScope
    let store: TaskDetailStore
    let followers: [UserSummary]
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Followers").font(.headline)
                Spacer()
                Button(store.isFollowing ? "Unfollow" : "Follow") {
                    Task { store.isFollowing ? await store.unfollow() : await store.follow() }
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: -4) {
                ForEach(followers) { follower in
                    Avatar(user: follower, size: 24)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .help(follower.name)
                        .contextMenu {
                            Button("Remove \(follower.name)") { Task { await store.removeFollower(follower) } }
                        }
                }
                Button {
                    adding = true
                } label: {
                    Image(systemName: "person.badge.plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .padding(.leading, followers.isEmpty ? 0 : 10)
                .accessibilityLabel("Add follower")
                .popover(isPresented: $adding, arrowEdge: .leading) {
                    UserPickerView(search: scope.userSearch(), excludedIDs: Set(followers.map(\.id))) { user in
                        adding = false
                        if let user { Task { await store.addFollower(user) } }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(followers.isEmpty ? "No followers" : "Followers: \(followers.map(\.name).joined(separator: ", "))")
        }
    }
}
