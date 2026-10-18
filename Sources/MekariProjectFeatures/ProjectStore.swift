import Foundation
import MekariProjectKit
import Observation

/// One project: List and Board (SPEC-MAC §5).
@MainActor @Observable
public final class ProjectStore {
  public enum ViewMode: Sendable { case list, board }

  public let projectID: String
  public private(set) var detail: ProjectDetail?
  public private(set) var sections: [Section] = []
  /// Starts on the project's defaultView (CALENDAR → list).
  public var viewMode: ViewMode = .list
  public var showCompleted = false
  public private(set) var phase: LoadState = .idle
  public private(set) var lastError: APIError?

  @ObservationIgnored private let api: any MekariAPI
  @ObservationIgnored private let tasks: TaskCache
  @ObservationIgnored private let workspaceRole: WorkspaceRole
  private var ids: [String] = []
  @ObservationIgnored private var didChooseInitialMode = false
  @ObservationIgnored private var loadVersion = 0
  @ObservationIgnored private var appliedVersion = 0

  public init(api: any MekariAPI, tasks: TaskCache, projectID: String, workspaceRole: WorkspaceRole) {
    self.api = api
    self.tasks = tasks
    self.projectID = projectID
    self.workspaceRole = workspaceRole
  }

  /// Workspace admins, and every project member except COMMENTERs (BE §4; W7 limits managing, not editing).
  public var canEdit: Bool {
    guard let detail else { return false }
    return workspaceRole == .admin || detail.myRole != .commenter
  }

  /// Top-level tasks in a section (nil = "No section"), by position.
  public func taskIDs(in sectionID: String?) -> [String] {
    orderedTasks(in: sectionID, includeCompleted: showCompleted).map(\.id)
  }

  /// Whether to show the "No section" group (only when it has tasks).
  public var hasUnsectionedTasks: Bool { !taskIDs(in: nil).isEmpty }

  public func load() async {
    if detail == nil { phase = .loading }
    loadVersion += 1
    let mine = loadVersion
    do {
      async let detailCall = api.project(projectID)
      async let tasksCall = api.projectTasks(projectID, completed: nil)
      let (loaded, list) = try await (detailCall, tasksCall)
      guard mine > appliedVersion else { return } // a later load already landed
      appliedVersion = mine
      // Tasks edited meanwhile keep their newer state (TaskCache ignores older copies).
      detail = loaded
      sections = loaded.sections.sorted { $0.position < $1.position }
      tasks.upsert(list)
      ids = list.map(\.id)
      if !didChooseInitialMode {
        viewMode = loaded.defaultView == .board ? .board : .list
        didChooseInitialMode = true
      }
      phase = .loaded
    } catch {
      recordFailure(error, phase: &phase, lastError: &lastError)
    }
  }

