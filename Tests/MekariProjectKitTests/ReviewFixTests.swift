import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import XCTest
@testable import MekariProjectKit

/// Tests for the PR #2 review fixes: 401 race, cancellation, token store, open enums, decoding context.
final class SessionRaceAndCancellationTests: XCTestCase {
  let server = URL(string: "https://mp.example.com")!

  func testALate401ForAnOldTokenDoesNotEndANewSession() async throws {
    let transport = StubTransport()
    let tokens = InMemoryTokenStore(token: "old")
    let api = LiveMekariAPI(baseURL: server, tokens: tokens, transport: transport)
    // While the request (sent with "old") is in flight, the user signs in again.
    transport.duringRequest = { tokens.save("new") }
    transport.enqueue(.init(status: 401, body: #"{"error":{"code":"UNAUTHORIZED","message":"Expired"}}"#))
    _ = try? await api.notifications(unreadOnly: false, limit: 50)
    XCTAssertEqual(tokens.load(), "new")

    // A 401 for the current token still ends the session (and is the first event seen).
    transport.duringRequest = nil
    var events = api.events.makeAsyncIterator()
    transport.enqueue(.init(status: 401, body: #"{"error":{"code":"UNAUTHORIZED","message":"Expired"}}"#))
    _ = try? await api.me()
    XCTAssertNil(tokens.load())
    let event = await events.next()
    XCTAssertEqual(event, .unauthorized)
  }

  func testLoggingOutOfAnExpiredSessionEmitsNothing() async throws {
    let transport = StubTransport()
    let tokens = InMemoryTokenStore(token: "expired")
    let api = LiveMekariAPI(baseURL: server, tokens: tokens, transport: transport)
    transport.enqueue(.init(status: 401, body: #"{"error":{"code":"UNAUTHORIZED","message":"Expired"}}"#))
    transport.enqueue(.init(status: 404, body: #"{"error":{"code":"NOT_FOUND","message":"x"}}"#))
    var events = api.events.makeAsyncIterator()
    await api.logout()
    XCTAssertNil(tokens.load())
    // The next event is from a later call, not from logout.
    tokens.save("t")
    await api.setWorkspace("ws")
    _ = try? await api.projects(archived: false)
    let event = await events.next()
    XCTAssertEqual(event, .workspaceLost(workspaceID: "ws"))
  }

  func testCancellationIsRethrownNotTransport() async throws {
    let transport = StubTransport()
    transport.hang = true
    let api = LiveMekariAPI(baseURL: server, tokens: InMemoryTokenStore(token: "t"), transport: transport)
    let call = Task { try await api.me() }
    try await Task.sleep(for: .milliseconds(20))
    call.cancel()
    do {
      _ = try await call.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }

    // URLSession's own cancellation error is mapped too.
    let urlCancel = StubTransport()
    urlCancel.failWithURLCancelled = true
    let api2 = LiveMekariAPI(baseURL: server, tokens: InMemoryTokenStore(token: "t"), transport: urlCancel)
    do {
      _ = try await api2.me()
      XCTFail("expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }
  }

  func testCancellingCancelsTheURLSessionTask() async throws {
    // A local server that accepts connections and never answers.
    let listener = try SilentListener()
    defer { listener.close() }
    let transport = URLSessionTransport(timeout: 30)
    let request = URLRequest(url: URL(string: "http://127.0.0.1:\(listener.port)/health")!)
    let started = Date()
    let call = Task { try await transport.send(request) }
    try await Task.sleep(for: .milliseconds(200))
    call.cancel()
    do {
      _ = try await call.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the request kept running after cancel")
  }

  func testURLSessionTransportHandlesNoCookiesItself() {
    let configuration = URLSessionTransport().configuration
    XCTAssertFalse(configuration.httpShouldSetCookies)
    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
  }

  func testEmpty204BodiesAreFine() async throws {
    let transport = StubTransport()
    let api = LiveMekariAPI(baseURL: server, tokens: InMemoryTokenStore(token: "t"), transport: transport)
    transport.enqueue(.init(status: 204, body: ""))
    try await api.markRead("n-1")
    transport.enqueue(.init(status: 204, body: ""))
    try await api.deleteTask("t-1")
    transport.enqueue(.init(status: 204, body: ""))
    await api.logout()
  }

  func testTwoSetCookieEntriesAsURLSessionDeliversThem() async throws {
    // URLSession joins repeated Set-Cookie headers into one comma-separated value.
    let transport = StubTransport()
    let tokens = InMemoryTokenStore()
    let api = LiveMekariAPI(baseURL: server, tokens: tokens, transport: transport)
    transport.enqueue(.init(body: Fixtures.me, headers: [
      "Set-Cookie": "theme=dark; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT, sid=tok.en.value; Path=/; HttpOnly; SameSite=Lax",
    ]))
    _ = try await api.login(email: "a@b.c", password: "x")
    XCTAssertEqual(tokens.load(), "tok.en.value")
  }
}

final class CachedTokenStoreTests: XCTestCase {
  final class FakeBackend: SecretBackend, @unchecked Sendable {
    private let lock = NSLock()
    var stored: String?
    var readStatus: Int32 = SecretStatus.success
    var updateStatus: Int32?
    var reads = 0
    var log: [String] = []

    init(stored: String? = nil) { self.stored = stored }

    func read() -> (status: Int32, value: String?) {
      lock.locked {
        reads += 1
        log.append("read")
        if readStatus != SecretStatus.success { return (readStatus, nil) }
        return stored == nil ? (SecretStatus.itemNotFound, nil) : (SecretStatus.success, stored)
      }
    }
    func update(_ value: String) -> Int32 {
      lock.locked {
        log.append("update")
        if let updateStatus { return updateStatus }
        guard stored != nil else { return SecretStatus.itemNotFound }
        stored = value
        return SecretStatus.success
      }
    }
    func add(_ value: String) -> Int32 {
      lock.locked {
        log.append("add")
        if stored != nil { return -25299 } // errSecDuplicateItem
        stored = value
        return SecretStatus.success
      }
    }
    func delete() -> Int32 {
      lock.locked {
        log.append("delete")
        let had = stored != nil
        stored = nil
        return had ? SecretStatus.success : SecretStatus.itemNotFound
      }
    }
  }

  func testReadsOnceAndWritesThrough() {
    let backend = FakeBackend(stored: "abc")
    let store = CachedTokenStore(backend: backend)
    XCTAssertEqual(store.load(), "abc")
    XCTAssertEqual(store.load(), "abc")
    XCTAssertEqual(backend.reads, 1)
    store.save("def")
    XCTAssertEqual(backend.stored, "def")
    XCTAssertEqual(store.load(), "def")
    store.clear()
    XCTAssertNil(backend.stored)
    XCTAssertNil(store.load())
    XCTAssertEqual(backend.reads, 1)
  }

  func testSaveAddsWhenMissingAndReAddsWhenUpdateFails() {
    let empty = FakeBackend()
    let store = CachedTokenStore(backend: empty)
    store.save("first")
    XCTAssertEqual(empty.log, ["read", "update", "add"])
    XCTAssertEqual(empty.stored, "first")

    let broken = FakeBackend(stored: "old")
    broken.updateStatus = -25293 // errSecAuthFailed: the ACL belongs to an older build's signature
    let messages = LogBox()
    let store2 = CachedTokenStore(backend: broken) { messages.append($0) }
    store2.save("new-token")
    XCTAssertEqual(broken.log, ["read", "update", "delete", "add"])
    XCTAssertEqual(broken.stored, "new-token")
    XCTAssertEqual(messages.all, ["token update failed: -25293; re-adding"])
    XCTAssertFalse(messages.all.joined().contains("new-token"), "the token must never be logged")
  }

  func testADeniedReadMeansSignedOut() {
    let backend = FakeBackend(stored: "abc")
    backend.readStatus = -128 // errSecUserCanceled: the user denied the prompt
    let messages = LogBox()
    let store = CachedTokenStore(backend: backend) { messages.append($0) }
    XCTAssertNil(store.load())
    XCTAssertEqual(messages.all, ["token read failed: -128"])
  }

  final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.locked { lines.append(line) } }
    var all: [String] { lock.locked { lines } }
  }
}

final class OpenEnumAndDecodingTests: XCTestCase {
  let decoder = MekariJSON.makeDecoder()

  func testUnknownEnumValuesDecodeAndRoundTrip() throws {
    let urgent = Fixtures.task.replacingOccurrences(of: #""priority":"HIGH""#, with: #""priority":"URGENT""#)
    let list = try decoder.decode(ListResponse<TaskItem>.self, from: Data(#"{"data":[\#(urgent),\#(Fixtures.task)]}"#.utf8)).data
    XCTAssertEqual(list.map(\.priority), [.other("URGENT"), .high])
    XCTAssertFalse(list[0].priority.isKnown)
    XCTAssertEqual(Priority.allCases, [.none, .low, .medium, .high])
    let encoded = try MekariJSON.makeEncoder().encode(list[0])
    XCTAssertTrue(String(data: encoded, encoding: .utf8)!.contains(#""priority":"URGENT""#))

    let workspace = Fixtures.workspace.replacingOccurrences(of: #""myRole":"MEMBER""#, with: #""myRole":"OWNER""#)
      .replacingOccurrences(of: "\n", with: "")
    let decoded = try decoder.decode(Workspace.self, from: Data(workspace.utf8))
    XCTAssertEqual(decoded.myRole, .other("OWNER"))
    XCTAssertFalse(decoded.isAdmin)
    XCTAssertFalse(decoded.isGuest)

    let project = Fixtures.projectDetail.replacingOccurrences(of: #""privacy":"TEAM""#, with: #""privacy":"SECRET""#)
      .replacingOccurrences(of: #""defaultView":"CALENDAR""#, with: #""defaultView":"TIMELINE""#)
      .replacingOccurrences(of: #""role":"OWNER""#, with: #""role":"VIEWER""#)
    let detail = try decoder.decode(ProjectDetail.self, from: Data(project.utf8))
    XCTAssertEqual(detail.privacy, .other("SECRET"))
    XCTAssertEqual(detail.defaultView, .other("TIMELINE"))
    XCTAssertEqual(detail.members.first?.role, .other("VIEWER"))
    XCTAssertEqual(ProjectRole(rawValue: "EDITOR"), .editor)
  }

  func testStoriesOfAnUnknownKindAreSkipped() throws {
    let feed = Fixtures.stories.replacingOccurrences(of: #"{"data":["#, with: #"{"data":[{"kind":"reaction","id":"r-1","emoji":"🎉"},"#)
    let stories = try decoder.decode(StoryFeed.self, from: Data(feed.utf8)).data
    XCTAssertEqual(stories.count, 4)
    // A malformed known kind still fails loudly.
    let broken = #"{"data":[{"kind":"comment","id":"c-1"}]}"#
    XCTAssertThrowsError(try decoder.decode(StoryFeed.self, from: Data(broken.utf8)))
  }

  func testDecodingErrorsSayWhereAndWhat() async {
    let transport = StubTransport()
    let api = LiveMekariAPI(baseURL: URL(string: "https://x")!, tokens: InMemoryTokenStore(token: "t"), transport: transport)
    let bad = Fixtures.task.replacingOccurrences(of: #""dueDate":"2026-10-20""#, with: #""dueDate":"20/10/2026""#)
    transport.enqueue(.init(body: #"{"data":[\#(bad)]}"#))
    do {
      _ = try await api.myTasks(includeCompleted: false)
      XCTFail("expected an error")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .decoding)
      XCTAssertTrue(error.message.contains("$.data[0].dueDate"), error.message)
      XCTAssertTrue(error.message.contains("Expected YYYY-MM-DD"), error.message)
    } catch {
      XCTFail("\(error)")
    }
  }
}

/// Accepts TCP connections on 127.0.0.1 and never reads or answers.
final class SilentListener: @unchecked Sendable {
  private let fd: Int32
  let port: UInt16

  init() throws {
    #if canImport(Glibc)
    let socketFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard socketFD >= 0 else { throw POSIXError(.EIO) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(socketFD, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
    }
    fd = socketFD
    port = UInt16(bigEndian: actual.sin_port)
  }

  func close() {
    #if canImport(Glibc)
    _ = Glibc.close(fd)
    #else
    _ = Darwin.close(fd)
    #endif
  }
}
