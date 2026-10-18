import Foundation
import MekariProjectKit
import XCTest
@testable import MekariProjectFeatures

/// PR #4 review: concurrent operations interleaving. No real sleeps: the fake parks calls
/// (`hold`/`release`) so each test fixes the order in which requests finish.
final class TaskCacheInterleavingTests: XCTestCase {
  @MainActor
  func testAFailedEditRevertsOnlyItselfNotALaterSavedOne() async throws {
    let fake = demoFake()
    let cache = TaskCache(api: fake)
    cache.upsert(try await fake.task(DemoIDs.taskWithStories))
    await fake.hold(.updateTask)

    // A: complete (slow, will fail). B: rename (fast, succeeds).
    async let a: Void = { try? await cache.update(DemoIDs.taskWithStories, TaskChanges(completed: true)) }()
    await waitUntil("A in flight") { await fake.parkedCount(.updateTask) == 1 }
    async let b: Void = { try? await cache.update(DemoIDs.taskWithStories, TaskChanges(title: "Renamed")) }()
    await waitUntil("B in flight") { await fake.parkedCount(.updateTask) == 2 }
    XCTAssertEqual(cache[DemoIDs.taskWithStories]?.completed, true)
    XCTAssertEqual(cache[DemoIDs.taskWithStories]?.title, "Renamed")

    await fake.release(.updateTask, newest: true) // B saves first
    await waitUntil("B saved") { await fake.parkedCount(.updateTask) == 1 }
    await settle()
    XCTAssertEqual(cache[DemoIDs.taskWithStories]?.completed, true, "A is still pending")
    await fake.failNext(.updateTask, with: APIError(code: .conflict, status: 409, message: "No"))
    await fake.release(.updateTask, all: true) // A fails
    _ = await (a, b)

    let shown = try XCTUnwrap(cache[DemoIDs.taskWithStories])
    XCTAssertEqual(shown.title, "Renamed", "B's saved rename survives A's failure")
    XCTAssertFalse(shown.completed, "A's own change is reverted")
    XCTAssertEqual(cache.detail(DemoIDs.taskWithStories)?.title, "Renamed")
    XCTAssertFalse(cache.hasPendingEdits(DemoIDs.taskWithStories))
  }

  @MainActor
  func testADetailLoadedDuringAFailedEditIsKept() async throws {
    let fake = demoFake()
    let cache = TaskCache(api: fake)
    await fake.hold(.updateTask)
    async let edit: Void = { try? await cache.update(DemoIDs.taskWithStories, TaskChanges(priority: .low)) }()
    await waitUntil("edit in flight") { await fake.parkedCount(.updateTask) == 1 }
    cache.upsert(try await fake.task(DemoIDs.taskWithStories)) // the inspector opens meanwhile
    await fake.failNext(.updateTask, with: .transport())
    await fake.release(.updateTask, all: true)
    await edit
    XCTAssertNotNil(cache.detail(DemoIDs.taskWithStories), "the failure must not wipe the loaded detail")
    XCTAssertEqual(cache[DemoIDs.taskWithStories]?.priority, .high)
  }

  @MainActor
  func testOlderServerCopiesAreIgnored() async throws {
    let fake = demoFake()
    let cache = TaskCache(api: fake)
    await fake.setWorkspace(DemoIDs.mekari)
    let stale = try await fake.projectTasks(DemoIDs.boardProject, completed: nil) // loaded before the drag
    cache.upsert(stale)
    let id = stale[0].id
    var newer = stale[0]
    newer.position = 42
    newer.updatedAt = stale[0].updatedAt.addingTimeInterval(5)
    cache.upsert([newer])                    // the drag's PATCH response
    cache.upsert(stale)                      // a slow list load lands afterwards
    XCTAssertEqual(cache[id]?.position, 42)
  }

  @MainActor
  func testPendingEditsStayVisibleThroughALoad() async throws {
    let fake = demoFake()
    let cache = TaskCache(api: fake)
    await fake.setWorkspace(DemoIDs.mekari)
    cache.upsert(try await fake.projectTasks(DemoIDs.boardProject, completed: nil))
    let id = DemoIDs.taskWithStories
    await fake.hold(.updateTask)
    async let edit: Void = { try? await cache.update(id, TaskChanges(position: 7)) }()
    await waitUntil("edit in flight") { await fake.parkedCount(.updateTask) == 1 }
    cache.upsert(try await fake.projectTasks(DemoIDs.boardProject, completed: nil)) // a refresh lands mid-edit
    XCTAssertEqual(cache[id]?.position, 7)
    await fake.release(.updateTask, all: true)
    await edit
    XCTAssertEqual(cache[id]?.position, 7)
  }
}

