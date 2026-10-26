import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one HTTP request. Abstracted so `LiveMekariAPI` can be tested with a stub.
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
  /// Sends `request` with the body streamed from `file`. `progress(sent, expected)`.
  func upload(_ request: URLRequest, fromFile file: URL,
              progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> (Data, HTTPURLResponse)
  /// Sends `request`; a 200 body is streamed into `destination` (replaced only once complete) and the returned
  /// data is empty. Any other status returns its body in memory and leaves `destination` alone.
  /// `progress(received, expected)`.
  func download(_ request: URLRequest, to destination: URL,
                progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> (Data, HTTPURLResponse)
}

/// In-memory fallbacks, for test stubs. `URLSessionTransport` streams instead.
extension HTTPTransport {
  public func upload(_ request: URLRequest, fromFile file: URL,
                     progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> (Data, HTTPURLResponse) {
    var request = request
    request.httpBody = try Data(contentsOf: file)
    let size = Int64(request.httpBody?.count ?? 0)
    let result = try await send(request)
    progress(size, size)
    return result
  }

  public func download(_ request: URLRequest, to destination: URL,
                       progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await send(request)
    guard response.statusCode == 200 else { return (data, response) }
    try data.write(to: destination, options: .atomic)
    progress(Int64(data.count), Int64(data.count))
    return (Data(), response)
  }
}

/// `URLSession` with automatic cookie handling off: the session token is managed by hand (SPEC-MAC §4).
/// Redirects are never followed: URLSession would carry our hand-set `Cookie` (and re-post a login on 307/308)
/// to wherever the server, a proxy or a captive portal points. The 3xx itself comes back as the response.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
  private let session: URLSession
  private let redirects = TransferDelegate()

  public init(timeout: TimeInterval = 30) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = timeout
    session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
  }

  /// A session with a delegate keeps it (and itself) alive until invalidated; one transport per client.
  deinit {
    session.finishTasksAndInvalidate()
  }

  /// Cancelling the calling task cancels the `URLSessionTask` and throws `CancellationError`.
  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let handle = TaskHandle()
    return try await withTaskCancellationHandler {
      // The continuation form works on every Foundation (some Linux toolchains lack `data(for:)`).
      try await withCheckedThrowingContinuation { continuation in
        let task = session.dataTask(with: request) { data, response, error in
          if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            continuation.resume(throwing: cancelled ? CancellationError() : error)
          } else if let http = response as? HTTPURLResponse {
            continuation.resume(returning: (data ?? Data(), http))
          } else {
            continuation.resume(throwing: URLError(.badServerResponse))
          }
        }
        handle.start(task)
      }
    } onCancel: {
      handle.cancel()
    }
  }

  /// Streams the body from `file` (`uploadTask(fromFile:)`); progress comes from the session delegate.
  public func upload(_ request: URLRequest, fromFile file: URL,
                     progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> (Data, HTTPURLResponse) {
    try await transfer(progress: progress, destination: nil) { session.uploadTask(with: request, fromFile: file) }
  }

  /// Streams a 200 body to a temp file next to `destination`, then moves it into place.
  public func download(_ request: URLRequest, to destination: URL,
                       progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> (Data, HTTPURLResponse) {
    try await transfer(progress: progress, destination: destination) { session.dataTask(with: request) }
  }

  private func transfer(progress: @escaping @Sendable (Int64, Int64?) -> Void, destination: URL?,
                        makeTask: () -> URLSessionTask) async throws -> (Data, HTTPURLResponse) {
    let handle = TaskHandle()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let task = makeTask()
        redirects.register(task, Transfer(progress: progress, destination: destination, continuation: continuation))
        handle.start(task)
      }
    } onCancel: {
      handle.cancel()
    }
  }

  /// Settings this transport relies on (tested).
  var configuration: URLSessionConfiguration { session.configuration }
  var delegate: URLSessionDelegate? { session.delegate }
}

/// Declines every redirect, so the task completes with the 3xx response.
class RedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

/// One delegate-driven upload or download.
final class Transfer: @unchecked Sendable {
  let progress: @Sendable (Int64, Int64?) -> Void
  let destination: URL?
  var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
  var response: HTTPURLResponse?
  var body = Data()
  var temp: URL?
  var file: FileHandle?
  var received: Int64 = 0
  var writeError: Error?

  init(progress: @escaping @Sendable (Int64, Int64?) -> Void, destination: URL?,
       continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
    self.progress = progress
    self.destination = destination
    self.continuation = continuation
  }

  /// In-memory error bodies are capped: an envelope is small.
  static let maxErrorBody = 1 << 20
}

