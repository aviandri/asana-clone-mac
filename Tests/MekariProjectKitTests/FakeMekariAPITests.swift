import Foundation
import XCTest
@testable import MekariProjectKit

final class FakeMekariAPITests: XCTestCase {
  let today = LocalDate(year: 2026, month: 10, day: 18)

  func fake(as email: String? = "alice@example.com") -> FakeMekariAPI {
    FakeMekariAPI(seed: .demo(today: today), signedInAs: email)
  }

  func code(_ body: () async throws -> Void) async -> APIError.Code? {
    do {
      try await body()
      return nil
    } catch let error as APIError {
      return error.code
    } catch {
      return .unknown("\(error)")
    }
  }

  func testSignedOutBootAndLogin() async throws {
    let api = fake(as: nil)
    let hasSession = await api.hasSession
    XCTAssertFalse(hasSession)
    try await api.health()
    let wrong = await code { _ = try await api.login(email: "alice@example.com", password: "nope") }
    XCTAssertEqual(wrong, .unauthorized)
    let me = try await api.login(email: "Alice@Example.com", password: DemoIDs.password)
    XCTAssertEqual(me.id, DemoIDs.alice)
    XCTAssertEqual(me.workspaces.map(\.name), ["Acme Pilot", "Mekari"])
    XCTAssertEqual(me.workspaces.first?.myRole, .admin)
    XCTAssertNotNil(me.currentWorkspace)
  }

  func testWorkspaceHeaderScopesCollectionsAndLostAccessEmitsAnEvent() async throws {
    let api = fake()
    await api.setWorkspace(DemoIDs.mekari)
    let mekari = try await api.projects(archived: false).map(\.name)
    XCTAssertEqual(mekari, ["Mobile App v2", "Website Redesign"]) // not the Marketing TEAM project
    await api.setWorkspace(DemoIDs.acmePilot)
    let acme = try await api.projects(archived: false).map(\.name)
    XCTAssertEqual(acme, ["Pilot Rollout"])

    var events = api.events.makeAsyncIterator()
    await api.removeMembership(userID: DemoIDs.alice, workspaceID: DemoIDs.acmePilot)
    let lost = await code { _ = try await api.myTasks(includeCompleted: false) }
    XCTAssertEqual(lost, .notFound)
    let event = await events.next()
    XCTAssertEqual(event, .workspaceLost(workspaceID: DemoIDs.acmePilot))
    // ID-addressed endpoints ignore the header.
    let task = try await api.task(DemoIDs.taskWithStories)
    XCTAssertEqual(task.workspaceId, DemoIDs.mekari)
  }

  func testMyTasksCoverEveryBucket() async throws {
    let api = fake()
    await api.setWorkspace(DemoIDs.mekari)
    let tasks = try await api.myTasks(includeCompleted: false)
    let offsets = Set(tasks.map { $0.dueDate.map { $0.days(since: today) } })
    XCTAssertTrue(offsets.contains { ($0 ?? 0) < 0 }, "overdue")
    XCTAssertTrue(offsets.contains(0), "today")
    XCTAssertTrue(offsets.contains { (1...7).contains($0 ?? -99) }, "upcoming")
    XCTAssertTrue(offsets.contains { ($0 ?? 0) > 7 }, "later")
    XCTAssertTrue(offsets.contains(nil), "no date")
    XCTAssertTrue(tasks.allSatisfy { !$0.completed && $0.assignee?.id == DemoIDs.alice })
    let all = try await api.myTasks(includeCompleted: true)
    XCTAssertGreaterThan(all.count, tasks.count)
  }

  func testCommenterIsReadOnly() async throws {
    let api = fake()
    let project = try await api.project(DemoIDs.readOnlyProject)
    XCTAssertEqual(project.myRole, .commenter)
    let create = await code { _ = try await api.createTask(NewTask(title: "x", projectId: DemoIDs.readOnlyProject)) }
    XCTAssertEqual(create, .forbidden)
    let task = try await api.projectTasks(DemoIDs.readOnlyProject, completed: nil).first!
    let edit = await code { _ = try await api.updateTask(task.id, TaskChanges(title: "y")) }
    XCTAssertEqual(edit, .forbidden)
    // Commenting is still allowed.
    let comment = try await api.addComment(taskID: task.id, body: "Looks good")
    XCTAssertEqual(comment.body, "Looks good")
  }

