import Foundation
import MekariProjectKit
import XCTest
@testable import MekariProjectFeatures

// Linux: @MainActor goes on each async test method, not the class.
final class AppSessionTests: XCTestCase {
  @MainActor
  func testStartWithoutAServerOrSessionIsSignedOut() async {
    let none = AppSession(settings: InMemoryServerSettings(), tokens: InMemoryTokenStore(), apiFactory: { _, _ in demoFake() })
    XCTAssertEqual(none.state, .restoring)
    await none.start()
    XCTAssertEqual(none.state, .signedOut)

    let ui = AppSession.uiTest(signedIn: false)
    await ui.start()
    XCTAssertEqual(ui.state, .signedOut)
    XCTAssertNil(ui.scope)
  }

  @MainActor
  func testStartRestoresTheSessionAndBuildsTheScope() async {
    let session = await signedInSession(demoFake())
    guard case .signedIn(let me) = session.state else { return XCTFail("not signed in") }
    XCTAssertEqual(me.id, DemoIDs.alice)
    XCTAssertEqual(session.current?.id, DemoIDs.mekari)
    XCTAssertEqual(session.all.map(\.name), ["Acme Pilot", "Mekari"])
    XCTAssertFalse(session.isGuest)
    XCTAssertEqual(session.scope?.id, DemoIDs.mekari)
    XCTAssertEqual(session.generation, 1)
    XCTAssertTrue(session.scope?.poller.isRunning ?? false)
  }

  @MainActor
  func testSignInErrorsAndSuccess() async {
    let session = AppSession.uiTest(signedIn: false)
    await session.start()

    await session.signIn(server: "   ", email: "alice@example.com", password: DemoIDs.password)
    XCTAssertEqual(session.signInError, .badServer)

    await session.signIn(server: "demo.invalid", email: "alice@example.com", password: "wrong")
    XCTAssertEqual(session.signInError, .wrongCredentials)
    XCTAssertEqual(session.signInError?.message, "Wrong email or password")
    XCTAssertEqual(session.state, .signedOut)

    await session.signIn(server: "demo.invalid", email: "alice@example.com", password: DemoIDs.password)
    XCTAssertNil(session.signInError)
    XCTAssertEqual(session.me?.id, DemoIDs.alice)
    XCTAssertEqual(session.settings.serverURL?.absoluteString, "https://demo.invalid")
    XCTAssertNotNil(session.scope)
  }

  @MainActor
  func testSignInMapsRateLimitingAndOfflineServers() async {
    let fake = demoFake(as: nil)
    let session = AppSession(settings: InMemoryServerSettings(), tokens: InMemoryTokenStore(), apiFactory: { _, _ in fake })
    await fake.failNext(.login, with: APIError(code: .rateLimited, status: 429, message: "Slow down"))
    await session.signIn(server: "mp.example.com", email: "alice@example.com", password: DemoIDs.password)
    XCTAssertEqual(session.signInError, .rateLimited)
    await fake.failNext(.health, with: .transport())
    await session.signIn(server: "mp.example.com", email: "alice@example.com", password: DemoIDs.password)
    XCTAssertEqual(session.signInError, .transport)
    await fake.failNext(.health, with: APIError(code: .unknown("HTTP 404"), status: 404, message: "nope"))
    await session.signIn(server: "mp.example.com", email: "alice@example.com", password: DemoIDs.password)
    XCTAssertEqual(session.signInError, .badServer)
  }

  @MainActor
  func testSwitchingWorkspaceReplacesTheScopeAndSendsTheNewHeader() async {
    let fake = demoFake()
    let session = await signedInSession(fake)
    let before = session.generation
    await session.switchWorkspace(index: 0) // Acme Pilot (by name)
    XCTAssertEqual(session.current?.name, "Acme Pilot")
    XCTAssertEqual(session.scope?.id, DemoIDs.acmePilot)
    XCTAssertEqual(session.generation, before + 1)
    XCTAssertEqual(session.notice, "Switched to Acme Pilot")
    XCTAssertTrue(session.isAdmin)
    await session.scope?.sidebar.load()
    XCTAssertEqual(session.scope?.sidebar.projects.map(\.name), ["Pilot Rollout"])
    let lastCall = await fake.calls.last
    XCTAssertEqual(lastCall?.workspaceID, DemoIDs.acmePilot)

    await session.switchWorkspace(index: 9) // out of range: nothing
    XCTAssertEqual(session.current?.name, "Acme Pilot")
    session.dismissNotice()
    XCTAssertNil(session.notice)
  }

