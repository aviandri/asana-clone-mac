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
public struct Comment      { id: String; author: UserSummary; body: String; createdAt: Date; editedAt: Date?
                             var segments: [Mentions.Segment] }   // parsed body
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

Timestamps decode from ISO-8601 with or without fractional seconds (`MekariJSON.makeDecoder()`);
`MekariJSON.makeEncoder()` writes fractional seconds.

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
  func health() async throws                           // GET /health at the server root (no auth); validates a server URL
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
- `FakeMekariAPI.health()` accepts any server URL. `login` works for every seeded user with
  `password123`; `signedInAs: nil` starts signed out.
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
  public func failNext(_ endpoint: FakeEndpoint, with error: APIError)   // e.g. .updateTask → validation error
  public func setLatency(_ duration: Duration)                       // previews: .milliseconds(300)
  public var calls: [FakeCall] { get }                               // recorded requests, for assertions
  public func emit(_ event: APIEvent)                                // simulate 401 or lost access
  public func addNotification(_ n: InboxNotification, for userID: String)   // drive the poller
  public func removeMembership(userID: String, workspaceID: String)         // simulate lost access
  public func currentTasks() -> [TaskItem]                                  // assert on the fake's state
}
public struct FakeSeed: Sendable { public static let demo: FakeSeed; public static let empty: FakeSeed }

