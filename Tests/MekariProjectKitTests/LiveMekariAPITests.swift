// Swift 5.10's Linux Foundation doesn't mark URL, URLRequest, HTTPURLResponse & co. Sendable yet
// (Darwin's and Swift 6's do), so take its types as pre-concurrency there.
#if canImport(FoundationNetworking) && compiler(<6.0)
@preconcurrency import Foundation
@preconcurrency import FoundationNetworking
#else
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#endif
import XCTest
@testable import MekariProjectKit

/// Records requests and replies from a queue of canned responses.
final class StubTransport: HTTPTransport, @unchecked Sendable {
  struct Reply {
    var status: Int = 200
    var body: String = "{}"
    var headers: [String: String] = [:]
  }

  private let lock = NSLock()
  private var replies: [Reply] = []
  private(set) var requests: [URLRequest] = []
  var failWithTransportError = false
  /// Runs while a request is "in flight" (after it was sent, before the reply).
  var duringRequest: (@Sendable () -> Void)?
  /// Never replies; only cancellation ends the request.
  var hang = false
  /// Fails like URLSession does when its task is cancelled.
  var failWithURLCancelled = false

  func enqueue(_ reply: Reply) {
    lock.locked { replies.append(reply) }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let reply: Reply? = lock.locked {
      requests.append(request)
      return replies.isEmpty ? nil : replies.removeFirst()
    }
    duringRequest?()
    if hang { try await Task.sleep(for: .seconds(3600)) }
    if failWithURLCancelled { throw URLError(.cancelled) }
    if failWithTransportError { throw URLError(.notConnectedToInternet) }
    let r = reply ?? Reply()
    let response = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
    return (Data(r.body.utf8), response)
  }

  var last: URLRequest? { lock.locked { requests.last } }
}

final class LiveMekariAPITests: XCTestCase {
  let server = URL(string: "https://mp.example.com")!
  var transport: StubTransport!
  var tokens: InMemoryTokenStore!
  var api: LiveMekariAPI!

  override func setUp() {
    transport = StubTransport()
    tokens = InMemoryTokenStore()
    api = LiveMekariAPI(baseURL: server, tokens: tokens, transport: transport)
  }

