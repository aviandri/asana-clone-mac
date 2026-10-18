import Foundation
import MekariProjectKit
import XCTest
@testable import MekariProjectFeatures

final class MyTasksStoreTests: XCTestCase {
  @MainActor
  func makeStore(_ fake: FakeMekariAPI) async -> (MyTasksStore, TaskCache) {
    await fake.setWorkspace(DemoIDs.mekari)
    let cache = TaskCache(api: fake)
    let store = MyTasksStore(api: fake, tasks: cache, me: alice, calendar: TestTime.calendar, now: { TestTime.now })
    await store.refresh()
    return (store, cache)
  }

  @MainActor
  func testGroupsFollowTheWebBuckets() async {
    let (store, cache) = await makeStore(demoFake())
    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.groups.map(\.bucket), [.overdue, .today, .upcoming, .later, .noDate])
    XCTAssertEqual(store.groups.map(\.title), ["Overdue", "Today", "Upcoming", "Later", "No date"])
    let overdue = store.groups[0].taskIDs.compactMap { cache[$0] }
    XCTAssertEqual(overdue.map(\.title), ["Fix login redirect"])
    let today = store.groups[1].taskIDs.compactMap { cache[$0]?.title }
    XCTAssertEqual(today, ["Prepare 1:1 notes", "Push notification settings"])
    XCTAssertEqual(Set(store.dueSoon), Set(store.groups[0].taskIDs + store.groups[1].taskIDs))
    // Sorted by due date within a bucket.
    let upcoming = store.groups[2].taskIDs.compactMap { cache[$0]?.dueDate }
    XCTAssertEqual(upcoming, upcoming.sorted())
  }

  @MainActor
  func testToggleCompleteIsOptimisticAndRevertsOnFailure() async {
    let fake = demoFake()
    let (store, cache) = await makeStore(fake)
    let id = store.groups[1].taskIDs[0]
    await store.toggleComplete(id)
    XCTAssertEqual(cache[id]?.completed, true)
    XCTAssertFalse(store.groups.flatMap(\.taskIDs).contains(id)) // completed tasks are hidden

    await fake.failNext(.updateTask, with: APIError(code: .forbidden, status: 403, message: "No"))
    await store.toggleComplete(id)
    XCTAssertEqual(cache[id]?.completed, true) // reverted to the server state
    XCTAssertEqual(store.lastError?.message, "No")
    store.clearError()
    XCTAssertNil(store.lastError)
  }

  @MainActor
  func testShowCompletedAddsTheCompletedBucket() async {
    let (store, _) = await makeStore(demoFake())
    store.showCompleted = true
    await settle()
    XCTAssertEqual(store.groups.last?.bucket, .completed)
  }

  @MainActor
  func testAddTaskAndQuickAdd() async {
    let fake = demoFake()
    let (store, cache) = await makeStore(fake)
    await store.addTask(title: "  Water plants ", dueDate: TestTime.today)
    let todayTitles = store.groups.first { $0.bucket == .today }?.taskIDs.compactMap { cache[$0]?.title }
    XCTAssertTrue(todayTitles?.contains("Water plants") ?? false)

    let quick = QuickAddModel(api: fake, me: alice, myTasks: store)
    XCTAssertFalse(quick.canSubmit)
    quick.title = "Call mum"
    await quick.submit()
    XCTAssertEqual(quick.title, "")
    XCTAssertTrue(store.groups.first { $0.bucket == .noDate }?.taskIDs.contains { cache[$0]?.title == "Call mum" } ?? false)
    let created = await fake.currentTasks().first { $0.title == "Call mum" }
    XCTAssertEqual(created?.assignee?.id, DemoIDs.alice)
    XCTAssertNil(created?.projectId)
  }

  @MainActor
  func testReassigningElsewhereDropsTheTaskAtOnce() async {
    let (store, cache) = await makeStore(demoFake())
    let id = store.groups[0].taskIDs[0]
    try? await cache.update(id, TaskChanges(assigneeId: .set(DemoIDs.bob)), assignee: .some(bob))
    XCTAssertFalse(store.groups.flatMap(\.taskIDs).contains(id))
  }
}

