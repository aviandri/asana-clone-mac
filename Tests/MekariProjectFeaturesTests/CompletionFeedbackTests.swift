import Foundation
import MekariProjectKit
import XCTest
@testable import MekariProjectFeatures

/// Lingering just-completed tasks, and when a completion celebrates.
final class CompletionFeedbackTests: XCTestCase {
  /// A Mekari scope on the demo fake with a test clock and its own defaults suite. My Tasks is loaded;
  /// the board project only when `board` is set.
  @MainActor
  func makeScope(board: Bool = true, fake: FakeMekariAPI = demoFake()) async throws
    -> (WorkspaceScope, TestClock, FakeMekariAPI, UserDefaults) {
    let suite = "completion-feedback-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    await fake.setWorkspace(DemoIDs.mekari)
    let me = try await fake.me()
    let workspace = try XCTUnwrap(me.workspaces.first { $0.id == DemoIDs.mekari })
    let clock = TestClock()
    let scope = WorkspaceScope(api: fake, workspace: workspace, me: alice, clock: clock,
                               calendar: TestTime.calendar, now: { TestTime.now }, defaults: defaults)
    await scope.myTasks.refresh()
    if board { await scope.project(DemoIDs.boardProject).load() }
    return (scope, clock, fake, defaults)
  }

  @MainActor
  func todayIDs(_ scope: WorkspaceScope) -> [String] {
    scope.myTasks.groups.first { $0.bucket == .today }?.taskIDs ?? []
  }

  @MainActor
  func taskID(_ title: String, _ scope: WorkspaceScope, in ids: [String]) throws -> String {
    try XCTUnwrap(ids.first { scope.tasks[$0]?.title == title }, title)
  }

  /// Open top-level tasks of the board's section `index` (nil: "No section").
  @MainActor
  func openIDs(_ board: ProjectStore, section index: Int?) -> [String] {
    board.taskIDs(in: index.map { board.sections[$0].id }).filter { !board.isCompleted($0) }
  }

  // MARK: - Linger

  @MainActor
  func testACompletedTaskLingersInPlaceThenLeaves() async throws {
    let (scope, clock, _, _) = try await makeScope()
    let board = scope.project(DemoIDs.boardProject)
    let id = try taskID("Push notification settings", scope, in: todayIDs(scope))
    let column = board.taskIDs(in: board.sections[0].id)

    await scope.myTasks.toggleComplete(id)
    XCTAssertEqual(scope.tasks[id]?.completed, true)
    XCTAssertTrue(scope.tasks.isLingering(id))
    XCTAssertTrue(todayIDs(scope).contains(id), "stays in its old bucket, not hidden or moved")
    XCTAssertEqual(board.taskIDs(in: board.sections[0].id), column, "stays in place on the board")

    let linger = scope.tasks.lingerDuration
    XCTAssertEqual(linger, .milliseconds(400))
    await clock.advance(by: linger - .milliseconds(1))
    XCTAssertTrue(scope.tasks.isLingering(id))
    await clock.advance(by: .milliseconds(1))
    XCTAssertFalse(scope.tasks.isLingering(id))
    XCTAssertFalse(todayIDs(scope).contains(id))
    XCTAssertFalse(board.taskIDs(in: board.sections[0].id).contains(id))

    // With completed tasks shown, it goes straight to Completed instead.
    scope.myTasks.showCompleted = true
    await scope.myTasks.refresh()
    let other = try taskID("Prepare 1:1 notes", scope, in: todayIDs(scope))
    await scope.myTasks.toggleComplete(other)
    XCTAssertTrue(scope.tasks.isLingering(other))
    XCTAssertEqual(scope.myTasks.groups.first { $0.taskIDs.contains(other) }?.bucket, .completed)
  }