final class ProjectRenumberTests: XCTestCase {
  @MainActor
  func testRenumberingIncludesHiddenCompletedTasks() async throws {
    let fake = demoFake()
    let cache = TaskCache(api: fake)
    let store = ProjectStore(api: fake, tasks: cache, projectID: DemoIDs.boardProject, workspaceRole: .member)
    await store.load()
    let done = store.sections[2].id
    store.showCompleted = true
    let completed = store.taskIDs(in: done)                 // two completed tasks (hidden by default)
    store.showCompleted = false
    let todo = store.taskIDs(in: store.sections[0].id)
    let (open1, open2, mover) = (todo[0], todo[1], todo[2])
    await store.move(taskID: open1, toSection: done, before: nil)
    await store.move(taskID: open2, toSection: done, before: nil)
    // Crowd the whole section, hidden completed tasks first.
    for (id, position) in [(completed[0], 1.0), (completed[1], 1 + 1e-7), (open1, 1 + 2e-7), (open2, 1 + 3e-7)] {
      try await cache.update(id, TaskChanges(position: position))
    }
    XCTAssertEqual(store.taskIDs(in: done), [open1, open2])

    await store.move(taskID: mover, toSection: done, before: open2) // between two crowded neighbours

    XCTAssertNil(store.lastError)
    store.showCompleted = true
    XCTAssertEqual(store.taskIDs(in: done), [completed[0], completed[1], open1, mover, open2])
    let positions = store.taskIDs(in: done).compactMap { cache[$0]?.position }
    XCTAssertEqual(positions, [1000, 2000, 3000, 4000, 5000], "hidden completed tasks are renumbered too, in order")
    let server = try await fake.projectTasks(DemoIDs.boardProject, completed: nil)
      .filter { $0.sectionId == done }.sorted { $0.position < $1.position }.map(\.id)
    XCTAssertEqual(server, [completed[0], completed[1], open1, mover, open2])
  }

  @MainActor
  func testAFailedRenumberReloadsFromTheServer() async throws {
    let fake = demoFake()
    let cache = TaskCache(api: fake)
    let store = ProjectStore(api: fake, tasks: cache, projectID: DemoIDs.boardProject, workspaceRole: .member)
    await store.load()
    let todo = store.taskIDs(in: store.sections[0].id)
    try await cache.update(todo[0], TaskChanges(position: 1))
    try await cache.update(todo[1], TaskChanges(position: 1 + 1e-7))
    await fake.failNext(.projectTasks, with: .transport())
    await store.move(taskID: todo[3], toSection: store.sections[0].id, before: todo[1])
    XCTAssertEqual(store.lastError?.code, .transport)
    // Reloaded: the server order is what we show (nothing half-applied).
    let server = try await fake.projectTasks(DemoIDs.boardProject, completed: nil)
      .filter { $0.sectionId == store.sections[0].id }.sorted { $0.position < $1.position }.map(\.id)
    XCTAssertEqual(store.taskIDs(in: store.sections[0].id), server)
  }
}

final class InboxInterleavingTests: XCTestCase {
  @MainActor
  func testStoppingMidPollIsNotAnError() async {
    let fake = demoFake()
    await fake.setWorkspace(DemoIDs.mekari)
    let inbox = InboxStore(api: fake)
    let poller = NotificationPoller(inbox: inbox, clock: TestClock())
    await fake.hold(.notifications)
    poller.start()
    await waitUntil("poll in flight") { await fake.parkedCount(.notifications) == 1 }
    poller.stop()
    await fake.release(.notifications, all: true)
    await settle()
    XCTAssertNil(inbox.lastError)
    XCTAssertNotEqual(inbox.phase, .failed(APIError(code: .unknown("client"), message: "")))
    if case .failed = inbox.phase { XCTFail("cancellation must not fail the inbox") }
  }

  @MainActor
  func testAnOlderLoadNeverOverwritesNewerState() async {
    let fake = demoFake()
    await fake.setWorkspace(DemoIDs.mekari)
    let inbox = InboxStore(api: fake)
    await inbox.load()
    await fake.hold(.notifications)
    async let slow: Void = inbox.load()
    await waitUntil("load in flight") { await fake.parkedCount(.notifications) == 1 }
    let unread = inbox.notifications.first { !$0.read }!.id
    await inbox.markRead(unread)                         // newer local state
    await fake.failNext(.notifications, with: .transport())
    await fake.release(.notifications, all: true)
    await slow
    XCTAssertNil(inbox.lastError, "the stale load's failure is ignored")
    XCTAssertEqual(inbox.unreadCount, 0)
  }

