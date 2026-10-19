import Foundation
import MekariProjectKit
import Observation

/// Everything for the current workspace. A new instance on every switch, so all state resets together.
@MainActor @Observable
public final class WorkspaceScope: Identifiable {
  public let id: String
  public let workspace: Workspace
  public let me: UserSummary
  public let tasks: TaskCache
  public let sidebar: SidebarStore
  public let myTasks: MyTasksStore
  public let inbox: InboxStore
  public let poller: NotificationPoller
  public let search: SearchStore
  public let quickAdd: QuickAddModel
  public let completionFeedback: CompletionFeedback

  /// Every request from this scope; refused once the scope is closed (see `ScopedAPI`).
  @ObservationIgnored private let api: ScopedAPI
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private var projects: [String: ProjectStore] = [:]
  @ObservationIgnored private var details: [String: TaskDetailStore] = [:]

  public init(api: any MekariAPI, workspace: Workspace, me: UserSummary, clock: any Clock<Duration> = ContinuousClock(),
              calendar: Calendar = .current, now: @escaping () -> Date = Date.init, defaults: UserDefaults = .standard) {
    let api = ScopedAPI(api)
    self.api = api
    self.clock = clock
    id = workspace.id
    self.workspace = workspace
    self.me = me
    tasks = TaskCache(api: api, clock: clock)
    sidebar = SidebarStore(api: api)
    myTasks = MyTasksStore(api: api, tasks: tasks, me: me, calendar: calendar, now: now)
    inbox = InboxStore(api: api)
    poller = NotificationPoller(inbox: inbox, clock: clock)
    search = SearchStore(api: api, clock: clock)
    quickAdd = QuickAddModel(api: api, me: me, myTasks: myTasks)
    completionFeedback = CompletionFeedback(clock: clock, defaults: defaults)
    completionFeedback.tasks = tasks
    completionFeedback.myTasks = myTasks
    completionFeedback.me = me
    completionFeedback.projectStore = { [weak self] id in self?.projects[id] }
    completionFeedback.isClosed = { [api] in api.isClosed }
    tasks.feedback = completionFeedback
  }

  /// True once this workspace was left (switch, lost access, sign-out).
  public var isClosed: Bool { api.isClosed }

  /// Nothing from this scope reaches the server or the session-wide cooldown afterwards: in-flight work
  /// (an edit, a renumber loop, a load a view started) can't go out under the next workspace's header.
  func close() {
    api.close()
    poller.stop()
  }

  /// One store per project, kept for the life of the scope.
  public func project(_ id: String) -> ProjectStore {
    if let store = projects[id] { return store }
    let store = ProjectStore(api: api, tasks: tasks, projectID: id, workspaceRole: workspace.myRole)
    projects[id] = store
    return store
  }

  /// One store per task; the ⌘O window reuses the inspector's.
  public func taskDetail(_ id: String) -> TaskDetailStore {
    if let store = details[id] { return store }
    let store = TaskDetailStore(api: api, tasks: tasks, taskID: id, me: me, workspaceRole: workspace.myRole, clock: clock,
                                knownProject: { [weak self] projectID in self?.sidebar.projects.first { $0.id == projectID } })
    details[id] = store
    return store
  }

  /// Whether I may edit `task` without opening it (My Tasks checkboxes): personal tasks and workspace
  /// admins yes; a project task only if its project is in the sidebar and I'm not a COMMENTER there.
  /// Fails closed: a project not (yet) loaded counts as read-only, like `TaskDetailStore.canEdit`.
  public func canEdit(task: TaskItem) -> Bool {
    guard let projectID = task.projectId else { return true }
    if workspace.myRole == .admin { return true }
    guard let project = sidebar.projects.first(where: { $0.id == projectID }) else { return false }
    return project.myRole != .commenter
  }

  public func userSearch() -> UserSearch {
    UserSearch(api: api, clock: clock)
  }

  /// Window focus: My Tasks, the sidebar and the inbox.
  public func refresh() async {
    async let a: Void = myTasks.refresh()
    async let b: Void = sidebar.load()
    async let c: Void = inbox.load()
    _ = await (a, b, c)
  }
}

