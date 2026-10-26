// Swift 5.10's Linux Foundation doesn't mark URL, URLRequest, HTTPURLResponse & co. Sendable yet
// (Darwin's and Swift 6's do), so take its types as pre-concurrency there.
#if canImport(FoundationNetworking) && compiler(<6.0)
@preconcurrency import Foundation
@preconcurrency import FoundationNetworking
#elseif canImport(FoundationNetworking)
import Foundation
import FoundationNetworking
#else
import Foundation
#endif

/// `MekariAPI` over HTTP (SPEC-MAC §4).
///
/// - The session cookie is handled by hand: `sid` is read from the login response's `Set-Cookie`,
///   kept in the `TokenStore`, and sent as `Cookie: sid=<token>`.
/// - `X-Workspace-Id` goes on every request except `/auth/*`, `/health` and `/workspaces*`.
/// - A 401 (except from login) clears the token and emits `.unauthorized`. A 404 from a scoped
///   collection endpoint with the header set emits `.workspaceLost`.
public actor LiveMekariAPI: MekariAPI {
  public static let workspaceHeader = "X-Workspace-Id"

  public nonisolated let events: AsyncStream<APIEvent>
  private nonisolated let eventSink: AsyncStream<APIEvent>.Continuation

  private let server: URL
  private let tokens: TokenStore
  private let transport: HTTPTransport
  private var workspaceID: String?
  private let decoder = MekariJSON.makeDecoder()
  private let encoder = MekariJSON.makeEncoder()

  public init(baseURL: URL, tokens: TokenStore, transport: HTTPTransport = URLSessionTransport()) {
    server = baseURL
    self.tokens = tokens
    self.transport = transport
    (events, eventSink) = AsyncStream.makeStream(of: APIEvent.self)
  }

  public func setWorkspace(_ id: String?) {
    workspaceID = id
  }

  public var hasSession: Bool { tokens.load() != nil }

  // MARK: - Health & auth

  public func health() async throws {
    var request = URLRequest(url: server.appendingPathComponent("health"))
    request.httpMethod = "GET"
    let (_, response) = try await perform(request)
    guard (200..<300).contains(response.statusCode) else {
      throw APIError(code: .unknown("HTTP \(response.statusCode)"), status: response.statusCode, message: "Not a Mekari Project server")
    }
  }

  public func login(email: String, password: String) async throws -> Me {
    struct Body: Encodable { let email: String; let password: String }
    // A stored session (another account's, maybe another server's) has no business here.
    let (data, response) = try await send(.post, "/auth/login", body: Body(email: email, password: password), session: .none)
    guard let token = SessionCookie.token(from: response) else {
      throw APIError.decoding("no session cookie in the login response")
    }
    // Decoded first: a response we can't read must not leave a half session behind.
    let me = try decode(Me.self, from: data)
    tokens.save(token)
    return me
  }

  /// Ends the stored session locally FIRST, then tells the server with that captured token: a sign-in that
  /// lands while this request hangs keeps its new token, and this request never carries the next session.
  public func logout() async {
    guard let ending = tokens.load() else { return }
    tokens.clear()
    _ = try? await send(.post, "/auth/logout", body: Optional<NoBody>.none, session: .exactly(ending))
  }

  public func me() async throws -> Me {
    try await get("/auth/me")
  }

  // MARK: - Workspaces & users

  public func switchWorkspace(_ id: String) async throws -> Workspace {
    try await call(.post, "/workspaces/\(id)/switch")
  }

  public func users(query: String?) async throws -> [PickableUser] {
    try await list("/users", query: ["q": query])
  }

  // MARK: - Projects & sections

  public func projects(archived: Bool) async throws -> [Project] {
    try await list("/projects", query: ["archived": String(archived)])
  }

  public func project(_ id: String) async throws -> ProjectDetail {
    try await get("/projects/\(id)")
  }

  public func projectTasks(_ projectID: String, completed: Bool?) async throws -> [TaskItem] {
    try await list("/projects/\(projectID)/tasks", query: ["completed": completed.map { String($0) }])
  }

  public func createSection(projectID: String, name: String, position: Double?) async throws -> Section {
    struct Body: Encodable { let name: String; let position: Double? }
    return try await call(.post, "/projects/\(projectID)/sections", body: Body(name: name, position: position))
  }

  public func updateSection(_ id: String, _ changes: SectionChanges) async throws -> Section {
    try await call(.patch, "/sections/\(id)", body: changes)
  }

  public func deleteSection(_ id: String) async throws {
    _ = try await send(.delete, "/sections/\(id)")
  }

  // MARK: - Tasks

  public func myTasks(includeCompleted: Bool) async throws -> [TaskItem] {
    try await list("/me/tasks", query: ["completed": includeCompleted ? nil : "false"])
  }

  public func task(_ id: String) async throws -> TaskDetail {
    try await get("/tasks/\(id)")
  }

  public func createTask(_ task: NewTask) async throws -> TaskDetail {
    try await call(.post, "/tasks", body: task)
  }

  public func updateTask(_ id: String, _ changes: TaskChanges) async throws -> TaskDetail {
    try await call(.patch, "/tasks/\(id)", body: changes)
  }

  public func deleteTask(_ id: String) async throws {
    _ = try await send(.delete, "/tasks/\(id)")
  }

  public func addFollower(taskID: String, userID: String) async throws -> TaskDetail {
    struct Body: Encodable { let userId: String }
    return try await call(.post, "/tasks/\(taskID)/followers", body: Body(userId: userID))
  }

  public func removeFollower(taskID: String, userID: String) async throws -> TaskDetail {
    try await call(.delete, "/tasks/\(taskID)/followers/\(userID)")
  }

  // MARK: - Stories

  public func stories(taskID: String) async throws -> [Story] {
    let feed: StoryFeed = try await get("/tasks/\(taskID)/stories")
    return feed.data
  }

  public func addComment(taskID: String, body: String, attachmentIDs: [String]) async throws -> Comment {
    struct Body: Encodable {
      let body: String
      let attachmentIds: [String]?
      // Without attachments the body is the v1 shape, so older servers keep working.
      func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(body, forKey: .body)
        try c.encodeIfPresent(attachmentIds, forKey: .attachmentIds)
      }
      enum CodingKeys: String, CodingKey { case body, attachmentIds }
    }
    return try await call(.post, "/tasks/\(taskID)/comments",
                          body: Body(body: body, attachmentIds: attachmentIDs.isEmpty ? nil : attachmentIDs))
  }

  public func editComment(_ id: String, body: String) async throws -> Comment {
    struct Body: Encodable { let body: String }
    return try await call(.patch, "/comments/\(id)", body: Body(body: body))
  }

  public func deleteComment(_ id: String) async throws {
    _ = try await send(.delete, "/comments/\(id)")
  }

  // MARK: - Inbox & search

  public func notifications(unreadOnly: Bool, limit: Int) async throws -> InboxPage {
    try await get("/notifications", query: ["unread": unreadOnly ? "true" : nil, "limit": String(limit)])
  }

  public func markRead(_ notificationID: String) async throws {
    _ = try await send(.post, "/notifications/\(notificationID)/read")
  }

  public func markAllRead() async throws {
    _ = try await send(.post, "/notifications/read-all")
  }

  public func search(_ query: String) async throws -> SearchResults {
    try await get("/search", query: ["q": query])
  }

  // MARK: - Attachments & links

  public func uploadAttachment(taskID: String, file: URL, fileName: String?, draft: Bool,
                               progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> Attachment {
    let size = try Multipart.fileSize(file)
    guard size <= AttachmentLimits.maxUploadBytes else { throw AttachmentLimits.tooLarge() }
    try Task.checkCancellation()
    let name = fileName ?? file.lastPathComponent
    // Built off the actor: copying up to 100 MB must not hold up other requests.
    let body = try await Task.detached { try Multipart.writeTempFile(copying: file, fileName: name) }.value
    defer { try? FileManager.default.removeItem(at: body.url) }
    let path = "/tasks/\(taskID)/attachments"
    var prepared = prepare(.post, url: url(path, query: ["draft": draft ? "true" : nil]), path: path)
    prepared.request.setValue("application/json", forHTTPHeaderField: "Accept")
    prepared.request.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
    prepared.request.setValue(String(body.length), forHTTPHeaderField: "Content-Length")
    let overhead = body.headerLength
    let (data, response) = try await perform { [transport, request = prepared.request] in
      try await transport.upload(request, fromFile: body.url) { sent, _ in
        progress(TransferProgress(completed: min(size, max(0, sent - overhead)), total: size))
      }
    }
    try check(response, data, prepared)
    return try decode(Attachment.self, from: data)
  }

  public func addLink(taskID: String, url: String, title: String?, draft: Bool) async throws -> Attachment {
    struct Body: Encodable { let url: String; let title: String?; let draft: Bool }
    return try await call(.post, "/tasks/\(taskID)/attachments/link", body: Body(url: url, title: title, draft: draft))
  }

  public func attachment(_ id: String) async throws -> Attachment {
    try await get("/attachments/\(id)")
  }

  public func refreshLinkPreview(_ id: String) async throws -> Attachment {
    try await call(.post, "/attachments/\(id)/refresh-preview")
  }

  public func deleteAttachment(_ id: String) async throws {
    _ = try await send(.delete, "/attachments/\(id)")
  }

  public func download(_ path: String, to destination: URL, ifNoneMatch etag: String?,
                       progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> DownloadOutcome {
    var prepared = try prepareBytes(path)
    if let etag { prepared.request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    let (data, response) = try await perform { [transport, request = prepared.request] in
      try await transport.download(request, to: destination) { received, expected in
        progress(TransferProgress(completed: received, total: expected))
      }
    }
    try check(response, data, prepared, allowNotModified: true)
    if response.statusCode == 304 { return .notModified }
    return .downloaded(etag: LiveMekariAPI.header("ETag", in: response))
  }

  public func attachmentData(_ path: String) async throws -> Data {
    let prepared = try prepareBytes(path)
    let (data, response) = try await perform { [transport, request = prepared.request] in try await transport.send(request) }
    try check(response, data, prepared)
    return data
  }

  /// A GET of a server-given attachment path: the cookie, no workspace header (ID-addressed, BE §13).
  private func prepareBytes(_ path: String) throws -> Prepared {
    guard AttachmentLinks.isAttachmentPath(path), let target = URL(string: serverRoot + path) else {
      throw APIError(code: .validation, message: "Not an attachment address")
    }
    var prepared = prepare(.get, url: target, path: path, workspaceHeader: false)
    prepared.request.setValue("*/*", forHTTPHeaderField: "Accept")
    return prepared
  }

  /// The server URL without a trailing "/", which server-relative paths (`/api/v1/…`) are appended to.
  private var serverRoot: String {
    var root = server.absoluteString
    while root.hasSuffix("/") { root.removeLast() }
    return root
  }

  static func header(_ name: String, in response: HTTPURLResponse) -> String? {
    for (key, value) in response.allHeaderFields {
      if let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame { return value as? String }
    }
    return nil
  }

  // MARK: - Plumbing

  enum Method: String { case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE" }

  private struct NoBody: Encodable {}

  private func get<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
    let (data, _) = try await send(.get, path, query: query)
    return try decode(T.self, from: data)
  }

  private func list<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> [T] {
    let response: ListResponse<T> = try await get(path, query: query)
    return response.data
  }

  private func call<T: Decodable>(_ method: Method, _ path: String) async throws -> T {
    let (data, _) = try await send(method, path)
    return try decode(T.self, from: data)
  }

  private func call<T: Decodable, B: Encodable>(_ method: Method, _ path: String, body: B) async throws -> T {
    let (data, _) = try await send(method, path, body: body)
    return try decode(T.self, from: data)
  }

  private func send(_ method: Method, _ path: String, query: [String: String?] = [:]) async throws -> (Data, HTTPURLResponse) {
    try await send(method, path, query: query, body: Optional<NoBody>.none)
  }

  /// Which session a request carries: the stored one (read when it's sent), none, or exactly one.
  private enum SessionChoice {
    case stored
    case none
    case exactly(String)
  }

  private func send<B: Encodable>(_ method: Method, _ path: String, query: [String: String?] = [:], body: B?,
                                  session: SessionChoice = .stored) async throws -> (Data, HTTPURLResponse) {
    var prepared = prepare(method, url: url(path, query: query), path: path, session: session)
    prepared.request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      prepared.request.httpBody = try encoder.encode(body)
      prepared.request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await perform { [transport, request = prepared.request] in try await transport.send(request) }
    try check(response, data, prepared)
    return (data, response)
  }

  /// A request with the session cookie and (where it applies) the workspace header, plus what was sent.
  private struct Prepared {
    var request: URLRequest
    let method: Method
    let path: String
    let sentToken: String?
    let sentWorkspace: String?
  }

  private func prepare(_ method: Method, url: URL, path: String, session: SessionChoice = .stored,
                       workspaceHeader: Bool = true) -> Prepared {
    var request = URLRequest(url: url)
    request.httpMethod = method.rawValue
    let sentToken: String?
    switch session {
    case .stored: sentToken = tokens.load()
    case .none: sentToken = nil
    case .exactly(let token): sentToken = token
    }
    if let sentToken {
      request.setValue("\(SessionCookie.name)=\(sentToken)", forHTTPHeaderField: "Cookie")
    }
    let sentWorkspace = workspaceHeader && LiveMekariAPI.sendsWorkspaceHeader(path) ? workspaceID : nil
    if let sentWorkspace {
      request.setValue(sentWorkspace, forHTTPHeaderField: LiveMekariAPI.workspaceHeader)
    }
    return Prepared(request: request, method: method, path: path, sentToken: sentToken, sentWorkspace: sentWorkspace)
  }

  /// Throws for redirects and errors, ending the session on a 401 for the token still stored and
  /// reporting a lost workspace on a scoped collection's 404. `allowNotModified` lets a 304 through.
  private func check(_ response: HTTPURLResponse, _ data: Data, _ prepared: Prepared, allowNotModified: Bool = false) throws {
    if allowNotModified, response.statusCode == 304 { return }
    if (300..<400).contains(response.statusCode) {
      // The transport never follows redirects (they'd carry the Cookie, or re-post a login, elsewhere).
      throw APIError(code: .unknown("REDIRECT"), status: response.statusCode,
                     message: "The server answered with a redirect (HTTP \(response.statusCode)). Check the server address, including https://.")
    }
    guard (200..<300).contains(response.statusCode) else {
      let error = APIError.from(status: response.statusCode, body: data)
      if response.statusCode == 401 {
        // Only a 401 for the session we still hold ends it: a late answer to a request sent with an
        // older token (the poller, another window) must not sign out a fresh session. Login and
        // logout never emit.
        if let sentToken = prepared.sentToken, prepared.path != "/auth/login", prepared.path != "/auth/logout",
           tokens.clear(ifCurrent: sentToken) {
          eventSink.yield(.unauthorized)
        }
      } else if response.statusCode == 404, let sentWorkspace = prepared.sentWorkspace,
                LiveMekariAPI.isScopedCollection(prepared.method, prepared.path) {
        eventSink.yield(.workspaceLost(workspaceID: sentWorkspace))
      }
      throw error
    }
  }

  private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await perform { [transport] in try await transport.send(request) }
  }

  /// Cancellation is passed through as `CancellationError` (never "Can't reach the server").
  private func perform(_ operation: @Sendable () async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse) {
    do {
      try Task.checkCancellation()
      return try await operation()
    } catch let error as APIError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw APIError.transport()
    }
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try decoder.decode(T.self, from: data)
    } catch let error as DecodingError {
      throw APIError.decoding("\(T.self): \(DecodingFailure.describe(error))")
    } catch {
      throw APIError.decoding("\(T.self)")
    }
  }

  private func url(_ path: String, query: [String: String?]) -> URL {
    var components = URLComponents(url: server, resolvingAgainstBaseURL: false) ?? URLComponents()
    let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
    components.path = base + "/api/v1" + path
    let items = query.compactMap { key, value in value.map { (key, $0) } }.sorted { $0.0 < $1.0 }
    components.percentEncodedQuery = items.isEmpty ? nil : items.map { "\(QueryEncoding.encode($0.0))=\(QueryEncoding.encode($0.1))" }
      .joined(separator: "&")
    return components.url ?? server
  }

  /// Not on `/auth/*` and `/workspaces*` (SPEC-MAC §4); `/health` is outside `/api/v1` anyway.
  static func sendsWorkspaceHeader(_ path: String) -> Bool {
    !(path.hasPrefix("/auth/") || path == "/workspaces" || path.hasPrefix("/workspaces/") || path == "/health")
  }

  /// BE §12 scoped collection endpoints: a 404 there means the header's workspace is gone for us.
  /// ID-addressed endpoints 404 for their own resource instead.
  static func isScopedCollection(_ method: Method, _ path: String) -> Bool {
    switch path {
    case "/users", "/projects", "/me/tasks", "/notifications", "/notifications/read-all", "/search": return true
    case "/tasks": return method == .post
    default: return false
    }
  }
}

/// Strict query encoding: `URLComponents.queryItems` leaves `+`, `&` and `=` alone in values, which
/// breaks searches such as "fix & ship" or "c++".
enum QueryEncoding {
  // Computed: a stored static CharacterSet isn't Sendable on Swift 5.10's Linux Foundation.
  private static var allowed: CharacterSet {
    var set = CharacterSet.alphanumerics
    set.insert(charactersIn: "-._~")
    return set
  }

  static func encode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}

/// A short, diagnosable description of a decoding failure: where (coding path) and what.
enum DecodingFailure {
  static func describe(_ error: DecodingError) -> String {
    let context: DecodingError.Context
    switch error {
    case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): context = c
    case .keyNotFound(let key, let c):
      return "\(path(c.codingPath + [key])): missing key"
    @unknown default:
      return "\(error)"
    }
    return "\(path(context.codingPath)): \(context.debugDescription)"
  }

  private static func path(_ keys: [CodingKey]) -> String {
    let parts = keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
    return parts.isEmpty ? "$" : "$" + parts
  }
}

