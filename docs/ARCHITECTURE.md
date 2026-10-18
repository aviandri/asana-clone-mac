# Mekari Project for Mac: architecture (Kit & Features)

This is the public API of the two platform-neutral modules. The SwiftUI app (`App/`) builds against
it. It implements [`SPEC-MAC.md`](SPEC-MAC.md); the API contract is the backend's `docs/SPEC.md`
(§5 shapes, §6 endpoints, §12 workspaces, W1–W8). Signatures here are the agreement between the Kit
and UI engineers: change them by PR, and tell the other side.

```
MekariProjectKit        Foundation (+FoundationNetworking on Linux, +Security on Apple)
  Models, LocalDate, JSON coding, APIError, MekariAPI protocol, LiveMekariAPI,
  TokenStore, ServerSettings, FakeMekariAPI (+ demo data), WebLinks, DeepLink, Mentions
        ▲
MekariProjectFeatures   Kit + Observation only. @MainActor @Observable stores / view models.
        ▲
App (macOS)             SwiftUI/AppKit views; no business logic, no networking.
```

Both libraries build and test on Linux (`swift test`) and macOS. Neither imports SwiftUI, AppKit,
or Combine.

## 1. Kit: models

All models are `Codable, Sendable, Hashable` structs and `Identifiable` where they have an `id`. IDs
are `String` (UUIDs from the BE, not parsed). JSON is camelCase, so no key strategy is needed.

Two names avoid clashes with Swift and Foundation: **`TaskItem`** (a BE `Task`; Swift's `Task` is
concurrency) and **`InboxNotification`** (a BE `Notification`; Foundation has `Notification`).

```swift
public enum WorkspaceRole: String, Codable, Sendable, CaseIterable { case admin = "ADMIN", member = "MEMBER", guest = "GUEST" }
public enum ProjectRole: String, Codable, Sendable { case owner = "OWNER", editor = "EDITOR", commenter = "COMMENTER" }
public enum ProjectPrivacy: String, Codable, Sendable { case `public` = "PUBLIC", team = "TEAM", `private` = "PRIVATE" }
public enum ProjectView: String, Codable, Sendable { case list = "LIST", board = "BOARD", calendar = "CALENDAR" }
public enum Priority: String, Codable, Sendable, CaseIterable { case none = "NONE", low = "LOW", medium = "MEDIUM", high = "HIGH" }

/// Open enums: unknown values decode to `.other(raw)` instead of failing.
public enum NotificationType: Codable, Sendable, Hashable { case assigned, commented, completed, mentioned, other(String) }
public enum ActivityType: Codable, Sendable, Hashable {
  case created, completed, reopened, assigned, unassigned, dueDateChanged, movedSection, renamed,
       priorityChanged, descriptionChanged, other(String)
}

public struct UserSummary  { id, name, email, avatarColor: String }
public struct PickableUser { user: UserSummary; role: WorkspaceRole; var isGuest: Bool }   // GET /users item (W8); flat JSON
public struct User         { id, name, email, avatarColor; role: WorkspaceRole; isActive: Bool; createdAt: Date }
public struct Workspace    { id, name: String; isOrganization: Bool; domain: String?; color: String;
                             myRole: WorkspaceRole; memberCount: Int; createdAt: Date; var isGuest: Bool }
public struct Me           { user: User; currentWorkspace: Workspace?; workspaces: [Workspace] }  // flat JSON (User & {...})

public struct Section      { id, projectId, name: String; position: Double }
public struct ProjectMember{ user: UserSummary; role: ProjectRole }
public struct Project      { id, workspaceId, teamId, name: String; description: String?; color: String;
                             privacy: ProjectPrivacy; archived: Bool; defaultView: ProjectView;
                             owner: UserSummary; myRole: ProjectRole?; createdAt, updatedAt: Date }
public struct ProjectDetail{ project: Project; sections: [Section]; members: [ProjectMember]; team: TeamRef }  // flat JSON
public struct TeamRef      { id, name: String }
public struct ProjectRef   { id, name, color: String }               // Task.project

public struct TaskItem {
  id, workspaceId: String; projectId, sectionId, parentId: String?
  title: String; description: String?; assignee: UserSummary?; creator: UserSummary
  dueDate, startDate: LocalDate?; priority: Priority
  completed: Bool; completedAt: Date?; position: Double
  subtaskCount, completedSubtaskCount, commentCount: Int
  project: ProjectRef?; createdAt, updatedAt: Date
}
public struct TaskDetail   { task: TaskItem; followers: [UserSummary]; subtasks: [TaskItem]; parent: TaskParentRef? }  // flat JSON
public struct TaskParentRef{ id, title: String }

public enum Story: Identifiable { case comment(Comment), activity(Activity) }   // discriminated by "kind"
public struct Comment      { id: String; author: UserSummary; body: String; createdAt: Date; editedAt: Date? }
public struct Activity     { id: String; actor: UserSummary; type: ActivityType; data: JSONValue; createdAt: Date }
public enum JSONValue      { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }

public struct InboxNotification { id, workspaceId: String; type: NotificationType; read: Bool; createdAt: Date;
                                  actor: UserSummary; task: NotificationTaskRef? }
public struct NotificationTaskRef { id, title: String; projectId: String? }
public struct InboxPage    { data: [InboxNotification]; unreadCount: Int }
public struct SearchResults{ tasks: [TaskItem]; projects: [Project]; users: [UserSummary] }
```