/// The app's root model: sign-in state, the current workspace and its stores (SPEC-MAC §4).
@MainActor @Observable
public final class AppSession {
  public enum State: Equatable { case restoring, signedOut, signedIn(Me) }
  public enum SignInError: Equatable, Sendable {
    case wrongCredentials, rateLimited, badServer, transport
    case other(String)

    /// SPEC-MAC §5 copy.
    public var message: String {
      switch self {
      case .wrongCredentials: return "Wrong email or password"
      case .rateLimited: return "Too many attempts. Try again in a minute."
      case .badServer: return "That doesn't look like a Mekari Project server"
      case .transport: return "Can't reach the server"
      case .other(let message): return message
      }
    }
  }

  public private(set) var state: State = .restoring
  public private(set) var isSigningIn = false
  public private(set) var signInError: SignInError?
  /// The current workspace's stores; nil when signed out or signed in without a workspace.
  public private(set) var scope: WorkspaceScope?
  /// Bumps whenever `scope` is replaced (switch, lost access, sign-in): `.task(id: generation)`.
  public private(set) var generation = 0
  /// A short message for a toast, e.g. "Switched to Acme Pilot".
  public private(set) var notice: String?
  /// True from the moment a workspace switch (or lost-access recovery) is queued until the last
  /// queued one commits or fails: show progress, hold off edits.
  public private(set) var isSwitching = false
  public let settings: ServerSettings

  @ObservationIgnored private let tokens: TokenStore
  @ObservationIgnored private let apiFactory: @Sendable (URL, TokenStore) -> any MekariAPI
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private var api: (any MekariAPI)?
  @ObservationIgnored private var eventLoop: Task<Void, Never>?
  @ObservationIgnored private var switchRequest = 0
  @ObservationIgnored private var switchQueue: Task<Void, Never>?
  /// The celebration rate limit, kept across workspace switches.
  @ObservationIgnored private let celebrationCooldown = CelebrationCooldown()
  /// Jobs queued and not finished, and jobs skipped as superseded (tests pin the queue with these).
  @ObservationIgnored private(set) var queuedJobs = 0 {
    didSet { if isSwitching != (queuedJobs > 0) { isSwitching = queuedJobs > 0 } }
  }
  @ObservationIgnored private(set) var skippedJobs = 0
  /// The workspace the server will open next (its `lastWorkspaceId`), as far as we know.
  @ObservationIgnored private var serverWorkspaceID: String?

  public init(settings: ServerSettings, tokens: TokenStore, apiFactory: @escaping @Sendable (URL, TokenStore) -> any MekariAPI,
              clock: any Clock<Duration> = ContinuousClock(), calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
    self.settings = settings
    self.tokens = tokens
    self.apiFactory = apiFactory
    self.clock = clock
    self.calendar = calendar
    self.now = now
  }

  // MARK: - Workspaces

  public var me: Me? {
    if case .signedIn(let me) = state { return me }
    return nil
  }

  public var current: Workspace? { scope?.workspace }
  /// Me.workspaces order (by name), for ⌘1…⌘9.
  public var all: [Workspace] { me?.workspaces ?? [] }
  public var isGuest: Bool { current?.isGuest ?? false }
  public var isAdmin: Bool { current?.isAdmin ?? false }

  /// Switches the app's workspace. Switches (and lost-access recovery) run one at a time, in order;
  /// one superseded before it starts is skipped before its POST, so both the app and the server's
  /// `lastWorkspaceId` end on the newest choice.
  public func switchWorkspace(to id: String) async {
    await serialized { session, request in await session.performSwitch(to: id, request: request) }
  }

  /// ⌘1…⌘9 (0-based). Out of range does nothing.
  public func switchWorkspace(index: Int) async {
    guard all.indices.contains(index) else { return }
    await switchWorkspace(to: all[index].id)
  }

  // MARK: - Session

  /// Restores a saved session (`/auth/me`) or ends signed out.
  public func start() async {
    guard let server = settings.serverURL else {
      state = .signedOut
      return
    }
    let api = makeAPI(server)
    guard await api.hasSession else {
      state = .signedOut
      return
    }
    do {
      let me = try await api.me()
      serverWorkspaceID = me.currentWorkspace?.id
      await adopt(me, api: api)
    } catch {
      let apiError = error.asAPIError
      // Offline at launch keeps the token for next time.
      signInError = apiError.code == .transport ? .transport : nil
      state = .signedOut
    }
  }