  @MainActor
  func testAnAwaitedLoadAppliesEvenWhileANewerOneIsStillInFlight() async {
    let fake = demoFake()
    await fake.setWorkspace(DemoIDs.mekari)
    let inbox = InboxStore(api: fake)
    await fake.hold(.notifications)
    async let mine: Void = inbox.load()                  // e.g. the view's .task
    await waitUntil("first load in flight") { await fake.parkedCount(.notifications) == 1 }
    async let poll: Void = inbox.load()                  // the poller starts right after
    await waitUntil("second load in flight") { await fake.parkedCount(.notifications) == 2 }
    await fake.release(.notifications)                   // the older one answers first
    await mine
    XCTAssertEqual(inbox.phase, .loaded)
    XCTAssertEqual(inbox.unreadCount, 1)
    await fake.release(.notifications, all: true)
    await poll
    XCTAssertEqual(inbox.phase, .loaded)
  }

  @MainActor
  func testAFailedMarkReadDoesNotRevertOverANewerLoad() async {
    let fake = demoFake()
    await fake.setWorkspace(DemoIDs.mekari)
    let inbox = InboxStore(api: fake)
    await inbox.load()
    let unread = inbox.notifications.first { !$0.read }!.id
    await fake.hold(.markRead)
    async let mark: Void = inbox.markRead(unread)
    await waitUntil("mark in flight") { await fake.parkedCount(.markRead) == 1 }
    await inbox.load()                                   // server still says unread: 1
    await fake.failNext(.markRead, with: .transport())
    await fake.release(.markRead, all: true)
    await mark
    XCTAssertEqual(inbox.unreadCount, 1, "no double revert (would be 2)")
    XCTAssertEqual(inbox.lastError?.code, .transport)
  }
}

final class SmallReviewFixTests: XCTestCase {
  @MainActor
  func testTextTypedWhileSendingIsKept() async {
    let fake = demoFake()
    let store = TaskDetailStore(api: fake, tasks: TaskCache(api: fake), taskID: DemoIDs.taskWithStories, me: alice,
                                workspaceRole: .member, clock: TestClock())
    await store.load()
    await fake.hold(.addComment)
    store.composer.draft = "First"
    async let send: Void = store.composer.send()
    await waitUntil("send in flight") { await fake.parkedCount(.addComment) == 1 }
    store.composer.draft = "First and more"
    await fake.release(.addComment, all: true)
    await send
    XCTAssertEqual(store.composer.draft, "and more")
  }

  @MainActor
  func testAFailedRoleLookupMeansReadOnly() async {
    let fake = demoFake()
    await fake.failNext(.project, with: .transport())
    let store = TaskDetailStore(api: fake, tasks: TaskCache(api: fake), taskID: DemoIDs.taskWithStories, me: alice,
                                workspaceRole: .member)
    await store.load()
    XCTAssertNotNil(store.task)
    XCTAssertFalse(store.canEdit)
  }

  @MainActor
  func testRapidShowCompletedTogglesEndOnTheLastChoice() async {
    let fake = demoFake()
    await fake.setWorkspace(DemoIDs.mekari)
    let store = MyTasksStore(api: fake, tasks: TaskCache(api: fake), me: alice, calendar: TestTime.calendar, now: { TestTime.now })
    await store.refresh()
    await fake.hold(.myTasks)
    store.showCompleted = true
    await waitUntil("first reload in flight") { await fake.parkedCount(.myTasks) == 1 }
    store.showCompleted = false
    await waitUntil("second reload in flight") { await fake.parkedCount(.myTasks) == 2 }
    // The second (incl. completed = false) answers first; the first's later answer must not win.
    let first = store.loadedTaskIDs
    await fake.release(.myTasks, newest: true)
    await waitUntil("second applied") { await fake.parkedCount(.myTasks) == 1 }
    await settle()
    await fake.release(.myTasks, all: true)
    await settle()
    let completedIDs = await fake.currentTasks().filter { $0.completed && $0.assignee?.id == DemoIDs.alice }.map(\.id)
    XCTAssertFalse(completedIDs.isEmpty)
    XCTAssertTrue(Set(store.loadedTaskIDs).isDisjoint(with: completedIDs), "the stale include-completed load was dropped")
    XCTAssertEqual(Set(store.loadedTaskIDs), Set(first))
    XCTAssertNil(store.lastError)
  }

  @MainActor
  func testUserSearchSurfacesErrors() async {
    let fake = demoFake()
    await fake.setWorkspace(DemoIDs.mekari)
    let clock = TestClock()
    let search = UserSearch(api: fake, clock: clock)
    await fake.failNext(.users, with: APIError(code: .internal, status: 500, message: "Boom"))
    search.query = "bo"
    await clock.advance(by: .milliseconds(250))
    XCTAssertEqual(search.lastError?.message, "Boom")
    XCTAssertFalse(search.isLoading)
  }

