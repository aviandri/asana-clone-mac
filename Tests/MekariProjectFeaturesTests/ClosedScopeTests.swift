import Foundation
import MekariProjectKit
import XCTest
@testable import MekariProjectFeatures

/// Work from a scope that was left (a switch) never reaches the server or the session-wide cooldown.
final class ClosedScopeTests: XCTestCase {
  @MainActor
  func open(_ scope: WorkspaceScope, _ board: ProjectStore, section: Int) -> [String] {
    board.taskIDs(in: board.sections[section].id).filter { scope.tasks[$0]?.completed == false }
  }

  @MainActor
  func testALateConfirmFromAClosedScopeNeitherCelebratesNorStartsTheCooldown() async throws {
    let fake = demoFake()
    let session = await signedInSession(fake)
    let old = try XCTUnwrap(session.scope)
    let board = old.project(DemoIDs.boardProject)
    await board.load()
    let ids = open(old, board, section: 1)
    for id in ids.dropLast() { await board.toggleComplete(id) }

    // The last task in the section; the switch lands before its PATCH answers.
    await fake.hold(.updateTask)
    async let complete: Void = board.toggleComplete(ids.last!)
    await waitUntil { await fake.parkedCount(.updateTask) == 1 }
    await session.switchWorkspace(to: DemoIDs.acmePilot)
    XCTAssertTrue(old.isClosed)
    await fake.release(.updateTask, all: true)
    await complete
    XCTAssertNil(old.completionFeedback.lastEvent)

    // The first real celebration in the new workspace isn't blocked by a cooldown.
    let acme = try XCTUnwrap(session.scope)
    let pilot = acme.project(DemoIDs.pilotProject)
    await pilot.load()
    for id in open(acme, pilot, section: 0) { await pilot.toggleComplete(id) }
    guard case .sectionCleared? = acme.completionFeedback.lastEvent?.celebration else {
      return XCTFail("expected a section celebration, got \(String(describing: acme.completionFeedback.lastEvent))")
    }
  }

  @MainActor
  func testARenumberInProgressStopsWhenTheWorkspaceChanges() async throws {
    let fake = demoFake()
    let session = await signedInSession(fake)
    let old = try XCTUnwrap(session.scope)
    let board = old.project(DemoIDs.boardProject)
    await board.load()
    let todo = board.sections[0].id
    let column = board.taskIDs(in: todo)
    let (push, offline, tablet) = (column[0], column[1], column[3])
    try await old.tasks.update(offline, TaskChanges(position: try XCTUnwrap(old.tasks[push]).position + 1e-9))

    await fake.hold(.updateTask)
    async let move: Void = board.move(taskID: tablet, toSection: todo, before: offline) // crowded: renumbers
    await waitUntil { await fake.parkedCount(.updateTask) == 1 }
    let patches = await fake.calls.filter { $0.endpoint == .updateTask }.count
    await session.switchWorkspace(to: DemoIDs.acmePilot)
    await fake.release(.updateTask, all: true)
    await move
    await settle()
    let after = await fake.calls.filter { $0.endpoint == .updateTask }.count
    XCTAssertEqual(after, patches, "no PATCH goes out after the switch")
    XCTAssertNil(board.lastError, "a cancellation, not an error")

    // Every other request from the closed scope is refused before it's sent, too.
    let calls = await fake.calls.count
    await old.myTasks.refresh()
    let callsAfter = await fake.calls.count
    XCTAssertEqual(callsAfter, calls)
  }
}