/// The session delegate: declines redirects (as `RedirectRefusal`) and drives uploads and downloads, keyed by
/// task. Callbacks arrive on the session's serial delegate queue; `lock` guards the table against `register`.
final class TransferDelegate: RedirectRefusal, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var transfers: [Int: Transfer] = [:]

  func register(_ task: URLSessionTask, _ transfer: Transfer) {
    lock.locked { transfers[task.taskIdentifier] = transfer }
  }

  private func transfer(_ task: URLSessionTask) -> Transfer? {
    lock.locked { transfers[task.taskIdentifier] }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                  totalBytesExpectedToSend: Int64) {
    transfer(task)?.progress(totalBytesSent, totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : nil)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let transfer = transfer(dataTask) else { return completionHandler(.allow) }
    transfer.response = response as? HTTPURLResponse
    if let destination = transfer.destination, transfer.response?.statusCode == 200 {
      let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).part")
      if FileManager.default.createFile(atPath: temp.path, contents: nil), let file = try? FileHandle(forWritingTo: temp) {
        transfer.temp = temp
        transfer.file = file
      } else {
        transfer.writeError = CocoaError(.fileWriteUnknown)
        return completionHandler(.cancel)
      }
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let transfer = transfer(dataTask) else { return }
    if let file = transfer.file {
      do {
        try file.write(contentsOf: data)
      } catch {
        transfer.writeError = error
        dataTask.cancel()
        return
      }
      transfer.received += Int64(data.count)
      let expected = transfer.response?.expectedContentLength ?? -1
      transfer.progress(transfer.received, expected > 0 ? expected : nil)
    } else if transfer.body.count < Transfer.maxErrorBody {
      transfer.body.append(data)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let transfer = lock.locked({ transfers.removeValue(forKey: task.taskIdentifier) }),
          let continuation = transfer.continuation else { return }
    transfer.continuation = nil
    try? transfer.file?.close()
    let cleanUp = { if let temp = transfer.temp { try? FileManager.default.removeItem(at: temp) } }
    if let writeError = transfer.writeError {
      cleanUp()
      return continuation.resume(throwing: writeError)
    }
    if let error {
      cleanUp()
      let cancelled = (error as? URLError)?.code == .cancelled
      return continuation.resume(throwing: cancelled ? CancellationError() : error)
    }
    guard let response = transfer.response ?? (task.response as? HTTPURLResponse) else {
      cleanUp()
      return continuation.resume(throwing: URLError(.badServerResponse))
    }
    if let temp = transfer.temp, let destination = transfer.destination {
      do {
        if FileManager.default.fileExists(atPath: destination.path) {
          _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else {
          try FileManager.default.moveItem(at: temp, to: destination)
        }
      } catch {
        cleanUp()
        return continuation.resume(throwing: error)
      }
      return continuation.resume(returning: (Data(), response))
    }
    continuation.resume(returning: (transfer.body, response))
  }
}

/// Holds the task so a cancellation that races with its start still cancels it.
private final class TaskHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var task: URLSessionTask?
  private var cancelled = false

  func start(_ task: URLSessionTask) {
    let shouldCancel = lock.locked { () -> Bool in
      self.task = task
      return cancelled
    }
    task.resume()
    if shouldCancel { task.cancel() }
  }

  func cancel() {
    let task = lock.locked { () -> URLSessionTask? in
      cancelled = true
      return self.task
    }
    task?.cancel()
  }
}

/// Reads the BE session cookie (`sid`) from `Set-Cookie`.
public enum SessionCookie {
  public static let name = "sid"

  /// The `sid` value from a response's headers, or nil. Handles several `Set-Cookie` headers folded
  /// into one comma-separated value, attributes in any order, and an `Expires=` date's comma.
  public static func token(from response: HTTPURLResponse) -> String? {
    var values: [String] = []
    for (key, value) in response.allHeaderFields {
      guard let key = key as? String, key.lowercased() == "set-cookie", let value = value as? String else { continue }
      values.append(value)
    }
    for value in values {
      if let token = token(fromHeader: value) { return token }
    }
    return nil
  }

  /// The `sid` value from one (possibly folded) `Set-Cookie` header value.
  public static func token(fromHeader header: String) -> String? {
    // Each cookie starts a ";"-separated list; its first pair is name=value. Folded headers join cookies
    // with ", ", so split on "," and keep only pieces that start with "sid=".
    for piece in header.split(separator: ",") {
      let firstPair = piece.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
      let trimmed = firstPair.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("\(name)=") else { continue }
      let value = String(trimmed.dropFirst(name.count + 1))
      // An empty value (or a clearing cookie) is not a session.
      return value.isEmpty ? nil : value
    }
    return nil
  }
}
