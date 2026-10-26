import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// The task inspector (SPEC-MAC §5): every v1 field editable in place, subtasks, followers,
/// comments and activity with a composer. Text fields commit on Return or when focus leaves.
@MainActor
struct TaskInspectorView: View {
    let session: AppSession
    let scope: WorkspaceScope
    @Bindable var store: TaskDetailStore
    /// Open another task (subtask / parent) in the same inspector or window.
    var onOpenTask: (String) -> Void = { _ in }
    /// Files dragged over the inspector (editors attach them to the task).
    @State private var dropTargeted = false

    private var attachmentContext: AttachmentContext {
        AttachmentContext(actions: AttachmentActions(session: session, scope: scope, store: store))
    }

    var body: some View {
        Group {
            if let task = InspectorPreview.detail(store: store, cache: scope.tasks) {
                // Before the first GET /tasks/:id, `task` is the list row's TaskItem (stale-while-
                // revalidate): shown at once, read-only, with the rest loading in place.
                let loaded = store.task != nil
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ErrorBanner(error: store.lastError) { store.clearError() }
                        header(task, loaded: loaded)
                        fields(task)
                        if loaded || !(task.description ?? "").isEmpty {
                            DescriptionEditor(text: task.description ?? "", canEdit: store.canEdit) { text in
                                guard canCommit else { return }
                                Task { await store.setDescription(text.isEmpty ? nil : text) }
                            }
                        }
                        if loaded {
                            AttachmentsSection(context: attachmentContext)
                            SubtasksSection(store: store, subtasks: task.subtasks, onOpenTask: onOpenTask)
                            FollowersSection(scope: scope, store: store, followers: task.followers)
                            Divider()
                            StoriesSection(stories: store.stories, me: scope.me, canDelete: { $0.author.id == scope.me.id },
                                           attachmentContext: attachmentContext) { id in
                                Task { await store.deleteComment(id) }
                            }
                        } else {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading details…").foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("inspector.loadingDetails")
                        }
                    }
                    .padding(16)
                }
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .padding(4)
                            .allowsHitTesting(false)
                    }
                }
                .onDrop(of: AttachmentDrop.types, isTargeted: Binding(get: { dropTargeted }, set: { dropTargeted = $0 && store.canAttach })) { providers in
                    attachDropped(providers)
                }
                .background {
                    PasteCatcher { responder in pasteIntoTask(firstResponder: responder) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if loaded {
                        CommentComposerView(composer: store.composer)
                            .padding(12)
                            .background(.bar)
                    }
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

    /// Files dropped on the inspector become task-level attachments (editors only; the composer takes
    /// drops for commenters). Folders are left out.
    private func attachDropped(_ providers: [NSItemProvider]) -> Bool {
        guard store.task != nil, store.canAttach else { return false }
        Task {
            for file in await AttachmentDrop.files(from: providers).files { store.attach(fileAt: file.url) }
        }
        return true
    }

    /// ⌘V of files or an image with no text field focused attaches them to the task (editors only); in a
    /// text field it's an ordinary paste (the composer takes its own).
    private func pasteIntoTask(firstResponder: NSResponder?) -> Bool {
        guard store.task != nil, store.canAttach, !(firstResponder is NSText),
              let files = AttachmentPaste.files(from: .general) else { return false }
        for file in files { store.attach(fileAt: file.url, fileName: file.name, deletesFile: file.deletesFile) }
        return true
    }

    /// Commits from onDisappear can fire while a workspace switch replaces the scope; by then requests
    /// carry the new workspace's header, so a late save for this task is dropped instead.
    private var canCommit: Bool {
        guard !session.isSwitching else { return false }
        return session.scope?.id == scope.id
    }

    @ViewBuilder private func header(_ task: TaskDetail, loaded: Bool) -> some View {
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
                CompleteTaskButton(completed: task.completed, title: task.title, canEdit: store.canEdit) {
                    Task { await store.toggleComplete() }
                }
                .tint(task.completed ? .green : nil)
                .buttonStyle(.bordered)
                .disabled(!store.canEdit)
                Spacer()
                if loaded, !store.canEdit {
                    Label("Read only", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("You can comment, but not edit tasks in this project.")
                }
            }
            CommitTextField(value: task.title, placeholder: "Task name", font: .title2.weight(.semibold), canEdit: store.canEdit) { title in
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return false } // an empty name reverts
                guard canCommit else { return false } // mid-switch: revert rather than pretend it saved
                Task { await store.setTitle(trimmed) }
                return true
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

/// A text field that edits a local copy and commits on Return, on focus loss, and when the view goes
/// away (switching to a subtask, ⌘W): macOS buttons don't take focus, so focus loss alone would drop
/// the draft. `commit` returns false to reject the value (the field reverts). Outside changes, such as
/// the store reverting a failed save, show unless there are uncommitted edits.
@MainActor
struct CommitTextField: View {
    let value: String
    var placeholder = ""
    var font: Font = .body
    var canEdit = true
    let commit: (String) -> Bool

    @State private var text = ""
    @State private var dirty = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .disabled(!canEdit)
            .onAppear { text = value }
            .onChange(of: text) { _, new in if new != value { dirty = true } }
            .onChange(of: value) { _, new in if !dirty { text = new } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commitIfChanged() } }
            .onSubmit(commitIfChanged)
            .onDisappear(perform: commitIfChanged)
    }

    private func commitIfChanged() {
        defer { dirty = false }
        guard dirty, text != value else { return }
        if !commit(text) { text = value }
    }
}

/// The description, rendered as inline markdown like comments (SPEC-MAC §5); a click switches an
/// editor to the plain-text editor, which commits when focus leaves it.
@MainActor
struct DescriptionEditor: View {
    let text: String
    let canEdit: Bool
    let commit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Description").font(.headline)
            if editing {
                editor
            } else {
                rendered
            }
        }
    }

    private var rendered: some View {
        Group {
            if text.isEmpty {
                Text(canEdit ? "What is this task about?" : "No description")
                    .foregroundStyle(.tertiary)
            } else if canEdit {
                Text(Formatting.markdown(text))
            } else {
                Text(Formatting.markdown(text)).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(box)
        .contentShape(Rectangle())
        .onTapGesture { if canEdit { beginEditing() } }
        .help(canEdit ? "Click to edit" : "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Description")
        .accessibilityValue(text)
        .accessibilityAddTraits(canEdit ? .isButton : [])
        .accessibilityRemoveTraits(canEdit ? [] : .isButton)
        .accessibilityAction { if canEdit { beginEditing() } }
        .accessibilityIdentifier("inspector.description")
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.body)
            .frame(minHeight: 70)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(box)
            .focused($focused)
            .accessibilityLabel("Description")
            .accessibilityIdentifier("inspector.descriptionEditor")
            .onAppear {
                draft = text
                focused = true
            }
            .onChange(of: text) { _, new in if !focused { draft = new } }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused else { return }
                if draft != text { commit(draft) }
                // Leaving edit mode removes the editor; its onDisappear must not commit again.
                draft = text
                editing = false
            }
            .onExitCommand { focused = false }
            // Switching tasks or closing the window doesn't move focus first on macOS.
            .onDisappear { if draft != text { commit(draft) } }
    }

    private var box: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private func beginEditing() {
        draft = text
        editing = true
    }
}

