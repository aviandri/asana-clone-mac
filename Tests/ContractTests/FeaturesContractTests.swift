// Swift 5.10's Linux Foundation doesn't mark URL, URLRequest, HTTPURLResponse & co. Sendable yet
// (Darwin's and Swift 6's do), so take its types as pre-concurrency there.
#if canImport(FoundationNetworking) && compiler(<6.0)
@preconcurrency import Foundation
#else
import Foundation
#endif
import XCTest
import MekariProjectKit
@testable import MekariProjectFeatures

/// The Features stores over `LiveMekariAPI` against a real, freshly seeded BE: the same flows the app
/// runs. Skipped unless `MP_BASE_URL` is set. Creates (and mostly deletes) tasks and comments.
final class FeaturesContractTests: XCTestCase {
  var server: URL!

  override func setUpWithError() throws {
    guard let raw = ProcessInfo.processInfo.environment["MP_BASE_URL"], let url = ServerURL.normalize(raw) else {
      throw XCTSkip("MP_BASE_URL not set")
    }
    server = url
  }

  @MainActor
  func session(_ email: String) async throws -> AppSession {
    let session = AppSession(settings: InMemoryServerSettings(), tokens: InMemoryTokenStore(),
                             apiFactory: { url, tokens in LiveMekariAPI(baseURL: url, tokens: tokens) })
    await session.signIn(server: server.absoluteString, email: email, password: "password123")
    XCTAssertNil(session.signInError)
    guard session.scope != nil else { throw XCTSkip("no workspace for \(email)") }
    return session
  }

  @MainActor
  func testSignInErrorsAreMapped() async {
    let session = AppSession(settings: InMemoryServerSettings(), tokens: InMemoryTokenStore(),
                             apiFactory: { url, tokens in LiveMekariAPI(baseURL: url, tokens: tokens) })
    await session.signIn(server: server.absoluteString, email: "alice@example.com", password: "wrong-password")
    XCTAssertEqual(session.signInError, .wrongCredentials)
    await session.signIn(server: "http://127.0.0.1:9", email: "alice@example.com", password: "password123")
    XCTAssertEqual(session.signInError, .transport)
    await session.signIn(server: server.absoluteString, email: "alice@example.com", password: "password123")
    XCTAssertNotNil(session.me)
    await session.signOut()
    XCTAssertEqual(session.state, .signedOut)
  }

  @MainActor
  func testSwitchingWorkspacesAndTheSidebar() async throws {
    let session = try await session("alice@example.com")
    XCTAssertEqual(session.all.map(\.name), ["Acme Pilot", "Mekari"])
    let start = try XCTUnwrap(session.current)

    await session.switchWorkspace(to: session.all.first { $0.name == "Acme Pilot" }!.id)
    XCTAssertEqual(session.current?.name, "Acme Pilot")
    await session.scope?.sidebar.load()
    XCTAssertEqual(session.scope?.sidebar.projects.map(\.name), ["Pilot Rollout"])

    await session.switchWorkspace(to: session.all.first { $0.name == "Mekari" }!.id)
    await session.scope?.sidebar.load()
    XCTAssertTrue(session.scope?.sidebar.projects.contains { $0.name == "Mobile App v2" } ?? false)
    await session.switchWorkspace(to: start.id)
  }

  @MainActor
  func testMyTasksQuickAddAndToggle() async throws {
    let session = try await session("alice@example.com")
    await session.switchWorkspace(to: session.all.first { $0.name == "Mekari" }!.id)
    let scope = try XCTUnwrap(session.scope)
    await scope.myTasks.refresh()
    XCTAssertEqual(scope.myTasks.phase, .loaded)
    XCTAssertFalse(scope.myTasks.groups.isEmpty)

    scope.quickAdd.title = "Contract quick add"
    scope.quickAdd.dueDate = LocalDate.today()
    await scope.quickAdd.submit()
    XCTAssertNil(scope.quickAdd.lastError)
    let id = try XCTUnwrap(scope.myTasks.groups.flatMap(\.taskIDs).first { scope.tasks[$0]?.title == "Contract quick add" })
    XCTAssertTrue(scope.myTasks.dueSoon.contains(id))

    await scope.myTasks.toggleComplete(id)
    XCTAssertEqual(scope.tasks[id]?.completed, true)
    XCTAssertNil(scope.myTasks.lastError)
  }

