import Foundation
import MekariProjectKit

/// The API as one `WorkspaceScope` sees it. Once the scope is closed (a switch, lost access,
/// sign-out), every call fails with `CancellationError` BEFORE it is sent: work started in the old
/// workspace (a renumber loop, an edit, a load a view kicked off) can never go out under the next
/// workspace's header. `AppSession` closes the old scope before it changes the header. The header and
/// the events belong to `AppSession`'s client.
///
/// `@unchecked Sendable`: the only mutable state, `closed`, is guarded by `lock`.
final class ScopedAPI: MekariAPI, @unchecked Sendable {
  private let base: any MekariAPI
  private let lock = NSLock()
  private var closed = false

  init(_ base: any MekariAPI) {
    self.base = base
  }

  var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }

  func close() {
    lock.lock()
    closed = true
    lock.unlock()
  }

  private func check() throws {
    if isClosed { throw CancellationError() }
  }

  // The header and events stay with AppSession's client.
  func setWorkspace(_ id: String?) async { await base.setWorkspace(id) }
  var events: AsyncStream<APIEvent> { base.events }
  var hasSession: Bool { get async { await base.hasSession } }

  func health() async throws { try check(); try await base.health() }
  func login(email: String, password: String) async throws -> Me { try check(); return try await base.login(email: email, password: password) }
  func logout() async { if !isClosed { await base.logout() } }
  func me() async throws -> Me { try check(); return try await base.me() }
  func switchWorkspace(_ id: String) async throws -> Workspace { try check(); return try await base.switchWorkspace(id) }
  func users(query: String?) async throws -> [PickableUser] { try check(); return try await base.users(query: query) }
  func projects(archived: Bool) async throws -> [Project] { try check(); return try await base.projects(archived: archived) }
  func project(_ id: String) async throws -> ProjectDetail { try check(); return try await base.project(id) }
  func projectTasks(_ projectID: String, completed: Bool?) async throws -> [TaskItem] {
    try check(); return try await base.projectTasks(projectID, completed: completed)
  }
  func createSection(projectID: String, name: String, position: Double?) async throws -> Section {
    try check(); return try await base.createSection(projectID: projectID, name: name, position: position)
  }
  func updateSection(_ id: String, _ changes: SectionChanges) async throws -> Section { try check(); return try await base.updateSection(id, changes) }
  func deleteSection(_ id: String) async throws { try check(); try await base.deleteSection(id) }
  func myTasks(includeCompleted: Bool) async throws -> [TaskItem] { try check(); return try await base.myTasks(includeCompleted: includeCompleted) }
  func task(_ id: String) async throws -> TaskDetail { try check(); return try await base.task(id) }
  func createTask(_ task: NewTask) async throws -> TaskDetail { try check(); return try await base.createTask(task) }
  func updateTask(_ id: String, _ changes: TaskChanges) async throws -> TaskDetail { try check(); return try await base.updateTask(id, changes) }
  func deleteTask(_ id: String) async throws { try check(); try await base.deleteTask(id) }
  func addFollower(taskID: String, userID: String) async throws -> TaskDetail {
    try check(); return try await base.addFollower(taskID: taskID, userID: userID)
  }
  func removeFollower(taskID: String, userID: String) async throws -> TaskDetail {
    try check(); return try await base.removeFollower(taskID: taskID, userID: userID)
  }
  func stories(taskID: String) async throws -> [Story] { try check(); return try await base.stories(taskID: taskID) }
  func addComment(taskID: String, body: String, attachmentIDs: [String]) async throws -> Comment {
    try check(); return try await base.addComment(taskID: taskID, body: body, attachmentIDs: attachmentIDs)
  }
  func editComment(_ id: String, body: String) async throws -> Comment { try check(); return try await base.editComment(id, body: body) }
  func deleteComment(_ id: String) async throws { try check(); try await base.deleteComment(id) }
  func notifications(unreadOnly: Bool, limit: Int) async throws -> InboxPage {
    try check(); return try await base.notifications(unreadOnly: unreadOnly, limit: limit)
  }
  func markRead(_ notificationID: String) async throws { try check(); try await base.markRead(notificationID) }
  func markAllRead() async throws { try check(); try await base.markAllRead() }
  func search(_ query: String) async throws -> SearchResults { try check(); return try await base.search(query) }
  func uploadAttachment(taskID: String, file: URL, fileName: String?, draft: Bool,
                        progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> Attachment {
    try check(); return try await base.uploadAttachment(taskID: taskID, file: file, fileName: fileName, draft: draft, progress: progress)
  }
  func addLink(taskID: String, url: String, title: String?, draft: Bool) async throws -> Attachment {
    try check(); return try await base.addLink(taskID: taskID, url: url, title: title, draft: draft)
  }
  func attachment(_ id: String) async throws -> Attachment { try check(); return try await base.attachment(id) }
  func refreshLinkPreview(_ id: String) async throws -> Attachment { try check(); return try await base.refreshLinkPreview(id) }
  func deleteAttachment(_ id: String) async throws { try check(); try await base.deleteAttachment(id) }
  func download(_ path: String, to destination: URL, ifNoneMatch etag: String?,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> DownloadOutcome {
    try check(); return try await base.download(path, to: destination, ifNoneMatch: etag, progress: progress)
  }
  func attachmentData(_ path: String) async throws -> Data { try check(); return try await base.attachmentData(path) }
}