"Flat JSON" types decode and encode the BE's intersection types (`Project & {...}`), so the nested
property is filled from the same JSON object. They also forward the common fields (for example
`detail.id` and `detail.title`) through `@dynamicMemberLookup`, so views can use them like the
web's flat objects.

### LocalDate

```swift
public struct LocalDate: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
  public let year: Int, month: Int, day: Int
  public init?(_ string: String)                       // "YYYY-MM-DD", validated
  public init(year: Int, month: Int, day: Int)
  public static func today(in calendar: Calendar = .current, now: Date = .now) -> LocalDate
  public func adding(days: Int) -> LocalDate
  public func days(since other: LocalDate) -> Int       // calendar days, no time zones involved
  public func date(in calendar: Calendar = .current) -> Date   // local midnight, for DatePicker
  public init(_ date: Date, in calendar: Calendar = .current)
  public var description: String                        // "YYYY-MM-DD", also the Codable form
}
```

Timestamps decode from ISO-8601 with or without fractional seconds (`MekariJSON.decoder`);
`MekariJSON.encoder` writes fractional seconds.

### Writes

```swift
/// Tri-state for PATCH bodies: field omitted (`nil`), cleared (`.clear` → JSON null), or set.
public enum Patch<Value: Encodable & Sendable>: Sendable { case set(Value), clear }

public struct NewTask: Encodable, Sendable {      // POST /tasks
  public var title: String
  public var projectId, sectionId, parentId, description, assigneeId: String?
  public var dueDate, startDate: LocalDate?
  public var priority: Priority?
  public var position: Double?
}
public struct TaskChanges: Encodable, Sendable {  // PATCH /tasks/:id; nil = untouched
  public var title: String?
  public var description, projectId, sectionId, assigneeId: Patch<String>?
  public var dueDate, startDate: Patch<LocalDate>?
  public var priority: Priority?
  public var completed: Bool?
  public var position: Double?
}
public struct SectionChanges: Encodable, Sendable { public var name: String?; public var position: Double? }
```

## 2. Kit: errors

```swift
public struct APIError: Error, Sendable, Equatable, LocalizedError {
  public enum Code: Sendable, Equatable {
    case notFound, validation, unauthorized, forbidden, conflict, gone, rateLimited, `internal`
    case transport          // no response (offline, DNS, TLS, timeout)
    case decoding           // 2xx with a body we couldn't decode
    case unknown(String)    // unrecognised code from the BE
  }
  public let code: Code
  public let status: Int?             // HTTP status, nil for .transport
  public let message: String         // BE message; UI shows this
  public let issues: [FieldIssue]    // error.details on VALIDATION
  public var errorDescription: String? { message }
  public func issue(for field: String) -> FieldIssue?   // e.g. "assigneeId"
  public var isNoWorkspace: Bool     // 403 with details [{path:["workspace"], message:"NO_WORKSPACE"}]
}
public struct FieldIssue: Sendable, Equatable { public let path: [String]; public let message: String }
```

