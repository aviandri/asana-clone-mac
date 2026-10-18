import Foundation
import XCTest
@testable import MekariProjectKit

final class ModelCodingTests: XCTestCase {
  let decoder = MekariJSON.makeDecoder()

  func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try decoder.decode(T.self, from: Data(json.utf8))
  }

  func testMeIsFlatUserPlusWorkspaces() throws {
    let me = try decode(Me.self, Fixtures.me)
    XCTAssertEqual(me.id, "u-alice")
    XCTAssertEqual(me.role, .member)
    XCTAssertEqual(me.currentWorkspace?.name, "Mekari")
    XCTAssertEqual(me.workspaces.map(\.name), ["Acme Pilot", "Mekari"])
    XCTAssertTrue(me.workspaces[0].isGuest)
    XCTAssertNil(me.workspaces[0].domain)

    let none = try decode(Me.self, Fixtures.meWithoutWorkspace)
    XCTAssertNil(none.currentWorkspace)
    XCTAssertEqual(none.workspaces, [])
  }

  func testTaskDecodesDatesNullsAndLocalDates() throws {
    let task = try decode(TaskItem.self, Fixtures.task)
    XCTAssertEqual(task.dueDate, LocalDate(year: 2026, month: 10, day: 20))
    XCTAssertNil(task.startDate)
    XCTAssertEqual(task.priority, .high)
    XCTAssertEqual(task.position, 1500.5)
    XCTAssertEqual(task.project?.name, "Mobile App v2")
    XCTAssertEqual(task.createdAt, Date(timeIntervalSince1970: 1_792_314_000))
    XCTAssertEqual(task.updatedAt, Date(timeIntervalSince1970: 1_792_315_800))
  }

  func testTaskDetailIsFlat() throws {
    let detail = try decode(TaskDetail.self, Fixtures.taskDetail)
    XCTAssertEqual(detail.id, "t-1")
    XCTAssertEqual(detail.title, "Fix login redirect")
    XCTAssertTrue(detail.completed)
    XCTAssertEqual(detail.startDate, LocalDate("2026-10-01"))
    XCTAssertEqual(detail.followers.map(\.name), ["Alice Johnson", "Bob Smith"])
    XCTAssertEqual(detail.subtasks.count, 1)
    XCTAssertEqual(detail.parent?.title, "Epic")
    XCTAssertNotNil(detail.completedAt)
  }

  func testProjectDetailIsFlat() throws {
    let detail = try decode(ProjectDetail.self, Fixtures.projectDetail)
    XCTAssertEqual(detail.name, "Mobile App v2")
    XCTAssertEqual(detail.defaultView, .calendar)
    XCTAssertNil(detail.myRole)
    XCTAssertEqual(detail.sections.first?.name, "To do")
    XCTAssertEqual(detail.members.first?.role, .owner)
    XCTAssertEqual(detail.team.name, "Engineering")
  }

  func testStoriesDiscriminateOnKindAndKeepUnknownActivityTypes() throws {
    let stories = try decode(ListResponse<Story>.self, Fixtures.stories).data
    XCTAssertEqual(stories.count, 4)
    guard case .activity(let assigned) = stories[1], case .activity(let unknown) = stories[2], case .comment(let comment) = stories[3] else {
      return XCTFail("wrong kinds")
    }
    XCTAssertEqual(assigned.type, .assigned)
    XCTAssertEqual(assigned.data["assigneeId"]?.stringValue, "u-alice")
    XCTAssertEqual(unknown.type, .other("SOMETHING_NEW"))
    XCTAssertEqual(unknown.data["list"], .array([.number(1), .string("x")]))
    XCTAssertEqual(comment.segments, [.text("Hey "), .mention(name: "Bob Smith", userID: "u-bob"), .text(", look")])
    XCTAssertEqual(stories[3].id, "comment-c-1")
  }

  func testNotificationsWithUnknownTypeAndNoTask() throws {
    let page = try decode(InboxPage.self, Fixtures.notifications)
    XCTAssertEqual(page.unreadCount, 1)
    XCTAssertEqual(page.data[0].type, .commented)
    XCTAssertEqual(page.data[0].summary, "Bob Smith commented on Fix login redirect")
    XCTAssertEqual(page.data[1].type, .other("GOAL_DUE"))
    XCTAssertNil(page.data[1].task)
    XCTAssertEqual(page.data[1].summary, "Bob Smith updated")
  }

  func testPickableUsersCarryRole() throws {
    let users = try decode(ListResponse<PickableUser>.self, Fixtures.users).data
    XCTAssertEqual(users.map(\.user.name), ["Alice Johnson", "Gita Guest"])
    XCTAssertEqual(users.map(\.isGuest), [false, true])
  }

  func testRoundTripsThroughTheEncoder() throws {
    let encoder = MekariJSON.makeEncoder()
    let detail = try decode(TaskDetail.self, Fixtures.taskDetail)
    XCTAssertEqual(try decoder.decode(TaskDetail.self, from: encoder.encode(detail)), detail)
    let project = try decode(ProjectDetail.self, Fixtures.projectDetail)
    XCTAssertEqual(try decoder.decode(ProjectDetail.self, from: encoder.encode(project)), project)
    let me = try decode(Me.self, Fixtures.me)
    XCTAssertEqual(try decoder.decode(Me.self, from: encoder.encode(me)), me)
    let stories = try decode(ListResponse<Story>.self, Fixtures.stories).data
    XCTAssertEqual(try decoder.decode([Story].self, from: encoder.encode(stories)), stories)
  }

  func testTaskChangesEncodesOnlyTouchedFields() throws {
    let encoder = MekariJSON.makeEncoder()
    let body = String(data: try encoder.encode(TaskChanges(title: "New", description: .clear, priority: .low)), encoding: .utf8)
    XCTAssertEqual(body, #"{"description":null,"priority":"LOW","title":"New"}"#)
    XCTAssertEqual(String(data: try encoder.encode(TaskChanges()), encoding: .utf8), "{}")
    XCTAssertTrue(TaskChanges().isEmpty)
  }

  func testTaskChangesAppliedLocally() throws {
    let task = try decode(TaskItem.self, Fixtures.task)
    let bob = UserSummary(id: "u-bob", name: "Bob Smith", email: "bob@example.com", avatarColor: "#20aaea")
    let changed = TaskChanges(sectionId: .set("s-2"), assigneeId: .set("u-bob"), dueDate: .clear, completed: true, position: 3)
      .applied(to: task, assignee: .some(bob))
    XCTAssertEqual(changed.sectionId, "s-2")
    XCTAssertEqual(changed.assignee, bob)
    XCTAssertNil(changed.dueDate)
    XCTAssertTrue(changed.completed)
    XCTAssertNotNil(changed.completedAt)
    XCTAssertEqual(changed.position, 3)
    // Untouched assignee stays when no resolution is passed.
    XCTAssertEqual(TaskChanges(title: "x").applied(to: task).assignee, task.assignee)
  }

  func testAPIErrorEnvelope() {
    let noWorkspace = APIError.from(status: 403, body: Data(#"{"error":{"code":"FORBIDDEN","message":"No","details":[{"path":["workspace"],"message":"NO_WORKSPACE"}]}}"#.utf8))
    XCTAssertTrue(noWorkspace.isNoWorkspace)
    let odd = APIError.from(status: 418, body: Data(#"{"error":{"code":"TEAPOT","message":"Short and stout","details":{"x":1}}}"#.utf8))
    XCTAssertEqual(odd.code, .unknown("TEAPOT"))
    XCTAssertEqual(odd.issues, [])
    XCTAssertEqual(odd.errorDescription, "Short and stout")
  }
}