  @MainActor
  func testWhitespaceOnlyQueryChangesDoNotSearchAgain() async {
    let fake = demoFake()
    await fake.setWorkspace(DemoIDs.mekari)
    let clock = TestClock()
    let search = SearchStore(api: fake, clock: clock)
    search.query = "login"
    await clock.advance(by: .milliseconds(250))
    search.query = "login  "
    search.query = "  login"
    await clock.advance(by: .milliseconds(250))
    let calls = await fake.calls.filter { $0.endpoint == .search }.count
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(search.results?.tasks.map(\.title), ["Fix login redirect"])
  }
}

final class ReReviewTests: XCTestCase {
  @MainActor
  func testCanEditIsFalseUntilTheProjectRoleIsKnown() async {
    let fake = demoFake()
    let store = TaskDetailStore(api: fake, tasks: TaskCache(api: fake), taskID: DemoIDs.taskWithStories, me: alice,
                                workspaceRole: .member)
    await fake.hold(.project)
    async let load: Void = store.load()
    await waitUntil("role lookup in flight") { await fake.parkedCount(.project) == 1 }
    XCTAssertFalse(store.canEdit, "no editable flash before the role is known")
    await fake.release(.project, all: true)
    await load
    XCTAssertTrue(store.canEdit)
  }

  @MainActor
  func testDeletedTasksStayDeletedWhenAnOlderListArrives() async throws {
    let fake = demoFake()
    await fake.setWorkspace(DemoIDs.mekari)
    let cache = TaskCache(api: fake)
    let list = try await fake.projectTasks(DemoIDs.boardProject, completed: nil)
    cache.upsert(list)
    let id = list[0].id
    cache.remove(id)
    cache.upsert(list)                                   // a slow load from before the delete
    XCTAssertNil(cache[id])
  }

  @MainActor
  func crowdedStore(_ fake: FakeMekariAPI) async throws -> (ProjectStore, TaskCache, [String]) {
    let cache = TaskCache(api: fake)
    let store = ProjectStore(api: fake, tasks: cache, projectID: DemoIDs.boardProject, workspaceRole: .member)
    await store.load()
    let todo = store.taskIDs(in: store.sections[0].id)
    try await cache.update(todo[0], TaskChanges(position: 1))
    try await cache.update(todo[1], TaskChanges(position: 1 + 1e-7))
    return (store, cache, todo)
  }

  @MainActor
  func testAFailedRenumberPatchIsRetriedOnce() async throws {
    let fake = demoFake()
    let (store, cache, todo) = try await crowdedStore(fake)
    await fake.failNext(.updateTask, with: .transport()) // the first PATCH of the renumber fails once
    await store.move(taskID: todo[3], toSection: store.sections[0].id, before: todo[1])
    XCTAssertNil(store.lastError)
    XCTAssertEqual(store.taskIDs(in: store.sections[0].id), [todo[0], todo[3], todo[1], todo[2]])
    XCTAssertEqual(store.taskIDs(in: store.sections[0].id).compactMap { cache[$0]?.position }, [1000, 2000, 3000, 4000])
  }

  @MainActor
  func testARenumberThatStillFailsReloadsAndSaysSo() async throws {
    let fake = demoFake()
    let (store, _, todo) = try await crowdedStore(fake)
    await fake.failNext(.updateTask, with: .transport(), times: 100) // every PATCH fails, retries too
    await store.move(taskID: todo[3], toSection: store.sections[0].id, before: todo[1])
    XCTAssertEqual(store.lastError?.message, "Couldn't reorder; try again")
    let server = try await fake.projectTasks(DemoIDs.boardProject, completed: nil)
      .filter { $0.sectionId == store.sections[0].id }.sorted { $0.position < $1.position }.map(\.id)
    XCTAssertEqual(store.taskIDs(in: store.sections[0].id), server, "the screen shows the server's order")
  }

  @MainActor
  func testScopeCanEditTaskFailsClosed() async throws {
    let fake = demoFake()
    let session = await signedInSession(fake)
    let scope = try XCTUnwrap(session.scope)
    let tasks = await fake.currentTasks()
    let personal = try XCTUnwrap(tasks.first { $0.projectId == nil && $0.workspaceId == DemoIDs.mekari })
    let editable = try XCTUnwrap(tasks.first { $0.projectId == DemoIDs.boardProject })
    let readOnly = try XCTUnwrap(tasks.first { $0.projectId == DemoIDs.readOnlyProject })

    XCTAssertTrue(scope.canEdit(task: personal))
    XCTAssertFalse(scope.canEdit(task: editable), "sidebar not loaded yet: fail closed")
    await scope.sidebar.load()
    XCTAssertTrue(scope.canEdit(task: editable))
    XCTAssertFalse(scope.canEdit(task: readOnly)) // alice is COMMENTER there

    let admin = await signedInSession(demoFake(as: "admin@example.com"))
    XCTAssertTrue(admin.scope?.canEdit(task: readOnly) ?? false)
  }
}

