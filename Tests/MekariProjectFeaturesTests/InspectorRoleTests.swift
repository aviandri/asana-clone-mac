import Foundation
import MekariProjectKit
import XCTest
@testable import MekariProjectFeatures

/// The inspector's edit permission before, during and after its own project-role fetch.
final class InspectorRoleTests: XCTestCase {
  /// A Mekari scope (alice, MEMBER) with My Tasks loaded, and the sidebar when `sidebar` is set.
  @MainActor
  func makeScope(sidebar: Bool = true, fake: FakeMekariAPI = demoFake()) async throws -> WorkspaceScope {
    await fake.setWorkspace(DemoIDs.mekari)
    let me = try await fake.me()
    let workspace = try XCTUnwrap(me.workspaces.first { $0.id == DemoIDs.mekari })
    let scope = WorkspaceScope(api: fake, workspace: workspace, me: alice, clock: TestClock(),
                               calendar: TestTime.calendar, now: { TestTime.now })
    await scope.myTasks.refresh()
    if sidebar { await scope.sidebar.load() }
    return scope
  }

  @MainActor
  func cachedTask(_ scope: WorkspaceScope, in projectID: String) throws -> String {
    try XCTUnwrap(scope.myTasks.groups.flatMap(\.taskIDs).first { scope.tasks[$0]?.projectId == projectID })
  }

  @MainActor
  func testTheScopesKnownRoleAppliesBeforeTheInspectorsOwnFetch() async throws {
    let fake = demoFake()
    let scope = try await makeScope(fake: fake)
    let editable = try cachedTask(scope, in: DemoIDs.boardProject) // alice is EDITOR there
    let readOnlyProject = scope.project(DemoIDs.readOnlyProject)   // alice is COMMENTER there
    await readOnlyProject.load()
    let readOnly = try XCTUnwrap(readOnlyProject.taskIDs(in: readOnlyProject.sections.first?.id).first)

    // Nothing fetched yet (and the fetches parked): the scope's roles apply at once.
    await fake.hold(.task)
    let detail = scope.taskDetail(editable)
    XCTAssertTrue(detail.canEdit, "not briefly read-only")
    XCTAssertFalse(scope.taskDetail(readOnly).canEdit)
    async let load: Void = detail.load()
    await waitUntil { await fake.parkedCount(.task) == 1 }
    XCTAssertTrue(detail.canEdit)
    await fake.release(.task, all: true)
    await load
    XCTAssertTrue(detail.canEdit)
  }

  @MainActor
  func testAProjectNobodyKnowsYetStaysReadOnlyUntilFetched() async throws {
    let scope = try await makeScope(sidebar: false)
    let id = try cachedTask(scope, in: DemoIDs.boardProject)
    let detail = scope.taskDetail(id)
    XCTAssertFalse(detail.canEdit, "fail closed")
    await detail.load()
    XCTAssertTrue(detail.canEdit)

    // Personal tasks need no role at all.
    let personal = try XCTUnwrap(scope.myTasks.groups.flatMap(\.taskIDs).first { scope.tasks[$0]?.projectId == nil })
    XCTAssertTrue(scope.taskDetail(personal).canEdit)
  }

  @MainActor
  func testTheFetchedRoleWinsAndAFailedFetchFallsBackToTheScopes() async throws {
    let fake = demoFake()
    await fake.setWorkspace(DemoIDs.mekari)
    let cache = TaskCache(api: fake)
    let all = await fake.currentTasks()
    let task = try XCTUnwrap(all.first { $0.projectId == DemoIDs.readOnlyProject && $0.parentId == nil })
    cache.upsert([task])
    // The scope's copy says EDITOR (stale); the server says COMMENTER.
    let projects = try await fake.projects(archived: false)
    var stale = try XCTUnwrap(projects.first { $0.id == DemoIDs.readOnlyProject })
    stale.myRole = .editor
    let known = stale
    let store = TaskDetailStore(api: fake, tasks: cache, taskID: task.id, me: alice, workspaceRole: .member,
                                knownProject: { $0 == known.id ? known : nil })
    XCTAssertTrue(store.canEdit)
    await store.load()
    XCTAssertFalse(store.canEdit, "our own fetch wins")

    await fake.failNext(.project, with: .transport())
    await store.load()
    XCTAssertTrue(store.canEdit, "a failed fetch falls back to what the scope knows")
  }
}
