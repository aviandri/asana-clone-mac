import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one HTTP request. Abstracted so `LiveMekariAPI` can be tested with a stub.
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` with automatic cookie handling off: the session token is managed by hand (SPEC-MAC §4).
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
  private let session: URLSession

  public init(timeout: TimeInterval = 30) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = timeout
    session = URLSession(configuration: configuration)
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    // The continuation form works on every Foundation (some Linux toolchains lack `data(for:)`).
    try await withCheckedThrowingContinuation { continuation in
      let task = session.dataTask(with: request) { data, response, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let http = response as? HTTPURLResponse {
          continuation.resume(returning: (data ?? Data(), http))
        } else {
          continuation.resume(throwing: URLError(.badServerResponse))
        }
      }
      task.resume()
    }
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
