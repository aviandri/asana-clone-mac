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

enum AttachmentFixtures {
  static let file = ##"""
  {"id":"att-1","workspaceId":"ws-1","taskId":"t-1","commentId":null,"kind":"FILE","draft":false,
   "uploader":\##(Fixtures.alice),"createdAt":"2026-10-20T09:00:00.000Z",
   "name":"login.png","mimeType":"image/png","size":48213,"width":1280,"height":800,"hasThumbnail":true,
   "url":null,"title":null,"description":null,"siteName":null,"provider":null,"previewStatus":null,
   "hasIcon":false,"hasImage":false,
   "contentPath":"/api/v1/attachments/att-1/content","thumbnailPath":"/api/v1/attachments/att-1/thumbnail",
   "iconPath":null,"imagePath":null}
  """##

  static let link = ##"""
  {"id":"att-2","workspaceId":"ws-1","taskId":"t-1","commentId":"c-1","kind":"LINK","draft":false,
   "uploader":\##(Fixtures.bob),"createdAt":"2026-10-20T09:01:00Z",
   "name":null,"mimeType":null,"size":null,"width":null,"height":null,"hasThumbnail":false,
   "url":"https://www.figma.com/file/x","title":null,"description":"Screens","siteName":"Figma","provider":"figma",
   "previewStatus":"READY","hasIcon":true,"hasImage":false,
   "contentPath":null,"thumbnailPath":null,"iconPath":"/api/v1/attachments/att-2/icon","imagePath":null}
  """##

  static let futureKind = ##"""
  {"id":"att-3","workspaceId":"ws-1","taskId":"t-1","commentId":null,"kind":"EMBED","draft":true,
   "uploader":\##(Fixtures.bob),"createdAt":"2026-10-20T09:02:00Z","previewStatus":"QUEUED","embedHtml":"<x>"}
  """##
}

final class AttachmentModelTests: XCTestCase {
  let decoder = MekariJSON.makeDecoder()

  func testDecodesFilesLinksAndUnknownKinds() throws {
    let file = try decoder.decode(Attachment.self, from: Data(AttachmentFixtures.file.utf8))
    XCTAssertEqual(file.kind, .file)
    XCTAssertEqual(file.size, 48_213)
    XCTAssertTrue(file.isImage)
    XCTAssertEqual(file.displayName, "login.png")
    XCTAssertEqual(file.thumbnailPath(size: .small), "/api/v1/attachments/att-1/thumbnail?size=small")
    XCTAssertNil(file.linkURL)

    let link = try decoder.decode(Attachment.self, from: Data(AttachmentFixtures.link.utf8))
    XCTAssertEqual(link.kind, .link)
    XCTAssertEqual(link.previewStatus, .ready)
    XCTAssertEqual(link.commentId, "c-1")
    XCTAssertEqual(link.linkURL?.absoluteString, "https://www.figma.com/file/x")
    XCTAssertEqual(link.displayName, "figma.com", "no title: the host without www.")
    XCTAssertNil(link.thumbnailPath(size: .large))

    let future = try decoder.decode(Attachment.self, from: Data(AttachmentFixtures.futureKind.utf8))
    XCTAssertEqual(future.kind, .other("EMBED"))
    XCTAssertEqual(future.previewStatus, .other("QUEUED"))
    XCTAssertFalse(future.hasThumbnail)
    XCTAssertNil(future.contentPath)
  }

  func testRoundTripsThroughJSON() throws {
    let file = try decoder.decode(Attachment.self, from: Data(AttachmentFixtures.file.utf8))
    let again = try decoder.decode(Attachment.self, from: MekariJSON.makeEncoder().encode(file))
    XCTAssertEqual(again, file)
  }

  func testOnlyHttpLinksAreOpenable() throws {
    var link = try decoder.decode(Attachment.self, from: Data(AttachmentFixtures.link.utf8))
    for bad in ["javascript:alert(1)", "file:///etc/passwd", "mailto:a@b.c", "https://", "notaurl", "ftp://x.y/z"] {
      link.url = bad
      XCTAssertNil(link.linkURL, bad)
    }
    link.url = "HTTP://Example.com/a"
    XCTAssertNotNil(link.linkURL)
  }

  func testTaskCommentAndDetailFieldsDefaultForOlderServers() throws {
    let task = try decoder.decode(TaskItem.self, from: Data(Fixtures.task.utf8))
    XCTAssertEqual(task.attachmentCount, 0)
    let detail = try decoder.decode(TaskDetail.self, from: Data(Fixtures.taskDetail.utf8))
    XCTAssertEqual(detail.attachments, [])
    let stories = try decoder.decode(StoryFeed.self, from: Data(Fixtures.stories.utf8))
    guard case .comment(let comment)? = stories.data.last else { return XCTFail("no comment") }
    XCTAssertEqual(comment.attachments, [])
  }

  func testCommentWithAttachmentsAndAnEmptyBody() throws {
    let json = ##"""
    {"kind":"comment","id":"c-1","author":\##(Fixtures.bob),"body":"","createdAt":"2026-10-20T09:01:00Z","editedAt":null,
     "attachments":[\##(AttachmentFixtures.link)]}
    """##
    let story = try decoder.decode(Story.self, from: Data(json.utf8))
    guard case .comment(let comment) = story else { return XCTFail("not a comment") }
    XCTAssertEqual(comment.body, "")
    XCTAssertEqual(comment.attachments.map(\.id), ["att-2"])
    let task = try decoder.decode(TaskItem.self, from: Data(Fixtures.task.replacingOccurrences(of: #""commentCount":3"#,
                                                                                               with: #""commentCount":3,"attachmentCount":4"#).utf8))
    XCTAssertEqual(task.attachmentCount, 4)
  }

  func testAttachmentErrorCodes() {
    func code(_ raw: String, _ status: Int) -> APIError.Code {
      APIError.from(status: status, body: Data(#"{"error":{"code":"\#(raw)","message":"m"}}"#.utf8)).code
    }
    XCTAssertEqual(code("PAYLOAD_TOO_LARGE", 413), .payloadTooLarge)
    XCTAssertEqual(code("INSUFFICIENT_STORAGE", 507), .insufficientStorage)
    XCTAssertEqual(code("RATE_LIMITED", 429), .rateLimited)
    XCTAssertEqual(code("QUOTA_SOMETHING_NEW", 409), .unknown("QUOTA_SOMETHING_NEW"))
    func htmlCode(_ status: Int) -> APIError.Code {
      APIError.from(status: status, body: Data("<html><body>nginx</body></html>".utf8)).code
    }
    XCTAssertEqual(htmlCode(413), .payloadTooLarge, "a proxy's HTML 413")
    XCTAssertEqual(htmlCode(429), .rateLimited)
    XCTAssertEqual(htmlCode(507), .insufficientStorage)
    XCTAssertEqual(htmlCode(502), .unknown("HTTP 502"))
    let local = AttachmentLimits.tooLarge()
    XCTAssertEqual(local.code, .payloadTooLarge)
    XCTAssertNil(local.status)
  }

  func testAttachmentPathsAndFileNames() {
    XCTAssertTrue(AttachmentLinks.isAttachmentPath("/api/v1/attachments/abc/content"))
    XCTAssertTrue(AttachmentLinks.isAttachmentPath("/api/v1/attachments/abc/thumbnail?size=small"))
    for bad in ["/api/v1/tasks/abc", "https://evil.example/api/v1/attachments/x/content", "/api/v1/attachments/../auth/me",
                "//evil.example/api/v1/attachments/x", "/api/v1/attachments/x/content\n", "api/v1/attachments/x/content"] {
      XCTAssertFalse(AttachmentLinks.isAttachmentPath(bad), bad)
    }
    XCTAssertEqual(AttachmentLinks.safeFileName("../../etc/passwd"), "etcpasswd")
    XCTAssertEqual(AttachmentLinks.safeFileName("   "), "file")
    XCTAssertEqual(AttachmentLinks.safeFileName("a\u{202E}gpj.exe"), "agpj.exe", "bidi controls are dropped")
    XCTAssertEqual(AttachmentLinks.safeFileName("Résumé 2026.pdf"), "Résumé 2026.pdf")
    let long = AttachmentLinks.safeFileName(String(repeating: "é", count: 300) + ".pdf")
    XCTAssertLessThanOrEqual(long.utf8.count, 200)
    XCTAssertTrue(long.hasSuffix(".pdf"))
  }

  func testQuarantineValueLooksLikeSafaris() {
    let value = Quarantine.value(at: Date(timeIntervalSince1970: 0x6500_0000), id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    XCTAssertEqual(value, "0081;65000000;Mekari Project;00000000-0000-0000-0000-000000000001")
  }
}

final class AttachmentLiveAPITests: XCTestCase {
  let server = URL(string: "https://mp.example.com")!
  var transport: StubTransport!
  var tokens: InMemoryTokenStore!
  var api: LiveMekariAPI!
  var scratch: URL!

  override func setUp() async throws {
    transport = StubTransport()
    tokens = InMemoryTokenStore(token: "tok")
    api = LiveMekariAPI(baseURL: server, tokens: tokens, transport: transport)
    await api.setWorkspace("ws-1")
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("att-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: scratch)
  }

  func file(_ name: String, _ contents: String) throws -> URL {
    let url = scratch.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
  }

  /// A sparse file of `size` bytes (no disk or memory used for the hole).
  func sparse(_ size: Int64) throws -> URL {
    let url = scratch.appendingPathComponent("big-\(size).bin")
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(size))
    try handle.close()
    return url
  }

  func testUploadIsOneMultipartFilePartWithDraftQuery() async throws {
    let source = try file("notes.txt", "hello world")
    let tempFiles = { Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
      .filter { $0.hasPrefix("mekari-upload-") } }
    let before = tempFiles()
    transport.enqueue(.init(status: 201, body: AttachmentFixtures.file))
    let progress = ProgressLog()
    let attachment = try await api.uploadAttachment(taskID: "t-1", file: source, fileName: "Résumé \"final\".txt", draft: true) {
      progress.append($0)
    }
    XCTAssertEqual(attachment.id, "att-1")
    let request = try XCTUnwrap(transport.last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.absoluteString, "https://mp.example.com/api/v1/tasks/t-1/attachments?draft=true")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sid=tok")
    let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
    XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=MekariProject-"))
    let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
    let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), String(request.httpBody!.count))
    XCTAssertTrue(body.hasPrefix("--\(boundary)\r\n"))
    XCTAssertTrue(body.contains(#"Content-Disposition: form-data; name="file"; filename="Résumé %22final%22.txt""#), body)
    XCTAssertTrue(body.contains("\r\n\r\nhello world\r\n--\(boundary)--\r\n"))
    XCTAssertEqual(progress.values.last, TransferProgress(completed: 11, total: 11))
    XCTAssertEqual(request.timeoutInterval, 300, "the server may be quiet a while after the last byte")
    XCTAssertEqual(tempFiles().subtracting(before), [], "the temp multipart file is deleted")
  }

  func testTaskLevelUploadSendsNoDraftQuery() async throws {
    transport.enqueue(.init(status: 201, body: AttachmentFixtures.file))
    _ = try await api.uploadAttachment(taskID: "t-1", file: try file("a.png", "x"), fileName: nil, draft: false) { _ in }
    XCTAssertEqual(transport.last?.url?.absoluteString, "https://mp.example.com/api/v1/tasks/t-1/attachments")
    XCTAssertTrue(String(decoding: transport.last!.httpBody!, as: UTF8.self).contains(#"filename="a.png""#))
  }

  func testOver100MBIsRefusedBeforeAnyRequest() async throws {
    let big = try sparse(AttachmentLimits.maxUploadBytes + 1)
    do {
      _ = try await api.uploadAttachment(taskID: "t-1", file: big, fileName: nil, draft: true) { _ in }
      XCTFail("expected payloadTooLarge")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .payloadTooLarge)
      XCTAssertNil(error.status)
    }
    XCTAssertTrue(transport.requests.isEmpty)
  }

  func testExactly100MBPassesThePreCheck() throws {
    XCTAssertEqual(try Multipart.fileSize(try sparse(AttachmentLimits.maxUploadBytes)), 104_857_600)
  }

  func testServerUploadErrorsKeepTheirCodeAndMessage() async throws {
    let source = try file("a.txt", "x")
    for (status, code, expected) in [(413, "PAYLOAD_TOO_LARGE", APIError.Code.payloadTooLarge), (429, "RATE_LIMITED", .rateLimited),
                                     (507, "INSUFFICIENT_STORAGE", .insufficientStorage), (409, "BRAND_NEW", .unknown("BRAND_NEW"))] {
      transport.enqueue(.init(status: status, body: #"{"error":{"code":"\#(code)","message":"server says \#(status)"}}"#))
      do {
        _ = try await api.uploadAttachment(taskID: "t-1", file: source, fileName: nil, draft: true) { _ in }
        XCTFail("expected \(code)")
      } catch let error as APIError {
        XCTAssertEqual(error.code, expected)
        XCTAssertEqual(error.status, status)
        XCTAssertEqual(error.message, "server says \(status)")
      }
    }
  }

  func testAnUnreadableFileIsAValidationErrorWithoutARequest() async {
    do {
      _ = try await api.uploadAttachment(taskID: "t-1", file: scratch.appendingPathComponent("missing"), fileName: nil, draft: false) { _ in }
      XCTFail("expected an error")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .validation)
    } catch {
      XCTFail("\(error)")
    }
    XCTAssertTrue(transport.requests.isEmpty)
  }

  func testCommentWithAttachmentIDsAndWithout() async throws {
    let comment = ##"{"kind":"comment","id":"c-9","author":\##(Fixtures.alice),"body":"","createdAt":"2026-10-20T09:00:00Z","editedAt":null,"attachments":[]}"##
    transport.enqueue(.init(status: 201, body: comment))
    _ = try await api.addComment(taskID: "t-1", body: "", attachmentIDs: ["a", "b"])
    let withIDs = try JSONSerialization.jsonObject(with: transport.last!.httpBody!) as? [String: Any]
    XCTAssertEqual(withIDs?["attachmentIds"] as? [String], ["a", "b"])
    transport.enqueue(.init(status: 201, body: comment))
    _ = try await api.addComment(taskID: "t-1", body: "hi")
    let without = try JSONSerialization.jsonObject(with: transport.last!.httpBody!) as? [String: Any]
    XCTAssertNil(without?["attachmentIds"], "the v1 body shape, for older servers")
  }

  func testLinkDeleteAndRefreshRequests() async throws {
    transport.enqueue(.init(status: 201, body: AttachmentFixtures.link))
    _ = try await api.addLink(taskID: "t-1", url: "https://figma.com/x", title: nil, draft: true)
    XCTAssertEqual(transport.last?.url?.path, "/api/v1/tasks/t-1/attachments/link")
    let body = try JSONSerialization.jsonObject(with: transport.last!.httpBody!) as? [String: Any]
    XCTAssertEqual(body?["draft"] as? Bool, true)
    transport.enqueue(.init(status: 204, body: ""))
    try await api.deleteAttachment("att-2")
    XCTAssertEqual(transport.last?.httpMethod, "DELETE")
    XCTAssertEqual(transport.last?.url?.path, "/api/v1/attachments/att-2")
    transport.enqueue(.init(body: AttachmentFixtures.link))
    _ = try await api.refreshLinkPreview("att-2")
    XCTAssertEqual(transport.last?.url?.path, "/api/v1/attachments/att-2/refresh-preview")
  }

  func testDownloadsAreIDAddressedRevalidatedAndWrittenOnlyOn200() async throws {
    let destination = scratch.appendingPathComponent("login.png")
    transport.enqueue(.init(body: "PNGBYTES", headers: ["ETag": "\"abc\""]))
    let first = try await api.download("/api/v1/attachments/att-1/content", to: destination, ifNoneMatch: nil) { _ in }
    XCTAssertEqual(first, .downloaded(etag: "\"abc\""))
    XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "PNGBYTES")
    let request = try XCTUnwrap(transport.last)
    XCTAssertEqual(request.url?.absoluteString, "https://mp.example.com/api/v1/attachments/att-1/content")
    XCTAssertNil(request.value(forHTTPHeaderField: LiveMekariAPI.workspaceHeader), "byte GETs ignore the workspace")
    XCTAssertEqual(request.timeoutInterval, 300)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sid=tok")

    transport.enqueue(.init(status: 304, body: ""))
    let second = try await api.download("/api/v1/attachments/att-1/content", to: destination, ifNoneMatch: "\"abc\"") { _ in }
    XCTAssertEqual(second, .notModified)
    XCTAssertEqual(transport.last?.value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
    XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "PNGBYTES")

    transport.enqueue(.init(status: 404, body: #"{"error":{"code":"NOT_FOUND","message":"Attachment not found"}}"#))
    do {
      _ = try await api.download("/api/v1/attachments/att-1/content", to: destination, ifNoneMatch: nil) { _ in }
      XCTFail("expected notFound")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .notFound)
    }
    XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "PNGBYTES", "an error never replaces the file")
  }

  func testPathsOutsideAttachmentsAreRefusedWithoutARequest() async {
    for path in ["/api/v1/auth/me", "https://evil.example/api/v1/attachments/x/content", "/api/v1/attachments/../users"] {
      do {
        _ = try await api.attachmentData(path)
        XCTFail(path)
      } catch let error as APIError {
        XCTAssertEqual(error.code, .validation)
      } catch {
        XCTFail("\(error)")
      }
    }
    XCTAssertTrue(transport.requests.isEmpty)
  }

  func testAServerUnderAPathPrefixKeepsIt() async throws {
    let prefixed = LiveMekariAPI(baseURL: URL(string: "https://host.example/mp")!, tokens: tokens, transport: transport)
    transport.enqueue(.init(body: "x"))
    _ = try await prefixed.attachmentData("/api/v1/attachments/a/thumbnail?size=small")
    XCTAssertEqual(transport.last?.url?.absoluteString, "https://host.example/mp/api/v1/attachments/a/thumbnail?size=small")
  }

  func testMultipartBodyStreamsTheFileInChunks() throws {
    let bytes = Data((0..<(Multipart.chunkSize * 2 + 17)).map { UInt8($0 % 251) })
    let source = scratch.appendingPathComponent("blob.bin")
    try bytes.write(to: source)
    let body = try Multipart.writeTempFile(copying: source, fileName: "blob.bin", directory: scratch)
    let written = try Data(contentsOf: body.url)
    XCTAssertEqual(Int64(written.count), body.length)
    XCTAssertEqual(written.subdata(in: Int(body.headerLength)..<(Int(body.headerLength) + bytes.count)), bytes)
    XCTAssertTrue(String(decoding: written.suffix(60), as: UTF8.self).hasSuffix("\r\n--\(body.boundary)--\r\n"))
  }
}

final class ProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var log: [TransferProgress] = []
  func append(_ p: TransferProgress) { lock.locked { log.append(p) } }
  var values: [TransferProgress] { lock.locked { log } }
}