  func testLoginReadsSidFromSetCookieAndSendsItAfterwards() async throws {
    transport.enqueue(.init(body: Fixtures.me, headers: ["Set-Cookie": "sid=abc.def.ghi; Path=/; HttpOnly; SameSite=Lax"]))
    let me = try await api.login(email: "alice@example.com", password: "password123")
    XCTAssertEqual(me.name, "Alice Johnson")
    XCTAssertEqual(tokens.load(), "abc.def.ghi")
    let login = try XCTUnwrap(transport.last)
    XCTAssertEqual(login.url?.absoluteString, "https://mp.example.com/api/v1/auth/login")
    XCTAssertEqual(login.httpMethod, "POST")
    XCTAssertNil(login.value(forHTTPHeaderField: "Cookie"))

    transport.enqueue(.init(body: #"{"data":[]}"#))
    _ = try await api.projects(archived: false)
    XCTAssertEqual(transport.last?.value(forHTTPHeaderField: "Cookie"), "sid=abc.def.ghi")
    XCTAssertEqual(transport.last?.url?.absoluteString, "https://mp.example.com/api/v1/projects?archived=false")
  }

  func testLoginWithoutCookieIsADecodingError() async {
    transport.enqueue(.init(body: Fixtures.me))
    do {
      _ = try await api.login(email: "a@b.c", password: "x")
      XCTFail("expected an error")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .decoding)
    } catch {
      XCTFail("\(error)")
    }
  }

  func testWorkspaceHeaderOnScopedButNotOnAuthOrWorkspaces() async throws {
    await api.setWorkspace("ws-1")
    transport.enqueue(.init(body: #"{"data":[]}"#))
    _ = try await api.myTasks(includeCompleted: false)
    XCTAssertEqual(transport.last?.value(forHTTPHeaderField: "X-Workspace-Id"), "ws-1")
    XCTAssertEqual(transport.last?.url?.query, "completed=false")

    transport.enqueue(.init(body: Fixtures.me))
    _ = try await api.me()
    XCTAssertNil(transport.last?.value(forHTTPHeaderField: "X-Workspace-Id"))

    transport.enqueue(.init(body: Fixtures.workspace))
    _ = try await api.switchWorkspace("ws-2")
    XCTAssertNil(transport.last?.value(forHTTPHeaderField: "X-Workspace-Id"))
    XCTAssertEqual(transport.last?.url?.path, "/api/v1/workspaces/ws-2/switch")
  }

  func test401ClearsTheTokenAndEmitsUnauthorized() async throws {
    tokens.save("old")
    var iterator = api.events.makeAsyncIterator()
    transport.enqueue(.init(status: 401, body: #"{"error":{"code":"UNAUTHORIZED","message":"Session expired"}}"#))
    do {
      _ = try await api.me()
      XCTFail("expected an error")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .unauthorized)
      XCTAssertEqual(error.message, "Session expired")
    }
    XCTAssertNil(tokens.load())
    let event = await iterator.next()
    XCTAssertEqual(event, .unauthorized)
  }

  func testFailedLoginDoesNotEmitUnauthorized() async throws {
    transport.enqueue(.init(status: 401, body: #"{"error":{"code":"UNAUTHORIZED","message":"Invalid email or password"}}"#))
    transport.enqueue(.init(status: 404, body: #"{"error":{"code":"NOT_FOUND","message":"Workspace not found"}}"#))
    await api.setWorkspace("ws-gone")
    var iterator = api.events.makeAsyncIterator()
    _ = try? await api.login(email: "a@b.c", password: "nope")
    _ = try? await api.projects(archived: false)
    // The first event is the lost workspace from the second call, not an unauthorized from login.
    let event = await iterator.next()
    XCTAssertEqual(event, .workspaceLost(workspaceID: "ws-gone"))
  }

  func test404OnIdAddressedEndpointIsNotLostAccess() async throws {
    await api.setWorkspace("ws-1")
    transport.enqueue(.init(status: 404, body: #"{"error":{"code":"NOT_FOUND","message":"Task not found"}}"#))
    transport.enqueue(.init(status: 404, body: #"{"error":{"code":"NOT_FOUND","message":"Workspace not found"}}"#))
    var iterator = api.events.makeAsyncIterator()
    _ = try? await api.task("t-1")
    _ = try? await api.search("ab")
    let event = await iterator.next()
    XCTAssertEqual(event, .workspaceLost(workspaceID: "ws-1"))
  }

  func testValidationErrorsCarryFieldIssues() async {
    transport.enqueue(.init(status: 400, body: #"{"error":{"code":"VALIDATION","message":"Invalid request","details":[{"path":["assigneeId"],"message":"Not an active workspace member"},{"path":["items",0],"message":"x"}]}}"#))
    do {
      _ = try await api.createTask(NewTask(title: "x", assigneeId: "u"))
      XCTFail("expected an error")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .validation)
      XCTAssertEqual(error.issue(for: "assigneeId")?.message, "Not an active workspace member")
      XCTAssertEqual(error.issues.last?.path, ["items", "0"])
    } catch {
      XCTFail("\(error)")
    }
  }

  func testNonJSONErrorsAndTransportFailures() async {
    transport.enqueue(.init(status: 502, body: "<html>Bad gateway</html>"))
    do {
      try await api.markAllRead()
      XCTFail("expected an error")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .unknown("HTTP 502"))
      XCTAssertEqual(error.status, 502)
    } catch {
      XCTFail("\(error)")
    }

    transport.failWithTransportError = true
    do {
      try await api.health()
      XCTFail("expected an error")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .transport)
    } catch {
      XCTFail("\(error)")
    }
  }

  func testHealthIsAtTheServerRoot() async throws {
    transport.enqueue(.init(body: #"{"ok":true}"#))
    try await api.health()
    XCTAssertEqual(transport.last?.url?.absoluteString, "https://mp.example.com/health")
  }

  func testPatchBodiesOmitUntouchedFieldsAndSendNullToClear() async throws {
    transport.enqueue(.init(body: Fixtures.taskDetail))
    _ = try await api.updateTask("t-1", TaskChanges(assigneeId: .clear, dueDate: .set(LocalDate(year: 2026, month: 10, day: 20)), completed: true))
    let body = try XCTUnwrap(transport.last?.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(Set(json.keys), ["assigneeId", "dueDate", "completed"])
    XCTAssertTrue(json["assigneeId"] is NSNull)
    XCTAssertEqual(json["dueDate"] as? String, "2026-10-20")
    XCTAssertEqual(transport.last?.httpMethod, "PATCH")
  }

  func testLogoutClearsTheTokenEvenWhenTheCallFails() async {
    tokens.save("t")
    transport.failWithTransportError = true
    await api.logout()
    XCTAssertNil(tokens.load())
  }

  func testQueryValuesAreEncoded() async throws {
    transport.enqueue(.init(body: #"{"tasks":[],"projects":[],"users":[]}"#))
    _ = try await api.search("fix & ship")
    XCTAssertEqual(transport.last?.url?.query, "q=fix%20%26%20ship")
  }
}
