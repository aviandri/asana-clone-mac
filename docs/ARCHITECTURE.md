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
/// All BE enums are OPEN: unknown values decode to `.other(raw)` instead of failing a whole list
/// (`allCases` lists the known ones, for pickers; switches need a `default`/`.other` branch).
public enum WorkspaceRole: OpenEnum { case admin, member, guest, other(String) }     // .other: neither admin nor guest
public enum ProjectRole: OpenEnum { case owner, editor, commenter, other(String) }
public enum ProjectPrivacy: OpenEnum { case `public`, team, `private`, other(String) }
public enum ProjectView: OpenEnum { case list, board, calendar, other(String) }      // unknown → list
public enum Priority: OpenEnum { case none, low, medium, high, other(String) }
public enum NotificationType: OpenEnum { case assigned, commented, completed, mentioned, other(String) }
public enum ActivityType: OpenEnum {
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

public enum Story: Identifiable { case comment(Comment), activity(Activity) }   // discriminated by "kind"; unknown kinds are skipped in feeds
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
  Decoding failures name the coding path (`$.data[0].dueDate: Expected YYYY-MM-DD…`).
- **401 race:** only a 401 for the token still stored ends the session; a late 401 for an older token
  (poller, another window) is ignored. Login and logout never emit `.unauthorized`.
- **Cancellation:** cancelling the calling task cancels the `URLSessionTask` and throws
  `CancellationError` (never `APIError`); Features treat it as "no result", not an error.
- No retries or caching in v1.

### TokenStore & settings

```swift
public protocol TokenStore: Sendable { func load() -> String?; func save(_ token: String); func clear() }
public final class InMemoryTokenStore: TokenStore { public init(token: String? = nil) }
/// Reads its backend ONCE (init), then serves from memory; writes through. Save = update → add if
/// missing → delete + add on any other failure. Logs status codes only, never the token.
public final class CachedTokenStore: TokenStore { public init(backend: SecretBackend, log: @escaping @Sendable (String) -> Void = { _ in }) }
public protocol SecretBackend: Sendable { read/update/add/delete returning OSStatus-style Int32 }
#if canImport(Security)
public final class KeychainTokenStore: TokenStore {    // CachedTokenStore over the Keychain item
  public init(account: String)                        // service "com.mekari.project"; the app uses a fixed account ("session"):
}                                                     // one server per install, sign out to change it
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
  public private(set) var isSwitching: Bool           // a switch or lost-access recovery is queued/running: show progress, hold edits
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
  public func canEdit(task: TaskItem) -> Bool              // My Tasks checkboxes: personal/admin yes; project task iff its
                                                           // project is in the sidebar and I'm not COMMENTER (fail closed)
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
public var canEdit: Bool { get }                     // false until the project role is known (and if its lookup fails)
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
7. **Concurrency rules (PR #4 review):**
   - `TaskCache` shows *server-confirmed + edits in flight, replayed in order*. A failed edit drops only
     itself. Server copies older than the confirmed one (`updatedAt`) are ignored, so a slow list load
     can't undo a drag. `hasPendingEdits(id)`.
   - Workspace switches and lost-access recovery run one at a time. A switch superseded before it
     starts is skipped before its POST, so the app and the server's `lastWorkspaceId` both end on the
     newest choice. Recovery never cancels a user's switch.
   - Loads drop a response only when something newer has already been applied. `CancellationError` is
     never shown as an error, and a cancelled first load goes back to `.idle`.
   - Renumbering fetches the whole section (completed tasks too) and reloads the project if it fails.
   - The composer keeps text typed while a comment is sending. A failed project-role lookup means
     read-only. `UserSearch.lastError`.
   - `FakeMekariAPI.hold(_:)` / `release(_:all:newest:)` / `parkedCount(_:)` let tests order requests
     deterministically; a parked call that gets cancelled throws `CancellationError`.
8. **Re-review additions (PR #4):**
   - Lost-access recovery never clears the header. Until `adopt` swaps header and scope together, both
     still name the lost workspace, so requests 404 instead of showing another workspace's data under
     its label. If recovery fails, the notice stays and the next scoped request (focus) retries.
   - `AppSession.isSwitching` is true while any switch or recovery is queued or running.
   - `TaskDetailStore.canEdit` is false until the project role is known. It's known at once when the scope
     already knows the project (the sidebar's `myRole`, via `knownProject`), and its own fetch
     overrides that; if the fetch fails, it falls back to the scope's role (0.1.1).
   - `TaskCache.remove` leaves a tombstone, so later copies never bring a deleted task back.
   - Renumbering: every PATCH is tried, the failed ones are retried once, and if any still fail the
     project reloads and `lastError` says "Couldn't reorder; try again".
   - My Tasks, Project and Inbox loads all use "apply unless something newer already landed".

9. **Completion feedback (0.1.1, agreed with the UI side):**
   - `TaskCache` keeps a just-completed task in `lingering` for `lingerDuration` (300 ms, on the scope
     clock; settable, read when each linger starts; `.zero` turns it off), with `isLingering(_:)`. My Tasks shows it in its old bucket (unless
     completed tasks are shown), and project lists and the board keep it in place. An un-complete or a
     failed completion ends the linger at once; an older timer or failure never ends a newer linger.
   - `scope.completionFeedback` (`CompletionFeedback`) publishes `lastEvent` (`Event { id, taskID,
     celebration }`, where `id` increments per event). The decision is made against the cache at the
     optimistic apply, judged again once the server confirms, and published only if it still holds.
     An un-complete, a rejected completion, one un-completed before the server answered, or one whose
     "last" stopped being true meanwhile (a sibling's failed completion reopened it, a refresh brought
     in a new task) never celebrates.
   - Celebrations, highest first: `projectCleared` (last open top-level task in the project, anyone's),
     `sectionCleared` (last open top-level task in its section), `dueTodayCleared` (my last open task
     due today; overdue doesn't count). Subtasks never celebrate, and don't hold back "due today". The project and section rules need
     that project's `ProjectStore` loaded; the due-today rule needs My Tasks loaded.
   - At most one event per 30 s, on the session clock; the window survives workspace switches. `celebrationsEnabled` is persisted in UserDefaults
     under `CompletionFeedback.celebrationsEnabledKey` and is on when unset; while it's off, no event
     fires and no 30 s window starts.
10. **Closed scopes (from the Android #6 review):** a `WorkspaceScope` that was left (switch, lost access,
    sign-out) is closed before the header changes. Its API client (`ScopedAPI`) then refuses every
    request with `CancellationError` before it is sent, so in-flight work (an edit, a renumber loop, a
    load a view started) never goes out under the next workspace's header. A late `confirm()` from a
    closed scope neither celebrates nor starts the session-wide cooldown. `WorkspaceScope.isClosed`.

## 7. Attachments & links (v0.2: SPEC-MAC §8, BE SPEC §13 A1–A12)

The Kit and Features part of attachments. The App adds Quick Look, Open With, drag and drop, paste,
`NSOpenPanel`/`NSSavePanel` and the chips on top. Nothing here imports AppKit.

### Kit: models

```swift
public enum AttachmentKind: OpenEnum { case file, link, other(String) }            // open: unknown kinds still decode
public enum LinkPreviewStatus: OpenEnum { case pending, ready, failed, other(String) }

public struct Attachment: Codable, Sendable, Hashable, Identifiable {
  public var id, workspaceId, taskId: String
  public var commentId: String?                  // nil = task-level
  public var kind: AttachmentKind
  public var draft: Bool
  public var uploader: UserSummary
  public var createdAt: Date
  // FILE (nil for LINK)
  public var name, mimeType: String?
  public var size: Int64?
  public var width, height: Int?
  public var hasThumbnail: Bool
  // LINK (nil for FILE)
  public var url, title, description, siteName: String?
  public var provider: String?                   // open string: google_docs, figma, … ; unknown = generic badge
  public var previewStatus: LinkPreviewStatus?
  public var hasIcon, hasImage: Bool
  // Server-relative paths. Never build these by hand; pass them to the API / cache as they are.
  public var contentPath, thumbnailPath, iconPath, imagePath: String?

