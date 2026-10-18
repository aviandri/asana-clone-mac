import Foundation
import MekariProjectKit
import Observation

/// The task inspector (SPEC-MAC §5). Every edit is optimistic through `TaskCache`.
@MainActor @Observable
public final class TaskDetailStore {
  public let taskID: String
  /// Comments and activity, oldest first.
  public private(set) var stories: [Story] = []
  public private(set) var phase: LoadState = .idle
  public private(set) var lastError: APIError?
  public let composer: CommentComposer

  @ObservationIgnored private let api: any MekariAPI
  @ObservationIgnored private let tasks: TaskCache
  @ObservationIgnored private let me: UserSummary
  @ObservationIgnored private let workspaceRole: WorkspaceRole
  private var projectRole: ProjectRole?
  /// False until the project role is known; project tasks stay read-only until then (fail closed).
  private var projectRoleKnown = false

  public init(api: any MekariAPI, tasks: TaskCache, taskID: String, me: UserSummary, workspaceRole: WorkspaceRole,
              clock: any Clock<Duration> = ContinuousClock()) {
    self.api = api
    self.tasks = tasks
    self.taskID = taskID
    self.me = me
    self.workspaceRole = workspaceRole
    composer = CommentComposer(api: api, taskID: taskID, users: UserSearch(api: api, clock: clock))
    composer.onSent = { [weak self] comment in self?.stories.append(.comment(comment)) }
  }

  public var task: TaskDetail? { tasks.detail(taskID) }

  /// Personal tasks: always. Project tasks: workspace admins and every member but COMMENTERs.
  public var canEdit: Bool {
    guard let task else { return false }
    if task.projectId == nil || workspaceRole == .admin { return true }
    return projectRoleKnown && projectRole != .commenter
  }

  public var isFollowing: Bool { task?.followers.contains { $0.id == me.id } ?? false }

  public func load() async {
    if task == nil { phase = .loading }
    do {
      async let detailCall = api.task(taskID)
      async let storiesCall = api.stories(taskID: taskID)
      let (detail, loadedStories) = try await (detailCall, storiesCall)
      tasks.upsert(detail)
      stories = loadedStories
      if let projectID = detail.projectId {
        do {
          projectRole = try await api.project(projectID).myRole
          projectRoleKnown = true
        } catch {
          projectRoleKnown = false
        }
      }
      phase = .loaded
    } catch {
      recordFailure(error, phase: &phase, lastError: &lastError)
    }
  }

  public func setTitle(_ title: String) async {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != task?.title else { return }
    await apply(TaskChanges(title: trimmed))
  }

  public func setDescription(_ text: String?) async {
    let value = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    guard value != task?.description else { return }
    await apply(TaskChanges(description: value.map { .set($0) } ?? .clear))
  }

  public func setAssignee(_ user: UserSummary?) async {
    guard user?.id != task?.assignee?.id else { return }
    await apply(TaskChanges(assigneeId: user.map { .set($0.id) } ?? .clear), assignee: .some(user))
  }

  public func setDueDate(_ date: LocalDate?) async {
    guard date != task?.dueDate else { return }
    await apply(TaskChanges(dueDate: date.map { .set($0) } ?? .clear))
  }

  public func setPriority(_ priority: Priority) async {
    guard priority != task?.priority else { return }
    await apply(TaskChanges(priority: priority))
  }

  public func toggleComplete() async {
    guard let task else { return }
    await apply(TaskChanges(completed: !task.completed))
  }