final class ProjectStoreTests: XCTestCase {
  @MainActor
  func load(_ projectID: String = DemoIDs.boardProject, fake: FakeMekariAPI = demoFake(), role: WorkspaceRole = .member)
    async -> (ProjectStore, TaskCache, FakeMekariAPI) {
    let cache = TaskCache(api: fake)
    let store = ProjectStore(api: fake, tasks: cache, projectID: projectID, workspaceRole: role)
    await store.load()
    return (store, cache, fake)
  }

  @MainActor
  func titles(_ store: ProjectStore, _ cache: TaskCache, _ section: Int) -> [String] {
    store.taskIDs(in: store.sections[section].id).compactMap { cache[$0]?.title }
  }

  @MainActor
  func testLoadPicksTheDefaultViewAndPermissions() async {
    let (board, _, _) = await load()
    XCTAssertEqual(board.viewMode, .board)
    XCTAssertEqual(board.sections.map(\.name), ["To do", "In progress", "Done"])
    XCTAssertTrue(board.canEdit)

    let (readOnly, _, _) = await load(DemoIDs.readOnlyProject)
    XCTAssertEqual(readOnly.viewMode, .list)
    XCTAssertFalse(readOnly.canEdit)
    let (asAdmin, _, _) = await load(DemoIDs.readOnlyProject, role: .admin)
    XCTAssertTrue(asAdmin.canEdit)
  }

  @MainActor
  func testCompletedTasksAreHiddenUntilShown() async {
    let (store, cache, _) = await load()
    XCTAssertEqual(titles(store, cache, 2), [])
    store.showCompleted = true
    XCTAssertEqual(titles(store, cache, 2), ["Upgrade analytics SDK", "Release 2.0 beta"])
  }

  @MainActor
  func testMoveWithinASectionUsesTheAnchor() async {
    let (store, cache, fake) = await load()
    XCTAssertEqual(titles(store, cache, 0), ["Push notification settings", "Offline mode for task list", "Dark mode QA pass", "Tablet layout"])
    let ids = store.taskIDs(in: store.sections[0].id)

    // Last → first.
    await store.move(taskID: ids[3], toSection: store.sections[0].id, before: ids[0])
    XCTAssertEqual(titles(store, cache, 0), ["Tablet layout", "Push notification settings", "Offline mode for task list", "Dark mode QA pass"])
    // First → end (nil anchor).
    await store.move(taskID: ids[3], toSection: store.sections[0].id, before: nil)
    XCTAssertEqual(titles(store, cache, 0).last, "Tablet layout")

    // No-ops send nothing.
    let before = await fake.calls.count
    await store.move(taskID: ids[1], toSection: store.sections[0].id, before: ids[1])
    await store.move(taskID: ids[1], toSection: store.sections[0].id, before: ids[2]) // already right before it
    await store.move(taskID: ids[3], toSection: store.sections[0].id, before: nil)    // already last
    let after = await fake.calls.count
    XCTAssertEqual(after, before)
  }

  @MainActor
  func testMoveAcrossSectionsAndToNoSection() async {
    let (store, cache, fake) = await load()
    let todo = store.taskIDs(in: store.sections[0].id)
    let doing = store.taskIDs(in: store.sections[1].id)
    await store.move(taskID: todo[0], toSection: store.sections[1].id, before: doing[1])
    XCTAssertEqual(titles(store, cache, 1), ["Fix login redirect", "Push notification settings", "App Store screenshots", "Crash on empty inbox"])
    let saved = await fake.currentTasks().first { $0.id == todo[0] }
    XCTAssertEqual(saved?.sectionId, store.sections[1].id)

    await store.move(taskID: todo[1], toSection: nil, before: nil)
    XCTAssertTrue(store.hasUnsectionedTasks)
    XCTAssertEqual(store.taskIDs(in: nil), [todo[1]])
  }