  func testGuestSeesOnlyTheirProjectAndCoMembers() async throws {
    let api = fake(as: DemoIDs.guestEmail)
    await api.setWorkspace(DemoIDs.acmePilot)
    let projects = try await api.projects(archived: false)
    XCTAssertEqual(projects.map(\.id), [DemoIDs.pilotProject])
    let users = try await api.users(query: nil)
    XCTAssertEqual(Set(users.map(\.id)), [DemoIDs.alice, DemoIDs.guest]) // bob isn't on the project
    XCTAssertTrue(users.first { $0.id == DemoIDs.guest }!.isGuest)
    let mekari = await code { _ = try await api.project(DemoIDs.boardProject) }
    XCTAssertEqual(mekari, .notFound)
  }

  func testCreateUpdateAndNotify() async throws {
    let api = fake()
    await api.setWorkspace(DemoIDs.mekari)
    let created = try await api.createTask(NewTask(title: "  Ship it  ", projectId: DemoIDs.boardProject, assigneeId: DemoIDs.bob))
    XCTAssertEqual(created.title, "Ship it")
    XCTAssertEqual(created.workspaceId, DemoIDs.mekari)
    XCTAssertEqual(Set(created.followers.map(\.id)), [DemoIDs.alice, DemoIDs.bob])

    let bad = await code { _ = try await api.createTask(NewTask(title: "x", assigneeId: DemoIDs.guest)) }
    XCTAssertEqual(bad, .validation) // the guest isn't in Mekari

    let done = try await api.updateTask(created.id, TaskChanges(dueDate: .set(today), completed: true))
    XCTAssertTrue(done.completed)
    XCTAssertEqual(done.dueDate, today)
    let cleared = try await api.updateTask(created.id, TaskChanges(assigneeId: .clear, dueDate: .clear))
    XCTAssertNil(cleared.assignee)
    XCTAssertNil(cleared.dueDate)

    let stories = try await api.stories(taskID: created.id)
    XCTAssertTrue(stories.contains { if case .activity(let a) = $0 { return a.type == .completed } else { return false } })
  }

  func testCommentsMentionAndInbox() async throws {
    let api = fake()
    await api.setWorkspace(DemoIDs.mekari)
    let before = try await api.notifications(unreadOnly: false, limit: 50)
    XCTAssertEqual(before.unreadCount, 1)
    try await api.markAllRead()
    let after = try await api.notifications(unreadOnly: true, limit: 50)
    XCTAssertEqual(after.unreadCount, 0)
    XCTAssertEqual(after.data, [])

    let detail = try await api.task(DemoIDs.taskWithStories)
    XCTAssertEqual(detail.subtasks.count, 2)
    XCTAssertEqual(detail.followers.count, 3)
    let stories = try await api.stories(taskID: DemoIDs.taskWithStories)
    let mentions = stories.compactMap { story -> Comment? in if case .comment(let c) = story { return c } else { return nil } }
      .flatMap(\.segments).filter { if case .mention = $0 { return true } else { return false } }
    XCTAssertEqual(mentions, [.mention(name: "Bob Smith", userID: DemoIDs.bob)])

    let comment = try await api.addComment(taskID: DemoIDs.taskWithStories, body: "Thanks!")
    let edited = try await api.editComment(comment.id, body: "Thanks a lot!")
    XCTAssertNotNil(edited.editedAt)
    try await api.deleteComment(comment.id)
    let afterDelete = try await api.stories(taskID: DemoIDs.taskWithStories)
    XCTAssertFalse(afterDelete.contains { $0.id == "comment-\(comment.id)" })
  }

  func testSearchNeedsTwoCharactersAndRespectsVisibility() async throws {
    let api = fake()
    await api.setWorkspace(DemoIDs.mekari)
    let short = await code { _ = try await api.search("a") }
    XCTAssertEqual(short, .validation)
    let results = try await api.search("web")
    XCTAssertEqual(results.tasks.map(\.title), [])   // "Webinar landing page" is in a TEAM project alice can't see
    let login = try await api.search("LOGIN")
    XCTAssertEqual(login.tasks.map(\.title), ["Fix login redirect"])
    let people = try await api.search("bob")
    XCTAssertEqual(people.users.map(\.name), ["Bob Smith"])
  }