  @MainActor
  func testUncompletingEndsTheLingerAndAnOldTimerCantEndANewOne() async throws {
    let (scope, clock, _, _) = try await makeScope()
    let id = try taskID("Push notification settings", scope, in: todayIDs(scope))
    let half = scope.tasks.lingerDuration / 2
    await scope.myTasks.toggleComplete(id)
    await clock.advance(by: half)
    await scope.myTasks.toggleComplete(id) // second click: un-complete
    XCTAssertFalse(scope.tasks.isLingering(id))
    XCTAssertEqual(scope.tasks[id]?.completed, false)
    XCTAssertTrue(todayIDs(scope).contains(id))

    // Complete again: the first linger's timer (due now) doesn't cut the new one short.
    await scope.myTasks.toggleComplete(id)
    await clock.advance(by: half)
    XCTAssertTrue(scope.tasks.isLingering(id))
    await clock.advance(by: half)
    XCTAssertFalse(scope.tasks.isLingering(id))
  }

  @MainActor
  func testAChangedLingerDurationAppliesFromTheNextCompletion() async throws {
    let (scope, clock, _, _) = try await makeScope()
    let today = todayIDs(scope)
    let (first, second) = (today[0], today[1])
    await scope.myTasks.toggleComplete(first)           // lingers 400 ms
    scope.tasks.lingerDuration = .milliseconds(300)     // e.g. a debug default while tuning
    await scope.myTasks.toggleComplete(second)          // lingers 300 ms
    await clock.advance(by: .milliseconds(300))
    XCTAssertTrue(scope.tasks.isLingering(first), "the running linger keeps its duration")
    XCTAssertFalse(scope.tasks.isLingering(second))
    await clock.advance(by: .milliseconds(100))
    XCTAssertFalse(scope.tasks.isLingering(first))

    scope.tasks.lingerDuration = .zero                  // off
    await scope.myTasks.toggleComplete(second)          // un-complete
    await scope.myTasks.toggleComplete(second)
    XCTAssertFalse(scope.tasks.isLingering(second))
    XCTAssertFalse(todayIDs(scope).contains(second))
  }

  @MainActor
  func testAFailedCompletionEndsTheLingerAtOnce() async throws {
    let (scope, _, fake, _) = try await makeScope()
    let id = try taskID("Push notification settings", scope, in: todayIDs(scope))
    await fake.failNext(.updateTask, with: APIError(code: .internal, status: 500, message: "boom"))
    await scope.myTasks.toggleComplete(id)
    XCTAssertFalse(scope.tasks.isLingering(id))
    XCTAssertEqual(scope.tasks[id]?.completed, false)
    XCTAssertTrue(todayIDs(scope).contains(id))
    XCTAssertNil(scope.completionFeedback.lastEvent)
  }

  @MainActor
  func testAnOlderFailedCompletionDoesntEndANewerLinger() async throws {
    let (scope, _, fake, _) = try await makeScope()
    let id = try taskID("Push notification settings", scope, in: todayIDs(scope))
    // Complete (held, then fails), un-complete, complete again: the old failure leaves the new linger.
    await fake.hold(.updateTask)
    await fake.failNext(.updateTask, with: APIError(code: .internal, status: 500, message: "boom"))
    async let first: Void = scope.myTasks.toggleComplete(id)
    await waitUntil { await fake.parkedCount(.updateTask) == 1 }
    async let undo: Void = scope.myTasks.toggleComplete(id)
    await waitUntil { await fake.parkedCount(.updateTask) == 2 }
    async let again: Void = scope.myTasks.toggleComplete(id)
    await waitUntil { await fake.parkedCount(.updateTask) == 3 }
    await fake.release(.updateTask) // the first: fails
    _ = await first
    XCTAssertTrue(scope.tasks.isLingering(id))
    await fake.release(.updateTask)
    _ = await undo
    await fake.release(.updateTask, all: true)
    _ = await again
    XCTAssertEqual(scope.tasks[id]?.completed, true)
  }

  // MARK: - Celebrations