  public func addTask(title: String, section sectionID: String?) async {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let last = orderedTasks(in: sectionID, includeCompleted: true).last?.position
    do {
      let created = try await api.createTask(NewTask(title: trimmed, projectId: projectID, sectionId: sectionID,
                                                     position: Reorder.position(between: last, and: nil)))
      tasks.upsert(created)
      ids.append(created.id)
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  public func addSection(name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      let section = try await api.createSection(projectID: projectID, name: trimmed,
                                                position: Reorder.position(between: sections.last?.position, and: nil))
      sections.append(section)
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  public func renameSection(_ id: String, to name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let index = sections.firstIndex(where: { $0.id == id }), sections[index].name != trimmed else { return }
    let previous = sections[index]
    sections[index].name = trimmed
    do {
      let saved = try await api.updateSection(id, SectionChanges(name: trimmed))
      if let i = sections.firstIndex(where: { $0.id == id }) { sections[i] = saved }
    } catch {
      if let i = sections.firstIndex(where: { $0.id == id }) { sections[i] = previous }
      recordFailure(error, lastError: &lastError)
    }
  }

  /// Moves a task into `sectionID` (nil = "No section") before `beforeTaskID`, or to the end when nil.
  /// List reorder and Board column moves both land here. A move that changes nothing sends no PATCH.
  public func move(taskID: String, toSection sectionID: String?, before beforeTaskID: String?) async {
    guard beforeTaskID != taskID, let task = tasks[taskID] else { return }
    // The destination as the user sees it (completed tasks only when shown), without the moved task.
    let destination = orderedTasks(in: sectionID, includeCompleted: showCompleted).filter { $0.id != taskID }
    let index = beforeTaskID.flatMap { id in destination.firstIndex { $0.id == id } } ?? destination.count

    if task.sectionId == sectionID {
      let current = orderedTasks(in: sectionID, includeCompleted: showCompleted)
      if let currentIndex = current.firstIndex(where: { $0.id == taskID }), currentIndex == index { return }
    }

    let before = index > 0 ? destination[index - 1].position : nil
    let after = index < destination.count ? destination[index].position : nil
    let sectionPatch: Patch<String>? = task.sectionId == sectionID ? nil : (sectionID.map { .set($0) } ?? .clear)

    if Reorder.needsRenumbering(between: before, and: after) {
      await renumber(moving: taskID, toSection: sectionID, before: index < destination.count ? destination[index].id : nil,
                     sectionPatch: sectionPatch)
      return
    }
    do {
      try await tasks.update(taskID, TaskChanges(sectionId: sectionPatch, position: Reorder.position(between: before, and: after)))
    } catch {
      recordFailure(error, lastError: &lastError)
    }
  }

  /// Too little room between neighbours: renumber the WHOLE destination section from the server's
  /// list (completed and hidden tasks included, so none of them jumps to the top), with the moved
  /// task placed before `anchorID` (or last). On any failure, reload the project from the server.
  private func renumber(moving taskID: String, toSection sectionID: String?, before anchorID: String?, sectionPatch: Patch<String>?) async {
    do {
      let all = try await api.projectTasks(projectID, completed: nil)
      tasks.upsert(all)
      for task in all where !ids.contains(task.id) { ids.append(task.id) }
      var order = all.filter { $0.sectionId == sectionID && $0.parentId == nil && $0.id != taskID }
        .sorted { $0.position != $1.position ? $0.position < $1.position : $0.createdAt < $1.createdAt }
        .map(\.id)
      let at = anchorID.flatMap { order.firstIndex(of: $0) } ?? order.count
      order.insert(taskID, at: at)
      for (id, position) in zip(order, Reorder.renumbered(count: order.count)) {
        let changes = TaskChanges(sectionId: id == taskID ? sectionPatch : nil, position: position)
        if tasks[id]?.position != position || changes.sectionId != nil { try await tasks.update(id, changes) }
      }
    } catch {
      recordFailure(error, lastError: &lastError)
      if !(error is CancellationError) { await load() }
    }
  }

  /// Moves a section before another one, or to the end when nil.
  public func moveSection(_ id: String, before beforeSectionID: String?) async {
    guard beforeSectionID != id, let moving = sections.first(where: { $0.id == id }) else { return }
    let others = sections.filter { $0.id != id }
    let index = beforeSectionID.flatMap { b in others.firstIndex { $0.id == b } } ?? others.count
    if sections.firstIndex(where: { $0.id == id }) == index { return }
    let before = index > 0 ? others[index - 1].position : nil
    let after = index < others.count ? others[index].position : nil
    let previous = sections
    var reordered = others
    var moved = moving
    moved.position = Reorder.position(between: before, and: after)
    reordered.insert(moved, at: index)
    sections = reordered
    do {
      let saved = try await api.updateSection(id, SectionChanges(position: moved.position))
      if let i = sections.firstIndex(where: { $0.id == id }) { sections[i] = saved }
    } catch {
      sections = previous
      recordFailure(error, lastError: &lastError)
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

  public func clearError() { lastError = nil }

  private func orderedTasks(in sectionID: String?, includeCompleted: Bool) -> [TaskItem] {
    ids.compactMap { tasks[$0] }
      .filter { $0.projectId == projectID && $0.parentId == nil && $0.sectionId == sectionID && (includeCompleted || !$0.completed) }
      .sorted { $0.position != $1.position ? $0.position < $1.position : $0.createdAt < $1.createdAt }
  }
}
