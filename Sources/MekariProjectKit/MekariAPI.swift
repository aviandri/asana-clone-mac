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
  /// `attachmentIDs`: drafts I uploaded on this task (≤ 20); `body` may then be empty.
  func addComment(taskID: String, body: String, attachmentIDs: [String]) async throws -> Comment
  func editComment(_ id: String, body: String) async throws -> Comment
  func deleteComment(_ id: String) async throws

  // Inbox & search
  func notifications(unreadOnly: Bool, limit: Int) async throws -> InboxPage
  func markRead(_ notificationID: String) async throws
  func markAllRead() async throws
  func search(_ query: String) async throws -> SearchResults

  // Attachments & links (BE §13)
  /// Streams `file` from disk as one multipart part `file` (never the whole file in memory). `draft` sends
  /// `?draft=true` (the comment composer). `fileName` overrides the file's own name. Over
  /// `AttachmentLimits.maxUploadBytes` → `.payloadTooLarge` without a request. Cancel the calling task to
  /// cancel the upload. `progress` may be called on any thread.
  func uploadAttachment(taskID: String, file: URL, fileName: String?, draft: Bool,
                        progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> Attachment
  func addLink(taskID: String, url: String, title: String?, draft: Bool) async throws -> Attachment
  func attachment(_ id: String) async throws -> Attachment
  func refreshLinkPreview(_ id: String) async throws -> Attachment
  func deleteAttachment(_ id: String) async throws
  /// GETs a server-relative attachment path (`contentPath`, `thumbnailPath(size:)`…) into `destination`,
  /// replacing it only on a 200. With `etag`, sends `If-None-Match` and a 304 leaves `destination` alone.
  /// Paths outside `/api/v1/attachments/` are refused (`.validation`) without a request.
  func download(_ path: String, to destination: URL, ifNoneMatch etag: String?,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> DownloadOutcome
  /// Small bytes in memory: thumbnails, link icons and images. Same path rule as `download`.
  func attachmentData(_ path: String) async throws -> Data
}

extension MekariAPI {
  public func addComment(taskID: String, body: String) async throws -> Comment {
    try await addComment(taskID: taskID, body: body, attachmentIDs: [])
  }
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

  /// Whether two server URLs name the same server: scheme and host compared without case, default ports
  /// (443 for https, 80 for http) and trailing slashes ignored. A scheme change is a different server.
  public static func isSameServer(_ a: URL?, _ b: URL?) -> Bool {
    guard let a, let b, let left = canonical(a), let right = canonical(b) else { return false }
    return left == right
  }

  static func canonical(_ url: URL) -> String? {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
    let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
    let port = parts.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
    var path = parts.percentEncodedPath
    while path.hasSuffix("/") { path.removeLast() }
    return "\(scheme)://\(host)\(port)\(path)"
  }
}