@MainActor
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

/// Due date: a button that opens a calendar popover. The choice is saved once, when the popover
/// closes (one PATCH, one activity entry), not on every click or arrow key.
@MainActor
struct DueDateField: View {
    let date: LocalDate?
    let canEdit: Bool
    let onChange: (LocalDate?) -> Void

    @State private var picking = false
    @State private var draft = Date()
    /// The calendar was changed since the popover opened (quick picks save on their own).
    @State private var touched = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                draft = (date ?? .today()).date()
                touched = false
                picking = true
            } label: {
                if let date {
                    Label(Formatting.due(date, today: .today()), systemImage: "calendar")
                        .foregroundStyle(Formatting.isOverdue(date, today: .today()) ? .red : .primary)
                } else {
                    Label("Add due date", systemImage: "calendar.badge.plus")
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(date.map { "Due date: \(Formatting.due($0, today: .today()))" } ?? "Add due date")
            .popover(isPresented: $picking, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("Due date", selection: $draft, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .onChange(of: draft) { _, _ in touched = true }
                    HStack {
                        Button("Today") { pick(.today()) }
                        Button("Tomorrow") { pick(LocalDate.today().adding(days: 1)) }
                        Spacer()
                        if date != nil {
                            Button("Clear", role: .destructive) { pick(nil) }
                        }
                        Button("Done") { picking = false }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
                .onDisappear {
                    // Closing the popover (Done, Escape, click outside) saves the calendar choice once.
                    let chosen = LocalDate(draft)
                    if touched, chosen != date { onChange(chosen) }
                    touched = false
                }
            }
            if date != nil {
                Button("Clear due date", systemImage: "xmark.circle.fill") { onChange(nil) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!canEdit)
    }

    /// Quick picks save immediately and close the popover without a second save.
    private func pick(_ value: LocalDate?) {
        touched = false
        if value != date { onChange(value) }
        picking = false
    }
}

@MainActor
struct SubtasksSection: View {
    let store: TaskDetailStore
    let subtasks: [TaskItem]
    let onOpenTask: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Subtasks").font(.headline)
            ForEach(subtasks) { subtask in
                HStack(spacing: 8) {
                    CompletionCheckbox(completed: subtask.completed, title: subtask.title, size: 14, canEdit: store.canEdit) {
                        Task { await store.toggleSubtask(subtask.id) }
                    }
                    Button { onOpenTask(subtask.id) } label: {
                        CompletionTitle(title: subtask.title, completed: subtask.completed)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(subtask.title)
                    Spacer()
                    if let assignee = subtask.assignee { Avatar(user: assignee, size: 16) }
                }
                .accessibilityIdentifier("subtask.row.\(subtask.id)")
            }
            if store.canEdit {
                HStack(spacing: 8) {
                    Image(systemName: "plus").foregroundStyle(.secondary).accessibilityHidden(true)
                    AddItemField(placeholder: "Add subtask", accessibilityID: "subtask.addField", accessibilityLabel: "New subtask title") { title in
                        Task { await store.addSubtask(title: title) }
                    }
                }
            }
        }
    }
}

@MainActor
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

/// What the inspector shows: the loaded detail, else (until the first load finishes) the task's row
/// from the list cache, so selecting a task never blanks the panel (rc1 QA P1). A failed load shows
/// its error instead (e.g. no access), not a stale preview.
@MainActor
enum InspectorPreview {
    static func detail(store: TaskDetailStore, cache: TaskCache) -> TaskDetail? {
        if let loaded = store.task { return loaded }
        if case .failed = store.phase { return nil }
        return cache[store.taskID].map { TaskDetail(task: $0) }
    }
}