  public var displayName: String { get }         // FILE: name; LINK: title, else host, else url
  public var isImage: Bool { get }               // FILE with an image/* mimeType
  public var linkURL: URL? { get }               // LINK url, only when it is http/https (else nil: never open it)
  public var host: String? { get }               // LINK host, for the card's "site" line
}

public enum AttachmentLimits {
  public static let maxUploadBytes: Int64 = 104_857_600   // A1: pre-checked before any request
  public static let maxPerComment = 20
  public static let maxConcurrentUploads = 3              // A12, per user: the client queues the rest
}
public enum ThumbnailSize: String, Sendable { case small, large }   // fit 240 px / 1600 px
public struct TransferProgress: Sendable, Hashable {
  public var completed: Int64
  public var total: Int64?                       // nil when unknown
  public var fraction: Double? { get }           // 0…1, nil when total is unknown
}
public enum DownloadOutcome: Sendable, Equatable { case notModified, downloaded(etag: String?) }
```

- `TaskItem.attachmentCount: Int` (0 from servers before v1.3), `TaskDetail.attachments: [Attachment]`
  (task-level and comment ones, newest first), `Comment.attachments: [Attachment]` (oldest first).
  A comment's `body` may be empty when it has attachments.
- `APIError.Code` gains `.payloadTooLarge` (413 `PAYLOAD_TOO_LARGE`, and the local 100 MB pre-check, which has
  `status == nil`) and `.insufficientStorage` (507 `INSUFFICIENT_STORAGE`). 429 is the existing `.rateLimited`.
  Any other new code stays `.unknown(raw)` and shows `message`.

### Kit: API

```swift
extension MekariAPI {   // new protocol requirements
  /// Streams `file` from disk (never loaded into memory) as one multipart part `file`. `draft: true` → `?draft=true`
  /// (comment composer). `fileName` overrides the file's own name (e.g. "Pasted image 2026-10-26 at 10.02.03.png").
  /// Throws `.payloadTooLarge` without a request when the file is over `maxUploadBytes`. Cancel the calling task
  /// to cancel the upload (→ CancellationError). `progress` is called on an arbitrary thread.
  func uploadAttachment(taskID: String, file: URL, fileName: String?, draft: Bool,
                        progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> Attachment
  func addLink(taskID: String, url: String, title: String?, draft: Bool) async throws -> Attachment
  func attachment(_ id: String) async throws -> Attachment
  func refreshLinkPreview(_ id: String) async throws -> Attachment
  func deleteAttachment(_ id: String) async throws
  func addComment(taskID: String, body: String, attachmentIDs: [String]) async throws -> Comment
  /// GETs a server-relative attachment path (`contentPath`, `thumbnailPath`…) into `destination` (replaced
  /// atomically), sending `If-None-Match` when `etag` is given. Only `/api/v1/attachments/…` paths are accepted.
  func download(_ path: String, to destination: URL, ifNoneMatch etag: String?,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> DownloadOutcome
  /// Small bytes in memory: thumbnails, link icons and images.
  func attachmentData(_ path: String) async throws -> Data
}
// addComment(taskID:body:) stays, as attachmentIDs: [].
```

- Byte GETs are ID-addressed (no `X-Workspace-Id`), carry `Cookie: sid`, and never follow redirects.
- Live: the upload writes a temp multipart file (copied in 1 MB chunks) and sends it with
  `URLSession.uploadTask(fromFile:)`; the temp file is deleted afterwards. Downloads stream to a temp file
  next to `destination` and are moved into place only on a 200.
- Fake: uploads read the file's size and name only; `FakeSeed.demo` has a PNG, a PDF, a text file and a
  LINK on `DemoIDs.taskWithAttachments`, plus a comment with an image. Fake bytes are served for every path.
  New endpoints in `FakeEndpoint` (`uploadAttachment`, `addLink`, `deleteAttachment`, `download`, …) work
  with `failNext` / `hold` / `release`.

### Kit: AttachmentCache (downloads on disk, thumbnails in memory)

```swift
public actor AttachmentCache {
  public static func defaultDirectory() -> URL                 // <Caches>/<bundle id>/Attachments (not sandboxed:
                                                               // keeps wipe() inside our own folder)
  public init(directory: URL, capacity: Int64 = 1 << 30,       // 1 GB LRU on disk
              memoryCapacity: Int = 64 << 20,                  // thumbnails / icons / images in memory
              quarantine: @escaping @Sendable (URL) -> Void = { Quarantine.mark($0) })
  /// The local copy at <directory>/<attachmentId>/<sanitised name>: revalidated with its ETag (304 → the
  /// cached file), downloaded otherwise. Offline with a cached copy → the cached copy. Concurrent calls for
  /// one id share a download. Downloaded files get the quarantine xattr; never made executable.
  public func file(for attachment: Attachment, using api: any MekariAPI,
                   progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws -> URL
  public func cachedFile(for attachmentID: String) -> URL?     // Show in Finder only after a download
  public func data(at path: String, using api: any MekariAPI) async throws -> Data   // memory cache, by path
  public func wipe()                                           // disk and memory; in-flight downloads are dropped
  public var diskUsage: Int64 { get }
}
public enum Quarantine {
  /// `com.apple.quarantine` = "0081;<hex time>;Mekari Project;<uuid>" on Apple platforms; no-op elsewhere.
  public static func mark(_ file: URL)
}
```

### Features

```swift
/// Task-level uploads, kept for the whole session (keyed by task id), so they survive closing the
/// inspector or the task window and reappear when the task opens again. Cleared on sign-out; a lost
/// workspace's uploads are cancelled. At most 3 run at once across the app (shared with composers).
@MainActor @Observable public final class AttachmentUploads {
  public func uploads(for taskID: String) -> [AttachmentUpload]     // oldest first; finished ones drop out
  public var all: [AttachmentUpload] { get }
}

public struct AttachmentUpload: Identifiable, Sendable, Hashable {
  public enum Source: Sendable, Hashable { case file(URL, name: String), link(url: String, title: String?) }
  public enum State: Sendable, Hashable {
    case queued                                  // waiting for one of the 3 slots
    case uploading(TransferProgress)             // links: total nil while the server fetches the preview
    case finishing                               // whole body sent: it lands even if cancelled, so cancel/remove refuse
    case finished(Attachment)                    // composer chips only; task uploads leave the list
    case failed(APIError)                        // server message kept (429/507); local 100 MB → .payloadTooLarge, status nil
  }
  public let id: UUID
  public let taskID: String
  public let source: Source
  public var state: State
  public let size: Int64?                        // FILE size when known
  public let deletesFile: Bool                   // our temp file (pasted image): deleted when the upload leaves its list
  public var name: String { get }                // file name or link title/url
  public var isActive: Bool { get }              // queued, uploading or finishing
  public var isFinishing, isFinished, isFailed: Bool { get }
  public var attachment: Attachment? { get }     // when finished
}

// TaskDetailStore additions
public var attachments: [Attachment] { get }        // task + comment ones, newest first (from TaskCache's detail)
public var uploads: [AttachmentUpload] { get }      // this task's queued/uploading/finishing/failed task-level uploads
public var canAttach: Bool { get }                  // = canEdit (COMMENTERs attach through the composer only)
public func canDelete(_ attachment: Attachment) -> Bool   // uploader, project OWNER, workspace ADMIN; personal:
                                                          // uploader or task creator (A7)
public func attach(fileAt url: URL, fileName: String? = nil, deletesFile: Bool = false)   // task-level (non-draft)
public func addLink(_ url: String, title: String?) async throws   // throws APIError (.validation on "url" locally
                                                                  // first, else the server's) for the popover
public func retryUpload(_ id: UUID)
@discardableResult public func cancelUpload(_ id: UUID) -> Bool   // cancel queued/uploading, dismiss failed;
                                                                  // false while finishing
public func deleteAttachment(_ id: String) async    // optimistic: leaves the list and its comment at once (an
                                                    // empty-body comment whose last attachment it was goes too);
                                                    // restored + lastError if the server refuses (404 = gone, fine)
public func refreshLinkPreview(_ id: String) async  // updates the task list and the copy in its comment

// CommentComposer additions (drafts live here, so they survive re-renders; App calls discard() when the task closes)
public private(set) var attachments: [AttachmentUpload]   // chips, in order added
public private(set) var sendingIDs: Set<UUID>       // chips being posted: × disabled, remove() refuses them
public var isUploading: Bool { get }                // a chip is queued/uploading/finishing
public var hasRoomForAnother: Bool { get }          // < 20 chips, not counting failed ones (links in flight count)
@discardableResult public func attach(fileAt url: URL, fileName: String? = nil, deletesFile: Bool = false) -> Bool
                                                    // false = no room (20); over 100 MB → failed chip, no request
@discardableResult public func attachLink(_ url: String, title: String?) async throws -> Bool
                                                    // false = no room; throws APIError for the popover; a failed
                                                    // link leaves no chip (so only file chips retry)
public func retry(_ id: UUID)
@discardableResult public func remove(_ id: UUID) async -> Bool   // cancels or DELETEs the draft; false while
                                                                  // finishing or being posted
public func discard() async                         // removes every chip; finishing ones are deleted once they land
public var canSend: Bool { get }                    // text or ≥ 1 finished chip, nothing active, not sending;
                                                    // failed chips don't block
// send() posts the finished chips' ids as attachmentIds; on success it drops those and the chips that had failed;
// chips added during the send stay for the next comment.

/// Downloads for the current workspace through the session's AttachmentCache. Lives on WorkspaceScope.
@MainActor @Observable public final class AttachmentFiles {
  public private(set) var downloads: [String: TransferProgress]     // attachment id → progress while downloading
  public private(set) var lastError: APIError?
  public func file(for attachment: Attachment, revalidate: Bool = true) async -> URL?
      // nil on failure (lastError) or cancellation. revalidate: a cached copy costs one 304 round trip;
      // revalidate: false returns a cached copy at once (Quick Look stepping) and downloads only a missing one
  public func cancelDownload(_ attachmentID: String)                // stops it for every caller (they get nil, no error)
  public func cachedFile(for attachment: Attachment) async -> URL?
  public func thumbnail(for attachment: Attachment, size: ThumbnailSize) async -> Data?   // nil if none/failed
  public func linkIcon(for attachment: Attachment) async -> Data?
  public func linkImage(for attachment: Attachment) async -> Data?
  public func clearError()
}

// WorkspaceScope: public let attachmentFiles: AttachmentFiles
// AppSession:     public let uploads: AttachmentUploads
//                 public let attachmentCache: AttachmentCache
//                 init(..., attachmentCache: AttachmentCache = AttachmentCache(directory: AttachmentCache.defaultDirectory()))
//                 preview()/uiTest() use AttachmentCache.scratch() (a temp folder, no quarantine)
```

- **Wipe rules:** sign-out (including a 401) and losing access to a workspace wipe the whole cache (disk and
  memory) and cancel the affected uploads. Composer drafts are cancelled when their scope closes; the server's
  sweeper removes unposted drafts after 24 h.
- **Pre-checks:** over 100 MB → a failed upload/chip (`.payloadTooLarge`, `status == nil`) and no request; a link
  that isn't absolute http(s) → thrown `.validation` on `url`, no request; a 21st chip → `false`. User-facing copy
  is the App's (the layer's `message`s are only fallbacks); server errors keep the server's `message`.
- A finished task-level upload is inserted at the top of `attachments` of that task's store (when it is
  open) and bumps `attachmentCount` in `TaskCache`.
