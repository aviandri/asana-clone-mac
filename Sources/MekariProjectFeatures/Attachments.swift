import Foundation
import MekariProjectKit
import Observation

/// One upload: a file or a link on its way to a task (task-level) or into the comment composer (a draft).
public struct AttachmentUpload: Identifiable, Sendable, Hashable {
  public enum Source: Sendable, Hashable {
    case file(URL, name: String)
    case link(url: String, title: String?)
  }

  public enum State: Sendable, Hashable {
    /// Waiting for one of the `AttachmentLimits.maxConcurrentUploads` slots.
    case queued
    case uploading(TransferProgress)
    /// Composer chips only; finished task-level uploads leave the list.
    case finished(Attachment)
    /// Retry or remove.
    case failed(APIError)
  }

  public let id: UUID
  public let taskID: String
  public let source: Source
  public internal(set) var state: State
  /// FILE size when known.
  public let size: Int64?

  init(id: UUID = UUID(), taskID: String, source: Source, state: State = .queued, size: Int64? = nil) {
    self.id = id
    self.taskID = taskID
    self.source = source
    self.state = state
    self.size = size
  }

  /// The file name, or the link's title, else its URL.
  public var name: String {
    switch source {
    case .file(_, let name): return name
    case .link(let url, let title): return title.flatMap { $0.isEmpty ? nil : $0 } ?? url
    }
  }

  public var isFinished: Bool { if case .finished = state { return true } else { return false } }
  public var isFailed: Bool { if case .failed = state { return true } else { return false } }
  /// Queued or uploading.
  public var isActive: Bool {
    switch state {
    case .queued, .uploading: return true
    case .finished, .failed: return false
    }
  }

  public var attachment: Attachment? { if case .finished(let a) = state { return a } else { return nil } }
}

/// At most `AttachmentLimits.maxConcurrentUploads` uploads at once across the app (A12), first come first served.
@MainActor
final class UploadSlots {
  private let limit: Int
  private var running = 0
  private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

  init(limit: Int = AttachmentLimits.maxConcurrentUploads) {
    self.limit = limit
  }

  /// Waits for a slot. Throws `CancellationError` if the calling task is cancelled while waiting.
  func acquire() async throws {
    try Task.checkCancellation()
    if running < limit {
      running += 1
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        waiting.append((id, continuation))
      }
    } onCancel: {
      Task { @MainActor in self.drop(id) }
    }
  }

  func release() {
    if waiting.isEmpty {
      running = max(0, running - 1)
    } else {
      waiting.removeFirst().continuation.resume() // the slot passes straight on
    }
  }

  private func drop(_ id: UUID) {
    guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
    waiting.remove(at: i).continuation.resume(throwing: CancellationError())
  }

  var runningCount: Int { running }
  var waitingCount: Int { waiting.count }
}

/// Runs uploads for a list of `AttachmentUpload`s that its owner keeps: slots, progress, cancel, retry.
@MainActor
final class UploadRunner {
  let slots: UploadSlots
  private var tasks: [UUID: Task<Void, Never>] = [:]

  init(slots: UploadSlots) {
    self.slots = slots
  }

  /// Starts `upload`, reporting each state change through `update`. File uploads take a slot; links don't.
  func run(_ upload: AttachmentUpload, draft: Bool, api: any MekariAPI,
           update: @escaping @MainActor @Sendable (UUID, AttachmentUpload.State) -> Void) {
    let id = upload.id
    tasks[id]?.cancel()
    tasks[id] = Task { [slots] in
      defer { if !Task.isCancelled { self.tasks[id] = nil } }
      do {
        let attachment: Attachment
        switch upload.source {
        case .file(let url, let name):
          try await slots.acquire()
          defer { slots.release() }
          update(id, .uploading(TransferProgress(completed: 0, total: upload.size)))
          attachment = try await api.uploadAttachment(taskID: upload.taskID, file: url, fileName: name, draft: draft) { progress in
            Task { @MainActor in update(id, .uploading(progress)) }
          }
        case .link(let url, let title):
          update(id, .uploading(TransferProgress(completed: 0, total: nil)))
          attachment = try await api.addLink(taskID: upload.taskID, url: url, title: title, draft: draft)
        }
        guard !Task.isCancelled else { return }
        update(id, .finished(attachment))
      } catch is CancellationError {
        // Cancelled by the owner (remove, cancel, sign-out): the owner already dropped it.
      } catch {
        guard !Task.isCancelled else { return }
        update(id, .failed(error.asAPIError))
      }
    }
  }

  func cancel(_ id: UUID) {
    tasks.removeValue(forKey: id)?.cancel()
  }

  func cancelAll() {
    tasks.values.forEach { $0.cancel() }
    tasks = [:]
  }

  var runningIDs: Set<UUID> { Set(tasks.keys) }
}

/// Checks a file before any request: readable, not a folder, at most 100 MB. Returns its size or the error.
func preflight(_ url: URL) -> Result<Int64, APIError> {
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
    return .failure(APIError(code: .validation, message: "Can't read that file"))
  }
  guard size <= AttachmentLimits.maxUploadBytes else { return .failure(AttachmentLimits.tooLarge()) }
  return .success(size)
}

/// A link's URL checked like the BE does (absolute http(s), ≤ 2048 chars, no credentials), or the error.
func validateLink(_ text: String) -> Result<String, APIError> {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed.count <= 2048, let url = AttachmentLinks.openable(trimmed), url.user == nil, url.password == nil else {
    let message = "Enter a link that starts with http:// or https://"
    return .failure(APIError(code: .validation, message: message, issues: [FieldIssue(path: ["url"], message: message)]))
  }
  return .success(trimmed)
}