  @MainActor
  func testCrowdedPositionsAreRenumbered() async {
    let (store, cache, fake) = await load()
    let todo = store.taskIDs(in: store.sections[0].id)
    // Squeeze the first two together.
    try? await cache.update(todo[0], TaskChanges(position: 1))
    try? await cache.update(todo[1], TaskChanges(position: 1 + 1e-7))
    await store.move(taskID: todo[3], toSection: store.sections[0].id, before: todo[1])
    XCTAssertEqual(store.taskIDs(in: store.sections[0].id), [todo[0], todo[3], todo[1], todo[2]])
    let positions = store.taskIDs(in: store.sections[0].id).compactMap { cache[$0]?.position }
    XCTAssertEqual(positions, [1000, 2000, 3000, 4000])
    let server = await fake.currentTasks().first { $0.id == todo[3] }?.position
    XCTAssertEqual(server, 2000)
  }

  @MainActor
  func testFailedMoveRevertsAndReports() async {
    let (store, cache, fake) = await load()
    let todo = store.taskIDs(in: store.sections[0].id)
    await fake.failNext(.updateTask, with: APIError(code: .forbidden, status: 403, message: "Read only"))
    await store.move(taskID: todo[0], toSection: store.sections[1].id, before: nil)
    XCTAssertEqual(store.taskIDs(in: store.sections[0].id), todo)
    XCTAssertEqual(cache[todo[0]]?.sectionId, store.sections[0].id)
    XCTAssertEqual(store.lastError?.message, "Read only")
  }

  @MainActor
  func testAddTaskSectionRenameAndMoveSection() async {
    let (store, cache, _) = await load()
    await store.addTask(title: "New card", section: store.sections[1].id)
    XCTAssertEqual(titles(store, cache, 1).last, "New card")
    await store.addSection(name: "QA")
    XCTAssertEqual(store.sections.map(\.name), ["To do", "In progress", "Done", "QA"])
    await store.renameSection(store.sections[3].id, to: "Testing")
    XCTAssertEqual(store.sections.last?.name, "Testing")
    await store.moveSection(store.sections[3].id, before: store.sections[0].id)
    XCTAssertEqual(store.sections.map(\.name), ["Testing", "To do", "In progress", "Done"])
    await store.moveSection(store.sections[0].id, before: nil)
    XCTAssertEqual(store.sections.map(\.name), ["To do", "In progress", "Done", "Testing"])
  }

  @MainActor
  func testCommenterEditsAreRejected() async {
    let (store, _, _) = await load(DemoIDs.readOnlyProject)
    await store.addTask(title: "Nope", section: store.sections[0].id)
    XCTAssertEqual(store.lastError?.code, .forbidden)
  }
}

final class TaskDetailStoreTests: XCTestCase {
  @MainActor
  func load(_ id: String = DemoIDs.taskWithStories, clock: TestClock = TestClock()) async -> (TaskDetailStore, TaskCache, FakeMekariAPI) {
    let fake = demoFake()
    let cache = TaskCache(api: fake)
    let store = TaskDetailStore(api: fake, tasks: cache, taskID: id, me: alice, workspaceRole: .member, clock: clock)
    await store.load()
    return (store, cache, fake)
  }

  @MainActor
  func testLoadsTaskStoriesAndPermissions() async {
    let (store, _, _) = await load()
    XCTAssertEqual(store.task?.title, "Fix login redirect")
    XCTAssertEqual(store.task?.subtasks.count, 2)
    XCTAssertTrue(store.canEdit)
    XCTAssertTrue(store.isFollowing)
    let comments = store.stories.compactMap { story -> Comment? in if case .comment(let c) = story { return c } else { return nil } }
    XCTAssertEqual(comments.count, 2)
    XCTAssertTrue(comments[0].segments.contains(.mention(name: "Bob Smith", userID: DemoIDs.bob)))
  }

