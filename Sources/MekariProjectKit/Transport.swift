import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one HTTP request. Abstracted so `LiveMekariAPI` can be tested with a stub.
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` with automatic cookie handling off: the session token is managed by hand (SPEC-MAC §4).
/// Redirects are never followed: URLSession would carry our hand-set `Cookie` (and re-post a login on 307/308)
/// to wherever the server, a proxy or a captive portal points. The 3xx itself comes back as the response.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
  private let session: URLSession
  private let redirects = RedirectRefusal()

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

  /// Settings this transport relies on (tested).
  var configuration: URLSessionConfiguration { session.configuration }
  var delegate: URLSessionDelegate? { session.delegate }
}

/// Declines every redirect, so the task completes with the 3xx response.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

/// Holds the data task so a cancellation that races with its start still cancels it.
private final class TaskHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var task: URLSessionDataTask?
  private var cancelled = false

  func start(_ task: URLSessionDataTask) {
    let shouldCancel = lock.locked { () -> Bool in
      self.task = task
      return cancelled
    }
    task.resume()
    if shouldCancel { task.cancel() }
  }

  func cancel() {
    let task = lock.locked { () -> URLSessionDataTask? in
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