## 3. Kit: the API

One protocol, two implementations: `LiveMekariAPI` (URLSession) and `FakeMekariAPI` (in memory).
Features depend only on the protocol.

```swift
public protocol MekariAPI: AnyObject, Sendable {
  // Workspace context: sent as X-Workspace-Id on every request except /auth/*, /health, /workspaces*.
  func setWorkspace(_ id: String?) async
  var events: AsyncStream<APIEvent> { get }            // single consumer: AppSession

  // Health & auth
  func health(baseURL: URL) async throws               // GET /health (no auth); validates a server URL
  func login(email: String, password: String) async throws -> Me   // stores the sid token
  func logout() async                                  // POST /auth/logout, best effort; always clears the token
  func me() async throws -> Me                         // GET /auth/me, sent WITHOUT the workspace header
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
  case unauthorized                       // any 401 (except a failed login): the token is already cleared
  case workspaceLost(workspaceID: String) // a scoped collection endpoint returned 404 with the header set
}
```

### LiveMekariAPI

```swift
public final class LiveMekariAPI: MekariAPI {          // an actor inside; Sendable
  public init(baseURL: URL, tokens: TokenStore, transport: HTTPTransport = URLSessionTransport())
}
public protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }
public struct URLSessionTransport: HTTPTransport {      // ephemeral URLSession: httpShouldSetCookies = false,
  public init()                                        // httpCookieStorage = nil, httpCookieAcceptPolicy = .never
}
```

- Base URL = server URL + `/api/v1` (`/health` is called at the server root).
- **Session cookie.** `login` reads `sid=<jwt>` from the response's `Set-Cookie` header (`SessionCookie.token(from:)`,
  which tolerates several cookies, folded headers, and attributes in any order). It saves the token in the `TokenStore`.
  Every request then sends `Cookie: sid=<token>`. A 401 from any call except `login` clears the token and
  emits `.unauthorized`.
- **Workspace header.** `setWorkspace(id)` sets the header for later requests. It's not sent for
  `/auth/*`, `/health`, `/workspaces*`. A 404 on a *scoped collection* path (the same list as the web FE:
  `/users`, `/projects`, `/me/tasks`, `/tasks` (POST), `/notifications`, `/notifications/read-all`,
  `/search`, …) while a header is set emits `.workspaceLost`, then throws as usual.
- Errors decode the BE envelope into `APIError`. A non-JSON error body → `.unknown("HTTP <status>")`.
- No retries or caching in v1.

### TokenStore & settings

```swift
public protocol TokenStore: Sendable { func load() -> String?; func save(_ token: String); func clear() }
public final class InMemoryTokenStore: TokenStore { public init(token: String? = nil) }
#if canImport(Security)
public final class KeychainTokenStore: TokenStore {   // kSecClassGenericPassword, service "com.mekari.project",
  public init(account: String)                       // account = server host, so a server change starts signed out
}
#endif

public protocol ServerSettings: AnyObject, Sendable { var serverURL: URL? { get set } }
public final class UserDefaultsServerSettings: ServerSettings { public init(defaults: UserDefaults = .standard) }  // key "serverURL"
public final class InMemoryServerSettings: ServerSettings { public init(serverURL: URL? = nil) }
public enum ServerURL { public static func normalize(_ input: String) -> URL? }  // adds https://, trims "/", rejects junk
```

### FakeMekariAPI

```swift
public actor FakeMekariAPI: MekariAPI {
  public init(seed: FakeSeed = .demo, signedInAs email: String? = "alice@example.com")
  // Test knobs
  public func failNext(_ path: FakeEndpoint, with error: APIError)   // e.g. .updateTask → validation error
  public func setLatency(_ duration: Duration)                       // previews: .milliseconds(300)
  public var calls: [FakeCall] { get }                               // recorded requests, for assertions
  public func emit(_ event: APIEvent)                                // simulate 401 or lost access
  public func addNotification(_ n: InboxNotification)                // drive the poller
}
public struct FakeSeed: Sendable { public static let demo: FakeSeed; public static let empty: FakeSeed }
```

