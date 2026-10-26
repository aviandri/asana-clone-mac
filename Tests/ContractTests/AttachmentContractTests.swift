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
import MekariProjectKit

/// Attachments (BE §13, A1–A12) through the real `LiveMekariAPI` and `URLSessionTransport` (streamed multipart
/// upload, delegate-driven downloads). Skipped unless `MP_BASE_URL` is set. The 429 and 507 cases need their own
/// BEs: `MP_BASE_URL_RATELIMIT` (UPLOAD_RATE_LIMIT_MAX=3) and `MP_BASE_URL_NOSPACE` (a huge STORAGE_MIN_FREE_BYTES).
final class AttachmentContractTests: XCTestCase {
  static let password = "password123"
  var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("att-contract-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: scratch)
  }

  func server(_ variable: String = "MP_BASE_URL") throws -> URL {
    guard let raw = ProcessInfo.processInfo.environment[variable], let url = ServerURL.normalize(raw) else {
      throw XCTSkip("\(variable) not set")
    }
    return url
  }

  func signIn(_ email: String, at variable: String = "MP_BASE_URL") async throws -> (LiveMekariAPI, Me, InMemoryTokenStore) {
    let tokens = InMemoryTokenStore()
    let api = LiveMekariAPI(baseURL: try server(variable), tokens: tokens)
    let me = try await api.login(email: email, password: Self.password)
    await api.setWorkspace(me.currentWorkspace?.id)
    return (api, me, tokens)
  }

  /// A fresh task in a project alice can edit, so tests don't share state.
  func newTask(_ api: LiveMekariAPI, title: String = "Attachments \(UUID().uuidString.prefix(8))") async throws -> TaskDetail {
    let projects = try await api.projects(archived: false)
    let project = try XCTUnwrap(projects.first { $0.name == "Mobile App v2" } ?? projects.first { $0.myRole != .commenter })
    return try await api.createTask(NewTask(title: title, projectId: project.id))
  }

  func file(_ name: String, _ data: Data) throws -> URL {
    let url = scratch.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  func sparse(_ size: Int64) throws -> URL {
    let url = scratch.appendingPathComponent("sparse-\(size).bin")
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(size))
    try handle.close()
    return url
  }

  func expectError(_ code: APIError.Code, status: Int? = nil, _ body: () async throws -> Void,
                   file: StaticString = #filePath, line: UInt = #line) async {
    do {
      try await body()
      XCTFail("expected \(code)", file: file, line: line)
    } catch let error as APIError {
      XCTAssertEqual(error.code, code, error.message, file: file, line: line)
      if let status { XCTAssertEqual(error.status, status, file: file, line: line) }
      XCTAssertFalse(error.message.isEmpty, file: file, line: line)
    } catch {
      XCTFail("\(error)", file: file, line: line)
    }
  }

  static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=")!

  // MARK: - Draft upload, then post

  func testDraftUploadThenPostAsACommentAttachment() async throws {
    let (alice, _, _) = try await signIn("alice@example.com")
    let task = try await newTask(alice)
    let progress = Log()
    // A non-ASCII name: sent as UTF-8 in filename="…" (as browsers do) and kept.
    let draft = try await alice.uploadAttachment(taskID: task.id, file: try file("x.txt", Data("hello attachments".utf8)),
                                                 fileName: "Résumé v2 ✓.txt", draft: true) { progress.add($0) }
    XCTAssertTrue(draft.draft)
    XCTAssertEqual(draft.kind, .file)
    XCTAssertEqual(draft.name, "Résumé v2 ✓.txt")
    XCTAssertEqual(draft.mimeType, "text/plain")
    XCTAssertEqual(draft.size, 17)
    XCTAssertEqual(progress.values.last?.completed, 17)

    let before = try await alice.task(task.id)
    XCTAssertEqual(before.attachments, [], "drafts aren't on the task")
    XCTAssertEqual(before.attachmentCount, 0)

    let comment = try await alice.addComment(taskID: task.id, body: "", attachmentIDs: [draft.id])
    XCTAssertEqual(comment.body, "")
    XCTAssertEqual(comment.attachments.map(\.id), [draft.id])
    XCTAssertEqual(comment.attachments.first?.draft, false)
    XCTAssertEqual(comment.attachments.first?.commentId, comment.id)

    let after = try await alice.task(task.id)
    XCTAssertEqual(after.attachments.map(\.id), [draft.id])
    XCTAssertEqual(after.attachmentCount, 1)
    let stories = try await alice.stories(taskID: task.id)
    let posted = stories.compactMap { story -> Comment? in if case .comment(let c) = story { return c } else { return nil } }
    XCTAssertEqual(posted.last?.attachments.map(\.id), [draft.id])

    // Someone else's draft id is refused.
    let (bob, _, _) = try await signIn("bob@example.com")
    let bobsDraft = try await bob.uploadAttachment(taskID: task.id, file: try file("b.txt", Data("b".utf8)), fileName: nil, draft: true) { _ in }
    await expectError(.validation, status: 400) { _ = try await alice.addComment(taskID: task.id, body: "x", attachmentIDs: [bobsDraft.id]) }

    // Deleting the only attachment of an empty-body comment deletes the comment too.
    try await alice.deleteAttachment(draft.id)
    let storiesAfter = try await alice.stories(taskID: task.id)
    XCTAssertFalse(storiesAfter.contains { $0.id == "comment-\(comment.id)" })
  }