  func testKnobs() async throws {
    let api = fake()
    await api.failNext(.updateTask, with: APIError(code: .conflict, status: 409, message: "Nope"))
    let failed = await code { _ = try await api.updateTask(DemoIDs.taskWithStories, TaskChanges(title: "x")) }
    XCTAssertEqual(failed, .conflict)
    _ = try await api.updateTask(DemoIDs.taskWithStories, TaskChanges(title: "x")) // only once
    let calls = await api.calls.map(\.endpoint)
    XCTAssertEqual(calls, [.updateTask, .updateTask])

    var events = api.events.makeAsyncIterator()
    await api.failNext(.me, with: APIError(code: .unauthorized, status: 401, message: "Expired"))
    _ = try? await api.me()
    let event = await events.next()
    XCTAssertEqual(event, .unauthorized)
    let hasSession = await api.hasSession
    XCTAssertFalse(hasSession)
  }

  func testNoWorkspaceIs403() async throws {
    let api = FakeMekariAPI(seed: .demo(today: today), signedInAs: "alice@example.com")
    await api.removeMembership(userID: DemoIDs.alice, workspaceID: DemoIDs.mekari)
    await api.removeMembership(userID: DemoIDs.alice, workspaceID: DemoIDs.acmePilot)
    do {
      _ = try await api.myTasks(includeCompleted: false)
      XCTFail("expected an error")
    } catch let error as APIError {
      XCTAssertTrue(error.isNoWorkspace)
    }
    let me = try await api.me()
    XCTAssertNil(me.currentWorkspace)
  }

  func testMovingATaskBetweenProjectsFollowsTheBERules() async throws {
    let api = fake()
    await api.setWorkspace(DemoIDs.mekari)
    let task = try await api.projectTasks(DemoIDs.boardProject, completed: false).first { $0.title == "Tablet layout" }!
    XCTAssertNotNil(task.sectionId)

    // Into a project in another workspace (alice can see it as Acme Pilot's ADMIN): 400.
    let crossWorkspace = await code { _ = try await api.updateTask(task.id, TaskChanges(projectId: .set(DemoIDs.pilotProject))) }
    XCTAssertEqual(crossWorkspace, .validation)
    // Into a project where alice is COMMENTER: 403.
    let readOnly = await code { _ = try await api.updateTask(task.id, TaskChanges(projectId: .set(DemoIDs.readOnlyProject))) }
    XCTAssertEqual(readOnly, .forbidden)
    // Into a project she can't see: 404.
    let hidden = await code { _ = try await api.updateTask(task.id, TaskChanges(projectId: .set(DemoIDs.campaignProject))) }
    XCTAssertEqual(hidden, .notFound)
    // Subtasks move with their parent, never alone.
    let subtask = try await api.task(DemoIDs.taskWithStories).subtasks[0]
    let alone = await code { _ = try await api.updateTask(subtask.id, TaskChanges(projectId: .clear)) }
    XCTAssertEqual(alone, .validation)

    // Becoming a personal task drops the old section; the parent's subtasks follow.
    let personal = try await api.updateTask(DemoIDs.taskWithStories, TaskChanges(projectId: .clear))
    XCTAssertNil(personal.projectId)
    XCTAssertNil(personal.sectionId)
    XCTAssertTrue(personal.subtasks.allSatisfy { $0.projectId == nil })
  }

  func testUnassigningRecordsActivity() async throws {
    let api = fake()
    _ = try await api.updateTask(DemoIDs.taskWithStories, TaskChanges(assigneeId: .clear))
    let stories = try await api.stories(taskID: DemoIDs.taskWithStories)
    guard case .activity(let last)? = stories.last else { return XCTFail("no activity") }
    XCTAssertEqual(last.type, .unassigned)
    XCTAssertEqual(last.data["assigneeId"]?.stringValue, DemoIDs.alice)
  }

  func testMentioningANonMemberIs400() async throws {
    let api = fake()
    let guestSummary = UserSummary(id: DemoIDs.guest, name: "Gita Guest", email: DemoIDs.guestEmail, avatarColor: "#aa62e3")
    let result = await code { _ = try await api.addComment(taskID: DemoIDs.taskWithStories, body: "hi \(Mentions.token(for: guestSummary))") }
    XCTAssertEqual(result, .validation) // the guest isn't in Mekari
  }
}