  /// Validates the server with `/health`, then signs in.
  public func signIn(server: String, email: String, password: String) async {
    guard !isSigningIn else { return }
    signInError = nil
    guard let url = ServerURL.normalize(server) else {
      signInError = .badServer
      return
    }
    isSigningIn = true
    defer { isSigningIn = false }
    let previousURL = settings.serverURL
    // A session kept from an offline launch belongs to the old server: its cookie must never reach another
    // one (/auth/login carries the stored token).
    if !ServerURL.isSameServer(url, previousURL), tokens.load() != nil { tokens.clear() }
    let api = makeAPI(url)
    do {
      try await api.health()
    } catch {
      signInError = error.asAPIError.code == .transport ? .transport : .badServer
      return
    }
    do {
      // The URL is stored BEFORE login saves the token, so stored tokens always sit next to their server's URL
      // (a token beside the previous server's URL would go to that host on the next launch). A failed sign-in
      // puts the previous URL back.
      settings.serverURL = url
      let me = try await api.login(email: email.trimmingCharacters(in: .whitespaces), password: password)
      serverWorkspaceID = me.currentWorkspace?.id
      await adopt(me, api: api)
    } catch {
      // Only while no session was stored for the new URL.
      if tokens.load() == nil { settings.serverURL = previousURL }
      let apiError = error.asAPIError
      switch apiError.code {
      case .unauthorized: signInError = .wrongCredentials
      case .rateLimited: signInError = .rateLimited
      case .transport: signInError = .transport
      default: signInError = .other(apiError.message)
      }
    }
  }

  public func signOut() async {
    let api = self.api
    endSession()
    await api?.logout()
  }

  /// `server + path + ?workspace=<current>` for Open in Browser (SPEC-MAC §5).
  public func webURL(path: String) -> URL? {
    guard let server = settings.serverURL else { return nil }
    return WebLinks.url(server, path: path, workspace: current?.id)
  }

  /// Opens a deep link, switching workspace first when the resource lives in another one I belong to.
  public func resolve(_ link: DeepLink) async -> DeepLinkResult {
    guard let api else { return .noAccess }
    // `DeepLink(url:)` only yields UUIDs, but the cases can be built directly: never let anything
    // else reach a request path.
    switch link {
    case .task(let id), .project(let id):
      guard UUID(uuidString: id) != nil else { return .noAccess }
    }
    do {
      let workspaceID: String
      let target: NavigationTarget
      switch link {
      case .task(let id):
        let task = try await api.task(id)
        workspaceID = task.workspaceId
        target = .task(id: id, projectID: task.projectId)
      case .project(let id):
        let project = try await api.project(id)
        workspaceID = project.workspaceId
        target = .project(id: id)
      }
      if workspaceID != current?.id {
        guard all.contains(where: { $0.id == workspaceID }) else { return .noAccess }
        await switchWorkspace(to: workspaceID)
        guard current?.id == workspaceID else { return .noAccess }
      }
      return .open(target)
    } catch {
      return .noAccess
    }
  }

  public func dismissNotice() { notice = nil }

  /// The live client (tests only).
  var currentAPI: (any MekariAPI)? { api }

  // MARK: - Internals

  /// Queues a workspace job after the ones already queued. A job is skipped (before it starts) or not
  /// committed if a newer superseding job was queued after it. User switches supersede everything
  /// queued before them; lost-access recovery supersedes nothing (it never cancels a user's switch).
  private func serialized(supersedes: Bool = true, _ job: @escaping @MainActor (AppSession, Int) async -> Void) async {
    if supersedes { switchRequest += 1 }
    let request = switchRequest
    let previous = switchQueue
    queuedJobs += 1
    let task = Task { @MainActor [weak self] in
      await previous?.value
      guard let self else { return }
      defer { self.queuedJobs -= 1 }
      guard request == self.switchRequest else {
        self.skippedJobs += 1
        return
      }
      await job(self, request)
    }
    switchQueue = task
    await task.value
  }

