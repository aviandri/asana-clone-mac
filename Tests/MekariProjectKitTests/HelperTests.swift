import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MekariProjectKit

final class LocalDateTests: XCTestCase {
  func testParsingIsStrict() {
    XCTAssertEqual(LocalDate("2026-10-18"), LocalDate(year: 2026, month: 10, day: 18))
    XCTAssertEqual(LocalDate("2024-02-29")?.description, "2024-02-29")
    for bad in ["2026-02-30", "2025-02-29", "2026-1-05", "26-01-05", "2026-13-01", "2026-10-18T00:00:00Z", "", "abcd-ef-gh"] {
      XCTAssertNil(LocalDate(bad), bad)
    }
  }

  func testArithmeticAcrossMonthsAndDST() {
    let d = LocalDate(year: 2026, month: 3, day: 28)
    XCTAssertEqual(d.adding(days: 5).description, "2026-04-02")
    XCTAssertEqual(d.adding(days: -28).description, "2026-02-28")
    XCTAssertEqual(LocalDate(year: 2026, month: 4, day: 2).days(since: d), 5)
    XCTAssertEqual(d.days(since: LocalDate(year: 2026, month: 4, day: 2)), -5)
    XCTAssertLessThan(d, d.adding(days: 1))
  }

  func testTodayUsesTheCalendarsTimeZone() {
    let instant = Date(timeIntervalSince1970: 1_792_364_400) // 2026-10-18T23:00:00Z
    var jakarta = Calendar(identifier: .gregorian)
    jakarta.timeZone = TimeZone(identifier: "Asia/Jakarta")!
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    XCTAssertEqual(LocalDate.today(in: jakarta, now: instant).description, "2026-10-19")
    XCTAssertEqual(LocalDate.today(in: utc, now: instant).description, "2026-10-18")
    XCTAssertEqual(LocalDate(LocalDate(year: 2026, month: 10, day: 19).date(in: jakarta), in: jakarta).description, "2026-10-19")
  }

