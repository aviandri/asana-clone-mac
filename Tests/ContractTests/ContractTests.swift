import Foundation
import XCTest
import MekariProjectKit

/// `LiveMekariAPI` against a real, freshly seeded BE (`npm run seed`). Skipped unless `MP_BASE_URL`
/// is set, e.g. `MP_BASE_URL=http://127.0.0.1:3000 swift test --filter ContractTests`.
/// Never point this at a shared database: it creates tasks and comments.
final class ContractTests: XCTestCase {
  static let password = "password123"

  var server: URL!

  override func setUpWithError() throws {
    guard let raw = ProcessInfo.processInfo.environment["MP_BASE_URL"], let url = ServerURL.normalize(raw) else {
      throw XCTSkip("MP_BASE_URL not set")
    }
    server = url
  }

  /// A signed-in client with its current workspace sent as the header.
  func signIn(_ email: String) async throws -> (LiveMekariAPI, Me) {
    let api = LiveMekariAPI(baseURL: server, tokens: InMemoryTokenStore())
    let me = try await api.login(email: email, password: Self.password)
    await api.setWorkspace(me.currentWorkspace?.id)
    return (api, me)
  }

  func workspace(_ me: Me, named name: String) throws -> Workspace {
    try XCTUnwrap(me.workspaces.first { $0.name == name }, "no workspace \(name)")
  }