`FakeSeed.demo` mirrors the BE seed: workspaces **Mekari** (organization, example.com; admin, alice,
bob) and **Acme Pilot** (alice ADMIN, bob MEMBER, guest `guest@partner.test` on one project), with
projects, sections, about 30 tasks (overdue, today, this week, later, no date; subtasks), comments
with a mention, and notifications. Everyone's password is `password123`. The fake applies the BE
rules that the UI depends on: workspace scoping, guest visibility (W1, W7, W8), and COMMENTER
read-only (403). It also keeps My Tasks and the project lists consistent with edits.

### Small helpers in Kit

```swift
public enum Mentions {                                // "@[Name](userId)" in comment bodies
  public enum Segment: Equatable { case text(String), mention(name: String, userID: String) }
  public static func parse(_ body: String) -> [Segment]
  public static func token(for user: UserSummary) -> String          // "@[Alice Johnson](id)"
}
public enum WebLinks {                                // SPEC-MAC §5 "Open in Browser"
  public static func project(_ id: String, server: URL) -> URL      // /projects/:id
  public static func task(_ task: TaskItem, server: URL) -> URL     // /projects/:pid?task=:id or /my-tasks?task=:id
  public static func workspaceSettings(server: URL) -> URL          // /workspace/settings
  public static func acceptInvite(server: URL) -> URL               // /login (invite flow stays on the web)
}
public enum DeepLink: Equatable, Sendable {           // mekariproject://task/<id>, mekariproject://project/<id>
  case task(id: String), project(id: String)
  public init?(url: URL)
}
public enum Reorder {                                 // BE §2 float positions
  public static let step: Double = 1000
  public static func position(between before: Double?, and after: Double?) -> Double  // (a+b)/2, last+1000, first/2…
  /// The position for an item dropped at `index` in `positions` (the destination list without the moved item).
  public static func position(forInsertingAt index: Int, in positions: [Double]) -> Double
}
```

## 4. Features: stores and view models

Everything is `@MainActor @Observable public final class`. Each store is built with a `MekariAPI`,
plus a `Clock` and `Calendar` where time matters, so tests and previews can inject them. Async
methods never throw to the view: they set a published `error: APIError?` (or `errorMessage`), and
loading states use `LoadState`.

```swift
public enum LoadState: Equatable { case idle, loading, loaded, failed(APIError) }
```

### AppSession (root, one per app)

```swift
@MainActor @Observable public final class AppSession {
  public enum Phase: Equatable { case launching, signedOut, signedIn }
  public private(set) var phase: Phase
  public private(set) var me: Me?
  public private(set) var workspace: WorkspaceScope?      // nil = signed out, or signed in with no workspace
  public var workspaces: [Workspace] { get }              // Me.workspaces order (by name), for ⌘1…⌘9
  public private(set) var notice: String?                 // toasts, e.g. "Switched to Acme Pilot"
  public let settings: ServerSettings

  public init(apiFactory: @escaping (URL) -> MekariAPI, settings: ServerSettings, clock: any Clock<Duration> = ContinuousClock())
  public static func preview(signedIn: Bool = true) -> AppSession     // FakeMekariAPI, demo seed

  public func start() async                          // restores the session (token + /auth/me) or → .signedOut
  public func makeSignIn() -> SignInModel
  public func signOut() async
  public func switchWorkspace(to id: String) async   // POST /switch, setWorkspace, new WorkspaceScope, notice
  public func switchWorkspace(index: Int) async      // ⌘1…⌘9 (0-based); ignored if out of range
  public func open(_ link: DeepLink) async -> DeepLinkResult   // auto-switches workspace like the web FE
  public func dismissNotice()
}
public enum DeepLinkResult: Equatable { case task(String), project(String), noAccess }
```

- On a `.unauthorized` event → token cleared, `phase = .signedOut`, `workspace = nil`.
- On `.workspaceLost` → `GET /auth/me` (no header), adopt its `currentWorkspace` (new
  `WorkspaceScope`), notice "You no longer have access to <name>".