  @MainActor
  func testClearingASectionCelebratesOnlyOnTheLastTask() async throws {
    let (scope, _, _, _) = try await makeScope()
    let board = scope.project(DemoIDs.boardProject)
    let section = board.sections[1]
    let ids = openIDs(board, section: 1)
    XCTAssertGreaterThan(ids.count, 1)
    for id in ids.dropLast() {
      await board.toggleComplete(id)
      XCTAssertNil(scope.completionFeedback.lastEvent, "not the last one")
    }
    await board.toggleComplete(ids.last!)
    XCTAssertEqual(scope.completionFeedback.lastEvent,
                   .init(id: 1, taskID: ids.last!, celebration: .sectionCleared(projectID: DemoIDs.boardProject, sectionID: section.id)))
  }

  @MainActor
  func testClearingTheProjectWinsOverItsSectionAndIsRateLimited() async throws {
    let (scope, clock, _, _) = try await makeScope()
    let board = scope.project(DemoIDs.boardProject)
    let open = (0..<board.sections.count).flatMap { openIDs(board, section: $0) } + openIDs(board, section: nil)
    for id in open.dropLast() { await board.toggleComplete(id) }
    // Clearing the earlier sections celebrated once; the rest fell inside the 30 s window.
    XCTAssertEqual(scope.completionFeedback.lastEvent?.id, 1)

    await clock.advance(by: .seconds(30))
    await board.toggleComplete(open.last!)
    XCTAssertEqual(scope.completionFeedback.lastEvent,
                   .init(id: 2, taskID: open.last!, celebration: .projectCleared(projectID: DemoIDs.boardProject)))
  }

  @MainActor
  func testTheRateLimitWindowIsThirtySeconds() async throws {
    let (scope, clock, _, _) = try await makeScope()
    let board = scope.project(DemoIDs.boardProject)
    for id in openIDs(board, section: 1) { await board.toggleComplete(id) }
    XCTAssertEqual(scope.completionFeedback.lastEvent?.id, 1)

    // Clear section 0 at 29.999 s: suppressed.
    await clock.advance(by: .milliseconds(29_999))
    let todo = openIDs(board, section: 0)
    for id in todo { await board.toggleComplete(id) }
    XCTAssertEqual(scope.completionFeedback.lastEvent?.id, 1)

    // Un-complete and redo the last one after the window: celebrates.
    await clock.advance(by: .milliseconds(1))
    await board.toggleComplete(todo.last!)
    await board.toggleComplete(todo.last!)
    XCTAssertEqual(scope.completionFeedback.lastEvent?.id, 2)
  }

  @MainActor
  func testMyLastTaskDueTodayCelebratesAndOverdueDoesntCount() async throws {
    // Board not loaded: the project and section rules can't apply, so only due today can.
    let (scope, clock, _, _) = try await makeScope(board: false)
    let today = todayIDs(scope)
    XCTAssertEqual(today.count, 2)
    XCTAssertFalse(scope.myTasks.groups.first { $0.bucket == .overdue }?.taskIDs.isEmpty ?? true, "an overdue task stays open")
    await scope.myTasks.toggleComplete(today[0])
    XCTAssertNil(scope.completionFeedback.lastEvent)
    await scope.myTasks.toggleComplete(today[1])
    XCTAssertEqual(scope.completionFeedback.lastEvent?.celebration, .dueTodayCleared)
    XCTAssertEqual(scope.completionFeedback.lastEvent?.taskID, today[1])

    // Completing the overdue task afterwards (outside the window) isn't "due today".
    await clock.advance(by: .seconds(30))
    let overdue = try XCTUnwrap(scope.myTasks.groups.first { $0.bucket == .overdue }?.taskIDs.first)
    await scope.myTasks.toggleComplete(overdue)
    XCTAssertEqual(scope.completionFeedback.lastEvent?.id, 1)
  }

