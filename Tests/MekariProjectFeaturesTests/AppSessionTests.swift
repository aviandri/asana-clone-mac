import Foundation
import MekariProjectKit
import XCTest
@testable import MekariProjectFeatures

// Linux: @MainActor goes on each async test method, not the class.
final class AppSessionTests: XCTestCase {
  @MainActor
  func testStartWithoutAServerOrSessionIsSignedOut() async {
    let none = AppSession(settings: InMemoryServerSettings(), tokens: InMemoryTokenStore(), apiFactory: { _, _ in demoFake() }, attachmentCache: .scratch())
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
    let session = AppSession(settings: InMemoryServerSettings(), tokens: InMemoryTokenStore(), apiFactory: { _, _ in fake }, attachmentCache: .scratch())
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
  func testSwitchingAwayAndBackBeforeTheFirstCommitsEndsWhereTheUserLastChose() async {
    let fake = demoFake()
    let session = await signedInSession(fake) // on Mekari
    await fake.hold(.switchWorkspace)
    async let toAcme: Void = session.switchWorkspace(to: DemoIDs.acmePilot)
    await waitUntil("the first POST is in flight") { await fake.parkedCount(.switchWorkspace) == 1 }
    async let back: Void = session.switchWorkspace(to: DemoIDs.mekari) // ⌘2 right after ⌘1
    await fake.release(.switchWorkspace, all: true)
    _ = await (toAcme, back)

    XCTAssertEqual(session.current?.id, DemoIDs.mekari)
    // The server was told about Acme, so going back is POSTed too: the next launch opens Mekari.
    let posts = await fake.calls.filter { $0.endpoint == .switchWorkspace }.count
    XCTAssertEqual(posts, 2)
    let next = try? await fake.me()
    XCTAssertEqual(next?.currentWorkspace?.id, DemoIDs.mekari)
  }

  @MainActor
  func testASwitchSupersededBeforeItStartsNeverPosts() async {
    let fake = demoFake()
    let session = await signedInSession(fake)
    await fake.hold(.switchWorkspace)
    async let first: Void = session.switchWorkspace(to: DemoIDs.acmePilot)
    await waitUntil("the first POST is in flight") { await fake.parkedCount(.switchWorkspace) == 1 }
    // `async let` children start in no fixed order: queue them one at a time so "newest" is certain.
    async let second: Void = session.switchWorkspace(to: DemoIDs.acmePilot) // queued behind the first…
    await waitUntil("second queued") { session.queuedJobs == 2 }
    async let third: Void = session.switchWorkspace(to: DemoIDs.mekari)     // …and superseded by this one
    await waitUntil("all three queued") { session.queuedJobs == 3 }
    XCTAssertTrue(session.isSwitching)
    await fake.release(.switchWorkspace, all: true)
    _ = await (first, second, third)

    XCTAssertEqual(session.current?.id, DemoIDs.mekari)
    XCTAssertEqual(session.skippedJobs, 1) // the second never started
    let posts = await fake.calls.filter { $0.endpoint == .switchWorkspace }.count
    XCTAssertEqual(posts, 2) // first and third; the second was skipped before its POST
    XCTAssertFalse(session.isSwitching)
  }

  @MainActor
  func testLostAccessDoesNotOverrideASwitchTheUserAlreadyStarted() async {
    let fake = demoFake()
    let session = await signedInSession(fake)
    await session.switchWorkspace(to: DemoIDs.acmePilot)
    let acmeScope = session.scope

    await fake.hold(.switchWorkspace)
    async let userSwitch: Void = session.switchWorkspace(to: DemoIDs.mekari)
    await waitUntil("the switch POST is in flight") { await fake.parkedCount(.switchWorkspace) == 1 }
    // Meanwhile Acme access is revoked and an Acme-scoped load notices.
    await stopPolling(session)
    await fake.removeMembership(userID: DemoIDs.alice, workspaceID: DemoIDs.acmePilot)
    await acmeScope?.myTasks.refresh()
    await fake.release(.switchWorkspace, all: true)
    await userSwitch
    await waitUntil("the queue drains") { session.current?.id == DemoIDs.mekari }
    await settle()

    XCTAssertEqual(session.current?.id, DemoIDs.mekari)
    XCTAssertEqual(session.notice, "Switched to Mekari") // the recovery saw it was moot
    let meCalls = await fake.calls.filter { $0.endpoint == .me }.count
    XCTAssertEqual(meCalls, 1) // only start(); no recovery /auth/me
  }

  @MainActor
  func testLostAccessAdoptsTheServersCurrentWorkspace() async {
    let fake = demoFake()
    let session = await signedInSession(fake)
    await session.switchWorkspace(to: DemoIDs.acmePilot)
    await stopPolling(session)
    await fake.removeMembership(userID: DemoIDs.alice, workspaceID: DemoIDs.acmePilot)
    await session.scope?.myTasks.refresh() // 404 with the header → .workspaceLost
    await settle()
    XCTAssertEqual(session.current?.id, DemoIDs.mekari)
    XCTAssertEqual(session.all.map(\.name), ["Mekari"])
    XCTAssertEqual(session.notice, "You no longer have access to Acme Pilot")
  }

  @MainActor
  func testIsSwitchingCoversQueuedSwitchesAndFailures() async {
    let fake = demoFake()
    let session = await signedInSession(fake)
    XCTAssertFalse(session.isSwitching)
    await fake.hold(.switchWorkspace)
    async let switching: Void = session.switchWorkspace(to: DemoIDs.acmePilot)
    await waitUntil("switch in flight") { await fake.parkedCount(.switchWorkspace) == 1 }
    XCTAssertTrue(session.isSwitching)
    await fake.failNext(.switchWorkspace, with: .transport())
    await fake.release(.switchWorkspace, all: true)
    await switching
    XCTAssertFalse(session.isSwitching)
    XCTAssertEqual(session.current?.id, DemoIDs.mekari)
    XCTAssertEqual(session.notice, "Can't reach the server")
  }

  /// MUST (re-review): after a failed recovery, header and scope still agree (both the lost
  /// workspace), so nothing from another workspace shows under its label; the next focus retries.
  @MainActor
  func testAFailedRecoveryKeepsHeaderAndScopeTogetherAndRetries() async {
    let fake = demoFake()
    let session = await signedInSession(fake)
    await session.switchWorkspace(to: DemoIDs.acmePilot)
    await stopPolling(session)
    await fake.removeMembership(userID: DemoIDs.alice, workspaceID: DemoIDs.acmePilot)
    await fake.failNext(.me, with: .transport())
    await session.scope?.myTasks.refresh()          // 404 → recovery → /auth/me fails
    await waitUntil("recovery ran") { session.queuedJobs == 0 && session.notice?.contains("retrying") == true }

    XCTAssertEqual(session.current?.id, DemoIDs.acmePilot)
    await session.scope?.sidebar.load()
    let lastScoped = await fake.calls.last { $0.endpoint == .projects }
    XCTAssertEqual(lastScoped?.workspaceID, DemoIDs.acmePilot, "the header still names the scope's workspace")
    XCTAssertTrue(session.scope?.sidebar.projects.isEmpty ?? false, "no other workspace's data under this label")

    await session.scope?.refresh()                   // window focus: 404 again → recovery succeeds
    await waitUntil("recovered") { session.current?.id == DemoIDs.mekari }
    XCTAssertEqual(session.notice, "You no longer have access to Acme Pilot")
  }

  @MainActor
  func testARecoverySupersededByAFailingSwitchStillKeepsHeaderAndScopeTogether() async {
    let fake = demoFake()
    let session = await signedInSession(fake)
    await session.switchWorkspace(to: DemoIDs.acmePilot)
    await stopPolling(session)
    await fake.removeMembership(userID: DemoIDs.alice, workspaceID: DemoIDs.acmePilot)
    await fake.hold(.me)
    await session.scope?.myTasks.refresh()          // recovery starts, /auth/me parked
    await waitUntil("recovery in flight") { await fake.parkedCount(.me) == 1 }
    await fake.failNext(.switchWorkspace, with: .transport())
    async let userSwitch: Void = session.switchWorkspace(to: DemoIDs.mekari) // supersedes, then fails
    await waitUntil("switch queued") { session.queuedJobs == 2 }
    await fake.release(.me, all: true)
    await userSwitch
    await waitUntil("queue drained") { session.queuedJobs == 0 }

    XCTAssertEqual(session.current?.id, DemoIDs.acmePilot) // nothing committed
    XCTAssertFalse(session.isSwitching)
    // The next scoped request (focus) still carries the lost workspace's header: it 404s, which
    // queues a fresh recovery, and that one succeeds.
    await session.scope?.sidebar.load()
    let lastScoped = await fake.calls.last { $0.endpoint == .projects }
    XCTAssertEqual(lastScoped?.workspaceID, DemoIDs.acmePilot)
    await waitUntil("recovered") { session.current?.id == DemoIDs.mekari }
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

    let missing = await session.resolve(.task(id: "00000000-0000-4000-8000-00000000dead"))
    XCTAssertEqual(missing, .noAccess)

    // Ids that aren't UUIDs never reach a request.
    let before = await fake.calls.count
    let traversal = await session.resolve(.task(id: "../users"))
    let junk = await session.resolve(.project(id: "nope"))
    XCTAssertEqual(traversal, .noAccess)
    XCTAssertEqual(junk, .noAccess)
    let after = await fake.calls.count
    XCTAssertEqual(after, before)
  }

  @MainActor
  func testWebURLCarriesTheWorkspace() async {
    let session = await signedInSession(demoFake())
    XCTAssertEqual(session.webURL(path: "/projects/p1?task=t1")?.absoluteString,
                   "https://demo.invalid/projects/p1?task=t1&workspace=\(DemoIDs.mekari)")
  }
}