// MARK: - Task-level uploads (session scope)

/// Task-level uploads for the whole session, keyed by task, so they survive closing the inspector or the task
/// window and show again when the task reopens. Cleared on sign-out; a lost workspace's uploads are cancelled.
/// Finished uploads leave the list and are handed to `onFinished` (the current scope inserts them).
@MainActor @Observable
public final class AttachmentUploads {
  public private(set) var all: [AttachmentUpload] = []

  @ObservationIgnored private let runner: UploadRunner
  @ObservationIgnored var api: () -> (any MekariAPI)?
  /// Which workspace each upload's task is in (for lost access).
  @ObservationIgnored private var workspaces: [UUID: String] = [:]
  @ObservationIgnored var onFinished: ((Attachment) -> Void)?

  init(slots: UploadSlots, api: @escaping () -> (any MekariAPI)?) {
    runner = UploadRunner(slots: slots)
    self.api = api
  }

  /// This task's queued, running and failed uploads, oldest first.
  public func uploads(for taskID: String) -> [AttachmentUpload] {
    all.filter { $0.taskID == taskID }
  }

  /// Starts a task-level (non-draft) file upload. A file that fails the pre-check shows as failed at once.
  func start(taskID: String, workspaceID: String, file url: URL, fileName: String?) {
    let name = fileName ?? url.lastPathComponent
    switch preflight(url) {
    case .failure(let error):
      all.append(AttachmentUpload(taskID: taskID, source: .file(url, name: name), state: .failed(error)))
    case .success(let size):
      let upload = AttachmentUpload(taskID: taskID, source: .file(url, name: name), size: size)
      all.append(upload)
      workspaces[upload.id] = workspaceID
      run(upload)
    }
  }

  public func retry(_ id: UUID) {
    guard let i = all.firstIndex(where: { $0.id == id }), all[i].isFailed else { return }
    if case .file(let url, _) = all[i].source, case .failure(let error) = preflight(url) {
      all[i].state = .failed(error)
      return
    }
    all[i].state = .queued
    run(all[i])
  }

  /// Cancels a queued or running upload, or dismisses a failed one.
  public func cancel(_ id: UUID) {
    runner.cancel(id)
    all.removeAll { $0.id == id }
    workspaces[id] = nil
  }

  func cancelAll() {
    runner.cancelAll()
    all = []
    workspaces = [:]
  }

  func cancel(workspaceID: String) {
    for upload in all where workspaces[upload.id] == workspaceID { cancel(upload.id) }
  }

  private func run(_ upload: AttachmentUpload) {
    guard let api = api() else {
      update(upload.id, .failed(APIError(code: .unauthorized, message: "Sign in to upload")))
      return
    }
    runner.run(upload, draft: false, api: api) { [weak self] id, state in self?.update(id, state) }
  }

  private func update(_ id: UUID, _ state: AttachmentUpload.State) {
    guard let i = all.firstIndex(where: { $0.id == id }) else { return }
    // A late progress report never overwrites the outcome.
    if case .uploading = state, !all[i].isActive { return }
    if case .finished(let attachment) = state {
      all.remove(at: i)
      workspaces[id] = nil
      onFinished?(attachment)
      return
    }
    all[i].state = state
  }
}

// MARK: - Downloads (workspace scope)

/// Downloads and images for the current workspace, through the session's `AttachmentCache`.
@MainActor @Observable
public final class AttachmentFiles {
  /// Attachment id → progress while it downloads.
  public private(set) var downloads: [String: TransferProgress] = [:]
  public private(set) var lastError: APIError?

  @ObservationIgnored private let api: any MekariAPI
  @ObservationIgnored private let cache: AttachmentCache

  init(api: any MekariAPI, cache: AttachmentCache) {
    self.api = api
    self.cache = cache
  }

  /// The local file (downloading or revalidating it first), or nil on failure (`lastError`) or cancellation.
  public func file(for attachment: Attachment) async -> URL? {
    let id = attachment.id
    downloads[id] = TransferProgress(completed: 0, total: attachment.size)
    defer { downloads[id] = nil }
    do {
      let url = try await cache.file(for: attachment, using: api) { progress in
        Task { @MainActor [weak self] in
          if self?.downloads[id] != nil { self?.downloads[id] = progress }
        }
      }
      lastError = nil
      return url
    } catch {
      recordFailure(error, lastError: &lastError)
      return nil
    }
  }

  /// The downloaded copy if there is one (Show in Finder).
  public func cachedFile(for attachment: Attachment) async -> URL? {
    await cache.cachedFile(for: attachment.id)
  }

  /// The server thumbnail's bytes (WebP), or nil when there's none or it failed.
  public func thumbnail(for attachment: Attachment, size: ThumbnailSize) async -> Data? {
    guard let path = attachment.thumbnailPath(size: size) else { return nil }
    return try? await cache.data(at: path, using: api)
  }

  public func linkIcon(for attachment: Attachment) async -> Data? {
    guard attachment.hasIcon, let path = attachment.iconPath else { return nil }
    return try? await cache.data(at: path, using: api)
  }

  public func linkImage(for attachment: Attachment) async -> Data? {
    guard attachment.hasImage, let path = attachment.imagePath else { return nil }
    return try? await cache.data(at: path, using: api)
  }

  public func clearError() { lastError = nil }
}