  @MainActor
  func testEditsGoThroughTheCache() async {
    let (store, cache, _) = await load()
    await store.setTitle("  Fix login redirect for SSO ")
    XCTAssertEqual(cache[DemoIDs.taskWithStories]?.title, "Fix login redirect for SSO")
    await store.setAssignee(bob)
    XCTAssertEqual(store.task?.assignee?.id, DemoIDs.bob)
    await store.setDueDate(TestTime.today.adding(days: 1))
    XCTAssertEqual(store.task?.dueDate, TestTime.today.adding(days: 1))
    await store.setDueDate(nil)
    XCTAssertNil(store.task?.dueDate)
    await store.setPriority(.low)
    XCTAssertEqual(store.task?.priority, .low)
    await store.setDescription("   ")
    XCTAssertNil(store.task?.description)
    await store.toggleComplete()
    XCTAssertEqual(store.task?.completed, true)
  }

  @MainActor
  func testSubtasksAndFollowers() async {
    let (store, cache, _) = await load()
    await store.addSubtask(title: "Write a regression test")
    XCTAssertEqual(store.task?.subtasks.map(\.title).last, "Write a regression test")
    let open = store.task!.subtasks.first { !$0.completed }!
    await store.toggleSubtask(open.id)
    XCTAssertEqual(store.task?.subtasks.first { $0.id == open.id }?.completed, true)
    XCTAssertEqual(cache[open.id]?.completed, true)

    await store.unfollow()
    XCTAssertFalse(store.isFollowing)
    await store.follow()
    XCTAssertTrue(store.isFollowing)
  }

  @MainActor
  func testComposerMentionsAndSending() async {
    let clock = TestClock()
    let (store, _, _) = await load(clock: clock)
    let composer = store.composer
    XCTAssertFalse(composer.canSend)
    composer.draft = "Thanks @bo"
    XCTAssertEqual(composer.mentionQuery, "bo")
    await clock.advance(by: .milliseconds(250))
    XCTAssertEqual(composer.users.results.map(\.user.name), ["Bob Smith"])
    composer.insertMention(composer.users.results[0])
    XCTAssertEqual(composer.draft, "Thanks @[Bob Smith](\(DemoIDs.bob)) ")
    XCTAssertNil(composer.mentionQuery)
    composer.draft += "for the fix"
    await composer.send()
    XCTAssertEqual(composer.draft, "")
    guard case .comment(let last)? = store.stories.last else { return XCTFail("no comment") }
    XCTAssertEqual(last.segments, [.text("Thanks "), .mention(name: "Bob Smith", userID: DemoIDs.bob), .text(" for the fix")])

    await store.editComment(last.id, body: "Edited")
    guard case .comment(let edited)? = store.stories.last else { return XCTFail("no comment") }
    XCTAssertEqual(edited.body, "Edited")
    await store.deleteComment(last.id)
    XCTAssertFalse(store.stories.contains { $0.id == "comment-\(last.id)" })
  }

  @MainActor
  func testMentionQueryRules() async {
    let (store, _, _) = await load()
    let c = store.composer
    for (draft, query) in [("@", ""), ("hi @al", "al"), ("mail@al", nil), ("@al ", nil), ("@[Al](1)", nil), ("", nil)] as [(String, String?)] {
      c.draft = draft
      XCTAssertEqual(c.mentionQuery, query, draft)
    }
  }

  @MainActor
  func testReadOnlyForCommenters() async {
    let fake = demoFake()
    await fake.setWorkspace(DemoIDs.mekari)
    let readOnlyTask = await fake.currentTasks().first { $0.projectId == DemoIDs.readOnlyProject }!
    let store = TaskDetailStore(api: fake, tasks: TaskCache(api: fake), taskID: readOnlyTask.id, me: alice, workspaceRole: .member)
    await store.load()
    XCTAssertFalse(store.canEdit)
    await store.setTitle("Nope")
    XCTAssertEqual(store.lastError?.code, .forbidden)
    XCTAssertEqual(store.task?.title, readOnlyTask.title)
  }
}

