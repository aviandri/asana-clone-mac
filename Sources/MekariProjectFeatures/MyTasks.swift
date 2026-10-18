import Foundation
import MekariProjectKit
import Observation

/// The sidebar's project list: the workspace's visible, non-archived projects by name.
@MainActor @Observable
public final class SidebarStore {
  public private(set) var projects: [Project] = []
  public private(set) var phase: LoadState = .idle
  public private(set) var lastError: APIError?
  @ObservationIgnored private let api: any MekariAPI

  public init(api: any MekariAPI) {
    self.api = api
  }

  public func load() async {
    if projects.isEmpty { phase = .loading }
    do {
      projects = try await api.projects(archived: false).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      phase = .loaded
    } catch {
      recordFailure(error, phase: &phase, lastError: &lastError)
    }
  }

  public func clearError() { lastError = nil }
}

/// My Tasks bucket (matches the web FE: upcoming = due in the next 7 days).
public enum DueBucket: String, CaseIterable, Sendable {
  case overdue, today, upcoming, later, noDate, completed

  public var title: String {
    switch self {
    case .overdue: return "Overdue"
    case .today: return "Today"
    case .upcoming: return "Upcoming"
    case .later: return "Later"
    case .noDate: return "No date"
    case .completed: return "Completed"
    }
  }

  public static func of(_ task: TaskItem, today: LocalDate) -> DueBucket {
    if task.completed { return .completed }
    guard let due = task.dueDate else { return .noDate }
    let days = due.days(since: today)
    if days < 0 { return .overdue }
    if days == 0 { return .today }
    if days <= 7 { return .upcoming }
    return .later
  }
}

public struct TaskGroup: Identifiable, Equatable, Sendable {
  public let bucket: DueBucket
  public let title: String
  public let taskIDs: [String]
  public var id: DueBucket { bucket }
}

@MainActor @Observable
public final class MyTasksStore {
  /// Includes completed tasks (reloads).
  public var showCompleted = false {
    didSet {
      guard showCompleted != oldValue else { return }
      reload?.cancel()
      reload = Task { [weak self] in await self?.refresh() }
    }
  }
  public private(set) var phase: LoadState = .idle
  public private(set) var lastError: APIError?

  @ObservationIgnored private let api: any MekariAPI
  @ObservationIgnored private let tasks: TaskCache
  @ObservationIgnored private let me: UserSummary
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private let now: () -> Date
  private var ids: [String] = []
  @ObservationIgnored private var reload: Task<Void, Never>?
  @ObservationIgnored private var loadVersion = 0
  @ObservationIgnored private var appliedVersion = 0

  public init(api: any MekariAPI, tasks: TaskCache, me: UserSummary, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
    self.api = api
    self.tasks = tasks
    self.me = me
    self.calendar = calendar
    self.now = now
  }

  /// Non-empty buckets in order, each sorted by due date then title. A task reassigned away from me
  /// drops out at once.
  public var groups: [TaskGroup] {
    let today = LocalDate.today(in: calendar, now: now())
    var buckets: [DueBucket: [TaskItem]] = [:]
    for id in ids {
      guard let task = tasks[id], task.assignee?.id == me.id else { continue }
      let bucket = DueBucket.of(task, today: today)
      if bucket == .completed && !showCompleted { continue }
      buckets[bucket, default: []].append(task)
    }
    return DueBucket.allCases.compactMap { bucket in
      guard let list = buckets[bucket], !list.isEmpty else { return nil }
      let sorted = list.sorted {
        switch ($0.dueDate, $1.dueDate) {
        case let (a?, b?) where a != b: return a < b
        case (nil, _?): return false
        case (_?, nil): return true
        default: return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
      }
      return TaskGroup(bucket: bucket, title: bucket.title, taskIDs: sorted.map(\.id))
    }
  }

  /// Overdue and due today, for the menu bar.
  public var dueSoon: [String] {
    groups.filter { $0.bucket == .overdue || $0.bucket == .today }.flatMap(\.taskIDs)
  }

  public func refresh() async {
    if ids.isEmpty { phase = .loading }
    loadVersion += 1
    let mine = loadVersion
    do {
      let list = try await api.myTasks(includeCompleted: showCompleted)
      // Applied unless a later refresh already landed (e.g. a quick second toggle answered first).
      guard mine > appliedVersion else { return }
      appliedVersion = mine
      tasks.upsert(list)
      // Keep tasks completed in this session visible (with "show completed" off they're filtered anyway).
      ids = list.map(\.id)
      phase = .loaded
    } catch {
      guard mine > appliedVersion else { return }
      recordFailure(error, phase: &phase, lastError: &lastError)
    }
  }

  public func toggleComplete(_ id: String) async {
    guard let task = tasks[id] else { return }
    do {
      try await tasks.update(id, TaskChanges(completed: !task.completed))
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  /// A personal task assigned to me.
  public func addTask(title: String, dueDate: LocalDate? = nil) async {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      let created = try await api.createTask(NewTask(title: trimmed, assigneeId: me.id, dueDate: dueDate))
      didCreate(created)
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  public func clearError() { lastError = nil }

  /// The ids from the last applied load (tests).
  var loadedTaskIDs: [String] { ids }

  /// Another store created a task (quick add); show it without a reload.
  func didCreate(_ detail: TaskDetail) {
    tasks.upsert(detail)
    if !ids.contains(detail.id) { ids.append(detail.id) }
  }
}

/// The menu bar's quick-add field: a personal task assigned to me, with an optional due date.
@MainActor @Observable
public final class QuickAddModel {
  public var title = ""
  public var dueDate: LocalDate?
  public private(set) var isSubmitting = false
  public private(set) var lastError: APIError?

  @ObservationIgnored private let api: any MekariAPI
  @ObservationIgnored private let me: UserSummary
  @ObservationIgnored private let myTasks: MyTasksStore

  public init(api: any MekariAPI, me: UserSummary, myTasks: MyTasksStore) {
    self.api = api
    self.me = me
    self.myTasks = myTasks
  }

  public var canSubmit: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting }

  public func submit() async {
    guard canSubmit else { return }
    isSubmitting = true
    defer { isSubmitting = false }
    do {
      let created = try await api.createTask(NewTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                     assigneeId: me.id, dueDate: dueDate))
      myTasks.didCreate(created)
      title = ""
      dueDate = nil
      lastError = nil
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  public func clearError() { lastError = nil }
}
