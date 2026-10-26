// Swift 5.10's Linux Foundation doesn't mark URL Sendable yet (Darwin's and Swift 6's do).
#if canImport(FoundationNetworking) && compiler(<6.0)
@preconcurrency import Foundation
#else
import Foundation
#endif
import XCTest
@testable import MekariProjectKit

final class AttachmentCacheTests: XCTestCase {
  var directory: URL!
  var fake: FakeMekariAPI!
  let marked = MarkedFiles()

  override func setUp() {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-tests-\(UUID().uuidString)")
    fake = FakeMekariAPI(seed: .demo(today: LocalDate(year: 2026, month: 10, day: 20)), signedInAs: "alice@example.com")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
  }

  func cache(capacity: Int64 = 1 << 30) -> AttachmentCache {
    AttachmentCache(directory: directory, capacity: capacity, quarantine: { [marked] in marked.add($0) })
  }

  func seeded(_ id: String) async throws -> Attachment {
    try await fake.attachment(id)
  }

  func downloads() async -> Int { await fake.calls.filter { $0.endpoint == .download }.count }

  func testDownloadsIntoItsOwnFolderQuarantinesAndRevalidates() async throws {
    let cache = cache()
    let pdf = try await seeded(DemoIDs.attachmentPDF)
    let url = try await cache.file(for: pdf, using: fake)
    XCTAssertEqual(url, directory.appendingPathComponent(DemoIDs.attachmentPDF).appendingPathComponent("SSO flow.pdf"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(marked.files, [url])
    let cachedURL = await cache.cachedFile(for: pdf.id)
    XCTAssertEqual(cachedURL, url)

    let again = try await cache.file(for: pdf, using: fake)
    XCTAssertEqual(again, url)
    let calls = await downloads()
    XCTAssertEqual(calls, 2, "a cached copy is revalidated")
    XCTAssertEqual(marked.files.count, 1, "a 304 doesn't re-mark or rewrite")
  }

  func testOfflineServesTheCachedCopyButNotNothing() async throws {
    let cache = cache()
    let pdf = try await seeded(DemoIDs.attachmentPDF)
    let png = try await seeded(DemoIDs.attachmentPNG)
    let url = try await cache.file(for: pdf, using: fake)
    await fake.failNext(.download, with: .transport(), times: 2)
    let offline = try await cache.file(for: pdf, using: fake)
    XCTAssertEqual(offline, url)
    do {
      _ = try await cache.file(for: png, using: fake)
      XCTFail("nothing cached: the transport error surfaces")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .transport)
    }
  }

  func testConcurrentCallsShareOneDownload() async throws {
    let cache = cache()
    let pdf = try await seeded(DemoIDs.attachmentPDF)
    let fake: FakeMekariAPI = self.fake
    await fake.hold(.download)
    async let a = cache.file(for: pdf, using: fake)
    async let b = cache.file(for: pdf, using: fake)
    for _ in 0..<1000 where await fake.parkedCount(.download) == 0 { await Task.yield() }
    for _ in 0..<200 { await Task.yield() }
    await fake.release(.download, all: true)
    let (first, second) = try await (a, b)
    XCTAssertEqual(first, second)
    let calls = await downloads()
    XCTAssertEqual(calls, 1)
  }

  func testCancelDownloadStopsItForEveryone() async throws {
    let cache = cache()
    let pdf = try await seeded(DemoIDs.attachmentPDF)
    let fake: FakeMekariAPI = self.fake
    await fake.hold(.download)
    let waiter = Task { try await cache.file(for: pdf, using: fake) }
    for _ in 0..<1000 where await fake.parkedCount(.download) == 0 { await Task.yield() }
    await cache.cancelDownload(pdf.id)
    await fake.release(.download, all: true)
    do {
      _ = try await waiter.value
      XCTFail("expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    let cached = await cache.cachedFile(for: pdf.id)
    XCTAssertNil(cached)
  }

  func testWipeRemovesEverythingAndAWipedDownloadNeverLands() async throws {
    let cache = cache()
    let pdf = try await seeded(DemoIDs.attachmentPDF)
    let png = try await seeded(DemoIDs.attachmentPNG)
    _ = try await cache.file(for: pdf, using: fake)
    _ = try await cache.data(at: png.thumbnailPath(size: .small)!, using: fake)

    let fake: FakeMekariAPI = self.fake
    await fake.hold(.download)
    let late = Task { try await cache.file(for: png, using: fake) }
    for _ in 0..<1000 where await fake.parkedCount(.download) == 0 { await Task.yield() }
    await cache.wipe()
    await fake.release(.download, all: true)
    _ = try? await late.value

    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(pdf.id).path))
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    XCTAssertEqual(leftovers.filter { $0 != "index.json" }, [], "nothing from before the wipe stays on disk")
    let usage = await cache.diskUsage
    XCTAssertEqual(usage, 0)
    let before = await fake.calls.filter { $0.endpoint == .attachmentData }.count
    _ = try await cache.data(at: png.thumbnailPath(size: .small)!, using: fake)
    let after = await fake.calls.filter { $0.endpoint == .attachmentData }.count
    XCTAssertEqual(after, before + 1, "thumbnails in memory went too")
  }

  func testAThumbnailFetchedAcrossAWipeIsNotKept() async throws {
    let cache = cache()
    let fake: FakeMekariAPI = self.fake
    let png = try await seeded(DemoIDs.attachmentPNG)
    let path = try XCTUnwrap(png.thumbnailPath(size: .small))
    await fake.hold(.attachmentData)
    let late = Task { try await cache.data(at: path, using: fake) }
    for _ in 0..<1000 where await fake.parkedCount(.attachmentData) == 0 { await Task.yield() }
    await cache.wipe()
    await fake.release(.attachmentData, all: true)
    do {
      _ = try await late.value
      XCTFail("a fetch that started before the wipe must not deliver")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    _ = try await cache.data(at: path, using: fake)
    let calls = await fake.calls.filter { $0.endpoint == .attachmentData }.count
    XCTAssertEqual(calls, 2, "nothing from before the wipe was cached")
  }

  func testEvictsLeastRecentlyUsedBeyondCapacity() async throws {
    // Fake content for non-images is the file name's bytes: "SSO flow.pdf" = 12, "console.log" = 11.
    let cache = cache(capacity: 20)
    let pdf = try await seeded(DemoIDs.attachmentPDF)
    let text = try await seeded(DemoIDs.attachmentText)
    _ = try await cache.file(for: pdf, using: fake)
    _ = try await cache.file(for: text, using: fake)
    let pdfCached = await cache.cachedFile(for: pdf.id)
    let textCached = await cache.cachedFile(for: text.id)
    XCTAssertNil(pdfCached, "the older file made room")
    XCTAssertNotNil(textCached)
  }

  func testTheIndexSurvivesANewInstanceAndStrayFoldersGo() async throws {
    let pdf = try await seeded(DemoIDs.attachmentPDF)
    _ = try await cache().file(for: pdf, using: fake)
    let stray = directory.appendingPathComponent("stray")
    try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
    let reopened = cache()
    let cached = await reopened.cachedFile(for: pdf.id)
    XCTAssertNotNil(cached)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
  }

  func testMemoryCacheServesRepeatsWithoutRequests() async throws {
    let cache = cache()
    let png = try await seeded(DemoIDs.attachmentPNG)
    let path = try XCTUnwrap(png.thumbnailPath(size: .small))
    let first = try await cache.data(at: path, using: fake)
    let second = try await cache.data(at: path, using: fake)
    XCTAssertEqual(first, FakeMekariAPI.pngBytes)
    XCTAssertEqual(second, first)
    let calls = await fake.calls.filter { $0.endpoint == .attachmentData }.count
    XCTAssertEqual(calls, 1)
  }

  func testIDsThatArentUUIDsNeverNameAFolder() async throws {
    let outside = directory.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    var evil = try await seeded(DemoIDs.attachmentPDF)
    evil.id = "../\(outside.lastPathComponent)"
    let cache = cache()
    do {
      _ = try await cache.file(for: evil, using: fake)
      XCTFail("expected a refusal")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .validation)
    }
    let cached = await cache.cachedFile(for: evil.id)
    XCTAssertNil(cached)
    let calls = await downloads()
    XCTAssertEqual(calls, 0, "refused before any request")
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
  }

  func testATamperedIndexCantDeleteOutsideAndPartFilesGo() async throws {
    let pdf = try await seeded(DemoIDs.attachmentPDF)
    _ = try await cache().file(for: pdf, using: fake)
    let folder = directory.appendingPathComponent(pdf.id)
    let part = folder.appendingPathComponent(".\(UUID().uuidString).part")
    try Data("half".utf8).write(to: part)
    let outside = directory.deletingLastPathComponent().appendingPathComponent("victim-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    // An index entry pointing outside the cache.
    var index = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("index.json"))) as! [String: Any]
    index["../\(outside.lastPathComponent)"] = ["name": "x", "size": 1, "lastUsed": 0]
    try JSONSerialization.data(withJSONObject: index).write(to: directory.appendingPathComponent("index.json"))

    let reopened = cache(capacity: 1) // tiny: eviction runs over every entry on the next download
    let text = try await seeded(DemoIDs.attachmentText)
    _ = try await reopened.file(for: text, using: fake)
    await reopened.wipe()
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "nothing outside the cache is ever deleted")
    XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
  }

  func testIsInsideRejectsLookalikesAndParents() async {
    let cache = cache()
    let inside = await cache.isInside(directory.appendingPathComponent("a/b"))
    let parent = await cache.isInside(directory.appendingPathComponent("../x"))
    let lookalike = await cache.isInside(URL(fileURLWithPath: directory.path + "-evil/x"))
    let itself = await cache.isInside(directory)
    XCTAssertTrue(inside)
    XCTAssertFalse(parent)
    XCTAssertFalse(lookalike)
    XCTAssertFalse(itself)
  }

  func testLinksCantBeDownloaded() async throws {
    let link = try await seeded(DemoIDs.attachmentLink)
    do {
      _ = try await cache().file(for: link, using: fake)
      XCTFail("expected an error")
    } catch let error as APIError {
      XCTAssertEqual(error.code, .validation)
    }
  }
}

final class MarkedFiles: @unchecked Sendable {
  private let lock = NSLock()
  private var list: [URL] = []
  func add(_ url: URL) { lock.locked { list.append(url) } }
  var files: [URL] { lock.locked { list } }
}
