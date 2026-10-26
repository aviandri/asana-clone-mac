// Swift 5.10's Linux Foundation doesn't mark URL Sendable yet (Darwin's and Swift 6's do).
#if canImport(FoundationNetworking) && compiler(<6.0)
@preconcurrency import Foundation
#else
import Foundation
#endif
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
  @ObservationIgnored private let uploadSlots: UploadSlots
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
    uploadSlots = slots
    self.workspaceID = workspaceID
    composer = CommentComposer(api: api, taskID: taskID, users: UserSearch(api: api, clock: clock), slots: slots)
    composer.onReload = { [weak self] in await self?.reloadAfterUncertainSend() }
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
  /// `deletesFile`: the file is a temp file of ours (a pasted image); it is deleted once the upload leaves the list.
  public func attach(fileAt url: URL, fileName: String? = nil, deletesFile: Bool = false) {
    uploadStore.start(taskID: taskID, workspaceID: task?.workspaceId ?? workspaceID, file: url, fileName: fileName,
                      deletesFile: deletesFile)
  }

  /// Adds a task-level link. Throws the `APIError` for the popover (`.validation` with an issue on `url` for a
  /// URL that isn't absolute http(s), checked locally first; the server's otherwise). `CancellationError` passes through.
  public func addLink(_ url: String, title: String?) async throws {
    let link = try validateLink(url).get()
    do {
      attachmentAdded(try await uploadSlots.run { try await api.addLink(taskID: taskID, url: link, title: title, draft: false) })
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw error.asAPIError
    }
  }

  public func retryUpload(_ id: UUID) { uploadStore.retry(id) }

  /// Cancels a queued or uploading upload, or dismisses a failed one. False (nothing happens) while it is finishing.
  @discardableResult
  public func cancelUpload(_ id: UUID) -> Bool { uploadStore.cancel(id) }

  /// Deletes an attachment, optimistically: it leaves the list (and its comment, and an empty-body comment whose
  /// last attachment it was, as the server does) at once, and comes back with `lastError` if the server refuses.
  public func deleteAttachment(_ id: String) async {
    let attachment = attachments.first { $0.id == id } ?? commentAttachment(id)
    let removedComment = attachment?.commentId.flatMap(comment(_:))
    let wasInList = attachments.contains { $0.id == id }
    tasks.editAttachments(taskID) { $0.removeAll { $0.id == id } }
    if let commentID = attachment?.commentId {
      stories = stories.compactMap { story in
        guard case .comment(var comment) = story, comment.id == commentID else { return story }
        comment.attachments.removeAll { $0.id == id }
        if comment.attachments.isEmpty && comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return .comment(comment)
      }
    }
    do {
      try await api.deleteAttachment(id)
    } catch let error as APIError where error.code == .notFound {
      // Already gone: stays gone.
    } catch {
      // Put it back where it was.
      if let attachment, wasInList { tasks.editAttachments(taskID) { list in list.append(attachment) } }
      if let removedComment { restore(removedComment) }
      recordFailure(error, lastError: &lastError)
    }
  }

  public func refreshLinkPreview(_ id: String) async {
    do {
      let refreshed = try await uploadSlots.run { try await api.refreshLinkPreview(id) }
      tasks.editAttachments(taskID) { list in
        if let i = list.firstIndex(where: { $0.id == id }) { list[i] = refreshed }
      }
      replaceInComments(refreshed)
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  /// A send's outcome was unknown and it turned out to have landed: show the comment and its attachments.
  func reloadAfterUncertainSend() async {
    do {
      async let loadedStories = api.stories(taskID: taskID)
      async let detail = api.task(taskID)
      let (newStories, newDetail) = try await (loadedStories, detail)
      stories = newStories
      tasks.upsert(newDetail)
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

  private func comment(_ id: String) -> Comment? {
    for story in stories {
      if case .comment(let comment) = story, comment.id == id { return comment }
    }
    return nil
  }

  /// Puts a comment back as it was (replacing the edited copy, or reinserting it by time).
  private func restore(_ comment: Comment) {
    if let i = stories.firstIndex(where: { $0.id == Story.comment(comment).id }) {
      stories[i] = .comment(comment)
    } else {
      let at = stories.firstIndex { $0.createdAt > comment.createdAt } ?? stories.endIndex
      stories.insert(.comment(comment), at: at)
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

  /// The body may be empty only when the comment has attachments (A9).
  public func editComment(_ id: String, body: String) async {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !(comment(id)?.attachments.isEmpty ?? true) else { return }
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
      // The server deletes the comment's attachments with it.
      tasks.editAttachments(taskID) { $0.removeAll { $0.commentId == id } }
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

  /// Text or at least one finished chip, nothing queued/uploading/finishing, not sending. Failed chips don't block
  /// (a successful send drops them, as on the web).
  public var canSend: Bool {
    let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return (hasText || attachments.contains(where: \.isFinished)) && !isUploading && !isSending
  }

  /// True while a chip is queued, uploading or finishing (Send stays disabled).
  public var isUploading: Bool { attachments.contains(where: \.isActive) }

  /// The chips being posted right now: their × is disabled and `remove` refuses them.
  public private(set) var sendingIDs: Set<UUID> = []

  public func send() async {
    guard canSend else { return }
    // A previous send failed without a definite answer: its chips may already be on a comment.
    if !uncertain.isEmpty {
      isSending = true
      let landed: Bool
      do {
        landed = try await settleUncertain()
      } catch {
        isSending = false
        recordFailure(error, lastError: &lastError)
        return
      }
      isSending = false
      if landed, draft.trimmingCharacters(in: .whitespacesAndNewlines) == uncertainBody {
        // That send did land (the answer was lost): don't post it again.
        uncertainBody = nil
        draft = ""
        lastError = nil
        return
      }
      guard canSend else { return }
    }
    isSending = true
    let sent = draft
    let posted = attachments.compactMap { chip in chip.attachment.map { (chip: chip.id, attachment: $0.id) } }
    let failedAtSend = Set(attachments.filter(\.isFailed).map(\.id))
    sendingIDs = Set(posted.map(\.chip))
    defer {
      isSending = false
      sendingIDs = []
    }
    do {
      let comment = try await api.addComment(taskID: taskID, body: sent.trimmingCharacters(in: .whitespacesAndNewlines),
                                             attachmentIDs: posted.map(\.attachment))
      // Keep anything typed while sending.
      if draft == sent {
        draft = ""
      } else if draft.hasPrefix(sent) {
        draft = String(draft.dropFirst(sent.count)).trimmingCharacters(in: .whitespaces)
      }
      // Only what was posted (and what had failed by then) goes; chips added meanwhile wait for the next comment.
      discardedWhileSending.subtract(sendingIDs)
      let gone = sendingIDs.union(failedAtSend)
      attachments.filter { gone.contains($0.id) }.forEach { $0.cleanUp() }
      attachments.removeAll { gone.contains($0.id) }
      lastError = nil
      onSent?(comment)
    } catch {
      recordFailure(error, lastError: &lastError)
      // Chips discarded while they were being posted: if the comment didn't take them, their drafts go now. Only a
      // 4xx says so for sure; after a transport failure or a 5xx (a proxy's 502/504 once the BE committed) the
      // comment may have landed, so ask first.
      let orphaned = posted.filter { item in discardedWhileSending.contains(item.chip) }
      discardedWhileSending.subtract(orphaned.map(\.chip))
      let rejected = (error as? APIError)?.status.map { (400..<500).contains($0) } ?? false
      for item in orphaned {
        if !rejected {
          guard let current = try? await api.attachment(item.attachment), current.commentId == nil, current.draft else { continue }
        }
        try? await api.deleteAttachment(item.attachment)
      }
      if !rejected {
        // A transport error or a 5xx: the BE may have committed. Ask before any delete or re-send.
        uncertain.formUnion(posted.map(\.chip).filter { id in attachments.contains { $0.id == id } })
        uncertainBody = sent.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
  }

  /// Chips a failed send may have posted (transport error or 5xx): checked before any delete or re-send.
  @ObservationIgnored private var uncertain: Set<UUID> = []
  @ObservationIgnored private var uncertainBody: String?
  /// Reloads the stories and the task (after an uncertain send turned out to have landed). Wired by TaskDetailStore.
  @ObservationIgnored var onReload: (() async -> Void)?

  /// Asks the server about every uncertain chip still here. One already on a comment (or no longer a draft, or gone)
  /// leaves without a delete; one still a draft becomes certain again. True when any had landed (the stories are then
  /// reloaded). Throws when the server can't say (the chips stay uncertain).
  private func settleUncertain() async throws -> Bool {
    var landed = false
    for chip in attachments where uncertain.contains(chip.id) {
      guard let attachmentID = chip.attachment?.id else { continue }
      if try await stillADraft(attachmentID) {
        uncertain.remove(chip.id)
      } else {
        uncertain.remove(chip.id)
        chip.cleanUp()
        attachments.removeAll { $0.id == chip.id }
        landed = true
      }
    }
    if landed { await onReload?() }
    return landed
  }

  /// Whether the attachment is still an unposted draft (404: gone, so no). Throws when the server can't say.
  private func stillADraft(_ attachmentID: String) async throws -> Bool {
    do {
      let current = try await api.attachment(attachmentID)
      return current.draft && current.commentId == nil
    } catch let error as APIError where error.code == .notFound {
      return false
    }
  }

  /// Deletes a chip's draft, unless it may already be on a comment (an uncertain send): then only if the server says
  /// it is still a draft. When the server can't say, nothing is deleted (it sweeps unposted drafts after 24 h).
  private func deleteDraft(_ chip: AttachmentUpload) async {
    guard let attachmentID = chip.attachment?.id else { return }
    if uncertain.remove(chip.id) != nil {
      guard let draft = try? await stillADraft(attachmentID) else { return }
      guard draft else {
        await onReload?()
        return
      }
    }
    try? await api.deleteAttachment(attachmentID)
  }

  /// Chips discarded while being posted: deleted only if that send fails (a successful send keeps them).
  @ObservationIgnored private var discardedWhileSending: Set<UUID> = []

  // MARK: Draft attachments

  /// Whether another chip fits (20 per comment; failed chips don't count, links in flight do).
  public var hasRoomForAnother: Bool {
    attachments.filter { !$0.isFailed }.count < AttachmentLimits.maxPerComment
  }

  /// Uploads a file as a draft (`?draft=true`). False when the comment already has 20 attachments (the UI says
  /// so). Over 100 MB or unreadable → a failed chip at once, without a request. `deletesFile`: a temp file of
  /// ours (pasted image), deleted once the chip goes.
  @discardableResult
  public func attach(fileAt url: URL, fileName: String? = nil, deletesFile: Bool = false) -> Bool {
    guard hasRoomForAnother else { return false }
    let name = fileName ?? url.lastPathComponent
    switch preflight(url) {
    case .failure(let error):
      attachments.append(AttachmentUpload(taskID: taskID, source: .file(url, name: name), state: .failed(error),
                                          deletesFile: deletesFile))
    case .success(let size):
      let chip = AttachmentUpload(taskID: taskID, source: .file(url, name: name), size: size, deletesFile: deletesFile)
      attachments.append(chip)
      run(chip)
    }
    return true
  }

  /// Adds a draft link: the chip shows `.uploading` (no total) while the server fetches the preview. Returns false
  /// when there's no room (20). Throws the `APIError` for the popover (local http(s) check first, then the
  /// server's); a failed link leaves no chip.
  @discardableResult
  public func attachLink(_ url: String, title: String?) async throws -> Bool {
    guard hasRoomForAnother else { return false }
    let link = try validateLink(url).get()
    let chip = AttachmentUpload(taskID: taskID, source: .link(url: link, title: title),
                                state: .uploading(TransferProgress(completed: 0, total: nil)))
    attachments.append(chip)
    do {
      let attachment = try await runner.slots.run { try await api.addLink(taskID: taskID, url: link, title: title, draft: true) }
      guard let i = attachments.firstIndex(where: { $0.id == chip.id }) else {
        // Removed (or discarded) while it was being added.
        try? await api.deleteAttachment(attachment.id)
        return true
      }
      attachments[i].state = .finished(attachment)
      return true
    } catch {
      attachments.removeAll { $0.id == chip.id }
      if error is CancellationError { throw error }
      throw error.asAPIError
    }
  }

  /// Retries a failed file chip.
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
  /// False (nothing happens) while it is finishing or being posted.
  @discardableResult
  public func remove(_ id: UUID) async -> Bool {
    guard let i = attachments.firstIndex(where: { $0.id == id }), !attachments[i].isFinishing, !sendingIDs.contains(id) else {
      return false
    }
    let chip = attachments.remove(at: i)
    runner.cancel(id)
    chip.cleanUp()
    await deleteDraft(chip)
    return true
  }

  /// Removes every chip (the App calls this when the task is closed); finishing ones are deleted once they land,
  /// and chips being posted are left to the send (deleted only if it fails). Typed text stays.
  public func discard() async {
    let chips = attachments
    attachments = []
    runner.cancelAll(except: Set(chips.filter(\.isFinishing).map(\.id)))
    discardedWhileFinishing.formUnion(chips.filter(\.isFinishing).map(\.id))
    discardedWhileSending.formUnion(chips.map(\.id).filter { sendingIDs.contains($0) })
    chips.forEach { $0.cleanUp() }
    for chip in chips where !sendingIDs.contains(chip.id) {
      await deleteDraft(chip)
    }
  }

  /// Stops uploads without deleting anything (the scope closed; the server sweeps the drafts).
  func cancelUploads() {
    runner.cancelAll()
    attachments.forEach { $0.cleanUp() }
    attachments = []
  }

  /// Finishing chips that were discarded: their draft is deleted when it lands.
  @ObservationIgnored private var discardedWhileFinishing: Set<UUID> = []

  private func run(_ chip: AttachmentUpload) {
    runner.run(chip, draft: true, api: api) { [weak self] id, state in
      guard let self else { return }
      guard let i = self.attachments.firstIndex(where: { $0.id == id }) else {
        if self.discardedWhileFinishing.remove(id) != nil, case .finished(let draft) = state {
          Task { try? await self.api.deleteAttachment(draft.id) }
        }
        return
      }
      if !self.attachments[i].accepts(state) { return }
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
