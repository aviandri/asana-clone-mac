import Foundation
import MekariProjectKit
import Observation

/// The single source of truth for tasks in the current workspace. Stores hold task ids; rows and
/// the inspector read tasks from here, so an edit anywhere shows up everywhere.
///
/// What views see is the last server-confirmed task with the edits still in flight replayed on top,
/// in order. So:
/// - a failed edit drops out on its own: later edits (in flight or already saved) stay;
/// - server data older than what we have (`updatedAt`) is ignored, so a slow list load can't snap
///   a just-moved task back.
///
/// A just-completed task lingers (`lingerDuration`) so lists keep it in place briefly and a second
/// click can un-complete it; an un-complete or a failed completion ends the linger at once.
@MainActor @Observable
public final class TaskCache {
  /// What views read: confirmed + pending edits.
  private var tasks: [String: TaskItem] = [:]
  private var details: [String: TaskDetail] = [:]
  /// Completed in this session less than `lingerDuration` ago (`.zero`: no linger); lists still show
  /// them in place.
  public private(set) var lingering: Set<String> = []
  public let lingerDuration: Duration

  @ObservationIgnored private let api: any MekariAPI
  @ObservationIgnored private var confirmed: [String: TaskItem] = [:]
  @ObservationIgnored private var confirmedDetails: [String: TaskDetail] = [:]
  @ObservationIgnored private var pending: [String: [PendingEdit]] = [:]
  /// Deleted tasks: later copies (a slow list load) never bring them back.
  @ObservationIgnored private var deleted: Set<String> = []
  @ObservationIgnored private var nextEdit = 0
  @ObservationIgnored private let clock: any Clock<Duration>
  /// Per task, the current linger; an older linger's timer can't end a newer one.
  @ObservationIgnored private var lingerTokens: [String: Int] = [:]
  @ObservationIgnored private var nextLinger = 0
  /// Told about completions (wired by `WorkspaceScope`).
  @ObservationIgnored weak var feedback: CompletionFeedback?

  private struct PendingEdit {
    let id: Int
    let changes: TaskChanges
    let assignee: UserSummary??
  }

  public init(api: any MekariAPI, clock: any Clock<Duration> = ContinuousClock(), lingerDuration: Duration = .milliseconds(700)) {
    self.api = api
    self.clock = clock
    self.lingerDuration = lingerDuration
  }

  public subscript(id: String) -> TaskItem? { tasks[id] }

  public func detail(_ id: String) -> TaskDetail? { details[id] }

  /// Whether an edit to this task is still waiting for the server.
  public func hasPendingEdits(_ id: String) -> Bool { !(pending[id] ?? []).isEmpty }

  public func isLingering(_ id: String) -> Bool { lingering.contains(id) }

  public func upsert(_ items: [TaskItem]) {
    var touched: Set<String> = []
    for item in items where accept(item) {
      touched.insert(item.id)
      if let parentID = item.parentId { touched.insert(parentID) }
    }
    touched.forEach(recompute)
  }

  public func upsert(_ detail: TaskDetail) {
    if deleted.contains(detail.id) { return }
    if let current = confirmedDetails[detail.id], current.updatedAt > detail.updatedAt { return }
    confirmedDetails[detail.id] = detail
    var touched: Set<String> = [detail.id]
    _ = accept(detail.task)
    for subtask in detail.subtasks where accept(subtask) { touched.insert(subtask.id) }
    if var stored = confirmedDetails[detail.id] {
      stored.subtasks.removeAll { deleted.contains($0.id) }
      confirmedDetails[detail.id] = stored
    }
    if let parentID = detail.parentId { touched.insert(parentID) }
    touched.forEach(recompute)
  }

  public func remove(_ id: String) {
    deleted.insert(id)
    let parentID = tasks[id]?.parentId
    tasks[id] = nil
    details[id] = nil
    confirmed[id] = nil
    confirmedDetails[id] = nil
    pending[id] = nil
    endLinger(id)
    if let parentID, var parent = confirmedDetails[parentID] {
      parent.subtasks.removeAll { $0.id == id }
      confirmedDetails[parentID] = parent
      recompute(parentID)
    }
  }

  /// Shows `changes` at once, PATCHes, then stores the server's `TaskDetail`. On failure only this
  /// edit is dropped (others stay) and the error is rethrown: an `APIError`, or `CancellationError`.
  /// Pass `assignee` when `changes.assigneeId` is set, so the row shows the person immediately.
  public func update(_ id: String, _ changes: TaskChanges, assignee: UserSummary?? = .none) async throws {
    let completing = changes.completed == true && tasks[id]?.completed == false
    nextEdit += 1
    let edit = PendingEdit(id: nextEdit, changes: changes, assignee: assignee)
    pending[id, default: []].append(edit)
    recompute(id)
    if changes.completed == false { endLinger(id) }
    var linger: Int?
    var celebrates = false
    if completing {
      linger = startLinger(id)
      celebrates = feedback?.celebration(forCompleting: id) != nil
    }
    do {
      let saved = try await api.updateTask(id, changes)
      finish(edit, of: id)
      upsert(saved)
      if celebrates { feedback?.confirm(taskID: id) }
    } catch {
      finish(edit, of: id)
      if let linger { endLinger(id, token: linger) }
      if error is CancellationError { throw error }
      throw error.asAPIError
    }
  }

  // MARK: - Internals

  /// Returns the linger's token (nil: lingering is off).
  private func startLinger(_ id: String) -> Int? {
    guard lingerDuration > .zero else { return nil }
    nextLinger += 1
    let token = nextLinger
    lingerTokens[id] = token
    lingering.insert(id)
    let (clock, duration) = (clock, lingerDuration)
    Task { [weak self] in
      do {
        try await clock.sleep(for: duration)
      } catch {
        return
      }
      self?.endLinger(id, token: token)
    }
    return token
  }

  /// Ends `id`'s linger; with `token`, only if it's still that linger.
  private func endLinger(_ id: String, token: Int? = nil) {
    if let token, lingerTokens[id] != token { return }
    lingerTokens[id] = nil
    if lingering.contains(id) { lingering.remove(id) }
  }

  private func finish(_ edit: PendingEdit, of id: String) {
    pending[id]?.removeAll { $0.id == edit.id }
    if pending[id]?.isEmpty == true { pending[id] = nil }
    recompute(id)
  }

  /// Takes a server copy unless we already hold a newer one.
  private func accept(_ item: TaskItem) -> Bool {
    if deleted.contains(item.id) { return false }
    if let current = confirmed[item.id], current.updatedAt > item.updatedAt { return false }
    confirmed[item.id] = item
    return true
  }

  /// Rebuilds what views see for one task (and its detail, and its parent's subtask list).
  private func recompute(_ id: String) {
    if let base = confirmed[id] {
      let shown = (pending[id] ?? []).reduce(base) { task, edit in edit.changes.applied(to: task, assignee: edit.assignee) }
      if tasks[id] != shown { tasks[id] = shown }
    }
    if var detail = confirmedDetails[id] {
      if let shown = tasks[id] { detail.task = shown }
      detail.subtasks = detail.subtasks.map { tasks[$0.id] ?? $0 }
      if details[id] != detail { details[id] = detail }
    }
    if let parentID = tasks[id]?.parentId, var parent = confirmedDetails[parentID],
       parent.subtasks.contains(where: { $0.id == id }) {
      if let shownParent = tasks[parentID] { parent.task = shownParent }
      parent.subtasks = parent.subtasks.map { tasks[$0.id] ?? $0 }
      if details[parentID] != parent { details[parentID] = parent }
    }
  }
}