  func testTaskLevelUploadDownloadRevalidateAndThumbnails() async throws {
    let (alice, _, _) = try await signIn("alice@example.com")
    let task = try await newTask(alice)
    let image = try await alice.uploadAttachment(taskID: task.id, file: try file("dot.png", Self.png), fileName: nil, draft: false) { _ in }
    XCTAssertFalse(image.draft)
    XCTAssertEqual(image.mimeType, "image/png")
    XCTAssertTrue(image.isImage)
    XCTAssertEqual(image.width, 2)
    let detail = try await alice.task(task.id)
    XCTAssertEqual(detail.attachments.map(\.id), [image.id])
    let stories = try await alice.stories(taskID: task.id)
    XCTAssertTrue(stories.contains { if case .activity(let a) = $0 { return a.type == ActivityType.attachmentAdded } else { return false } })

    // Download through the cache: ETag, then a 304 the second time, the same bytes.
    let cache = AttachmentCache(directory: scratch.appendingPathComponent("cache"), quarantine: { _ in })
    let url = try await cache.file(for: image, using: alice)
    XCTAssertEqual(try Data(contentsOf: url), Self.png)
    let destination = scratch.appendingPathComponent("again.png")
    let first = try await alice.download(try XCTUnwrap(image.contentPath), to: destination, ifNoneMatch: nil) { _ in }
    guard case .downloaded(let etag?) = first else { return XCTFail("no ETag: \(first)") }
    let second = try await alice.download(image.contentPath!, to: destination, ifNoneMatch: etag) { _ in }
    XCTAssertEqual(second, .notModified)

    // Thumbnails (sharp, WebP) when the server made one.
    if let small = image.thumbnailPath(size: .small) {
      let bytes = try await alice.attachmentData(small)
      XCTAssertEqual(bytes.prefix(4), Data("RIFF".utf8))
    }

    // Byte GETs ignore the workspace header: still served after switching to the other workspace.
    let me = try await alice.me()
    let other = try XCTUnwrap(me.workspaces.first { $0.id != task.workspaceId })
    await alice.setWorkspace(other.id)
    _ = try await alice.attachmentData(image.contentPath!)
    await alice.setWorkspace(task.workspaceId)

    try await alice.deleteAttachment(image.id)
    await expectError(.notFound, status: 404) { _ = try await alice.attachment(image.id) }
  }

  func testLinksAndTheirValidation() async throws {
    let (alice, _, _) = try await signIn("alice@example.com")
    let task = try await newTask(alice)
    await expectError(.validation, status: 400) { _ = try await alice.addLink(taskID: task.id, url: "javascript:alert(1)", title: nil, draft: false) }
    await expectError(.validation, status: 400) {
      _ = try await alice.addLink(taskID: task.id, url: "https://user:pass@example.com/", title: nil, draft: false)
    }
    // Private addresses are never fetched (SSRF rules): the link is still created, its preview FAILED.
    let link = try await alice.addLink(taskID: task.id, url: "http://127.0.0.1:9/x", title: "Local thing", draft: false)
    XCTAssertEqual(link.kind, .link)
    XCTAssertEqual(link.title, "Local thing")
    XCTAssertEqual(link.previewStatus, .failed)
    XCTAssertNotNil(link.linkURL)
    let refreshed = try await alice.refreshLinkPreview(link.id)
    XCTAssertEqual(refreshed.id, link.id)
  }

