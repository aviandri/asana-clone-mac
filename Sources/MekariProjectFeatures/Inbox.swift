import Foundation
import MekariProjectKit
import Observation

/// The inbox: the current workspace's notifications, newest first.
@MainActor @Observable
public final class InboxStore {
  public private(set) var notifications: [InboxNotification] = []
  public private(set) var unreadCount = 0
  public private(set) var phase: LoadState = .idle
  public private(set) var lastError: APIError?

  @ObservationIgnored private let api: any MekariAPI
  /// Every load and local change gets a number. A response is applied unless something newer (a later
  /// load that already finished, or a local change) has been applied since: so an older response never
  /// overwrites newer state, yet a caller awaiting `load()` still gets its data when nothing newer landed.
  @ObservationIgnored private var version = 0
  @ObservationIgnored private var applied = 0
  public static let pageSize = 50

  public init(api: any MekariAPI) {
    self.api = api
  }

  public func load() async {
    if notifications.isEmpty { phase = .loading }
    version += 1
    let mine = version
    do {
      let page = try await api.notifications(unreadOnly: false, limit: Self.pageSize)
      guard mine > applied else { return } // something newer is already showing
      applied = mine
      notifications = page.data
      unreadCount = page.unreadCount
      phase = .loaded
    } catch {
      guard mine > applied else { return }
      recordFailure(error, phase: &phase, lastError: &lastError)
    }
  }

  public func markRead(_ id: String) async {
    guard let i = notifications.firstIndex(where: { $0.id == id }), !notifications[i].read else { return }
    notifications[i].read = true
    unreadCount = max(0, unreadCount - 1)
    version += 1
    applied = version
    let mine = version
    do {
      try await api.markRead(id)
    } catch {
      // Revert only if nothing newer (a reload, another change) replaced this state meanwhile.
      if mine == applied, let j = notifications.firstIndex(where: { $0.id == id }) {
        notifications[j].read = false
        unreadCount += 1
      }
      recordFailure(error, lastError: &lastError)
    }
  }

  public func markAllRead() async {
    let previous = (notifications, unreadCount)
    for i in notifications.indices { notifications[i].read = true }
    unreadCount = 0
    version += 1
    applied = version
    let mine = version
    do {
      try await api.markAllRead()
    } catch {
      if mine == applied { (notifications, unreadCount) = previous }
      recordFailure(error, lastError: &lastError)
    }
  }

  /// Marks the notification read and returns where to go (nil when it has no task).
  public func open(_ id: String) async -> NavigationTarget? {
    guard let notification = notifications.first(where: { $0.id == id }) else { return nil }
    await markRead(id)
    return notification.task.map { .task(id: $0.id, projectID: $0.projectId) }
  }

  public func clearError() { lastError = nil }
}

/// Polls the inbox (SPEC-MAC §4: 60 s while active, 5 min in the background) and reports new unread
/// notifications for local banners.
@MainActor @Observable
public final class NotificationPoller {
  public enum Mode: Sendable { case active, background }

  /// One banner: "Alice Johnson commented on Fix login".
  public struct LocalNotice: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let taskID: String?
  }

  public private(set) var mode: Mode = .active
  /// New unread notifications since the last poll (never called for the first poll).
  @ObservationIgnored public var onNew: (([LocalNotice]) -> Void)?

  @ObservationIgnored private let inbox: InboxStore
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var seen: Set<String>?

  public static let activeInterval: Duration = .seconds(60)
  public static let backgroundInterval: Duration = .seconds(300)

  public init(inbox: InboxStore, clock: any Clock<Duration> = ContinuousClock()) {
    self.inbox = inbox
    self.clock = clock
  }

  public var isRunning: Bool { loop != nil }

  /// Starts polling now; does nothing if already running.
  public func start() {
    guard loop == nil else { return }
    let clock = clock
    // `self` is held only while polling, never across the sleep, so a dropped scope stops the loop.
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let interval = await self?.pollOnce() else { return }
        do {
          try await clock.sleep(for: interval)
        } catch {
          return
        }
      }
    }
  }

  public func stop() {
    loop?.cancel()
    loop = nil
  }

  /// Coming back to the foreground polls at once.
  public func setMode(_ newMode: Mode) {
    guard newMode != mode else { return }
    mode = newMode
    if newMode == .active, isRunning {
      stop()
      start()
    }
  }

  /// One poll; returns how long to wait before the next one.
  private func pollOnce() async -> Duration {
    await poll()
    return mode == .active ? Self.activeInterval : Self.backgroundInterval
  }

  /// One poll: refreshes the inbox and reports unread notifications not seen before.
  func poll() async {
    await inbox.load()
    guard !Task.isCancelled, case .loaded = inbox.phase else { return }
    let unread = inbox.notifications.filter { !$0.read }
    if let seen {
      let fresh = unread.filter { !seen.contains($0.id) }
      if !fresh.isEmpty {
        onNew?(fresh.map { LocalNotice(id: $0.id, title: $0.summary, taskID: $0.task?.id) })
      }
    }
    seen = (seen ?? []).union(inbox.notifications.map(\.id))
  }
}

/// The ⌘K palette: tasks, projects and people. At least 2 characters, debounced 250 ms; stale
/// responses are dropped.
@MainActor @Observable
public final class SearchStore {
  public var query = "" {
    didSet {
      // Whitespace-only edits don't search again.
      if Self.normalized(query) != Self.normalized(oldValue) { schedule() }
    }
  }
  public private(set) var results: SearchResults?
  public private(set) var isSearching = false
  public private(set) var lastError: APIError?

  @ObservationIgnored private let api: any MekariAPI
  @ObservationIgnored private let debouncer: Debouncer
  @ObservationIgnored private var generation = 0

  public static let minimumLength = 2

  public init(api: any MekariAPI, clock: any Clock<Duration> = ContinuousClock()) {
    self.api = api
    debouncer = Debouncer(clock: clock, delay: .milliseconds(250))
  }

  /// A finished search with nothing in it ("No results").
  public var isEmpty: Bool { results?.isEmpty == true && !isSearching }

  /// Projects open as `.project`; people open `mailto:` in the app (SPEC-MAC §5).
  public func target(forTask id: String) -> NavigationTarget {
    .task(id: id, projectID: results?.tasks.first { $0.id == id }?.projectId)
  }

  private static func normalized(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func schedule() {
    generation += 1
    let current = generation
    let q = Self.normalized(query)
    guard q.count >= Self.minimumLength else {
      debouncer.cancel()
      results = nil
      isSearching = false
      return
    }
    isSearching = true
    debouncer.schedule { [weak self] in
      guard let self else { return }
      do {
        let found = try await self.api.search(q)
        guard current == self.generation else { return }
        self.results = found
        self.lastError = nil
      } catch {
        guard current == self.generation else { return }
        recordFailure(error, lastError: &self.lastError)
      }
      self.isSearching = false
    }
  }
}
