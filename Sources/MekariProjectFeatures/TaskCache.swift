import Foundation
import MekariProjectKit
import Observation

/// The single source of truth for tasks in the current workspace. Stores hold task ids; rows and
/// the inspector read tasks from here, so an edit anywhere shows up everywhere.
@MainActor @Observable
public final class TaskCache {
  private var tasks: [String: TaskItem] = [:]
  private var details: [String: TaskDetail] = [:]
  @ObservationIgnored private let api: any MekariAPI

  public init(api: any MekariAPI) {
    self.api = api
  }

  public subscript(id: String) -> TaskItem? { tasks[id] }

  public func detail(_ id: String) -> TaskDetail? { details[id] }

  public func upsert(_ items: [TaskItem]) {
    for item in items { store(item) }
  }

  public func upsert(_ detail: TaskDetail) {
    details[detail.id] = detail
    store(detail.task)
    for subtask in detail.subtasks { store(subtask) }
  }

  public func remove(_ id: String) {
    let parentID = tasks[id]?.parentId
    tasks[id] = nil
    details[id] = nil
    if let parentID, var parent = details[parentID] {
      parent.subtasks.removeAll { $0.id == id }
      details[parentID] = parent
    }
  }

  /// Applies `changes` locally at once, PATCHes, then stores the server's `TaskDetail`. Reverts and
  /// rethrows (always an `APIError`) on failure. Pass `assignee` when `changes.assigneeId` is set, so
  /// the row shows the person immediately.
  public func update(_ id: String, _ changes: TaskChanges, assignee: UserSummary?? = .none) async throws {
    let previous = tasks[id]
    let previousDetail = details[id]
    let previousParent = previous?.parentId.flatMap { details[$0] }
    if let previous { store(changes.applied(to: previous, assignee: assignee)) }
    do {
      upsert(try await api.updateTask(id, changes))
    } catch {
      if let previous { store(previous) }
      details[id] = previousDetail
      if let previousParent { details[previousParent.id] = previousParent }
      throw error.asAPIError
    }
  }

  /// Keeps `tasks`, the task's own detail and its parent's subtask list in step.
  private func store(_ item: TaskItem) {
    tasks[item.id] = item
    if var detail = details[item.id], detail.task != item {
      detail.task = item
      details[item.id] = detail
    }
    if let parentID = item.parentId, var parent = details[parentID], let i = parent.subtasks.firstIndex(where: { $0.id == item.id }),
       parent.subtasks[i] != item {
      parent.subtasks[i] = item
      details[parentID] = parent
    }
  }
}