- `me.currentWorkspace == nil` while signed in → `workspace == nil`. The app shows "No workspace,
  open in browser" (the onboarding flows stay on the web in v1).

### WorkspaceScope (everything for the current workspace)

A new instance on every switch. Views key on `scope.id`, so all state resets together.

```swift
@MainActor @Observable public final class WorkspaceScope: Identifiable {
  public let id: String
  public let workspace: Workspace                       // name, color, myRole (Guest pill: workspace.isGuest)
  public let me: UserSummary
  public let sidebar: SidebarStore
  public let myTasks: MyTasksStore
  public let inbox: InboxStore
  public let poller: NotificationPoller
  public let search: SearchStore
  public let quickAdd: QuickAddModel
  public func project(_ id: String) -> ProjectStore            // cached per id
  public func taskDetail(_ id: String) -> TaskDetailStore      // cached per id; ⌘O window reuses it
  public func userPicker() -> UserPickerModel                  // new each time
  public func refreshAll() async                                // window focus
}
```

### SignInModel

```swift
@MainActor @Observable public final class SignInModel {
  public var server: String          // prefilled from settings
  public var email: String
  public var password: String
  public private(set) var isSubmitting: Bool
  public private(set) var errorMessage: String?   // "Wrong email or password" (401), "Too many attempts, try again in a minute" (429),
                                                  // "Can't reach the server" (transport / bad /health), else the BE message
  public var canSubmit: Bool
  public func submit() async                      // normalize URL → /health → login → session.signedIn
}
```

### SidebarStore

```swift
public private(set) var projects: [Project]     // non-archived, by name (guests: only theirs, BE-filtered)
public private(set) var state: LoadState
public var unreadCount: Int { get }             // from InboxStore, for the badge
public var canOpenSettingsInBrowser: Bool       // myRole == .admin
public func load() async
```

### MyTasksStore

```swift
public enum DueBucket: String, CaseIterable { case overdue, today, upcoming, later, noDate, completed }  // upcoming = next 7 days
public struct TaskGroup: Identifiable { public let bucket: DueBucket; public let title: String; public let tasks: [TaskItem] }

public private(set) var tasks: [TaskItem]
public var showCompleted: Bool                  // didSet → reload with completed tasks
public private(set) var state: LoadState
public var groups: [TaskGroup] { get }          // non-empty buckets, in order; sorted by due date then title
public var dueTodayOrOverdue: [TaskItem] { get }// menu bar list
public private(set) var error: APIError?
public func load() async
public func toggleComplete(_ task: TaskItem) async    // optimistic; reverts and sets error on failure
public func addTask(title: String, dueDate: LocalDate?) async -> Bool   // personal task, assigned to me
public func apply(_ updated: TaskItem)                // other stores push edits (inspector) here
```

### ProjectStore

```swift
public enum Mode { case list, board }                  // starts on defaultView; CALENDAR → list
public struct SectionColumn: Identifiable { public let section: Section?; public let tasks: [TaskItem] }  // nil section = "No section"

public let projectID: String
public private(set) var detail: ProjectDetail?
public private(set) var columns: [SectionColumn]       // sections by position, tasks by position
public var mode: Mode
public var showCompleted: Bool
public private(set) var state: LoadState
public private(set) var error: APIError?
public var canEdit: Bool { get }                       // workspace admin, or myRole != .commenter (BE §4)
public func load() async
public func addTask(title: String, in sectionID: String?) async -> Bool
public func addSection(name: String) async -> Bool
public func renameSection(_ id: String, to name: String) async
public func moveTask(_ taskID: String, toSection sectionID: String?, at index: Int) async   // optimistic + Reorder
public func moveSection(_ sectionID: String, to index: Int) async
public func toggleComplete(_ task: TaskItem) async
public func apply(_ updated: TaskItem)
```

### TaskDetailStore (inspector)