  func testCodableAsAString() throws {
    let data = try JSONEncoder().encode(["d": LocalDate(year: 2026, month: 1, day: 5)])
    XCTAssertEqual(String(data: data, encoding: .utf8), #"{"d":"2026-01-05"}"#)
    XCTAssertThrowsError(try JSONDecoder().decode([String: LocalDate].self, from: Data(#"{"d":"2026-01-32"}"#.utf8)))
  }
}

final class SessionCookieTests: XCTestCase {
  func testExtractsSidFromVariousHeaderShapes() {
    XCTAssertEqual(SessionCookie.token(fromHeader: "sid=abc; Path=/; HttpOnly"), "abc")
    XCTAssertEqual(SessionCookie.token(fromHeader: "Path=/; sid=nope"), nil)
    XCTAssertEqual(SessionCookie.token(fromHeader: "other=1; Path=/, sid=xyz.123; Expires=Wed, 21 Oct 2026 07:28:00 GMT; HttpOnly"), "xyz.123")
    XCTAssertEqual(SessionCookie.token(fromHeader: "sid=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"), nil)
    XCTAssertEqual(SessionCookie.token(fromHeader: "sidx=1"), nil)
  }

  func testReadsTheHeaderCaseInsensitively() {
    let response = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["set-cookie": "sid=tok; Path=/"])!
    XCTAssertEqual(SessionCookie.token(from: response), "tok")
  }
}

final class MentionsTests: XCTestCase {
  func testParse() {
    XCTAssertEqual(Mentions.parse("no mentions"), [.text("no mentions")])
    XCTAssertEqual(Mentions.parse("@[Ann](u1)@[Bo](u2)!"), [.mention(name: "Ann", userID: "u1"), .mention(name: "Bo", userID: "u2"), .text("!")])
    XCTAssertEqual(Mentions.parse("email@[x] and @[Bad](has space)"), [.text("email@[x] and @[Bad](has space)")])
    XCTAssertEqual(Mentions.parse("[link](url) @[A B](id)"), [.text("[link](url) "), .mention(name: "A B", userID: "id")])
    XCTAssertEqual(Mentions.parse(""), [])
  }

  func testToken() {
    let user = UserSummary(id: "u1", name: "Ann [Ops]", email: "a@x", avatarColor: "#000000")
    XCTAssertEqual(Mentions.token(for: user), "@[Ann Ops](u1)")
    XCTAssertEqual(Mentions.parse(Mentions.token(for: user)), [.mention(name: "Ann Ops", userID: "u1")])
  }
}

final class LinksTests: XCTestCase {
  let server = URL(string: "https://mp.example.com")!

  func testWebLinksCarryTheWorkspace() {
    XCTAssertEqual(WebLinks.project("p1", server: server, workspace: "w1").absoluteString, "https://mp.example.com/projects/p1?workspace=w1")
    let base = TaskItem(id: "t1", workspaceId: "w1", projectId: "p1", title: "x",
                        creator: UserSummary(id: "u", name: "U", email: "u@x", avatarColor: "#000000"),
                        createdAt: Date(), updatedAt: Date())
    XCTAssertEqual(WebLinks.task(base, server: server, workspace: "w1").absoluteString,
                   "https://mp.example.com/projects/p1?task=t1&workspace=w1")
    var personal = base
    personal.projectId = nil
    XCTAssertEqual(WebLinks.task(personal, server: server, workspace: "w1").absoluteString,
                   "https://mp.example.com/my-tasks?task=t1&workspace=w1")
    XCTAssertEqual(WebLinks.workspaceSettings(server: URL(string: "http://localhost:8090/")!, workspace: "w1").absoluteString,
                   "http://localhost:8090/workspace/settings?workspace=w1")
    XCTAssertEqual(WebLinks.url(server, path: "/projects/p1?task=t1", workspace: "w1").absoluteString,
                   "https://mp.example.com/projects/p1?task=t1&workspace=w1")
  }

  func testDeepLinks() {
    let id = "50000000-0000-4000-8000-000000000001"
    XCTAssertEqual(DeepLink(url: URL(string: "mekariproject://task/\(id)")!), .task(id: id))
    XCTAssertEqual(DeepLink(url: URL(string: "mekariproject://project/\(id)/")!), .project(id: id))
    XCTAssertEqual(DeepLink(url: URL(string: "MekariProject://TASK/\(id.uppercased())")!), .task(id: id), "normalised to lowercase")
    XCTAssertNil(DeepLink(url: URL(string: "mekariproject://goal/\(id)")!))
    XCTAssertNil(DeepLink(url: URL(string: "mekariproject://task")!))
    XCTAssertNil(DeepLink(url: URL(string: "https://task/\(id)")!))
    XCTAssertEqual(DeepLink.task(id: id).url.absoluteString, "mekariproject://task/\(id)")
  }

  func testDeepLinksRejectAnythingButAUUID() {
    for bad in [
      "mekariproject://task/abc",
      "mekariproject://task/..%2Fusers",
      "mekariproject://task/%2E%2E%2Fusers",
      "mekariproject://task/../users",
      "mekariproject://project/p-1",
      "mekariproject://task/50000000-0000-4000-8000-000000000001/comments",
      "mekariproject://task/50000000-0000-4000-8000-00000000000",
      "mekariproject://task/50000000-0000-4000-8000-000000000001%3Fx=1",
    ] {
      XCTAssertNil(URL(string: bad).flatMap(DeepLink.init(url:)), bad)
    }
  }

  func testServerURLNormalisation() {
    XCTAssertEqual(ServerURL.normalize("mp.example.com")?.absoluteString, "https://mp.example.com")
    XCTAssertEqual(ServerURL.normalize(" http://localhost:3100/ ")?.absoluteString, "http://localhost:3100")
    XCTAssertEqual(ServerURL.normalize("https://mp.example.com/api/v1/")?.absoluteString, "https://mp.example.com")
    XCTAssertNil(ServerURL.normalize(""))
    XCTAssertNil(ServerURL.normalize("ftp://x.com"))
    XCTAssertNil(ServerURL.normalize("https://"))
  }
}

final class ReorderTests: XCTestCase {
  func testPositions() {
    XCTAssertEqual(Reorder.position(between: nil, and: nil), 1000)
    XCTAssertEqual(Reorder.position(between: 3000, and: nil), 4000)
    XCTAssertEqual(Reorder.position(between: nil, and: 1000), 500)
    XCTAssertEqual(Reorder.position(between: nil, and: -2), -1002)
    XCTAssertEqual(Reorder.position(between: 1000, and: 2000), 1500)
    XCTAssertFalse(Reorder.needsRenumbering(between: 1000, and: 2000))
    XCTAssertTrue(Reorder.needsRenumbering(between: 1, and: 1 + 1e-7))
    XCTAssertTrue(Reorder.needsRenumbering(between: nil, and: 1e-7))
    XCTAssertEqual(Reorder.renumbered(count: 3), [1000, 2000, 3000])
  }
}

final class QueryEncodingTests: XCTestCase {
  func testStrict() {
    XCTAssertEqual(QueryEncoding.encode("c++ & ship=now"), "c%2B%2B%20%26%20ship%3Dnow")
    XCTAssertEqual(QueryEncoding.encode("Ünï"), "%C3%9Cn%C3%AF")
  }
}

final class ServerIdentityTests: XCTestCase {
  func testSameServerIgnoresCaseDefaultPortsAndTrailingSlashes() {
    let url = { (s: String) in URL(string: s)! }
    XCTAssertTrue(ServerURL.isSameServer(url("https://MP.Example.com"), url("https://mp.example.com/")))
    XCTAssertTrue(ServerURL.isSameServer(url("HTTPS://mp.example.com:443"), url("https://mp.example.com")))
    XCTAssertTrue(ServerURL.isSameServer(url("http://mp.example.com:80/app/"), url("http://mp.example.com/app")))
    XCTAssertFalse(ServerURL.isSameServer(url("http://mp.example.com"), url("https://mp.example.com")), "scheme change")
    XCTAssertFalse(ServerURL.isSameServer(url("https://mp.example.com:8443"), url("https://mp.example.com")))
    XCTAssertFalse(ServerURL.isSameServer(url("https://mp.example.com/a"), url("https://mp.example.com/b")))
    XCTAssertFalse(ServerURL.isSameServer(url("https://evil.example.com"), url("https://mp.example.com")))
    XCTAssertFalse(ServerURL.isSameServer(url("https://mp.example.com"), nil))
    XCTAssertFalse(ServerURL.isSameServer(nil, nil))
  }
}