  @MainActor
  func testRejectedOrUncompletedCompletionsNeverCelebrate() async throws {
    let (scope, _, fake, _) = try await makeScope()
    let board = scope.project(DemoIDs.boardProject)
    let ids = openIDs(board, section: 1)
    for id in ids.dropLast() { await board.toggleComplete(id) }
    let last = ids.last!

    // Rejected by the server: nothing, and no rate-limit window starts.
    await fake.failNext(.updateTask, with: APIError(code: .internal, status: 500, message: "boom"))
    await board.toggleComplete(last)
    XCTAssertNil(scope.completionFeedback.lastEvent)

    // Un-completed before the server answered: nothing either.
    await fake.hold(.updateTask)
    async let complete: Void = board.toggleComplete(last)
    await waitUntil { await fake.parkedCount(.updateTask) == 1 }
    async let undo: Void = board.toggleComplete(last)
    await waitUntil { await fake.parkedCount(.updateTask) == 2 }
    // One at a time, in order: released together, the fake could run them in either order.
    await fake.release(.updateTask)
    _ = await complete
    await fake.release(.updateTask, all: true)
    _ = await undo
    XCTAssertEqual(scope.tasks[last]?.completed, false)
    XCTAssertNil(scope.completionFeedback.lastEvent)

    // An un-complete of a completed task never celebrates; a real completion right after does.
    await board.toggleComplete(ids[0])
    XCTAssertNil(scope.completionFeedback.lastEvent)
    await board.toggleComplete(ids[0])
    await board.toggleComplete(last)
    XCTAssertEqual(scope.completionFeedback.lastEvent?.taskID, last)
  }

  @MainActor
  func testASiblingThatFailsAndReopensCancelsTheCelebration() async throws {
    let (scope, _, fake, _) = try await makeScope()
    let board = scope.project(DemoIDs.boardProject)
    let ids = openIDs(board, section: 1)
    for id in ids.dropLast(2) { await board.toggleComplete(id) }
    let (a, b) = (ids[ids.count - 2], ids[ids.count - 1])

    // A then B before either answers: B looks like the last one when clicked.
    await fake.hold(.updateTask)
    await fake.failNext(.updateTask, with: APIError(code: .internal, status: 500, message: "boom"))
    async let completeA: Void = board.toggleComplete(a)
    await waitUntil { await fake.parkedCount(.updateTask) == 1 }
    async let completeB: Void = board.toggleComplete(b)
    await waitUntil { await fake.parkedCount(.updateTask) == 2 }
    await fake.release(.updateTask) // A fails and reopens
    _ = await completeA
    await fake.release(.updateTask, all: true)
    _ = await completeB
    XCTAssertEqual(scope.tasks[a]?.completed, false)
    XCTAssertEqual(scope.tasks[b]?.completed, true)
    XCTAssertNil(scope.completionFeedback.lastEvent, "the section isn't cleared")
  }

  @MainActor
  func testANewTaskFromARefreshCancelsTheCelebration() async throws {
    let (scope, _, fake, _) = try await makeScope()
    let board = scope.project(DemoIDs.boardProject)
    let section = board.sections[1].id
    let ids = openIDs(board, section: 1)
    for id in ids.dropLast() { await board.toggleComplete(id) }

    await fake.hold(.updateTask)
    async let complete: Void = board.toggleComplete(ids.last!)
    await waitUntil { await fake.parkedCount(.updateTask) == 1 }
    // A teammate adds a task to the section; a refresh brings it in before the PATCH answers.
    _ = try await fake.createTask(NewTask(title: "Teammate's new task", projectId: DemoIDs.boardProject, sectionId: section))
    await board.load()
    await fake.release(.updateTask, all: true)
    _ = await complete
    XCTAssertEqual(scope.tasks[ids.last!]?.completed, true)
    XCTAssertNil(scope.completionFeedback.lastEvent)
  }

