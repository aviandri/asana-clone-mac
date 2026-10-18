import Foundation
import XCTest
import MekariProjectKit
@testable import MekariProjectFeatures

/// The PR 5 app flows end to end against a real, freshly seeded BE: inbox round trips, search groups,
/// quick add, and board moves that persist. Skipped unless `MP_BASE_URL` is set. Each test makes its
/// own data and cleans up what it can, so the tests don't depend on each other or on order.
final class AppFlowContractTests: XCTestCase {
  var server: URL!

  override func setUpWithError() throws {
    guard let raw = ProcessInfo.processInfo.environment["MP_BASE_URL"], let url = ServerURL.normalize(raw) else {
      throw XCTSkip("MP_BASE_URL not set")
    }
    server = url
  }

  /// A signed-in session on `workspace` (by name).
  @MainActor
  func session(_ email: String, in workspace: String = "Mekari") async throws -> (AppSession, WorkspaceScope) {
    let session = AppSession(settings: InMemoryServerSettings(), tokens: InMemoryTokenStore(),
                             apiFactory: { url, tokens in LiveMekariAPI(baseURL: url, tokens: tokens) })
    await session.signIn(server: server.absoluteString, email: email, password: "password123")
    XCTAssertNil(session.signInError)
    let target = try XCTUnwrap(session.all.first { $0.name == workspace }, "\(email) isn't in \(workspace)")
    await session.switchWorkspace(to: target.id)
    let scope = try XCTUnwrap(session.scope)
    XCTAssertEqual(scope.id, target.id)
    scope.poller.stop() // the tests drive the inbox themselves
    return (session, scope)
  }

  @MainActor
  func project(named name: String, in scope: WorkspaceScope) async throws -> ProjectStore {
    await scope.sidebar.load()
    let id = try XCTUnwrap(scope.sidebar.projects.first { $0.name == name }?.id, "no project \(name)")
    let store = scope.project(id)
    await store.load()
    XCTAssertEqual(store.phase, .loaded)
    return store
  }

  /// A fresh store over a fresh cache: what a new window (or the next launch) would load.
  @MainActor
  func reloaded(_ store: ProjectStore, _ session: AppSession) async -> ProjectStore {
    let api = session.currentAPI!
    let fresh = ProjectStore(api: api, tasks: TaskCache(api: api), projectID: store.projectID, workspaceRole: session.current!.myRole)
    await fresh.load()
    return fresh
  }

  // MARK: - Inbox

  @MainActor
  func testInboxMarkReadAndMarkAllReadRoundTrip() async throws {
    let (alice, aliceScope) = try await session("alice@example.com")
    let (bob, bobScope) = try await session("bob@example.com")
    let bobMe = try XCTUnwrap(bob.me)

    // Bob starts with an empty inbox.
    await bobScope.inbox.load()
    await bobScope.inbox.markAllRead()
    XCTAssertNil(bobScope.inbox.lastError)

    // Alice gives Bob two notifications: an assignment and a mention.
    let board = try await project(named: "Mobile App v2", in: aliceScope)
    await board.addTask(title: "Inbox flow task", section: board.sections[0].id)
    let taskID = try XCTUnwrap(board.taskIDs(in: board.sections[0].id).first { aliceScope.tasks[$0]?.title == "Inbox flow task" })
    let detail = aliceScope.taskDetail(taskID)
    await detail.load()
    await detail.setAssignee(bobMe.user.summary)
    detail.composer.draft = "Over to you \(Mentions.token(for: bobMe.user.summary))"
    await detail.composer.send()
    XCTAssertNil(detail.lastError)
    XCTAssertNil(detail.composer.lastError)

    await bobScope.inbox.load()
    let fresh = bobScope.inbox.notifications.filter { $0.task?.id == taskID && !$0.read }
    XCTAssertEqual(Set(fresh.map(\.type)), [.assigned, .mentioned])
    XCTAssertEqual(bobScope.inbox.unreadCount, 2)

    // Opening one marks it read on the server and points at the task.
    let mention = try XCTUnwrap(fresh.first { $0.type == .mentioned })
    let target = await bobScope.inbox.open(mention.id)
    XCTAssertEqual(target, .task(id: taskID, projectID: board.projectID))
    XCTAssertEqual(bobScope.inbox.unreadCount, 1)
    let afterOpen = InboxStore(api: bob.currentAPI!)
    await afterOpen.load()
    XCTAssertEqual(afterOpen.notifications.first { $0.id == mention.id }?.read, true)
    XCTAssertEqual(afterOpen.unreadCount, 1)

    // Mark all read sticks too.
    await bobScope.inbox.markAllRead()
    XCTAssertNil(bobScope.inbox.lastError)
    let afterAll = InboxStore(api: bob.currentAPI!)
    await afterAll.load()
    XCTAssertEqual(afterAll.unreadCount, 0)
    XCTAssertTrue(afterAll.notifications.filter { $0.task?.id == taskID }.allSatisfy(\.read))

    try await alice.currentAPI!.deleteTask(taskID)
  }

  // MARK: - Search

