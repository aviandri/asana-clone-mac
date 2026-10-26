// Swift 5.10's Linux Foundation doesn't mark URL Sendable yet (Darwin's and Swift 6's do).
#if canImport(FoundationNetworking) && compiler(<6.0)
@preconcurrency import Foundation
#else
import Foundation
#endif
import MekariProjectKit
import XCTest
@testable import MekariProjectFeatures

/// Composer drafts, session-scoped task uploads, downloads and the wipe rules (SPEC-MAC §8).
final class AttachmentStoreTests: XCTestCase {
  var scratch: URL!
  /// Kept alive for the test: the session owns the upload store's API (weakly, as in the app).
  var sessions: [AppSession] = []

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("att-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: scratch)
  }

  func file(_ name: String, _ contents: String = "hello") throws -> URL {
    let url = scratch.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
  }

  func sparse(_ size: Int64, _ name: String = "big.bin") throws -> URL {
    let url = scratch.appendingPathComponent(name)
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(size))
    try handle.close()
    return url
  }

  @MainActor
  func openTask(_ fake: FakeMekariAPI, _ id: String = DemoIDs.taskWithAttachments) async -> (AppSession, TaskDetailStore) {
    let session = await signedInSession(fake)
    session.uploadSlots.rateLimitRetryDelay = .zero
    sessions.append(session)
    await stopPolling(session)
    let store = session.scope!.taskDetail(id)
    await store.load()
    return (session, store)
  }

  @MainActor
  func calls(_ fake: FakeMekariAPI, _ endpoint: FakeEndpoint) async -> Int {
    await fake.calls.filter { $0.endpoint == endpoint }.count
  }

  // MARK: - Task detail

  @MainActor
  func testLoadsAttachmentsNewestFirstAndCommentOnes() async {
    let (_, store) = await openTask(demoFake())
    XCTAssertEqual(store.attachments.map(\.id), [DemoIDs.attachmentCommentImage, DemoIDs.attachmentLink, DemoIDs.attachmentText,
                                                 DemoIDs.attachmentPDF, DemoIDs.attachmentPNG])
    XCTAssertEqual(store.task?.attachmentCount, 5)
    let commentWithImage = store.stories.compactMap { story -> Comment? in
      if case .comment(let c) = story, !c.attachments.isEmpty { return c }
      return nil
    }
    XCTAssertEqual(commentWithImage.first?.attachments.map(\.id), [DemoIDs.attachmentCommentImage])
    XCTAssertTrue(store.canAttach)
  }

  @MainActor
  func testDeletePermissions() async {
    let (_, store) = await openTask(demoFake())
    let mine = store.attachments.first { $0.id == DemoIDs.attachmentPDF }!     // alice uploaded it
    let admins = store.attachments.first { $0.id == DemoIDs.attachmentPNG }!   // admin uploaded it; alice is EDITOR
    XCTAssertTrue(store.canDelete(mine))
    XCTAssertFalse(store.canDelete(admins))
  }

  @MainActor
  func testTaskLevelUploadLandsInTheListAndBumpsTheCount() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    store.attach(fileAt: try file("screenshot.png"))
    await waitUntil("upload landed") { store.attachments.count == 6 }
    XCTAssertEqual(store.attachments.first?.name, "screenshot.png")
    XCTAssertEqual(store.attachments.first?.draft, false)
    XCTAssertEqual(store.task?.attachmentCount, 6)
    XCTAssertEqual(store.uploads, [], "finished task uploads leave the list")
  }

  @MainActor
  func testOver100MBFailsAtOnceWithoutARequest() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    store.attach(fileAt: try sparse(AttachmentLimits.maxUploadBytes + 1))
    guard case .failed(let error)? = store.uploads.first?.state else { return XCTFail("expected a failed upload") }
    XCTAssertEqual(error.code, .payloadTooLarge)
    XCTAssertNil(error.status)
    let uploadCalls = await calls(fake, .uploadAttachment)
    XCTAssertEqual(uploadCalls, 0)
    store.cancelUpload(store.uploads[0].id)
    XCTAssertEqual(store.uploads, [])
  }

  @MainActor
  func testTaskUploadsSurviveClosingTheTaskAndReappear() async throws {
    let fake = demoFake()
    let (session, store) = await openTask(fake)
    await fake.hold(.uploadAttachment)
    store.attach(fileAt: try file("later.txt"))
    await waitUntil("upload parked") { await fake.parkedCount(.uploadAttachment) == 1 }
    // A different workspace and back: the scope (and its stores) are replaced, the upload isn't.
    await session.switchWorkspace(to: DemoIDs.acmePilot)
    XCTAssertEqual(session.uploads.uploads(for: DemoIDs.taskWithAttachments).count, 1)
    await session.switchWorkspace(to: DemoIDs.mekari)
    let reopened = session.scope!.taskDetail(DemoIDs.taskWithAttachments)
    XCTAssertFalse(reopened === store)
    await reopened.load()
    XCTAssertEqual(reopened.uploads.map(\.name), ["later.txt"])
    await fake.release(.uploadAttachment, all: true)
    await waitUntil("landed in the reopened task") { reopened.attachments.contains { $0.name == "later.txt" } }
    XCTAssertEqual(reopened.uploads, [])
  }

  @MainActor
  func testFailedTaskUploadRetries() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    await fake.failNext(.uploadAttachment, with: APIError(code: .insufficientStorage, status: 507, message: "Out of space"))
    store.attach(fileAt: try file("x.txt"))
    await waitUntil("failed") { store.uploads.first?.isFailed == true }
    guard case .failed(let error)? = store.uploads.first?.state else { return XCTFail() }
    XCTAssertEqual(error.code, .insufficientStorage)
    XCTAssertEqual(error.message, "Out of space", "the server's message is kept")
    store.retryUpload(store.uploads[0].id)
    await waitUntil("retried and landed") { store.uploads.isEmpty && store.attachments.contains { $0.name == "x.txt" } }
  }

  @MainActor
  func testAddLinkThrowsForThePopoverAndAddsOnSuccess() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    do {
      try await store.addLink("javascript:alert(1)", title: nil)
      XCTFail("expected a validation error")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .validation)
      XCTAssertNotNil(error.issue(for: "url"))
    }
    let linkCalls = await calls(fake, .addLink)
    XCTAssertEqual(linkCalls, 0, "checked locally first")
    try await store.addLink("https://github.com/aviandri", title: "Repo")
    XCTAssertEqual(store.attachments.first?.title, "Repo")
  }

  @MainActor
  func testCommentersCantAttachToTheTask() async {
    let fake = demoFake()
    let session = await signedInSession(fake)
    await stopPolling(session)
    await session.scope!.sidebar.load()
    let readOnly = await fake.currentTasks().first { $0.projectId == DemoIDs.readOnlyProject }!
    let store = session.scope!.taskDetail(readOnly.id)
    await store.load()
    XCTAssertFalse(store.canAttach)
  }

  @MainActor
  func testDeleteIsOptimisticAndRestoresOnFailure() async {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    await fake.hold(.deleteAttachment)
    let deleting = Task { await store.deleteAttachment(DemoIDs.attachmentPDF) }
    await waitUntil("delete in flight") { await fake.parkedCount(.deleteAttachment) == 1 }
    XCTAssertFalse(store.attachments.contains { $0.id == DemoIDs.attachmentPDF }, "gone at once")
    await fake.failNext(.deleteAttachment, with: APIError(code: .forbidden, status: 403, message: "No"))
    await fake.release(.deleteAttachment, all: true)
    await deleting.value
    XCTAssertTrue(store.attachments.contains { $0.id == DemoIDs.attachmentPDF }, "back after the failure")
    XCTAssertEqual(store.lastError?.code, .forbidden)
  }

  @MainActor
  func testDeletingTheLastAttachmentOfAnEmptyCommentRemovesTheComment() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    XCTAssertTrue(store.composer.attach(fileAt: try file("only.png")))
    await waitUntil("draft uploaded") { store.composer.attachments.first?.isFinished == true }
    XCTAssertTrue(store.composer.canSend, "attachments alone can be sent")
    await store.composer.send()
    guard case .comment(let posted)? = store.stories.last else { return XCTFail("no comment") }
    XCTAssertEqual(posted.body, "")
    let attachmentID = try XCTUnwrap(posted.attachments.first?.id)
    XCTAssertTrue(store.attachments.contains { $0.id == attachmentID }, "comment attachments are in the task list too")
    await store.deleteAttachment(attachmentID)
    XCTAssertFalse(store.stories.contains { $0.id == Story.comment(posted).id })
    let stories = try await fake.stories(taskID: DemoIDs.taskWithAttachments)
    XCTAssertFalse(stories.contains { $0.id == Story.comment(posted).id }, "the server dropped it too")
  }

  @MainActor
  func testA429IsRetriedOnceAutomatically() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    await fake.failNext(.uploadAttachment, with: APIError(code: .rateLimited, status: 429, message: "Slow down"))
    store.attach(fileAt: try file("retry.txt"))
    await waitUntil("landed after one retry") { store.attachments.contains { $0.name == "retry.txt" } }
    let uploadCalls = await calls(fake, .uploadAttachment)
    XCTAssertEqual(uploadCalls, 2)
    await fake.failNext(.uploadAttachment, with: APIError(code: .rateLimited, status: 429, message: "Slow down"), times: 2)
    store.attach(fileAt: try file("twice.txt"))
    await waitUntil("failed after the retry") { store.uploads.first?.isFailed == true }
    guard case .failed(let error)? = store.uploads.first?.state else { return XCTFail() }
    XCTAssertEqual(error.code, .rateLimited)
  }

  @MainActor
  func testA429AfterTheWholeBodyIsNotResent() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    await fake.failNextUploadAfterBody(with: APIError(code: .rateLimited, status: 429, message: "Draft quota"))
    store.composer.attach(fileAt: try file("quota.txt"))
    await waitUntil("failed") { store.composer.attachments.first?.isFailed == true }
    let uploadCalls = await calls(fake, .uploadAttachment)
    XCTAssertEqual(uploadCalls, 1, "a body that was fully sent isn't sent again automatically")
    guard case .failed(let error)? = store.composer.attachments.first?.state else { return XCTFail() }
    XCTAssertEqual(error.code, .rateLimited)
    let removed = await store.composer.remove(store.composer.attachments[0].id)
    XCTAssertTrue(removed, "not stuck in finishing")
  }

  @MainActor
  func testLinksAndRefreshesWaitForAnUploadSlot() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    await fake.hold(.uploadAttachment)
    for i in 0..<3 { store.attach(fileAt: try file("u\(i).txt")) }
    await waitUntil("three parked") { await fake.parkedCount(.uploadAttachment) == 3 }
    let linking = Task { try await store.addLink("https://example.com/spec", title: nil) }
    await settle()
    let linkCalls = await calls(fake, .addLink)
    XCTAssertEqual(linkCalls, 0, "the BE counts links in the 3 (A12)")
    await fake.release(.uploadAttachment)
    try await linking.value
    let after = await calls(fake, .addLink)
    XCTAssertEqual(after, 1)
    await fake.release(.uploadAttachment, all: true)
  }

  @MainActor
  func testDeletingACommentDropsItsAttachmentsFromTheTask() async {
    // bob's comment carries the seeded image; an admin may delete any comment.
    let adminSession = await signedInSession(FakeMekariAPI(seed: .demo(today: TestTime.today), signedInAs: "admin@example.com"))
    sessions.append(adminSession)
    let store = adminSession.scope!.taskDetail(DemoIDs.taskWithAttachments)
    await store.load()
    let commentID = store.attachments.first { $0.id == DemoIDs.attachmentCommentImage }!.commentId!
    await store.deleteComment(commentID)
    XCTAssertFalse(store.attachments.contains { $0.id == DemoIDs.attachmentCommentImage })
    XCTAssertEqual(store.task?.attachmentCount, 4)
  }

  @MainActor
  func testAnEmptyEditKeepsACommentThatHasAttachments() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    store.composer.draft = "with a file"
    store.composer.attach(fileAt: try file("f.txt"))
    await waitUntil("uploaded") { store.composer.attachments.first?.isFinished == true }
    await store.composer.send()
    guard case .comment(let comment)? = store.stories.last else { return XCTFail() }
    await store.editComment(comment.id, body: "  ")
    guard case .comment(let edited)? = store.stories.last else { return XCTFail() }
    XCTAssertEqual(edited.body, "", "A9: the body may go empty when there are attachments")
    XCTAssertNil(store.lastError)
  }

  @MainActor
  func testAFailedPreCheckIsDroppedWithItsWorkspace() async throws {
    let fake = demoFake()
    let (session, store) = await openTask(fake)
    store.attach(fileAt: try sparse(AttachmentLimits.maxUploadBytes + 1))
    XCTAssertEqual(session.uploads.all.count, 1)
    session.uploads.cancel(workspaceID: DemoIDs.mekari)
    XCTAssertEqual(session.uploads.all, [])
  }

  @MainActor
  func testStartingSignedOutWipesTheCache() async throws {
    let cache = AttachmentCache.scratch()
    let directory = await cache.directory
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("leftover"), withIntermediateDirectories: true)
    let session = AppSession(settings: InMemoryServerSettings(), tokens: InMemoryTokenStore(), apiFactory: { _, _ in demoFake() },
                             attachmentCache: cache)
    await session.start()
    XCTAssertEqual(session.state, .signedOut)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  // MARK: - Composer

  @MainActor
  func testComposerPostsDraftIDsAndClearsOnlyWhatItSent() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    let composer = store.composer
    composer.attach(fileAt: try file("a.txt"))
    await waitUntil("a uploaded") { composer.attachments.first?.isFinished == true }
    let draft = try XCTUnwrap(composer.attachments.first?.attachment)
    XCTAssertTrue(draft.draft)
    let before = await fake.currentAttachments().filter { $0.id == draft.id && $0.draft }.count
    XCTAssertEqual(before, 1, "uploaded with ?draft=true")

    composer.draft = "See attached"
    await fake.hold(.addComment)
    let sending = Task { await composer.send() }
    await waitUntil("send in flight") { await fake.parkedCount(.addComment) == 1 }
    XCTAssertEqual(composer.sendingIDs, [composer.attachments[0].id])
    let refused = await composer.remove(composer.attachments[0].id)
    XCTAssertFalse(refused, "a chip being posted can't be removed")
    composer.attach(fileAt: try file("b.txt"))       // added mid-send: stays for the next comment
    await fake.release(.addComment, all: true)
    await sending.value
    XCTAssertEqual(composer.attachments.map(\.name), ["b.txt"])
    guard case .comment(let comment)? = store.stories.last else { return XCTFail() }
    XCTAssertEqual(comment.attachments.map(\.id), [draft.id])
    XCTAssertEqual(comment.body, "See attached")
  }

  @MainActor
  func testSendWaitsForUploadsButNotForFailedChips() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    let composer = store.composer
    composer.draft = "hi"
    await fake.hold(.uploadAttachment)
    composer.attach(fileAt: try file("slow.txt"))
    await waitUntil("uploading") { await fake.parkedCount(.uploadAttachment) == 1 }
    XCTAssertFalse(composer.canSend, "Send is disabled while uploads run")
    composer.attach(fileAt: try sparse(AttachmentLimits.maxUploadBytes + 1))
    await fake.release(.uploadAttachment, all: true)
    await waitUntil("finished") { composer.attachments.first?.isFinished == true }
    XCTAssertTrue(composer.attachments[1].isFailed)
    XCTAssertTrue(composer.canSend, "a failed chip doesn't block")
    await composer.send()
    XCTAssertEqual(composer.attachments, [], "failed chips go with a successful send")
  }

  @MainActor
  func testRemoveAndDiscardDeleteTheServerDrafts() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    let composer = store.composer
    composer.attach(fileAt: try file("one.txt"))
    composer.attach(fileAt: try file("two.txt"))
    await waitUntil("both uploaded") { composer.attachments.allSatisfy(\.isFinished) }
    let ids = composer.attachments.compactMap(\.attachment?.id)
    let removed = await composer.remove(composer.attachments[0].id)
    XCTAssertTrue(removed)
    await composer.discard()
    XCTAssertEqual(composer.attachments, [])
    let left = await fake.currentAttachments().filter { ids.contains($0.id) }
    XCTAssertEqual(left, [])
  }

  @MainActor
  func testDiscardDuringASendLeavesThePostedDraftsAlone() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    let composer = store.composer
    composer.attach(fileAt: try file("posted.txt"))
    await waitUntil("uploaded") { composer.attachments.first?.isFinished == true }
    let draftID = try XCTUnwrap(composer.attachments.first?.attachment?.id)
    await fake.hold(.addComment)
    let sending = Task { await composer.send() }
    await waitUntil("send in flight") { await fake.parkedCount(.addComment) == 1 }
    await composer.discard()                          // the task window closes mid-send
    let deletes = await calls(fake, .deleteAttachment)
    XCTAssertEqual(deletes, 0, "a chip being posted isn't deleted")
    await fake.release(.addComment, all: true)
    await sending.value
    guard case .comment(let comment)? = store.stories.last else { return XCTFail("no comment") }
    XCTAssertEqual(comment.attachments.map(\.id), [draftID], "the comment kept its attachment")
  }

  @MainActor
  func testDiscardDuringAFailedSendDeletesTheDraftsAfterwards() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    let composer = store.composer
    composer.attach(fileAt: try file("lost.txt"))
    await waitUntil("uploaded") { composer.attachments.first?.isFinished == true }
    let draftID = try XCTUnwrap(composer.attachments.first?.attachment?.id)
    await fake.hold(.addComment)
    let sending = Task { await composer.send() }
    await waitUntil("send in flight") { await fake.parkedCount(.addComment) == 1 }
    await composer.discard()
    await fake.failNext(.addComment, with: .transport())
    await fake.release(.addComment, all: true)
    await sending.value
    let left = await fake.currentAttachments().filter { $0.id == draftID }
    XCTAssertEqual(left, [], "the send failed, so the discarded draft is deleted")
  }

  @MainActor
  func testAFailedSendThatTheServerCommittedKeepsItsAttachments() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    let composer = store.composer
    composer.attach(fileAt: try file("kept.txt"))
    await waitUntil("uploaded") { composer.attachments.first?.isFinished == true }
    let draftID = try XCTUnwrap(composer.attachments.first?.attachment?.id)
    await fake.hold(.addComment)
    let sending = Task { await composer.send() }
    await waitUntil("send in flight") { await fake.parkedCount(.addComment) == 1 }
    await composer.discard()
    // The server took the comment, but the answer never arrived (a dropped connection).
    _ = try await fake.addCommentDirectly(taskID: DemoIDs.taskWithAttachments, attachmentIDs: [draftID])
    await fake.failNext(.addComment, with: .transport())
    await fake.release(.addComment, all: true)
    await sending.value
    let kept = await fake.currentAttachments().filter { $0.id == draftID }
    XCTAssertEqual(kept.count, 1, "a transport failure isn't a rejection: the posted attachment stays")
  }

  @MainActor
  func testAProxy5xxAfterTheServerCommittedKeepsTheAttachments() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    let composer = store.composer
    composer.attach(fileAt: try file("kept502.txt"))
    await waitUntil("uploaded") { composer.attachments.first?.isFinished == true }
    let draftID = try XCTUnwrap(composer.attachments.first?.attachment?.id)
    await fake.hold(.addComment)
    let sending = Task { await composer.send() }
    await waitUntil("send in flight") { await fake.parkedCount(.addComment) == 1 }
    await composer.discard()
    _ = try await fake.addCommentDirectly(taskID: DemoIDs.taskWithAttachments, attachmentIDs: [draftID])
    await fake.failNext(.addComment, with: APIError(code: .unknown("HTTP 502"), status: 502, message: "Bad gateway"))
    await fake.release(.addComment, all: true)
    await sending.value
    let kept = await fake.currentAttachments().filter { $0.id == draftID }
    XCTAssertEqual(kept.count, 1, "a 5xx isn't a definite rejection")
  }

  @MainActor
  func testASendWhoseAnswerWasLostNeverDeletesWhatLanded() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    let composer = store.composer
    composer.attach(fileAt: try file("landed.txt"))
    await waitUntil("uploaded") { composer.attachments.first?.isFinished == true }
    let draftID = try XCTUnwrap(composer.attachments.first?.attachment?.id)
    await fake.hold(.addComment)
    let sending = Task { await composer.send() }
    await waitUntil("send in flight") { await fake.parkedCount(.addComment) == 1 }
    // The BE commits, then the answer is lost (a 502 from the proxy).
    _ = try await fake.addCommentDirectly(taskID: DemoIDs.taskWithAttachments, attachmentIDs: [draftID])
    await fake.failNext(.addComment, with: APIError(code: .unknown("HTTP 502"), status: 502, message: "Bad gateway"))
    await fake.release(.addComment, all: true)
    await sending.value
    XCTAssertEqual(composer.attachments.first?.isFinished, true, "the chip stays (the outcome is unknown)")
    let removed = await composer.remove(composer.attachments[0].id)
    XCTAssertTrue(removed)
    let kept = await fake.currentAttachments().filter { $0.id == draftID && $0.commentId != nil }
    XCTAssertEqual(kept.count, 1, "it was posted: never deleted")
    let shown = store.stories.contains { story in
      if case .comment(let c) = story { return c.attachments.contains { $0.id == draftID } }
      return false
    }
    XCTAssertTrue(shown, "the stories reload and show it")
  }

  @MainActor
  func testReSendingAfterALostAnswerDoesntPostTwice() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    let composer = store.composer
    composer.attach(fileAt: try file("once.txt"))
    await waitUntil("uploaded") { composer.attachments.first?.isFinished == true }
    let draftID = try XCTUnwrap(composer.attachments.first?.attachment?.id)
    composer.draft = "Here"
    await fake.hold(.addComment)
    let sending = Task { await composer.send() }
    await waitUntil("send in flight") { await fake.parkedCount(.addComment) == 1 }
    _ = try await fake.addCommentDirectly(taskID: DemoIDs.taskWithAttachments, body: "Here", attachmentIDs: [draftID])
    await fake.failNext(.addComment, with: .transport())
    await fake.release(.addComment, all: true)
    await sending.value
    XCTAssertEqual(composer.draft, "Here", "kept after the failure")
    let before = await calls(fake, .addComment)
    await composer.send()
    let after = await calls(fake, .addComment)
    XCTAssertEqual(after, before, "it had landed: not posted again")
    XCTAssertEqual(composer.draft, "")
    XCTAssertEqual(composer.attachments, [])
  }

  @MainActor
  func testASweptDraftDoesntCountAsLandedSoTheTextIsPosted() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    let composer = store.composer
    composer.attach(fileAt: try file("swept.txt"))
    await waitUntil("uploaded") { composer.attachments.first?.isFinished == true }
    let draftID = try XCTUnwrap(composer.attachments.first?.attachment?.id)
    composer.draft = "Really sent?"
    await fake.failNext(.addComment, with: .transport()) // the send really failed
    await composer.send()
    try await fake.deleteAttachment(draftID)              // later the draft is swept (or deleted elsewhere)
    await composer.send()                                 // the user tries again with the same text
    XCTAssertEqual(composer.draft, "", "sent this time")
    XCTAssertEqual(composer.attachments, [], "the gone chip left")
    guard case .comment(let comment)? = store.stories.last else { return XCTFail("no comment") }
    XCTAssertEqual(comment.body, "Really sent?", "a 404 isn't 'landed': the text is posted, not dropped")
  }

  @MainActor
  func testACancelledSendLeavesItsChipsUncertain() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    let composer = store.composer
    composer.attach(fileAt: try file("cancelled.txt"))
    await waitUntil("uploaded") { composer.attachments.first?.isFinished == true }
    let draftID = try XCTUnwrap(composer.attachments.first?.attachment?.id)
    await fake.hold(.addComment)
    let sending = Task { await composer.send() }
    await waitUntil("send in flight") { await fake.parkedCount(.addComment) == 1 }
    _ = try await fake.addCommentDirectly(taskID: DemoIDs.taskWithAttachments, attachmentIDs: [draftID]) // the BE commits
    sending.cancel()                                     // and the caller goes away before the answer
    await fake.release(.addComment, all: true)
    await sending.value
    XCTAssertTrue(composer.sendingIDs.isEmpty)
    await composer.discard()
    let kept = await fake.currentAttachments().filter { $0.id == draftID }
    XCTAssertEqual(kept.count, 1, "a cancelled send is no rejection: what landed is never deleted")
  }

  @MainActor
  func testALostAnswerThatDidntLandStillDeletesOnRemoveAndDiscard() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    let composer = store.composer
    composer.attach(fileAt: try file("a.txt"))
    composer.attach(fileAt: try file("b.txt"))
    await waitUntil("uploaded") { composer.attachments.allSatisfy(\.isFinished) }
    let ids = composer.attachments.compactMap(\.attachment?.id)
    await fake.failNext(.addComment, with: .transport())
    await composer.send()
    let removed = await composer.remove(composer.attachments[0].id)
    XCTAssertTrue(removed)
    await composer.discard()
    let left = await fake.currentAttachments().filter { ids.contains($0.id) }
    XCTAssertEqual(left, [], "still drafts after asking: deleted")
  }

  @MainActor
  func testTwentyChipsAtMostAndFailedOnesDontCount() async throws {
    let (_, store) = await openTask(demoFake())
    let composer = store.composer
    XCTAssertTrue(composer.attach(fileAt: try sparse(AttachmentLimits.maxUploadBytes + 1, "huge.bin")))
    for i in 0..<20 { XCTAssertTrue(composer.attach(fileAt: try file("f\(i).txt")), "chip \(i)") }
    XCTAssertFalse(composer.hasRoomForAnother)
    XCTAssertFalse(composer.attach(fileAt: try file("f20.txt")))
    let added = try await composer.attachLink("https://example.com", title: nil)
    XCTAssertFalse(added)
    XCTAssertEqual(composer.attachments.count, 21)
  }

  @MainActor
  func testDraftLinksFailWithoutLeavingAChip() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    let composer = store.composer
    await fake.failNext(.addLink, with: APIError(code: .validation, status: 400, message: "Bad link",
                                                 issues: [FieldIssue(path: ["url"], message: "Bad link")]))
    do {
      try await composer.attachLink("https://example.com/x", title: nil)
      XCTFail("expected the server's error")
    } catch let error as APIError {
      XCTAssertEqual(error.issue(for: "url")?.message, "Bad link")
    }
    XCTAssertEqual(composer.attachments, [])
    try await composer.attachLink("https://example.com/y", title: "Spec")
    XCTAssertEqual(composer.attachments.first?.attachment?.draft, true)
    XCTAssertEqual(composer.attachments.first?.name, "Spec")
  }

  @MainActor
  func testPastedTempFilesAreDeletedWhenTheChipGoes() async throws {
    let (_, store) = await openTask(demoFake())
    let pasted = try file("Pasted image.png")
    store.composer.attach(fileAt: pasted, deletesFile: true)
    await waitUntil("uploaded") { store.composer.attachments.first?.isFinished == true }
    XCTAssertTrue(FileManager.default.fileExists(atPath: pasted.path), "kept until the chip goes (retry needs it)")
    await store.composer.send()
    XCTAssertFalse(FileManager.default.fileExists(atPath: pasted.path))

    let taskLevel = try file("Pasted image 2.png")
    store.attach(fileAt: taskLevel, deletesFile: true)
    await waitUntil("landed") { store.uploads.isEmpty && store.attachments.contains { $0.name == "Pasted image 2.png" } }
    XCTAssertFalse(FileManager.default.fileExists(atPath: taskLevel.path))
  }

  @MainActor
  func testAtMostThreeUploadsRunAtOnce() async throws {
    let fake = demoFake()
    let (_, store) = await openTask(fake)
    await fake.hold(.uploadAttachment)
    for i in 0..<2 { store.attach(fileAt: try file("t\(i).txt")) }
    for i in 0..<2 { store.composer.attach(fileAt: try file("c\(i).txt")) }
    await waitUntil("three parked") { await fake.parkedCount(.uploadAttachment) == 3 }
    await settle()
    let parked = await fake.parkedCount(.uploadAttachment)
    XCTAssertEqual(parked, 3, "task uploads and composer chips share the 3 slots")
    let queued = (store.uploads + store.composer.attachments).filter { $0.state == .queued }
    XCTAssertEqual(queued.count, 1)
    await fake.release(.uploadAttachment)
    await waitUntil("the fourth starts") { await fake.parkedCount(.uploadAttachment) == 3 }
    await fake.release(.uploadAttachment, all: true)
    await waitUntil("all done") { store.uploads.isEmpty && store.composer.attachments.allSatisfy(\.isFinished) }
  }

  @MainActor
  func testFinishingUploadsCantBeCancelled() async throws {
    let slots = UploadSlots()
    let uploads = AttachmentUploads(slots: slots, api: { nil })
    uploads.all = [AttachmentUpload(taskID: "t", source: .file(try file("f.txt"), name: "f.txt"), state: .finishing)]
    XCTAssertFalse(uploads.cancel(uploads.all[0].id))
    XCTAssertEqual(uploads.all.count, 1)
  }

  // MARK: - Downloads & wipe rules

  @MainActor
  func testDownloadsReportProgressAndRevalidateOnlyWhenAsked() async throws {
    let fake = demoFake()
    let (session, store) = await openTask(fake)
    let files = session.scope!.attachmentFiles
    let pdf = store.attachments.first { $0.id == DemoIDs.attachmentPDF }!
    let url = await files.file(for: pdf)
    XCTAssertNotNil(url)
    XCTAssertEqual(files.downloads, [:])
    let fast = await files.file(for: pdf, revalidate: false)
    XCTAssertEqual(fast, url)
    let downloadCalls = await calls(fake, .download)
    XCTAssertEqual(downloadCalls, 1, "revalidate: false uses the cached copy without a request")
    let thumb = await files.thumbnail(for: store.attachments.first { $0.id == DemoIDs.attachmentPNG }!, size: .small)
    XCTAssertEqual(thumb, FakeMekariAPI.pngBytes)
    let noThumb = await files.thumbnail(for: pdf, size: .small)
    XCTAssertNil(noThumb)
  }

  @MainActor
  func testSignOutCancelsUploadsAndEmptiesTheCache() async throws {
    let fake = demoFake()
    let (session, store) = await openTask(fake)
    let directory = await session.attachmentCache.directory
    _ = await session.scope!.attachmentFiles.file(for: store.attachments.first { $0.id == DemoIDs.attachmentPDF }!)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(DemoIDs.attachmentPDF).path))
    await fake.hold(.uploadAttachment)
    store.attach(fileAt: try file("x.txt"))
    await waitUntil("parked") { await fake.parkedCount(.uploadAttachment) == 1 }
    await session.signOut()
    await session.pendingWipe?.value
    XCTAssertEqual(session.uploads.all, [])
    let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    XCTAssertEqual(left, [], "the cache dir is empty after sign-out")
    await fake.release(.uploadAttachment, all: true)
  }

  @MainActor
  func testLosingTheWorkspaceWipesTheCacheAndItsUploads() async throws {
    let fake = demoFake()
    let (session, store) = await openTask(fake)
    let directory = await session.attachmentCache.directory
    _ = await session.scope!.attachmentFiles.file(for: store.attachments.first { $0.id == DemoIDs.attachmentPDF }!)
    await fake.hold(.uploadAttachment)
    store.attach(fileAt: try file("x.txt"))
    await waitUntil("parked") { await fake.parkedCount(.uploadAttachment) == 1 }
    await fake.removeMembership(userID: DemoIDs.alice, workspaceID: DemoIDs.mekari)
    await session.scope!.myTasks.refresh() // 404 → lost access → recovery
    await waitUntil("recovered") { session.current?.id == DemoIDs.acmePilot }
    XCTAssertEqual(session.uploads.all, [])
    let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    XCTAssertEqual(left, [])
    await fake.release(.uploadAttachment, all: true)
  }
}

final class UploadStateOrderTests: XCTestCase {
  func testLateProgressNeverOverwritesTheOutcome() {
    let finished = AttachmentUpload(taskID: "t", source: .link(url: "https://x.y", title: nil),
                                    state: .finished(Attachment(id: "a", workspaceId: "w", taskId: "t", kind: .link,
                                                                uploader: alice, createdAt: Date())))
    XCTAssertFalse(finished.accepts(.finishing))
    XCTAssertFalse(finished.accepts(.uploading(TransferProgress(completed: 1, total: 2))))
    let failed = AttachmentUpload(taskID: "t", source: .link(url: "https://x.y", title: nil), state: .failed(.transport()))
    XCTAssertFalse(failed.accepts(.finishing))
    XCTAssertTrue(failed.accepts(.queued), "retry")
    let finishing = AttachmentUpload(taskID: "t", source: .link(url: "https://x.y", title: nil), state: .finishing)
    XCTAssertFalse(finishing.accepts(.uploading(TransferProgress(completed: 1, total: 2))))
    XCTAssertTrue(finishing.accepts(.finished(finished.attachment!)))
  }
}