  func testCommentersCanAddDraftsButNotTaskAttachments() async throws {
    let (alice, _, _) = try await signIn("bob@example.com") // bob is a COMMENTER on one seeded project
    let projects = try await alice.projects(archived: false)
    let readOnly = try XCTUnwrap(projects.first { $0.myRole == .commenter }, "the BE seed makes bob a COMMENTER somewhere")
    let tasks = try await alice.projectTasks(readOnly.id, completed: nil)
    let task = try XCTUnwrap(tasks.first)
    let source = try file("c.txt", Data("c".utf8))
    await expectError(.forbidden, status: 403) { _ = try await alice.uploadAttachment(taskID: task.id, file: source, fileName: nil, draft: false) { _ in } }
    let draft = try await alice.uploadAttachment(taskID: task.id, file: source, fileName: nil, draft: true) { _ in }
    try await alice.deleteAttachment(draft.id)
  }

  // MARK: - Limits & error codes

  func testThe100MBPreCheckSendsNothing() async throws {
    let (alice, _, _) = try await signIn("alice@example.com")
    let task = try await newTask(alice)
    let over = try sparse(AttachmentLimits.maxUploadBytes + 1)
    do {
      _ = try await alice.uploadAttachment(taskID: task.id, file: over, fileName: nil, draft: true) { _ in }
      XCTFail("expected payloadTooLarge")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .payloadTooLarge)
      XCTAssertNil(error.status, "refused locally, no request")
    }
  }

  /// The raw 413: the body goes past the pre-check (sent by hand, the way an older client would).
  func testTheServerRefusesOver100MBWith413() async throws {
    let (alice, _, tokens) = try await signIn("alice@example.com")
    let task = try await newTask(alice)
    let boundary = "raw-\(UUID().uuidString)"
    let body = scratch.appendingPathComponent("raw-body")
    _ = FileManager.default.createFile(atPath: body.path, contents: nil)
    let handle = try FileHandle(forWritingTo: body)
    try handle.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"big.bin\"\r\n\r\n".utf8))
    try handle.seek(toOffset: try handle.offset() + UInt64(AttachmentLimits.maxUploadBytes) + 1024)
    try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    try handle.close()

    var request = URLRequest(url: try server().appendingPathComponent("api/v1/tasks/\(task.id)/attachments"))
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("sid=\(try XCTUnwrap(tokens.load()))", forHTTPHeaderField: "Cookie")
    request.timeoutInterval = 300
    do {
      let (data, response) = try await URLSessionTransport(timeout: 300).upload(request, fromFile: body) { _, _ in }
      XCTAssertEqual(response.statusCode, 413)
      XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("PAYLOAD_TOO_LARGE"), String(decoding: data, as: UTF8.self))
    } catch {
      // The server may reset the connection once it has refused the rest of the body; then nothing was stored either.
      let detail = try await alice.task(task.id)
      XCTAssertEqual(detail.attachments, [], "\(error)")
    }
  }

  func testRateLimitIs429() async throws {
    let (alice, _, _) = try await signIn("alice@example.com", at: "MP_BASE_URL_RATELIMIT")
    let task = try await newTask(alice)
    let source = try file("r.txt", Data("r".utf8))
    var refused: APIError?
    for _ in 0..<5 {
      do {
        _ = try await alice.uploadAttachment(taskID: task.id, file: source, fileName: nil, draft: true) { _ in }
      } catch let error as APIError {
        refused = error
        break
      }
    }
    XCTAssertEqual(refused?.code, .rateLimited)
    XCTAssertEqual(refused?.status, 429)
    XCTAssertFalse(refused?.message.isEmpty ?? true)
  }

  func testNoSpaceIs507() async throws {
    let (alice, _, _) = try await signIn("alice@example.com", at: "MP_BASE_URL_NOSPACE")
    let task = try await newTask(alice)
    await expectError(.insufficientStorage, status: 507) {
      _ = try await alice.uploadAttachment(taskID: task.id, file: try self.file("n.txt", Data("n".utf8)), fileName: nil, draft: true) { _ in }
    }
  }
}

private final class Log: @unchecked Sendable {
  private let lock = NSLock()
  private var list: [TransferProgress] = []
  func add(_ p: TransferProgress) { lock.lock(); list.append(p); lock.unlock() }
  var values: [TransferProgress] { lock.lock(); defer { lock.unlock() }; return list }
}
