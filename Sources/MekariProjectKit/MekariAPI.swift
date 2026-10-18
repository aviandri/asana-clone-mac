import Foundation

/// The Mekari Project BE API (SPEC §6, §12). `LiveMekariAPI` talks HTTP; `FakeMekariAPI` is in memory.
///
/// Every method throws `APIError` only.
public protocol MekariAPI: AnyObject, Sendable {
  /// The workspace sent as `X-Workspace-Id` on later requests (not on `/auth/*`, `/health`, `/workspaces*`).
  func setWorkspace(_ id: String?) async
  /// Session-wide events. Single consumer: `AppSession`.
  var events: AsyncStream<APIEvent> { get }

  // Health & auth
  /// `GET /health` at the server root (no auth), to validate a server URL.
  func health() async throws
  /// Signs in and stores the session token.
  func login(email: String, password: String) async throws -> Me
  /// `POST /auth/logout`, best effort. Always clears the stored token.
  func logout() async
  /// `GET /auth/me`, sent without the workspace header.
  func me() async throws -> Me
  var hasSession: Bool { get async }

  // Workspaces
  func switchWorkspace(_ id: String) async throws -> Workspace

  // Users
  func users(query: String?) async throws -> [PickableUser]

  // Projects & sections
  func projects(archived: Bool) async throws -> [Project]
  func project(_ id: String) async throws -> ProjectDetail
  func projectTasks(_ projectID: String, completed: Bool?) async throws -> [TaskItem]
  func createSection(projectID: String, name: String, position: Double?) async throws -> Section
  func updateSection(_ id: String, _ changes: SectionChanges) async throws -> Section
  func deleteSection(_ id: String) async throws

  // Tasks
  func myTasks(includeCompleted: Bool) async throws -> [TaskItem]
  func task(_ id: String) async throws -> TaskDetail
  func createTask(_ task: NewTask) async throws -> TaskDetail
  func updateTask(_ id: String, _ changes: TaskChanges) async throws -> TaskDetail
  func deleteTask(_ id: String) async throws
  func addFollower(taskID: String, userID: String) async throws -> TaskDetail
  func removeFollower(taskID: String, userID: String) async throws -> TaskDetail

  // Stories
  func stories(taskID: String) async throws -> [Story]
  func addComment(taskID: String, body: String) async throws -> Comment
  func editComment(_ id: String, body: String) async throws -> Comment
  func deleteComment(_ id: String) async throws

  // Inbox & search
  func notifications(unreadOnly: Bool, limit: Int) async throws -> InboxPage
  func markRead(_ notificationID: String) async throws
  func markAllRead() async throws
  func search(_ query: String) async throws -> SearchResults
}

public enum APIEvent: Sendable, Equatable {
  /// A 401 from anything but a failed login. The token is already cleared.
  case unauthorized
  /// A scoped collection endpoint returned 404 while this workspace was in the header (BE §12).
  case workspaceLost(workspaceID: String)
}

/// Normalises what people type into the server field.
public enum ServerURL {
  /// Adds `https://` when no scheme is given, drops a trailing `/` and any `/api/v1` suffix, and
  /// rejects anything that isn't an http(s) URL with a host.
  public static func normalize(_ input: String) -> URL? {
    var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if !text.contains("://") { text = "https://" + text }
    while text.hasSuffix("/") { text.removeLast() }
    if text.hasSuffix("/api/v1") { text.removeLast("/api/v1".count) }
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = url.host, !host.isEmpty, !host.contains(" ") else { return nil }
    return url
  }
}
