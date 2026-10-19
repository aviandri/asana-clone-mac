import Foundation
import MekariProjectKit
import XCTest
@testable import MekariProjectFeatures
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sign-in against a real LiveMekariAPI on a recording transport: the order of the URL and token writes, and
/// which cookie each request carried.
final class SignInServerTests: XCTestCase {
  /// One log for settings, the token store and the wire.
  final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var log: [String] {
      lock.lock()
      defer { lock.unlock() }
      return entries
    }

    func add(_ entry: String) {
      lock.lock()
      entries.append(entry)
      lock.unlock()
    }
  }

  final class Settings: ServerSettings, @unchecked Sendable {
    let recorder: Recorder
    private var url: URL?
    init(_ url: URL?, _ recorder: Recorder) {
      self.url = url
      self.recorder = recorder
    }
    var serverURL: URL? {
      get { url }
      set {
        url = newValue
        recorder.add("url=\(newValue?.absoluteString ?? "nil")")
      }
    }
  }

  final class Tokens: TokenStore, @unchecked Sendable {
    let recorder: Recorder
    private let inner: InMemoryTokenStore
    init(_ token: String?, _ recorder: Recorder) {
      inner = InMemoryTokenStore(token: token)
      self.recorder = recorder
    }
    func load() -> String? { inner.load() }
    func save(_ token: String) {
      inner.save(token)
      recorder.add("save")
    }
    func clear() {
      inner.clear()
      recorder.add("clear")
    }
  }

  /// /health and /auth/login like the BE (wrong password → 401); every other request a harmless 404.
  final class Server: HTTPTransport, @unchecked Sendable {
    let recorder: Recorder
    init(_ recorder: Recorder) { self.recorder = recorder }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      let path = request.url!.path
      let cookie = request.value(forHTTPHeaderField: "Cookie") ?? "none"
      var status = 404
      var headers: [String: String] = ["Content-Type": "application/json"]
      var body = #"{"error":{"code":"NOT_FOUND","message":"Not found"}}"#
      if path.hasSuffix("/health") {
        recorder.add("health")
        status = 200
        body = #"{"status":"ok"}"#
      } else if path.hasSuffix("/auth/login") {
        recorder.add("login(cookie=\(cookie))")
        let password = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        if password.contains(DemoIDs.password) {
          status = 200
          headers["Set-Cookie"] = "sid=new-token; Path=/; HttpOnly"
          body = Self.me
        } else {
          status = 401
          body = #"{"error":{"code":"UNAUTHORIZED","message":"Invalid email or password"}}"#
        }
      }
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      return (Data(body.utf8), response)
    }

    static let me = #"""
    {"id":"u-alice","name":"Alice Johnson","email":"alice@example.com","avatarColor":"#e8384f","role":"MEMBER",
     "isActive":true,"createdAt":"2026-10-15T08:00:00Z","currentWorkspace":null,"workspaces":[]}
    """#
  }

  @MainActor
  func session(server: URL?, token: String?) -> (AppSession, Recorder, Settings) {
    let recorder = Recorder()
    let settings = Settings(server, recorder)
    let transport = Server(recorder)
    let session = AppSession(settings: settings, tokens: Tokens(token, recorder), apiFactory: { url, tokens in
      LiveMekariAPI(baseURL: url, tokens: tokens, transport: transport)
    })
    return (session, recorder, settings)
  }

  let old = URL(string: "https://old.example.com")!

  @MainActor
  func testSigningInToAnotherServerNeverSendsTheKeptSessionAndStoresTheURLFirst() async {
    let (session, recorder, settings) = self.session(server: old, token: "old-token")
    await session.signIn(server: "new.example.com", email: "alice@example.com", password: DemoIDs.password)
    guard case .signedIn = session.state else { return XCTFail("not signed in: \(String(describing: session.signInError))") }
    XCTAssertEqual(recorder.log, ["clear", "health", "url=https://new.example.com", "login(cookie=none)", "save"])
    XCTAssertEqual(settings.serverURL?.absoluteString, "https://new.example.com")
  }

  @MainActor
  func testAFailedSignInElsewherePutsTheOldServerBack() async {
    let (session, recorder, settings) = self.session(server: old, token: "old-token")
    await session.signIn(server: "new.example.com", email: "alice@example.com", password: "wrong")
    XCTAssertEqual(session.signInError, .wrongCredentials)
    XCTAssertEqual(settings.serverURL, old)
    XCTAssertEqual(
      recorder.log,
      ["clear", "health", "url=https://new.example.com", "login(cookie=none)", "url=https://old.example.com"]
    )
  }

  @MainActor
  func testTheSameServerKeepsTheKeptSessionUntilTheNewLogin() async {
    // Typed differently, same server: host case and the default port don't make it another server.
    let (session, recorder, _) = self.session(server: old, token: "old-token")
    await session.signIn(server: "https://OLD.example.com:443/", email: "alice@example.com", password: DemoIDs.password)
    guard case .signedIn = session.state else { return XCTFail("not signed in") }
    XCTAssertEqual(recorder.log.first, "health")
    XCTAssertFalse(recorder.log.contains("clear"), "the kept session stays until the new login replaces it")
    XCTAssertTrue(recorder.log.contains("login(cookie=none)"), "a login never carries a stored session")
    XCTAssertEqual(recorder.log.last, "save")
  }

  @MainActor
  func testAStoredOnlySessionForAnotherServerIsClearedToo() async {
    // Nothing loaded, but the store is still asked to clear: whatever it holds belongs to the old server.
    let (session, recorder, _) = self.session(server: old, token: nil)
    await session.signIn(server: "new.example.com", email: "alice@example.com", password: DemoIDs.password)
    XCTAssertEqual(recorder.log.first, "clear")
  }
}