  public func addSubtask(title: String) async {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      _ = try await api.createTask(NewTask(title: trimmed, parentId: taskID))
      tasks.upsert(try await api.task(taskID))
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  public func toggleSubtask(_ id: String) async {
    guard let subtask = tasks[id] ?? task?.subtasks.first(where: { $0.id == id }) else { return }
    do {
      try await tasks.update(id, TaskChanges(completed: !subtask.completed))
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  public func follow() async { await addFollower(me) }
  public func unfollow() async { await removeFollower(me) }

  public func addFollower(_ user: UserSummary) async {
    guard !(task?.followers.contains { $0.id == user.id } ?? false) else { return }
    do {
      tasks.upsert(try await api.addFollower(taskID: taskID, userID: user.id))
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  public func removeFollower(_ user: UserSummary) async {
    do {
      tasks.upsert(try await api.removeFollower(taskID: taskID, userID: user.id))
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  public func editComment(_ id: String, body: String) async {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      let edited = try await api.editComment(id, body: trimmed)
      stories = stories.map { story in
        if case .comment(let c) = story, c.id == id { return .comment(edited) }
        return story
      }
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  public func deleteComment(_ id: String) async {
    do {
      try await api.deleteComment(id)
      stories.removeAll { if case .comment(let c) = $0 { return c.id == id } else { return false } }
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  public func clearError() { lastError = nil }

  private func apply(_ changes: TaskChanges, assignee: UserSummary?? = .none) async {
    do {
      try await tasks.update(taskID, changes, assignee: assignee)
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }
}

/// The comment box. Mentions are typed as "@word" and stored as `@[Name](id)`.
@MainActor @Observable
public final class CommentComposer {
  public var draft = "" {
    didSet { if let query = mentionQuery { users.query = query } }
  }
  public let users: UserSearch
  public private(set) var isSending = false
  public private(set) var lastError: APIError?

  @ObservationIgnored private let api: any MekariAPI
  @ObservationIgnored private let taskID: String
  @ObservationIgnored var onSent: ((Comment) -> Void)?

  public init(api: any MekariAPI, taskID: String, users: UserSearch) {
    self.api = api
    self.taskID = taskID
    self.users = users
  }

  /// The "@word" being typed at the end of the draft (no cursor API on macOS 14's TextEditor), or nil.
  /// "@" must start the draft or follow whitespace, and a finished token `@[Name](id)` doesn't count.
  public var mentionQuery: String? {
    guard let at = draft.lastIndex(of: "@") else { return nil }
    if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
    let word = draft[draft.index(after: at)...]
    guard !word.contains(where: { $0.isWhitespace || $0 == "[" || $0 == "(" || $0 == ")" }) else { return nil }
    return String(word)
  }

  /// Replaces the trailing "@word" with the mention token and a space.
  public func insertMention(_ user: PickableUser) {
    guard mentionQuery != nil, let at = draft.lastIndex(of: "@") else { return }
    draft = String(draft[..<at]) + Mentions.token(for: user.user) + " "
  }

  public var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending }

  public func send() async {
    guard canSend else { return }
    isSending = true
    defer { isSending = false }
    let sent = draft
    do {
      let comment = try await api.addComment(taskID: taskID, body: sent.trimmingCharacters(in: .whitespacesAndNewlines))
      // Keep anything typed while sending.
      if draft == sent {
        draft = ""
      } else if draft.hasPrefix(sent) {
        draft = String(draft.dropFirst(sent.count)).trimmingCharacters(in: .whitespaces)
      }
      lastError = nil
      onSent?(comment)
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  public func clearError() { lastError = nil }
}

/// People pickers (assignee, followers, mentions): `GET /users?q=`, debounced. Entries carry the
/// workspace role, so guests can be badged (W8).
@MainActor @Observable
public final class UserSearch {
  public var query = "" {
    didSet { schedule() }
  }
  public private(set) var results: [PickableUser] = []
  public private(set) var isLoading = false
  public private(set) var lastError: APIError?

  @ObservationIgnored private let api: any MekariAPI
  @ObservationIgnored private let debouncer: Debouncer
  @ObservationIgnored private var generation = 0

  public init(api: any MekariAPI, clock: any Clock<Duration> = ContinuousClock()) {
    self.api = api
    debouncer = Debouncer(clock: clock, delay: .milliseconds(250))
  }

  private func schedule() {
    generation += 1
    let current = generation
    let q = query.trimmingCharacters(in: .whitespaces)
    isLoading = true
    debouncer.schedule { [weak self] in
      guard let self else { return }
      do {
        let found = try await self.api.users(query: q.isEmpty ? nil : q)
        guard current == self.generation else { return } // a newer query is on its way
        self.results = found
        self.lastError = nil
      } catch {
        guard current == self.generation else { return }
        recordFailure(error, lastError: &self.lastError)
      }
      self.isLoading = false
    }
  }
}