  @MainActor
  func testAnOpenSubtaskDueTodayDoesntHoldBackDueTodayCleared() async throws {
    let (scope, _, fake, _) = try await makeScope(board: false)
    _ = try await fake.createTask(NewTask(title: "Subtask due today", parentId: DemoIDs.taskWithStories,
                                          assigneeId: DemoIDs.alice, dueDate: TestTime.today))
    await scope.myTasks.refresh()
    let today = todayIDs(scope)
    let subtask = try taskID("Subtask due today", scope, in: today)
    for title in ["Prepare 1:1 notes", "Push notification settings"] {
      await scope.myTasks.toggleComplete(try taskID(title, scope, in: today))
    }
    XCTAssertEqual(scope.tasks[subtask]?.completed, false)
    XCTAssertEqual(scope.completionFeedback.lastEvent?.celebration, .dueTodayCleared)
  }

  @MainActor
  func testTheRateLimitSurvivesAWorkspaceSwitch() async throws {
    let fake = demoFake()
    let clock = TestClock()
    let session = await signedInSession(fake, clock: clock)
    let first = try XCTUnwrap(session.scope)
    let board = first.project(DemoIDs.boardProject)
    await board.load()
    for id in openIDs(board, section: 1) { await board.toggleComplete(id) }
    XCTAssertEqual(first.completionFeedback.lastEvent?.id, 1)

    await session.switchWorkspace(to: DemoIDs.acmePilot)
    await session.switchWorkspace(to: DemoIDs.mekari)
    let second = try XCTUnwrap(session.scope)
    XCTAssertFalse(first === second)
    let again = second.project(DemoIDs.boardProject)
    await again.load()
    let todo = openIDs(again, section: 0)
    for id in todo { await again.toggleComplete(id) }
    XCTAssertNil(second.completionFeedback.lastEvent, "still inside the window from before the switch")

    await clock.advance(by: .seconds(30))
    await again.toggleComplete(todo.last!)
    await again.toggleComplete(todo.last!)
    XCTAssertNotNil(second.completionFeedback.lastEvent)
  }

  @MainActor
  func testSubtasksNeverCelebrate() async throws {
    let (scope, _, _, _) = try await makeScope()
    let detail = scope.taskDetail(DemoIDs.taskWithStories)
    await detail.load()
    let subtasks = try XCTUnwrap(detail.task?.subtasks.filter { !$0.completed })
    XCTAssertFalse(subtasks.isEmpty)
    for subtask in subtasks { await detail.toggleSubtask(subtask.id) }
    XCTAssertTrue(subtasks.allSatisfy { scope.tasks[$0.id]?.completed == true })
    XCTAssertNil(scope.completionFeedback.lastEvent)
  }

  @MainActor
  func testTheSettingIsPersistedOnByDefaultAndSilencesEvents() async throws {
    let (scope, _, _, defaults) = try await makeScope()
    let feedback = scope.completionFeedback
    XCTAssertTrue(feedback.celebrationsEnabled)
    XCTAssertNil(defaults.object(forKey: CompletionFeedback.celebrationsEnabledKey))

    feedback.celebrationsEnabled = false
    XCTAssertEqual(defaults.object(forKey: CompletionFeedback.celebrationsEnabledKey) as? Bool, false)
    XCTAssertFalse(CompletionFeedback(defaults: defaults).celebrationsEnabled, "read back from defaults")

    let board = scope.project(DemoIDs.boardProject)
    let ids = openIDs(board, section: 1)
    for id in ids { await board.toggleComplete(id) }
    XCTAssertNil(feedback.lastEvent)

    // Turned back on (e.g. from Settings via @AppStorage): no window was started while it was off.
    defaults.set(true, forKey: CompletionFeedback.celebrationsEnabledKey)
    await board.toggleComplete(ids.last!)
    await board.toggleComplete(ids.last!)
    XCTAssertEqual(feedback.lastEvent?.id, 1)
  }
}

private extension ProjectStore {
  func isCompleted(_ id: String) -> Bool { !openTopLevelTasks().contains { $0.id == id } }
}
