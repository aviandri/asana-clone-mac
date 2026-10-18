import Foundation
import MekariProjectKit
import Observation

/// What a completion cleared, for the occasional celebration.
public enum Celebration: Sendable, Equatable {
  /// The last open top-level task in a project section (nil = "No section").
  case sectionCleared(projectID: String, sectionID: String?)
  /// The last open top-level task in the project (anyone's).
  case projectCleared(projectID: String)
  /// My last open task due today.
  case dueTodayCleared
}

/// Decides when a completion celebrates. `TaskCache` asks at the optimistic apply (judged against
/// what's showing then) and reports back once the server confirms; the rule is judged again then, and
/// only if it still holds is `lastEvent` set. So an un-complete, a completion the server rejected, or
/// one whose "last" stopped being true meanwhile (a task completed alongside failed and reopened, a
/// refresh brought in a new one) never celebrates.
///
/// Rules: subtasks never celebrate; project > section > due today when several apply; the project and
/// section rules need that project's `ProjectStore` loaded, and the due-today rule needs My Tasks
/// loaded (the cache alone only holds whatever lists were loaded). At most one event per `minInterval`,
/// and none while `celebrationsEnabled` is off.
@MainActor @Observable
public final class CompletionFeedback {
  public struct Event: Sendable, Equatable {
    /// Increments per event, so the same celebration twice is still a change.
    public let id: Int
    public let taskID: String
    public let celebration: Celebration

    public init(id: Int, taskID: String, celebration: Celebration) {
      self.id = id
      self.taskID = taskID
      self.celebration = celebration
    }
  }

  public private(set) var lastEvent: Event?

  /// The Settings toggle (`@AppStorage(CompletionFeedback.celebrationsEnabledKey)`); on when unset.
  public static let celebrationsEnabledKey = "celebrationsEnabled"
  public var celebrationsEnabled: Bool {
    get { defaults.object(forKey: Self.celebrationsEnabledKey) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Self.celebrationsEnabledKey) }
  }

  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private let minInterval: Duration
  @ObservationIgnored private let defaults: UserDefaults
  /// Shared by every scope of a session (`AppSession` swaps its own in), so switching workspaces doesn't
  /// reset the window.
  @ObservationIgnored var cooldown = CelebrationCooldown()
  @ObservationIgnored private var nextID = 0

  // Wired by `WorkspaceScope`.
  @ObservationIgnored weak var tasks: TaskCache?
  @ObservationIgnored weak var myTasks: MyTasksStore?
  @ObservationIgnored var me: UserSummary?
  /// A project's store, only if one exists already (never creates one).
  @ObservationIgnored var projectStore: (String) -> ProjectStore? = { _ in nil }

  public init(clock: any Clock<Duration> = ContinuousClock(), minInterval: Duration = .seconds(30),
              defaults: UserDefaults = .standard) {
    self.clock = clock
    self.minInterval = minInterval
    self.defaults = defaults
  }

  /// What completing `taskID` clears, judged against what's showing now (the task itself excluded).
  func celebration(forCompleting taskID: String) -> Celebration? {
    guard let task = tasks?[taskID], task.parentId == nil else { return nil }
    if let projectID = task.projectId, let project = projectStore(projectID), project.phase == .loaded {
      let others = project.openTopLevelTasks().filter { $0.id != taskID }
      if others.isEmpty { return .projectCleared(projectID: projectID) }
      if !others.contains(where: { $0.sectionId == task.sectionId }) {
        return .sectionCleared(projectID: projectID, sectionID: task.sectionId)
      }
    }
    if let me, task.assignee?.id == me.id, let myTasks, myTasks.phase == .loaded,
       let due = task.dueDate, due == myTasks.today,
       !myTasks.openTasksDueToday().contains(where: { $0.id != taskID }) {
      return .dueTodayCleared
    }
    return nil
  }

  /// The server confirmed completing `taskID`, which celebrated when it was clicked: publishes what it
  /// clears now, unless the task was un-completed meanwhile, it no longer clears anything, celebrations
  /// are off, or the last event was under `minInterval` ago.
  func confirm(taskID: String) {
    guard tasks?[taskID]?.completed == true, celebrationsEnabled, !cooldown.isActive,
          let celebration = celebration(forCompleting: taskID) else { return }
    nextID += 1
    lastEvent = Event(id: nextID, taskID: taskID, celebration: celebration)
    cooldown.start(on: clock, for: minInterval)
  }
}

/// The rate-limit window: active for `interval` after `start`.
@MainActor
final class CelebrationCooldown {
  private(set) var isActive = false
  private var token = 0

  func start(on clock: any Clock<Duration>, for interval: Duration) {
    token += 1
    let mine = token
    isActive = true
    Task { [weak self] in
      try? await clock.sleep(for: interval)
      guard let self, self.token == mine else { return }
      self.isActive = false
    }
  }
}
