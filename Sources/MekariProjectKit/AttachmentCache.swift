// Swift 5.10's Linux Foundation doesn't mark URL Sendable yet (Darwin's and Swift 6's do).
#if canImport(FoundationNetworking) && compiler(<6.0)
@preconcurrency import Foundation
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Downloaded attachments on disk and small images (thumbnails, link icons and images) in memory
/// (SPEC-MAC §8). Files live at `<directory>/<attachmentId>/<sanitised name>`, are revalidated by ETag,
/// and are evicted least recently used beyond `capacity`. `wipe()` on sign-out and on losing a workspace.
public actor AttachmentCache {
  /// `<Caches>/<bundle id>/Attachments`: never stored outside Caches. The app isn't sandboxed, so `<Caches>` is
  /// the shared `~/Library/Caches`; the bundle-id folder keeps `wipe()` away from anyone else's files.
  public static func defaultDirectory(bundleID: String = Bundle.main.bundleIdentifier ?? "com.mekari.project") -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    return caches.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("Attachments", isDirectory: true)
  }

  struct Entry: Codable, Sendable {
    var name: String
    var etag: String?
    var size: Int64
    var lastUsed: Date
  }

  public let directory: URL
  private let capacity: Int64
  private let memoryCapacity: Int
  private let quarantine: @Sendable (URL) -> Void
  private let now: @Sendable () -> Date

  private var entries: [String: Entry] = [:]
  private var loaded = false
  private var inFlight: [String: Task<URL, Error>] = [:]
  /// Bumped by `wipe()`: a download that started before it never lands in the cache.
  private var generation = 0
  private var memory: [String: Data] = [:]
  private var memoryOrder: [String] = []
  private var memoryBytes = 0

  public init(directory: URL, capacity: Int64 = 1 << 30, memoryCapacity: Int = 64 << 20,
              quarantine: @escaping @Sendable (URL) -> Void = { Quarantine.mark($0) }, now: @escaping @Sendable () -> Date = { Date() }) {
    self.directory = directory
    self.capacity = capacity
    self.memoryCapacity = memoryCapacity
    self.quarantine = quarantine
    self.now = now
  }

  // MARK: - Files

  /// The local copy of a FILE attachment: revalidated with its ETag (304 → the cached file), downloaded otherwise.
  /// Offline (or any transport failure) with a cached copy → the cached copy. Concurrent calls for one id share a
  /// download; it is cancelled only when every caller waiting for it is.
  public func file(for attachment: Attachment, using api: any MekariAPI,
                   progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws -> URL {
    guard attachment.kind == .file, let path = attachment.contentPath else {
      throw APIError(code: .validation, message: "Only files can be downloaded")
    }
    // The id names a folder: anything but a UUID (e.g. "../../Documents") could point outside the cache.
    guard AttachmentCache.isSafeID(attachment.id) else { throw APIError(code: .validation, message: "Not an attachment") }
    loadIndex()
    let id = attachment.id
    let task: Task<URL, Error>
    if let running = inFlight[id] {
      task = running
    } else {
      task = Task { try await self.fetch(id: id, name: attachment.name ?? "file", path: path, api: api, progress: progress) }
      inFlight[id] = task
    }
    waiters[id, default: 0] += 1
    defer {
      waiters[id, default: 1] -= 1
      if waiters[id] == 0 {
        waiters[id] = nil
        cancelledWaiters[id] = nil
        if inFlight[id] == task { inFlight[id] = nil }
      }
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      Task { await self.callerCancelled(id, task) }
    }
  }

  private var waiters: [String: Int] = [:]
  private var cancelledWaiters: [String: Int] = [:]

  /// The shared download stops once every caller still waiting for it was cancelled.
  private func callerCancelled(_ id: String, _ task: Task<URL, Error>) {
    guard inFlight[id] == task else { return }
    cancelledWaiters[id, default: 0] += 1
    if cancelledWaiters[id, default: 0] >= waiters[id, default: 0] {
      cancelledWaiters[id] = nil
      task.cancel()
    }
  }

  private func fetch(id: String, name: String, path: String, api: any MekariAPI,
                     progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL {
    let started = generation
    let folder = directory.appendingPathComponent(id, isDirectory: true)
    let destination = folder.appendingPathComponent(AttachmentLinks.safeFileName(name))
    let cached = entries[id].flatMap { entry in
      FileManager.default.fileExists(atPath: folder.appendingPathComponent(entry.name).path) ? entry : nil
    }
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      throw APIError(code: .unknown("client"), message: "Couldn't save the file")
    }
    let outcome: DownloadOutcome
    do {
      // A cached copy under another name (the server renamed nothing, but be safe) is revalidated only in place.
      let etag = cached?.name == destination.lastPathComponent ? cached?.etag : nil
      outcome = try await api.download(path, to: destination, ifNoneMatch: etag, progress: progress)
    } catch let error as APIError where error.code == .transport {
      guard let cached, started == generation else { throw error }
      return touch(id, cached)
    }
    guard started == generation else {
      // Wiped while downloading (sign-out, lost access): the bytes must not stay.
      remove(folder)
      throw CancellationError()
    }
    switch outcome {
    case .notModified:
      guard let cached else { throw APIError.decoding("304 without a cached copy") }
      return touch(id, cached)
    case .downloaded(let etag):
      if let cached, cached.name != destination.lastPathComponent {
        remove(folder.appendingPathComponent(cached.name))
      }
      quarantine(destination)
      let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
      let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
      entries[id] = Entry(name: destination.lastPathComponent, etag: etag, size: size, lastUsed: now())
      evict(keeping: id)
      saveIndex()
      return destination
    }
  }

  private func touch(_ id: String, _ entry: Entry) -> URL {
    entries[id]?.lastUsed = now()
    saveIndex()
    return directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent(entry.name)
  }

  /// Cancels the download of `attachmentID` for every caller (they get `CancellationError`).
  public func cancelDownload(_ attachmentID: String) {
    guard AttachmentCache.isSafeID(attachmentID) else { return }
    inFlight.removeValue(forKey: attachmentID)?.cancel()
    cancelledWaiters[attachmentID] = nil
  }

  /// The downloaded copy, if any (Show in Finder is offered only then).
  public func cachedFile(for attachmentID: String) -> URL? {
    guard AttachmentCache.isSafeID(attachmentID) else { return nil }
    loadIndex()
    guard let entry = entries[attachmentID] else { return nil }
    let url = directory.appendingPathComponent(attachmentID, isDirectory: true).appendingPathComponent(entry.name)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  public var diskUsage: Int64 {
    loadIndex()
    return entries.values.reduce(0) { $0 + $1.size }
  }

  private func evict(keeping keep: String) {
    var total = entries.values.reduce(0) { $0 + $1.size }
    for (id, entry) in entries.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) where total > capacity {
      guard id != keep, inFlight[id] == nil else { continue }
      remove(directory.appendingPathComponent(id, isDirectory: true))
      entries[id] = nil
      total -= entry.size
    }
  }

  // MARK: - Index

  private var indexURL: URL { directory.appendingPathComponent("index.json") }

  /// Folders the index doesn't know (a crash mid-download, an older build) are removed.
  private func loadIndex() {
    guard !loaded else { return }
    loaded = true
    if let data = try? Data(contentsOf: indexURL), let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
      entries = decoded
    }
    // An index entry must name a UUID folder and a plain file name (a tampered index can't point elsewhere).
    entries = entries.filter { id, entry in
      AttachmentCache.isSafeID(id) && entry.name == AttachmentLinks.safeFileName(entry.name)
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name != "index.json" && entries[name] == nil {
      remove(directory.appendingPathComponent(name))
    }
    // Half-written downloads (".<uuid>.part") a crash left behind in the folders we keep.
    for id in entries.keys {
      let folder = directory.appendingPathComponent(id, isDirectory: true)
      let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
      for file in files where file.hasSuffix(".part") { remove(folder.appendingPathComponent(file)) }
    }
  }

  private func saveIndex() {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: indexURL, options: .atomic)
  }

  // MARK: - Memory (thumbnails, link icons and images)

  /// Bytes for a server-relative attachment path, cached in memory (least recently used beyond `memoryCapacity`).
  public func data(at path: String, using api: any MekariAPI) async throws -> Data {
    if let hit = memory[path] {
      memoryOrder.removeAll { $0 == path }
      memoryOrder.append(path)
      return hit
    }
    let started = generation
    let data = try await api.attachmentData(path)
    guard started == generation else { throw CancellationError() }
    if memory[path] == nil, data.count <= memoryCapacity {
      memory[path] = data
      memoryOrder.append(path)
      memoryBytes += data.count
      while memoryBytes > memoryCapacity, let oldest = memoryOrder.first {
        memoryOrder.removeFirst()
        memoryBytes -= memory.removeValue(forKey: oldest)?.count ?? 0
      }
    }
    return data
  }

  // MARK: - Wipe

  /// Removes every downloaded file and everything in memory. Downloads in flight finish into nothing.
  public func wipe() {
    generation += 1
    inFlight.values.forEach { $0.cancel() }
    inFlight = [:]
    cancelledWaiters = [:]
    entries = [:]
    loaded = true
    memory = [:]
    memoryOrder = []
    memoryBytes = 0
    try? FileManager.default.removeItem(at: directory)
  }

  /// Attachment ids are UUIDs; only those name folders here.
  static func isSafeID(_ id: String) -> Bool {
    UUID(uuidString: id) != nil && !id.contains("/")
  }

  /// Whether `url` (standardized) is strictly inside `directory`.
  func isInside(_ url: URL) -> Bool {
    let root = directory.standardizedFileURL.path
    let target = url.standardizedFileURL.path
    return target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }

  /// Removes `url` only if it sits inside the cache directory: nothing outside it is ever deleted.
  private func remove(_ url: URL) {
    guard isInside(url) else { return }
    try? FileManager.default.removeItem(at: url)
  }
}

/// Marks downloaded files as coming from the internet, as Safari does, so Gatekeeper checks apps and scripts
/// opened from attachments.
public enum Quarantine {
  public static let attribute = "com.apple.quarantine"
  public static let agent = "Mekari Project"

  /// "0081;<hex seconds>;Mekari Project;<UUID>" (0x0081: quarantined, downloaded by an app).
  public static func value(at date: Date = Date(), id: UUID = UUID()) -> String {
    String(format: "0081;%08x;%@;%@", Int(date.timeIntervalSince1970), agent, id.uuidString)
  }

  /// Sets `com.apple.quarantine` on Apple platforms; does nothing elsewhere.
  public static func mark(_ file: URL) {
    #if canImport(Darwin)
    let value = Array(value().utf8)
    _ = file.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return setxattr(path, attribute, value, value.count, 0, 0)
    }
    #endif
  }
}