  func expectError(_ code: APIError.Code, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
      try await body()
      XCTFail("expected \(code)", file: file, line: line)
    } catch let error as APIError {
      XCTAssertEqual(error.code, code, error.message, file: file, line: line)
    } catch {
      XCTFail("\(error)", file: file, line: line)
    }
  }

  // MARK: - Auth & session

  func testHealthLoginCookieAndMe() async throws {
    let api = LiveMekariAPI(baseURL: server, tokens: InMemoryTokenStore())
    try await api.health()
    await expectError(.unauthorized) { _ = try await api.login(email: "alice@example.com", password: "wrong-password") }
    let me = try await api.login(email: "alice@example.com", password: Self.password)
    XCTAssertEqual(me.name, "Alice Johnson")
    XCTAssertEqual(Set(me.workspaces.map(\.name)), ["Mekari", "Acme Pilot"])
    XCTAssertEqual(me.workspaces.map(\.name), me.workspaces.map(\.name).sorted())
    let hasSession = await api.hasSession
    XCTAssertTrue(hasSession)
    let again = try await api.me()
    XCTAssertEqual(again.id, me.id)
  }

  func testA401ClearsTheSessionAndEmitsAnEvent() async throws {
    let tokens = InMemoryTokenStore(token: "not-a-valid-jwt")
    let api = LiveMekariAPI(baseURL: server, tokens: tokens)
    var events = api.events.makeAsyncIterator()
    await expectError(.unauthorized) { _ = try await api.me() }
    XCTAssertNil(tokens.load())
    let event = await events.next()
    XCTAssertEqual(event, .unauthorized)
  }

  func testLogout() async throws {
    let (api, _) = try await signIn("bob@example.com")
    await api.logout()
    let hasSession = await api.hasSession
    XCTAssertFalse(hasSession)
    await expectError(.unauthorized) { _ = try await api.me() }
  }

  // MARK: - Workspaces

  func testHeaderScopesListsAndSwitchMovesTheDefault() async throws {
    let (api, me) = try await signIn("alice@example.com")
    let mekari = try workspace(me, named: "Mekari")
    let acme = try workspace(me, named: "Acme Pilot")

    await api.setWorkspace(acme.id)
    let acmeProjects = try await api.projects(archived: false).map(\.name)
    XCTAssertEqual(acmeProjects, ["Pilot Rollout"])
    await api.setWorkspace(mekari.id)
    let mekariProjects = try await api.projects(archived: false).map(\.name)
    XCTAssertTrue(mekariProjects.contains("Mobile App v2"))
    XCTAssertFalse(mekariProjects.contains("Pilot Rollout"))

    let switched = try await api.switchWorkspace(acme.id)
    XCTAssertEqual(switched.id, acme.id)
    XCTAssertEqual(switched.myRole, .admin)
    let after = try await api.me()
    XCTAssertEqual(after.currentWorkspace?.id, acme.id)
    _ = try await api.switchWorkspace(mekari.id)
  }

  func testAForeignWorkspaceHeaderIsLostAccess() async throws {
    let (api, _) = try await signIn("admin@example.com")
    let foreign = "00000000-0000-4000-8000-00000000dead"
    await api.setWorkspace(foreign)
    var events = api.events.makeAsyncIterator()
    await expectError(.notFound) { _ = try await api.projects(archived: false) }
    let event = await events.next()
    XCTAssertEqual(event, .workspaceLost(workspaceID: foreign))
    // /auth/me never sends the header, so the session survives.
    let me = try await api.me()
    XCTAssertNotNil(me.currentWorkspace)
  }

  // MARK: - Tasks

  func testMyTasksAndProjectTasksDecode() async throws {
    let (api, _) = try await signIn("alice@example.com")
    let mine = try await api.myTasks(includeCompleted: true)
    XCTAssertFalse(mine.isEmpty)
    XCTAssertTrue(mine.allSatisfy { $0.assignee?.name == "Alice Johnson" })
    let open = try await api.myTasks(includeCompleted: false)
    XCTAssertTrue(open.allSatisfy { !$0.completed })

    let projectCandidates = try await api.projects(archived: false)
    let project = try XCTUnwrap(projectCandidates.first { $0.name == "Mobile App v2" })
    let detail = try await api.project(project.id)
    XCTAssertFalse(detail.sections.isEmpty)
    let tasks = try await api.projectTasks(project.id, completed: nil)
    XCTAssertFalse(tasks.isEmpty)
    XCTAssertTrue(tasks.allSatisfy { $0.parentId == nil && $0.projectId == project.id })
  }

  func testCreatePatchCompleteAndDeleteATask() async throws {
    let (api, me) = try await signIn("alice@example.com")
    let projectCandidates = try await api.projects(archived: false)
    let project = try XCTUnwrap(projectCandidates.first { $0.name == "Mobile App v2" })
    let detail = try await api.project(project.id)
    let section = try XCTUnwrap(detail.sections.first)
    let due = LocalDate.today().adding(days: 3)

    let created = try await api.createTask(NewTask(title: "Contract test task", projectId: project.id, sectionId: section.id,
                                                   assigneeId: me.id, dueDate: due, priority: .medium))
    XCTAssertEqual(created.title, "Contract test task")
    XCTAssertEqual(created.dueDate, due)
    XCTAssertEqual(created.sectionId, section.id)
    XCTAssertEqual(created.workspaceId, project.workspaceId)

    let subtask = try await api.createTask(NewTask(title: "Contract subtask", parentId: created.id))
    XCTAssertEqual(subtask.parentId, created.id)

    let patched = try await api.updateTask(created.id, TaskChanges(title: "Renamed", description: .set("**bold**"),
                                                                    dueDate: .clear, priority: .high, position: 123.5))
    XCTAssertEqual(patched.title, "Renamed")
    XCTAssertEqual(patched.description, "**bold**")
    XCTAssertNil(patched.dueDate)
    XCTAssertEqual(patched.position, 123.5)
    XCTAssertEqual(patched.subtasks.map(\.id), [subtask.id])

    let done = try await api.updateTask(created.id, TaskChanges(completed: true))
    XCTAssertTrue(done.completed)
    XCTAssertNotNil(done.completedAt)

    let unassigned = try await api.updateTask(created.id, TaskChanges(assigneeId: .clear))
    XCTAssertNil(unassigned.assignee)

    await expectError(.validation) { _ = try await api.updateTask(created.id, TaskChanges(title: "")) }
    try await api.deleteTask(created.id)
    await expectError(.notFound) { _ = try await api.task(created.id) }
  }

  func testPersonalTaskAndFollowers() async throws {
    let (api, me) = try await signIn("alice@example.com")
    let users = try await api.users(query: "bob")
    let bob = try XCTUnwrap(users.first)
    XCTAssertEqual(bob.role, .member)
    let task = try await api.createTask(NewTask(title: "Personal contract task", assigneeId: me.id))
    XCTAssertNil(task.projectId)
    let followed = try await api.addFollower(taskID: task.id, userID: bob.id)
    XCTAssertTrue(followed.followers.contains { $0.id == bob.id })
    let unfollowed = try await api.removeFollower(taskID: task.id, userID: bob.id)
    XCTAssertFalse(unfollowed.followers.contains { $0.id == bob.id })
    try await api.deleteTask(task.id)
  }

  // MARK: - Stories, inbox, search

  func testCommentsWithMentionsNotifyAndCanBeEdited() async throws {
    let (alice, _) = try await signIn("alice@example.com")
    let (bob, bobMe) = try await signIn("bob@example.com")
    let projectCandidates = try await alice.projects(archived: false)
    let project = try XCTUnwrap(projectCandidates.first { $0.name == "Mobile App v2" })
    let task = try await alice.createTask(NewTask(title: "Mention contract task", projectId: project.id))

    let bobSummary = UserSummary(id: bobMe.id, name: bobMe.name, email: bobMe.email, avatarColor: bobMe.avatarColor)
    let comment = try await alice.addComment(taskID: task.id, body: "Hi \(Mentions.token(for: bobSummary)), please check")
    XCTAssertTrue(comment.segments.contains(.mention(name: "Bob Smith", userID: bobMe.id)))
    let edited = try await alice.editComment(comment.id, body: "Edited")
    XCTAssertNotNil(edited.editedAt)
    await expectError(.forbidden) { _ = try await bob.editComment(comment.id, body: "Not mine") }

    let stories = try await alice.stories(taskID: task.id)
    XCTAssertTrue(stories.contains { if case .comment(let c) = $0 { return c.id == comment.id } else { return false } })
    XCTAssertTrue(stories.contains { if case .activity(let a) = $0 { return a.type == .created } else { return false } })

    let inbox = try await bob.notifications(unreadOnly: true, limit: 50)
    let mention = try XCTUnwrap(inbox.data.first { $0.task?.id == task.id && $0.type == .mentioned })
    XCTAssertGreaterThan(inbox.unreadCount, 0)
    try await bob.markRead(mention.id)
    let afterRead = try await bob.notifications(unreadOnly: false, limit: 50)
    XCTAssertEqual(afterRead.data.first { $0.id == mention.id }?.read, true)
    try await bob.markAllRead()
    let none = try await bob.notifications(unreadOnly: true, limit: 50)
    XCTAssertEqual(none.unreadCount, 0)

    try await alice.deleteComment(comment.id)
    try await alice.deleteTask(task.id)
  }

  func testSearch() async throws {
    let (api, _) = try await signIn("alice@example.com")
    await expectError(.validation) { _ = try await api.search("a") }
    let results = try await api.search("mobile")
    XCTAssertTrue(results.projects.contains { $0.name == "Mobile App v2" })
    let people = try await api.search("bob")
    XCTAssertTrue(people.users.contains { $0.name == "Bob Smith" })
  }

  // MARK: - Guests (W1, W7, W8)

  func testGuestSeesOnlyTheirProjectAndCoMembersWithRoles() async throws {
    let (guest, me) = try await signIn("guest@partner.test")
    XCTAssertEqual(me.workspaces.map(\.name), ["Acme Pilot"])
    XCTAssertEqual(me.currentWorkspace?.myRole, .guest)
    let projects = try await guest.projects(archived: false)
    XCTAssertEqual(projects.map(\.name), ["Pilot Rollout"])
    XCTAssertEqual(projects.first?.myRole, .editor)

    let users = try await guest.users(query: nil)
    XCTAssertTrue(users.contains { $0.id == me.id && $0.isGuest })
    XCTAssertFalse(users.contains { $0.name == "Bob Smith" }) // not on Pilot Rollout
    XCTAssertTrue(users.contains { $0.name == "Alice Johnson" && $0.role == .admin })

    // As an editor the guest can still create tasks in their project (W7 limits managing, not editing).
    let task = try await guest.createTask(NewTask(title: "Guest contract task", projectId: projects[0].id))
    XCTAssertEqual(task.creator.id, me.id)
    try await guest.deleteTask(task.id)
  }

  func testMembersSeeGuestsBadgedInPickers() async throws {
    let (alice, me) = try await signIn("alice@example.com")
    await alice.setWorkspace(try workspace(me, named: "Acme Pilot").id)
    let users = try await alice.users(query: nil)
    XCTAssertTrue(users.contains { $0.email == "guest@partner.test" && $0.isGuest })
  }
}