final class InboxAndSearchTests: XCTestCase {
  @MainActor
  func testInboxMarkReadOpenAndMarkAll() async {
    let fake = demoFake()
    await fake.setWorkspace(DemoIDs.mekari)
    let inbox = InboxStore(api: fake)
    await inbox.load()
    XCTAssertEqual(inbox.unreadCount, 1)
    let unread = inbox.notifications.first { !$0.read }!
    let target = await inbox.open(unread.id)
    XCTAssertEqual(target, .task(id: DemoIDs.taskWithStories, projectID: DemoIDs.boardProject))
    XCTAssertEqual(inbox.unreadCount, 0)

    await fake.failNext(.markAllRead, with: .transport())
    await inbox.load()
    await inbox.markAllRead()
    XCTAssertEqual(inbox.lastError?.code, .transport)
  }

  @MainActor
  func testPollerReportsOnlyNewUnreadAfterTheFirstPoll() async {
    let fake = demoFake()
    await fake.setWorkspace(DemoIDs.mekari)
    let clock = TestClock()
    let inbox = InboxStore(api: fake)
    let poller = NotificationPoller(inbox: inbox, clock: clock)
    var notices: [NotificationPoller.LocalNotice] = []
    poller.onNew = { notices += $0 }
    poller.start()
    await settle()
    XCTAssertEqual(notices, [])          // the first poll only records what's there
    XCTAssertEqual(inbox.unreadCount, 1)

    await fake.addNotification(InboxNotification(
      id: "n-new", workspaceId: DemoIDs.mekari, type: .commented, read: false, createdAt: Date(), actor: bob,
      task: NotificationTaskRef(id: DemoIDs.taskWithStories, title: "Fix login redirect", projectId: DemoIDs.boardProject)),
      for: DemoIDs.alice)
    await clock.advance(by: .seconds(59))
    XCTAssertEqual(notices, [])
    await clock.advance(by: .seconds(1))
    XCTAssertEqual(notices.map(\.title), ["Bob Smith commented on Fix login redirect"])
    XCTAssertEqual(notices.first?.taskID, DemoIDs.taskWithStories)

    poller.setMode(.background)
    await clock.advance(by: .seconds(60)) // still waiting on the 60 s sleep that began before the switch
    let callsBefore = await fake.calls.filter { $0.endpoint == .notifications }.count
    await clock.advance(by: .seconds(120))
    let callsMid = await fake.calls.filter { $0.endpoint == .notifications }.count
    XCTAssertEqual(callsMid, callsBefore) // background: 5 minutes
    await clock.advance(by: .seconds(180))
    let callsAfter = await fake.calls.filter { $0.endpoint == .notifications }.count
    XCTAssertEqual(callsAfter, callsBefore + 1)

    poller.setMode(.active) // coming back polls at once
    await settle()
    let callsActive = await fake.calls.filter { $0.endpoint == .notifications }.count
    XCTAssertEqual(callsActive, callsAfter + 1)
    poller.stop()
    XCTAssertFalse(poller.isRunning)
  }

  @MainActor
  func testSearchDebouncesNeedsTwoCharactersAndDropsStaleResults() async {
    let fake = demoFake()
    await fake.setWorkspace(DemoIDs.mekari)
    let clock = TestClock()
    let search = SearchStore(api: fake, clock: clock)
    search.query = "l"
    await clock.advance(by: .milliseconds(300))
    XCTAssertNil(search.results)
    XCTAssertFalse(search.isSearching)

    search.query = "lo"
    search.query = "login"
    XCTAssertTrue(search.isSearching)
    await clock.advance(by: .milliseconds(249))
    let early = await fake.calls.filter { $0.endpoint == .search }.count
    XCTAssertEqual(early, 0)
    await clock.advance(by: .milliseconds(1))
    let calls = await fake.calls.filter { $0.endpoint == .search }.count
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(search.results?.tasks.map(\.title), ["Fix login redirect"])
    XCTAssertEqual(search.target(forTask: DemoIDs.taskWithStories), .task(id: DemoIDs.taskWithStories, projectID: DemoIDs.boardProject))

    search.query = "zzzz"
    await clock.advance(by: .milliseconds(250))
    XCTAssertTrue(search.isEmpty)
    search.query = ""
    XCTAssertNil(search.results)
  }
}