  @MainActor
  func testSearchGroupsAndVisibility() async throws {
    let (alice, _) = try await session("alice@example.com")
    let search = SearchStore(api: alice.currentAPI!, clock: ImmediateClock())

    func run(_ query: String) async throws -> SearchResults {
      search.query = query
      for _ in 0..<500 where search.isSearching { try await Task.sleep(for: .milliseconds(5)) }
      return try XCTUnwrap(search.results, "no results for \(query)")
    }

    let projects = try await run("mobile")
    XCTAssertTrue(projects.projects.contains { $0.name == "Mobile App v2" })
    XCTAssertTrue(projects.users.isEmpty)

    let people = try await run("bob")
    XCTAssertEqual(people.users.map(\.name), ["Bob Smith"])
    XCTAssertTrue(people.users.allSatisfy { !$0.email.isEmpty }, "people open mailto:")

    let tasks = try await run("onboarding")  // BE seed: "Onboarding screens" in Mobile App v2
    let task = try XCTUnwrap(tasks.tasks.first { $0.title == "Onboarding screens" })
    XCTAssertEqual(task.project?.name, "Mobile App v2")
    XCTAssertEqual(search.target(forTask: task.id), .task(id: task.id, projectID: task.projectId))

    let nothing = try await run("zzzz-no-such-thing")
    XCTAssertTrue(nothing.isEmpty)
    XCTAssertTrue(search.isEmpty)

    search.query = "a" // below the minimum: no request, no results
    XCTAssertNil(search.results)

    // A guest only finds their own project and co-members (W1/W8).
    let (guest, _) = try await session("guest@partner.test", in: "Acme Pilot")
    let guestSearch = SearchStore(api: guest.currentAPI!, clock: ImmediateClock())
    guestSearch.query = "pilot"
    for _ in 0..<500 where guestSearch.isSearching { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(guestSearch.results?.projects.map(\.name), ["Pilot Rollout"])
    guestSearch.query = "bob"
    for _ in 0..<500 where guestSearch.isSearching { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(guestSearch.results?.users, [], "bob isn't on the guest's project")
  }

  // MARK: - Quick add

  @MainActor
  func testQuickAddCreatesAPersonalTaskAssignedToMe() async throws {
    let (alice, scope) = try await session("alice@example.com")
    let me = try XCTUnwrap(alice.me)
    await scope.myTasks.refresh()
    let today = LocalDate.today()

    scope.quickAdd.title = "  Quick add contract task  "
    scope.quickAdd.dueDate = today
    await scope.quickAdd.submit()
    XCTAssertNil(scope.quickAdd.lastError)
    XCTAssertEqual(scope.quickAdd.title, "")
    XCTAssertNil(scope.quickAdd.dueDate)

    let id = try XCTUnwrap(scope.myTasks.dueSoon.first { scope.tasks[$0]?.title == "Quick add contract task" })
    let saved = try await alice.currentAPI!.task(id)
    XCTAssertNil(saved.projectId)
    XCTAssertEqual(saved.assignee?.id, me.id)
    XCTAssertEqual(saved.dueDate, today)
    XCTAssertEqual(saved.workspaceId, scope.id)

    // A fresh My Tasks (next launch) has it under Today.
    let api = alice.currentAPI!
    let fresh = MyTasksStore(api: api, tasks: TaskCache(api: api), me: me.user.summary)
    await fresh.refresh()
    XCTAssertTrue(fresh.groups.first { $0.bucket == .today }?.taskIDs.contains(id) ?? false)

    try await api.deleteTask(id)
  }

  // MARK: - Board moves

  @MainActor
  func testBoardMovesAcrossSectionsPersistAfterReload() async throws {
    let (alice, scope) = try await session("alice@example.com")
    let board = try await project(named: "Mobile App v2", in: scope)
    XCTAssertTrue(board.canEdit)
    let (todo, doing) = (board.sections[0].id, board.sections[1].id)

    // Three fresh cards at the end of "To do".
    var cards: [String] = []
    for title in ["Board card A", "Board card B", "Board card C"] {
      await board.addTask(title: title, section: todo)
      cards.append(try XCTUnwrap(board.taskIDs(in: todo).last))
    }
    let (a, b, c) = (cards[0], cards[1], cards[2])
    let doingBefore = board.taskIDs(in: doing)

    // C to the top of "In progress", A to its end, B before C.
    await board.move(taskID: c, toSection: doing, before: doingBefore.first)
    await board.move(taskID: a, toSection: doing, before: nil)
    await board.move(taskID: b, toSection: doing, before: c)
    XCTAssertNil(board.lastError)
    let expected = [b, c] + doingBefore + [a]
    XCTAssertEqual(board.taskIDs(in: doing), expected)
    XCTAssertTrue(Set(board.taskIDs(in: todo)).isDisjoint(with: cards))

    // Reloaded from the server: same order, sections and positions persisted.
    let fresh = await reloaded(board, alice)
    XCTAssertEqual(fresh.taskIDs(in: doing), expected)
    let api = alice.currentAPI!
    for id in cards {
      let saved = try await api.task(id)
      XCTAssertEqual(saved.sectionId, doing, saved.title)
    }
    let positions = try await api.projectTasks(board.projectID, completed: nil)
      .filter { $0.sectionId == doing }.sorted { $0.position < $1.position }.map(\.id)
    XCTAssertEqual(positions.filter { expected.contains($0) }, expected)

    // Moving within a column, and a no-op move, also persist (and the no-op sends nothing).
    await board.move(taskID: a, toSection: doing, before: b)
    await board.move(taskID: a, toSection: doing, before: b)
    let again = await reloaded(board, alice)
    XCTAssertEqual(again.taskIDs(in: doing).first, a)

    for id in cards { try await api.deleteTask(id) }
  }
}