/// Stable ids in `FakeSeed.demo`, for previews and the XCUITest smoke.
public enum DemoIDs {
  public static let mekari: String                 // workspace "Mekari" (organization)
  public static let acmePilot: String              // workspace "Acme Pilot"
  public static let boardProject: String           // ≥ 3 sections, tasks in each (alice is EDITOR)
  public static let readOnlyProject: String        // alice is COMMENTER
  public static let taskWithStories: String        // comment with a mention, subtasks, followers
  public static let alice, bob, admin, guest: String   // user ids
  public static let guestEmail = "guest@partner.test"
  public static let password = "password123"
}
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
public enum WebLinks {                                // SPEC-MAC §5 "Open in Browser"; every link carries ?workspace=<id>
  public static func project(_ id: String, server: URL, workspace: String) -> URL     // /projects/:id
  public static func task(_ task: TaskItem, server: URL, workspace: String) -> URL    // /projects/:pid?task=:id or /my-tasks?task=:id
  public static func workspaceSettings(server: URL, workspace: String) -> URL         // /workspace/settings
  public static func acceptInvite(server: URL) -> URL                                 // /login (invite flow stays on the web)
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

Every store is `@MainActor @Observable public final class`, built synchronously with
`init(api: any MekariAPI, …)` and no network work in `init` (previews). Time-dependent stores also
take `clock: any Clock<Duration>` and `calendar: Calendar` (time zone included) for deterministic
tests. Each has a `static func preview(…)` backed by `FakeMekariAPI`.

**Conventions (all stores)**
- Async actions return nothing (except where noted) and set state; they never throw to the view.
- `phase: LoadState` for loading; `lastError: APIError?` is transient, shown by the view and then
  cleared with `clearError()`.
- Optimistic edits go through the shared `TaskCache`, once. On failure it reverts and sets `lastError`
  on the calling store.

```swift
public enum LoadState: Equatable { case idle, loading, loaded, failed(APIError) }
public enum NavigationTarget: Hashable, Sendable { case task(id: String, projectID: String?), project(id: String) }
```

### AppSession (root, one per app)

```swift
@MainActor @Observable public final class AppSession {
  public enum State: Equatable { case restoring, signedOut, signedIn(Me) }
  public enum SignInError: Equatable { case wrongCredentials, rateLimited, badServer, transport, other(String) }

  public private(set) var state: State
  public private(set) var isSigningIn: Bool
  public private(set) var signInError: SignInError?   // 401 / 429 / bad URL or /health / offline / BE message
  public private(set) var scope: WorkspaceScope?      // the current workspace's stores; nil = signed out or no workspace
  public private(set) var generation: Int             // bumps when a switch commits or lost access resets → `.task(id: generation)`
  public private(set) var notice: String?             // e.g. "Switched to Acme Pilot", "You no longer have access to X"
  public let settings: ServerSettings

  // Workspaces
  public var current: Workspace? { get }
  public var all: [Workspace] { get }                 // Me.workspaces order, for ⌘1…⌘9
  public var isGuest: Bool { get }
  public var isAdmin: Bool { get }
  public func switchWorkspace(to id: String) async    // serialized; newest wins; header + scope change together
  public func switchWorkspace(index: Int) async       // ⌘1…⌘9 (0-based); ignored if out of range

  public init(settings: ServerSettings, tokens: TokenStore, apiFactory: @escaping @Sendable (URL, TokenStore) -> any MekariAPI,
              clock: any Clock<Duration> = ContinuousClock(), calendar: Calendar = .current)
  public static func preview(signedIn: Bool = true, as email: String = "alice@example.com") -> AppSession
  /// `-UITestFakeAPI` boot: FakeMekariAPI, in-memory server ("https://demo.invalid") and token stores.
  /// signedIn: false → start() ends in .signedOut and the smoke test drives sign-in (any URL, password123).
  public static func uiTest(signedIn: Bool) -> AppSession

  public func start() async                           // token + /auth/me → .signedIn, else .signedOut
  public func signIn(server: String, email: String, password: String) async   // normalize → /health → login
  public func signOut() async
  public func webURL(path: String) -> URL?            // server + path + ?workspace=<current>, for Open in Browser / settings
  public func resolve(_ link: DeepLink) async -> DeepLinkResult   // auto-switches workspace like the web FE
  public func dismissNotice()
}
public enum DeepLinkResult: Equatable { case open(NavigationTarget), noAccess }
```

- A `.unauthorized` event → `.signedOut`, `scope = nil`.
- `.workspaceLost` → `GET /auth/me` without a header, adopt its `currentWorkspace` (new scope,
  `generation += 1`), and post a notice.
- Signed in with `currentWorkspace == nil` → `scope == nil`; the app shows "No workspace, open in browser".
- Settings such as "show in menu bar" and "notifications on" stay in the app (`@AppStorage`).
  The server URL lives in `ServerSettings`.

### WorkspaceScope (everything for the current workspace)

```swift
@MainActor @Observable public final class WorkspaceScope: Identifiable {
  public let id: String                                   // workspace id
  public let workspace: Workspace
  public let me: UserSummary
  public let tasks: TaskCache
  public let sidebar: SidebarStore
  public let myTasks: MyTasksStore
  public let inbox: InboxStore
  public let poller: NotificationPoller
  public let search: SearchStore
  public let quickAdd: QuickAddModel
  public func project(_ id: String) -> ProjectStore        // cached per id
  public func taskDetail(_ id: String) -> TaskDetailStore  // cached per id; the ⌘O window reuses it
  public func userSearch() -> UserSearch                   // new instance each time
  public func refresh() async                              // window focus: My Tasks + sidebar + inbox
}
```

### TaskCache (single source of truth for tasks)

```swift
@MainActor @Observable public final class TaskCache {
  public subscript(id: String) -> TaskItem? { get }       // rows read tasks by id
  public func detail(_ id: String) -> TaskDetail?
  public func upsert(_ tasks: [TaskItem])
  public func upsert(_ detail: TaskDetail)
  public func remove(_ id: String)
  /// Applies `changes` locally at once, PATCHes, then stores the server's TaskDetail; reverts on error.
  public func update(_ id: String, _ changes: TaskChanges, assignee: UserSummary?? = .none) async throws   // always APIError
}
```

Stores hold **task ids**. My Tasks, Project and the inspector read the cache, so an edit anywhere
shows up everywhere without events. (Lists still re-query membership on load, e.g. a task that is
no longer assigned to me leaves My Tasks on the next refresh; the optimistic path also removes it
at once.)

### SidebarStore

```swift
public private(set) var projects: [Project]     // non-archived, by name (guests: only theirs, BE-filtered)
public private(set) var phase: LoadState
public private(set) var lastError: APIError?
public func load() async
```

### MyTasksStore

```swift
public enum DueBucket: String, CaseIterable, Sendable { case overdue, today, upcoming, later, noDate, completed }
// upcoming = due in 1…7 days; matches the web FE
public struct TaskGroup: Identifiable, Equatable { public let bucket: DueBucket; public let title: String; public let taskIDs: [String] }

public var showCompleted: Bool                  // reloads incl. completed
public private(set) var groups: [TaskGroup]     // non-empty buckets in order; by due date, then title
public var dueSoon: [String] { get }            // overdue + today, for the menu bar
public private(set) var phase: LoadState
public private(set) var lastError: APIError?
public func refresh() async                     // also on window focus
public func toggleComplete(_ id: String) async  // optimistic via TaskCache
public func addTask(title: String, dueDate: LocalDate? = nil) async   // personal, assigned to me
public func clearError()
```

### ProjectStore

```swift
public enum ViewMode: Sendable { case list, board }   // initial from defaultView; CALENDAR → list
public private(set) var detail: ProjectDetail?
public private(set) var sections: [Section]          // by position
public func taskIDs(in sectionID: String?) -> [String] // by position; nil = "No section" (only if it has tasks)
public var viewMode: ViewMode
public var showCompleted: Bool
public var canEdit: Bool { get }                     // workspace ADMIN, or myRole != .commenter (BE §4; W7 limits manage, not edit)
public private(set) var phase: LoadState
public private(set) var lastError: APIError?
public func load() async
public func addTask(title: String, section sectionID: String?) async
public func addSection(name: String) async
public func renameSection(_ id: String, to name: String) async
/// List reorder and Board column moves, anchored: insert before `beforeTaskID`, or at the end of the
/// section when nil. (`.onMove(IndexSet, Int)` → before = ids[dest] or nil; a row drop target = before
/// that row; a column/empty-area drop = nil.) Features computes the float position from the neighbours
/// (Reorder) and, if the gap is too small, first renumbers that section (one PATCH per task).
/// before == taskID, or a move that leaves the order unchanged, is a no-op (no PATCH).
public func move(taskID: String, toSection sectionID: String?, before beforeTaskID: String?) async
public func moveSection(_ id: String, before beforeSectionID: String?) async
public func toggleComplete(_ id: String) async
public func clearError()
```

### TaskDetailStore (inspector)

```swift
public let taskID: String
public var task: TaskDetail? { get }                 // from TaskCache
public private(set) var stories: [Story]             // oldest first; Comment.segments is pre-parsed
public var canEdit: Bool { get }
public private(set) var phase: LoadState
public private(set) var lastError: APIError?
public let composer: CommentComposer

public func load() async                             // task + stories in parallel
// Final values only: the view keeps text fields in @State and commits on submit/blur. All optimistic.
public func setTitle(_ title: String) async
public func setDescription(_ text: String?) async
public func setAssignee(_ user: UserSummary?) async
public func setDueDate(_ date: LocalDate?) async
public func setPriority(_ priority: Priority) async
public func toggleComplete() async
public func addSubtask(title: String) async
public func toggleSubtask(_ id: String) async
public func follow() async                           // me
public func unfollow() async
public func addFollower(_ user: UserSummary) async
public func removeFollower(_ user: UserSummary) async
public func editComment(_ id: String, body: String) async
public func deleteComment(_ id: String) async
public func clearError()
```

```swift
@MainActor @Observable public final class CommentComposer {
  public var draft: String                           // storage form: mentions as "@[Name](id)"
  public var mentionQuery: String? { get }           // the trailing "@word" of draft (no cursor API on macOS 14 TextEditor)
  public let users: UserSearch                       // follows mentionQuery
  public func insertMention(_ user: PickableUser)    // replaces the trailing "@word" with "@[Name](id) "
  public var canSend: Bool { get }
  public private(set) var isSending: Bool
  public func send() async                           // ⌘↩; appends the comment to stories; clears draft
}
```

In Kit: `Comment.segments: [Mentions.Segment]` (`.text` / `.mention(name:userID:)`); markdown is
rendered in the app.

### UserSearch (assignee, followers, mentions)

```swift
public var query: String                             // debounced 250 ms → GET /users?q=
public private(set) var results: [PickableUser]      // role → "Guest" badge (W8)
public private(set) var isLoading: Bool
```

### InboxStore & NotificationPoller

```swift
// InboxStore
public private(set) var notifications: [InboxNotification]   // newest first
public private(set) var unreadCount: Int
public private(set) var phase: LoadState
public private(set) var lastError: APIError?
public func load() async
public func markRead(_ id: String) async
public func markAllRead() async
public func open(_ id: String) async -> NavigationTarget?    // marks read; .task(id, projectID)

// NotificationPoller: drives InboxStore.load on a timer
public enum Mode: Sendable { case active, background }       // 60 s / 5 min (SPEC-MAC §4)
public struct LocalNotice: Equatable, Sendable { public let id: String; public let title: String; public let taskID: String? }  // "Alice commented on Fix login"
public func setMode(_ mode: Mode)
public var onNew: (([LocalNotice]) -> Void)?                 // new unread since the last poll (never on the first poll)
public func start()                                          // idempotent; the scope starts it
public func stop()
```

### SearchStore (⌘K)

```swift
public var query: String                             // min 2 chars, debounce 250 ms; stale responses dropped
public private(set) var results: SearchResults?      // tasks / projects / people groups
public private(set) var isSearching: Bool
public var isEmpty: Bool { get }                     // "No results"
public func target(forTask id: String) -> NavigationTarget   // projects: .project(id); people: the app opens mailto: (SPEC-MAC §5)
```

### QuickAddModel (menu bar)

```swift
public var title: String
public var dueDate: LocalDate?
public private(set) var isSubmitting: Bool
public private(set) var lastError: APIError?
public func submit() async                           // personal task assigned to me; clears on success; My Tasks updates
```

## 5. Testing

- **Unit tests (Linux + macOS):** Kit (coding of every model from recorded BE JSON fixtures, LocalDate,
  Set-Cookie parsing, error envelopes, workspace-header rules and events via a stub `HTTPTransport`, Reorder,
  Mentions, WebLinks, DeepLink); Features (every store against `FakeMekariAPI` with a test clock).
- **Contract tests** (`Tests/ContractTests`, skipped unless `MP_BASE_URL` is set): `LiveMekariAPI`
  against a freshly seeded BE: login/cookie, `/auth/me`, header + switch, lost access, my tasks,
  project tasks, create/patch/complete, comments, notifications, search, guest rules (W1, W7, W8).
  Locally they run against a throwaway BE DB, never the shared `asana` DB.

## 6. Decisions

1. **One current workspace per app**, shared by all windows and the menu bar (confirmed by the UI engineer;
   SPEC-MAC §4 says so). Per-window workspaces
   later would mean one `WorkspaceScope` per window. The API layer already allows it, because
   `setWorkspace` is per client.
2. Views use `task.id` for `accessibilityIdentifier("task.row.<id>")`. Drag payloads are task-id strings
   (UI side), so Features needs no `Transferable`.
3. Debounces and polling run in Features with an injected `Clock`. Views run no timers.
4. Agreed with the Mac UI engineer (asana-clone-b6), 2026-10-18: shared `TaskCache`, `phase`/`lastError`,
   `generation`, typed `SignInError`, a composer keyed on the trailing `@word`, `NavigationTarget`, and app
   settings kept in `@AppStorage`. Then: anchor-based `move(…before:)`, `DemoIDs`, `AppSession.uiTest`, and
   people search results open `mailto:` in the app. The signatures are frozen from here; change them only by PR,
   and tell the other side.
5. `TaskCache` is one observed dictionary, so any task edit re-renders the visible rows. That's fine at v1
   sizes; if profiling says otherwise, switch to per-task observable boxes behind the same subscript.
6. **Added in PR 3 (additive only; the frozen names are unchanged):**
   - `TaskCache.update(…, assignee:)` shows a new assignee before the server answers.
   - Stores that need "today" take `now: () -> Date` next to `calendar` (`MyTasksStore`, `WorkspaceScope`,
     `AppSession`).
   - Extra read-only conveniences: `AppSession.me`, `AppSession.SignInError.message` (SPEC-MAC §5 copy),
     `TaskDetailStore.isFollowing`, `ProjectStore.hasUnsectionedTasks`, `SearchStore.lastError`,
     `QuickAddModel.canSubmit`, `CommentComposer.lastError` / `clearError()`, `DueBucket.title`,
     `NotificationPoller.mode` / `isRunning`.
   - `LocalNotice` is nested: `NotificationPoller.LocalNotice` (also `Identifiable`).
   - The scaffold's `AppModel` (and Kit's `ServerConfiguration`) stay until the app shell (PR 4) moves to
     `AppSession`; PR 4 deletes them.

