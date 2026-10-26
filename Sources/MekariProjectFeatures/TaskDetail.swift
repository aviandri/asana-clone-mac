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
  /// What the scope already knows about a project (the sidebar's, with my role), until our own fetch.
  @ObservationIgnored private let knownProject: (String) -> Project?
  /// My role in a project, as fetched on `load()`.
  private var fetchedRole: (projectID: String, role: ProjectRole?)?
  /// Task-level uploads live at session scope, so they outlive this store's views.
  @ObservationIgnored private let uploadStore: AttachmentUploads
  @ObservationIgnored private let workspaceID: String

  public convenience init(api: any MekariAPI, tasks: TaskCache, taskID: String, me: UserSummary, workspaceRole: WorkspaceRole,
                          clock: any Clock<Duration> = ContinuousClock(), knownProject: @escaping (String) -> Project? = { _ in nil }) {
    let slots = UploadSlots()
    self.init(api: api, tasks: tasks, taskID: taskID, me: me, workspaceRole: workspaceRole, clock: clock, knownProject: knownProject,
              uploads: AttachmentUploads(slots: slots, api: { api }), slots: slots, workspaceID: "")
  }

  init(api: any MekariAPI, tasks: TaskCache, taskID: String, me: UserSummary, workspaceRole: WorkspaceRole,
       clock: any Clock<Duration>, knownProject: @escaping (String) -> Project?, uploads: AttachmentUploads, slots: UploadSlots,
       workspaceID: String) {
    self.api = api
    self.tasks = tasks
    self.taskID = taskID
    self.me = me
    self.workspaceRole = workspaceRole
    self.knownProject = knownProject
    uploadStore = uploads
    self.workspaceID = workspaceID
    composer = CommentComposer(api: api, taskID: taskID, users: UserSearch(api: api, clock: clock), slots: slots)
    composer.onSent = { [weak self] comment in
      guard let self else { return }
      self.stories.append(.comment(comment))
      if !comment.attachments.isEmpty {
        self.tasks.editAttachments(self.taskID) { list in
          list.removeAll { a in comment.attachments.contains { $0.id == a.id } }
          list += comment.attachments
        }
      }
    }
    if uploads.onFinished == nil {
      // Standalone (tests, previews): finished uploads land here directly. WorkspaceScope routes them otherwise.
      uploads.onFinished = { [weak self] attachment in self?.attachmentAdded(attachment) }
    }
  }

  public var task: TaskDetail? { tasks.detail(taskID) }

  /// Personal tasks: always. Project tasks: workspace admins and every member but COMMENTERs. The role
  /// comes from our own fetch, else what the scope already knows (so the inspector isn't briefly
  /// read-only); while neither knows the project, it's read-only (fail closed).
  public var canEdit: Bool {
    guard let task = tasks[taskID] else { return false }
    guard let projectID = task.projectId, workspaceRole != .admin else { return true }
    if let fetchedRole, fetchedRole.projectID == projectID { return fetchedRole.role != .commenter }
    guard let project = knownProject(projectID) else { return false }
    return project.myRole != .commenter
  }

  public var isFollowing: Bool { task?.followers.contains { $0.id == me.id } ?? false }

  // MARK: - Attachments

  /// Task-level and comment attachments, newest first.
  public var attachments: [Attachment] { task?.attachments ?? [] }

  /// This task's queued, running and failed task-level uploads (they survive closing the task).
  public var uploads: [AttachmentUpload] { uploadStore.uploads(for: taskID) }

  /// Task-level attachments need edit rights; COMMENTERs attach through the composer only.
  public var canAttach: Bool { canEdit }

  /// The uploader, the project OWNER or a workspace ADMIN; personal tasks: the uploader or the task creator (A7).
  public func canDelete(_ attachment: Attachment) -> Bool {
    if attachment.uploader.id == me.id || workspaceRole == .admin { return true }
    guard let task = tasks[taskID] else { return false }
    guard let projectID = task.projectId else { return task.creator.id == me.id }
    if let fetchedRole, fetchedRole.projectID == projectID { return fetchedRole.role == .owner }
    return knownProject(projectID)?.myRole == .owner
  }

  /// Starts a task-level upload (it carries on if the task is closed). Over 100 MB fails at once, without a request.
  public func attach(fileAt url: URL, fileName: String? = nil) {
    uploadStore.start(taskID: taskID, workspaceID: task?.workspaceId ?? workspaceID, file: url, fileName: fileName)
  }

  /// Adds a task-level link. A URL that isn't absolute http(s) is refused locally (`lastError`).
  public func addLink(_ url: String, title: String?) async {
    switch validateLink(url) {
    case .failure(let error):
      lastError = error
    case .success(let link):
      do {
        attachmentAdded(try await api.addLink(taskID: taskID, url: link, title: title, draft: false))
      } catch {
        recordFailure(error, lastError: &lastError)
      }
    }
  }

  public func retryUpload(_ id: UUID) { uploadStore.retry(id) }

  /// Cancels a queued or running upload, or dismisses a failed one.
  public func cancelUpload(_ id: UUID) { uploadStore.cancel(id) }

  /// Deletes an attachment. A comment one also leaves its comment, and an empty-body comment whose last
  /// attachment this was is removed (the server deletes it too).
  public func deleteAttachment(_ id: String) async {
    let attachment = attachments.first { $0.id == id } ?? commentAttachment(id)
    do {
      try await api.deleteAttachment(id)
    } catch let error as APIError where error.code == .notFound {
      // Already gone: drop it locally too.
    } catch {
      recordFailure(error, lastError: &lastError)
      return
    }
    tasks.editAttachments(taskID) { $0.removeAll { $0.id == id } }
    guard let commentID = attachment?.commentId else { return }
    stories = stories.compactMap { story in
      guard case .comment(var comment) = story, comment.id == commentID else { return story }
      comment.attachments.removeAll { $0.id == id }
      if comment.attachments.isEmpty && comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
      return .comment(comment)
    }
  }

  public func refreshLinkPreview(_ id: String) async {
    do {
      let refreshed = try await api.refreshLinkPreview(id)
      tasks.editAttachments(taskID) { list in
        if let i = list.firstIndex(where: { $0.id == id }) { list[i] = refreshed }
      }
      replaceInComments(refreshed)
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  /// A finished task-level upload or link (also called by the scope when an upload finishes after the task closed).
  func attachmentAdded(_ attachment: Attachment) {
    guard attachment.taskId == taskID else { return }
    tasks.editAttachments(taskID, bumpedAt: attachment.createdAt) { list in
      list.removeAll { $0.id == attachment.id }
      list.append(attachment)
    }
  }

  private func commentAttachment(_ id: String) -> Attachment? {
    for story in stories {
      if case .comment(let comment) = story, let found = comment.attachments.first(where: { $0.id == id }) { return found }
    }
    return nil
  }

  private func replaceInComments(_ attachment: Attachment) {
    guard let commentID = attachment.commentId else { return }
    stories = stories.map { story in
      guard case .comment(var comment) = story, comment.id == commentID,
            let i = comment.attachments.firstIndex(where: { $0.id == attachment.id }) else { return story }
      comment.attachments[i] = attachment
      return .comment(comment)
    }
  }

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
          fetchedRole = (projectID, try await api.project(projectID).myRole)
        } catch {
          fetchedRole = nil // back to what the scope knows, or read-only
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

  /// Draft attachment chips, in the order added. Finished ones are drafts on the server until sent.
  public private(set) var attachments: [AttachmentUpload] = []

  @ObservationIgnored private let api: any MekariAPI
  @ObservationIgnored private let taskID: String
  @ObservationIgnored private let runner: UploadRunner
  @ObservationIgnored var onSent: ((Comment) -> Void)?

  public convenience init(api: any MekariAPI, taskID: String, users: UserSearch) {
    self.init(api: api, taskID: taskID, users: users, slots: UploadSlots())
  }

  init(api: any MekariAPI, taskID: String, users: UserSearch, slots: UploadSlots) {
    self.api = api
    self.taskID = taskID
    self.users = users
    runner = UploadRunner(slots: slots)
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

  /// Text or at least one finished chip; nothing queued, uploading or failed (retry or remove it first); not sending.
  public var canSend: Bool {
    let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let ready = attachments.allSatisfy(\.isFinished)
    return (hasText || !attachments.isEmpty) && ready && !isSending
  }

  /// True while a chip is queued or uploading (Send stays disabled).
  public var isUploading: Bool { attachments.contains(where: \.isActive) }

  public func send() async {
    guard canSend else { return }
    isSending = true
    defer { isSending = false }
    let sent = draft
    let sentChips = attachments.compactMap { chip in chip.attachment.map { (chip.id, $0.id) } }
    do {
      let comment = try await api.addComment(taskID: taskID, body: sent.trimmingCharacters(in: .whitespacesAndNewlines),
                                             attachmentIDs: sentChips.map(\.1))
      // Keep anything typed while sending.
      if draft == sent {
        draft = ""
      } else if draft.hasPrefix(sent) {
        draft = String(draft.dropFirst(sent.count)).trimmingCharacters(in: .whitespaces)
      }
      // Chips added while sending stay.
      let sentIDs = Set(sentChips.map(\.0))
      attachments.removeAll { sentIDs.contains($0.id) }
      lastError = nil
      onSent?(comment)
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  // MARK: Draft attachments

  /// Uploads a file as a draft (`?draft=true`). Over 100 MB, unreadable, or past 20 chips → refused without a request.
  public func attach(fileAt url: URL, fileName: String? = nil) {
    guard roomForAnother() else { return }
    let name = fileName ?? url.lastPathComponent
    switch preflight(url) {
    case .failure(let error):
      attachments.append(AttachmentUpload(taskID: taskID, source: .file(url, name: name), state: .failed(error)))
    case .success(let size):
      let chip = AttachmentUpload(taskID: taskID, source: .file(url, name: name), size: size)
      attachments.append(chip)
      run(chip)
    }
  }

  /// Adds a draft link. A URL that isn't absolute http(s) is refused locally (`lastError`).
  public func attachLink(_ url: String, title: String?) async {
    guard roomForAnother() else { return }
    switch validateLink(url) {
    case .failure(let error):
      lastError = error
    case .success(let link):
      let chip = AttachmentUpload(taskID: taskID, source: .link(url: link, title: title))
      attachments.append(chip)
      run(chip)
    }
  }

  public func retry(_ id: UUID) {
    guard let i = attachments.firstIndex(where: { $0.id == id }), attachments[i].isFailed else { return }
    if case .file(let url, _) = attachments[i].source, case .failure(let error) = preflight(url) {
      attachments[i].state = .failed(error)
      return
    }
    attachments[i].state = .queued
    run(attachments[i])
  }

  /// Removes a chip: cancels its upload, or deletes the uploaded draft (best effort; the server sweeps the rest).
  public func remove(_ id: UUID) async {
    guard let i = attachments.firstIndex(where: { $0.id == id }) else { return }
    let chip = attachments.remove(at: i)
    runner.cancel(id)
    if let draft = chip.attachment { try? await api.deleteAttachment(draft.id) }
  }

  /// Removes every chip (the App calls this when the task is closed). Typed text stays.
  public func discard() async {
    let chips = attachments
    attachments = []
    runner.cancelAll()
    for draft in chips.compactMap(\.attachment) { try? await api.deleteAttachment(draft.id) }
  }

  /// Stops uploads without deleting anything (the scope closed; the server sweeps the drafts).
  func cancelUploads() {
    runner.cancelAll()
    attachments = []
  }

  private func roomForAnother() -> Bool {
    guard attachments.count < AttachmentLimits.maxPerComment else {
      lastError = APIError(code: .validation, message: "A comment can have up to \(AttachmentLimits.maxPerComment) attachments")
      return false
    }
    return true
  }

  private func run(_ chip: AttachmentUpload) {
    runner.run(chip, draft: true, api: api) { [weak self] id, state in
      guard let self, let i = self.attachments.firstIndex(where: { $0.id == id }) else { return }
      if case .uploading = state, !self.attachments[i].isActive { return }
      self.attachments[i].state = state
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