```swift
public let taskID: String
public private(set) var detail: TaskDetail?
public private(set) var stories: [Story]               // oldest first: comments + activity
public private(set) var state: LoadState
public private(set) var error: APIError?
public var canEdit: Bool { get }
public var composer: CommentComposer                    // see below

public func load() async                                // task + stories in parallel
public func setTitle(_ title: String) async
public func setDescription(_ text: String?) async
public func setAssignee(_ user: UserSummary?) async
public func setDueDate(_ date: LocalDate?) async
public func setPriority(_ priority: Priority) async
public func setCompleted(_ done: Bool) async
public func addSubtask(title: String) async -> Bool
public func toggleSubtask(_ subtask: TaskItem) async
public func addFollower(_ user: UserSummary) async
public func removeFollower(_ user: UserSummary) async
public func sendComment() async -> Bool                // ⌘↩
public func editComment(_ id: String, body: String) async
public func deleteComment(_ id: String) async
```

Every edit is optimistic and is pushed back to `MyTasksStore` / `ProjectStore` through
`WorkspaceScope`, so lists stay in sync.

```swift
@MainActor @Observable public final class CommentComposer {
  public var text: String
  public var cursor: Int                                  // UTF-16 offset, bound from the text view
  public private(set) var mentionQuery: String?           // non-nil while typing "@que…" → show the picker
  public let picker: UserPickerModel                      // driven by mentionQuery
  public func insertMention(_ user: UserSummary)          // replaces "@que" with "@[Name](id) "
  public var canSend: Bool
}
```

### UserPickerModel (assignee, followers, mentions)

```swift
public var query: String                                  // debounced 250 ms → GET /users?q=
public private(set) var results: [PickableUser]           // .isGuest → "Guest" badge (W8)
public private(set) var isLoading: Bool
```

### InboxStore & NotificationPoller

```swift
// InboxStore
public private(set) var items: [InboxNotification]       // newest first
public private(set) var unreadCount: Int
public private(set) var state: LoadState
public func load() async
public func open(_ n: InboxNotification) async -> String? // marks read, returns the task id to open
public func markAllRead() async

// NotificationPoller: drives InboxStore.load on a timer
public enum Activity { case active, background }          // 60 s / 5 min (SPEC-MAC §4)
public var activity: Activity
public var onNew: (([InboxNotification]) -> Void)?        // new unread since the last poll → local banners (not on the first poll)
public func start()                                       // idempotent
public func stop()
```

### SearchStore (⌘K)

```swift
public var query: String                                  // min 2 chars, debounce 250 ms
public private(set) var results: SearchResults?
public private(set) var isSearching: Bool
public var isEmpty: Bool { get }                          // for "No results"
```

### QuickAddModel (menu bar)

```swift
public var title: String
public var dueDate: LocalDate?
public private(set) var isSubmitting: Bool
public private(set) var errorMessage: String?
public func submit() async -> Bool                       // personal task assigned to me; clears on success; updates MyTasksStore
```

## 5. Testing

- **Unit tests (Linux + macOS):** Kit (coding of every model from recorded BE JSON fixtures, LocalDate,
  Set-Cookie parsing, error envelopes, workspace-header rules and events via a stub `HTTPTransport`, Reorder,
  Mentions, WebLinks, DeepLink); Features (every store against `FakeMekariAPI` with a test clock).
- **Contract tests** (`Tests/ContractTests`, skipped unless `MP_BASE_URL` is set): `LiveMekariAPI`
  against a freshly seeded BE: login/cookie, `/auth/me`, header + switch, lost access, my tasks,
  project tasks, create/patch/complete, comments, notifications, search, guest rules (W1, W7, W8).
  Locally they run against a throwaway BE DB, never the shared `asana` DB.

## 6. Open points (agreed with the UI engineer before PR 3)

1. **One current workspace per app**, shared by all windows and the menu bar. SPEC-MAC §4 says "the
   window's current workspace". With one main window in v1 they're the same. A per-window workspace
   would need one `WorkspaceScope` per window, and the API is already ready for that.
2. Stores expose `TaskItem` arrays. Views use `task.id` for `accessibilityIdentifier("task.row.<id>")`.
3. Debounces and polling use an injected `Clock`. Views don't run timers.