  @MainActor
  func testProjectMovesAndInspectorEditsPersist() async throws {
    let session = try await session("alice@example.com")
    await session.switchWorkspace(to: session.all.first { $0.name == "Mekari" }!.id)
    let scope = try XCTUnwrap(session.scope)
    await scope.sidebar.load()
    let projectID = try XCTUnwrap(scope.sidebar.projects.first { $0.name == "Mobile App v2" }?.id)
    let project = scope.project(projectID)
    await project.load()
    XCTAssertTrue(project.canEdit)
    XCTAssertGreaterThanOrEqual(project.sections.count, 2)

    await project.addTask(title: "Contract card", section: project.sections[0].id)
    let card = try XCTUnwrap(project.taskIDs(in: project.sections[0].id).last)
    let target = project.taskIDs(in: project.sections[1].id).first
    await project.move(taskID: card, toSection: project.sections[1].id, before: target)
    XCTAssertNil(project.lastError)
    XCTAssertEqual(project.taskIDs(in: project.sections[1].id).first, card)

    // A fresh load from the server agrees.
    let reloaded = ProjectStore(api: LiveMekariAPIProbe.api(of: session), tasks: TaskCache(api: LiveMekariAPIProbe.api(of: session)),
                                projectID: projectID, workspaceRole: session.current!.myRole)
    await reloaded.load()
    XCTAssertEqual(reloaded.taskIDs(in: project.sections[1].id).first, card)

    let detail = scope.taskDetail(card)
    await detail.load()
    await detail.setDueDate(LocalDate.today().adding(days: 2))
    await detail.setPriority(.high)
    await detail.addSubtask(title: "Contract subtask")
    detail.composer.draft = "Done from the contract suite"
    await detail.composer.send()
    XCTAssertNil(detail.lastError)
    XCTAssertNil(detail.composer.lastError)
    XCTAssertEqual(detail.task?.subtasks.count, 1)
    XCTAssertTrue(detail.stories.contains { if case .comment(let c) = $0 { return c.body == "Done from the contract suite" } else { return false } })

    let fresh = TaskDetailStore(api: LiveMekariAPIProbe.api(of: session), tasks: TaskCache(api: LiveMekariAPIProbe.api(of: session)),
                                taskID: card, me: scope.me, workspaceRole: session.current!.myRole)
    await fresh.load()
    XCTAssertEqual(fresh.task?.priority, .high)
    XCTAssertEqual(fresh.task?.dueDate, LocalDate.today().adding(days: 2))
  }

  @MainActor
  func testInboxAndSearchAgainstTheServer() async throws {
    let session = try await session("bob@example.com")
    let scope = try XCTUnwrap(session.scope)
    await scope.inbox.load()
    XCTAssertEqual(scope.inbox.phase, .loaded)
    await scope.inbox.markAllRead()
    XCTAssertNil(scope.inbox.lastError)
    XCTAssertEqual(scope.inbox.unreadCount, 0)

    let search = SearchStore(api: LiveMekariAPIProbe.api(of: session), clock: ImmediateClock())
    search.query = "mobile"
    for _ in 0..<200 where search.results == nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(search.results?.projects.contains { $0.name == "Mobile App v2" } ?? false)
  }

  @MainActor
  func testGuestSessionAndDeepLinkWithoutAccess() async throws {
    let session = try await session("guest@partner.test")
    XCTAssertTrue(session.isGuest)
    await session.scope?.sidebar.load()
    XCTAssertEqual(session.scope?.sidebar.projects.map(\.name), ["Pilot Rollout"])
    let result = await session.resolve(.project(id: "00000000-0000-4000-8000-00000000dead"))
    XCTAssertEqual(result, .noAccess)
  }
}

/// A clock whose sleeps return at once (debounces fire immediately).
struct ImmediateClock: Clock {
  typealias Instant = ContinuousClock.Instant
  var now: Instant { ContinuousClock.now }
  var minimumResolution: Duration { .zero }
  func sleep(until deadline: Instant, tolerance: Duration?) async throws {}
}

/// Reaches the session's API for "fresh from the server" checks.
@MainActor
enum LiveMekariAPIProbe {
  static func api(of session: AppSession) -> any MekariAPI {
    session.currentAPI!
  }
}