  private func performSwitch(to id: String, request: Int) async {
    guard let api, case .signedIn(var me) = state else { return }
    // Nothing to do only if both the app and the server are already there.
    if id == current?.id, id == serverWorkspaceID { return }
    do {
      let workspace = try await api.switchWorkspace(id)
      serverWorkspaceID = id
      guard request == switchRequest else { return }
      me.currentWorkspace = workspace
      if let i = me.workspaces.firstIndex(where: { $0.id == id }) { me.workspaces[i] = workspace }
      me.user.role = workspace.myRole
      await adopt(me, api: api)
      notice = "Switched to \(workspace.name)"
    } catch {
      guard request == switchRequest, !(error is CancellationError) else { return }
      notice = error.asAPIError.message
    }
  }

  /// Lost access: adopt the workspace `/auth/me` gives us (it never carries the header).
  ///
  /// The header is never cleared here: until `adopt` swaps header and scope together, both still
  /// name the lost workspace, so requests fail (404) instead of silently falling back server-side to
  /// another workspace's data under this one's label. On failure the notice stays up and the next
  /// scoped request (e.g. window focus) 404s again and retries.
  private func recoverLostAccess(from workspaceID: String, request: Int) async {
    guard let api, workspaceID == current?.id else { return }
    let lostName = current?.name ?? "this workspace"
    do {
      let me = try await api.me()
      guard request == switchRequest else { return }
      await adopt(me, api: api)
      notice = "You no longer have access to \(lostName)"
    } catch is CancellationError {
    } catch {
      guard request == switchRequest, current?.id == workspaceID else { return }
      // 401s arrive as their own event and sign out.
      notice = "You no longer have access to \(lostName). Couldn't load your other workspaces; retrying when you come back."
    }
  }

  private func makeAPI(_ server: URL) -> any MekariAPI {
    let api = apiFactory(server, tokens)
    eventLoop?.cancel()
    eventLoop = Task { [weak self] in
      for await event in api.events {
        await self?.handle(event)
      }
    }
    self.api = api
    return api
  }

  /// Signed in as `me`: header, scope and generation change together.
  private func adopt(_ me: Me, api: any MekariAPI) async {
    // Close first: the old scope's requests stop before the header names the next workspace.
    scope?.close()
    await api.setWorkspace(me.currentWorkspace?.id)
    state = .signedIn(me)
    scope = me.currentWorkspace.map {
      WorkspaceScope(api: api, workspace: $0, me: me.user.summary, clock: clock, calendar: calendar, now: now)
    }
    scope?.completionFeedback.cooldown = celebrationCooldown
    generation += 1
    scope?.poller.start()
  }

  private func handle(_ event: APIEvent) async {
    switch event {
    case .unauthorized:
      guard state != .signedOut else { return }
      endSession()
    case .workspaceLost(let workspaceID):
      guard workspaceID == current?.id else { return }
      await serialized(supersedes: false) { session, request in
        await session.recoverLostAccess(from: workspaceID, request: request)
      }
    }
  }

  private func endSession() {
    switchRequest += 1 // queued switches are void now
    serverWorkspaceID = nil
    scope?.close()
    scope = nil
    state = .signedOut
    generation += 1
  }
}

// MARK: - Previews & UI tests

extension AppSession {
  /// Backed by `FakeMekariAPI` with the demo seed. Starts itself.
  public static func preview(signedIn: Bool = true, as email: String = "alice@example.com") -> AppSession {
    let fake = FakeMekariAPI(signedInAs: signedIn ? email : nil)
    let session = AppSession(settings: InMemoryServerSettings(serverURL: URL(string: "https://demo.invalid")),
                             tokens: InMemoryTokenStore(), apiFactory: { _, _ in fake })
    Task { await session.start() }
    return session
  }

  /// `-UITestFakeAPI` boot: FakeMekariAPI with in-memory stores. With `signedIn: false`, `start()` ends
  /// in `.signedOut` and sign-in works with any server URL and `password123`. The caller runs `start()`.
  public static func uiTest(signedIn: Bool) -> AppSession {
    let fake = FakeMekariAPI(signedInAs: signedIn ? "alice@example.com" : nil)
    return AppSession(settings: InMemoryServerSettings(serverURL: URL(string: "https://demo.invalid")),
                      tokens: InMemoryTokenStore(), apiFactory: { _, _ in fake })
  }
}