  @MainActor
  func testConcurrentSwitchesNewestWins() async {
    let fake = demoFake()
    await fake.setLatency(.milliseconds(20))
    let session = await signedInSession(fake)
    async let first: Void = session.switchWorkspace(to: DemoIDs.acmePilot)
    async let second: Void = session.switchWorkspace(to: DemoIDs.mekari) // no-op: already current
    _ = await (first, second)
    XCTAssertEqual(session.current?.id, DemoIDs.acmePilot)

    async let a: Void = session.switchWorkspace(to: DemoIDs.mekari)
    try? await Task.sleep(for: .milliseconds(5))
    async let b: Void = session.switchWorkspace(to: DemoIDs.mekari)
    _ = await (a, b)
    XCTAssertEqual(session.current?.id, DemoIDs.mekari)
  }

  @MainActor
  func testLostAccessAdoptsTheServersCurrentWorkspace() async {
    let fake = demoFake()
    let session = await signedInSession(fake)
    await session.switchWorkspace(to: DemoIDs.acmePilot)
    await fake.removeMembership(userID: DemoIDs.alice, workspaceID: DemoIDs.acmePilot)
    await session.scope?.myTasks.refresh() // 404 with the header → .workspaceLost
    await settle()
    XCTAssertEqual(session.current?.id, DemoIDs.mekari)
    XCTAssertEqual(session.all.map(\.name), ["Mekari"])
    XCTAssertEqual(session.notice, "You no longer have access to Acme Pilot")
  }

  @MainActor
  func testA401SignsOut() async {
    let fake = demoFake()
    let session = await signedInSession(fake)
    await fake.emit(.unauthorized)
    await settle()
    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(session.scope)
  }

  @MainActor
  func testSignOut() async {
    let fake = demoFake()
    let session = await signedInSession(fake)
    await session.signOut()
    XCTAssertEqual(session.state, .signedOut)
    let hasSession = await fake.hasSession
    XCTAssertFalse(hasSession)
  }

  @MainActor
  func testNoWorkspaceMeansNoScope() async {
    let fake = demoFake()
    await fake.removeMembership(userID: DemoIDs.alice, workspaceID: DemoIDs.mekari)
    await fake.removeMembership(userID: DemoIDs.alice, workspaceID: DemoIDs.acmePilot)
    let session = await signedInSession(fake)
    XCTAssertNotNil(session.me)
    XCTAssertNil(session.scope)
    XCTAssertEqual(session.all, [])
  }

  @MainActor
  func testDeepLinksSwitchWorkspaceOrReportNoAccess() async {
    let fake = demoFake()
    let session = await signedInSession(fake)
    let pilot = await session.resolve(.project(id: DemoIDs.pilotProject))
    XCTAssertEqual(pilot, .open(.project(id: DemoIDs.pilotProject)))
    XCTAssertEqual(session.current?.id, DemoIDs.acmePilot)

    let task = await session.resolve(.task(id: DemoIDs.taskWithStories))
    XCTAssertEqual(task, .open(.task(id: DemoIDs.taskWithStories, projectID: DemoIDs.boardProject)))
    XCTAssertEqual(session.current?.id, DemoIDs.mekari)

    let missing = await session.resolve(.task(id: "nope"))
    XCTAssertEqual(missing, .noAccess)
  }

  @MainActor
  func testWebURLCarriesTheWorkspace() async {
    let session = await signedInSession(demoFake())
    XCTAssertEqual(session.webURL(path: "/projects/p1?task=t1")?.absoluteString,
                   "https://demo.invalid/projects/p1?task=t1&workspace=\(DemoIDs.mekari)")
  }
}
