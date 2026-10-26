import Foundation

/// Every failure from `MekariAPI`: the BE error envelope `{error:{code,message,details}}`, or a
/// transport/decoding problem. Views show `message`.
public struct APIError: Error, Sendable, Hashable, LocalizedError {
  public enum Code: Sendable, Hashable {
    case notFound, validation, unauthorized, forbidden, conflict, gone, rateLimited, `internal`
    /// 413 `PAYLOAD_TOO_LARGE` (over 100 MB), or the client's own pre-check (then `status` is nil).
    case payloadTooLarge
    /// 507 `INSUFFICIENT_STORAGE`: the server is out of space for attachments (A12).
    case insufficientStorage
    /// No HTTP response: offline, DNS, TLS, timeout.
    case transport
    /// A response we couldn't decode.
    case decoding
    /// An error code the BE added after this build.
    case unknown(String)

    init(raw: String) {
      switch raw {
      case "NOT_FOUND": self = .notFound
      case "VALIDATION": self = .validation
      case "UNAUTHORIZED": self = .unauthorized
      case "FORBIDDEN": self = .forbidden
      case "CONFLICT": self = .conflict
      case "GONE": self = .gone
      case "RATE_LIMITED": self = .rateLimited
      case "INTERNAL": self = .internal
      case "PAYLOAD_TOO_LARGE": self = .payloadTooLarge
      case "INSUFFICIENT_STORAGE": self = .insufficientStorage
      default: self = .unknown(raw)
      }
    }
  }

  public let code: Code
  /// The HTTP status; nil for `.transport`.
  public let status: Int?
  public let message: String
  /// `error.details` on VALIDATION (and NO_WORKSPACE on 403).
  public let issues: [FieldIssue]

  public init(code: Code, status: Int? = nil, message: String, issues: [FieldIssue] = []) {
    self.code = code
    self.status = status
    self.message = message
    self.issues = issues
  }

  public var errorDescription: String? { message }

  public func issue(for field: String) -> FieldIssue? {
    issues.first { $0.path.first == field }
  }

  /// 403 with `details: [{path:["workspace"], message:"NO_WORKSPACE"}]` (BE §12).
  public var isNoWorkspace: Bool {
    code == .forbidden && issues.contains { $0.path == ["workspace"] && $0.message == "NO_WORKSPACE" }
  }

  public static func transport(_ message: String = "Can't reach the server") -> APIError {
    APIError(code: .transport, message: message)
  }

  public static func decoding(_ message: String) -> APIError {
    APIError(code: .decoding, message: "Unexpected response from the server (\(message))")
  }

  /// Decodes the BE envelope; anything else becomes `.unknown("HTTP <status>")`.
  static func from(status: Int, body: Data) -> APIError {
    if let envelope = try? JSONDecoder().decode(Envelope.self, from: body) {
      return APIError(code: Code(raw: envelope.error.code), status: status, message: envelope.error.message,
                      issues: envelope.error.details?.issues ?? [])
    }
    // A proxy's HTML page (nginx 413, a gateway's 429/507) still means the same thing.
    switch status {
    case 413: return APIError(code: .payloadTooLarge, status: status, message: "The file is too large for the server (HTTP 413)")
    case 429: return APIError(code: .rateLimited, status: status, message: "Too many requests. Try again in a moment.")
    case 507: return APIError(code: .insufficientStorage, status: status, message: "The server is out of space (HTTP 507)")
    default: return APIError(code: .unknown("HTTP \(status)"), status: status, message: "The server returned an error (HTTP \(status))")
    }
  }

  private struct Envelope: Decodable {
    struct Body: Decodable {
      let code: String
      let message: String
      let details: Details?
    }
    let error: Body
  }

  /// `details` is a zod-style issue array when present; any other shape is ignored.
  private struct Details: Decodable {
    let issues: [FieldIssue]
    init(from decoder: Decoder) throws {
      issues = (try? decoder.singleValueContainer().decode([FieldIssue].self)) ?? []
    }
  }
}

public struct FieldIssue: Codable, Sendable, Hashable {
  public let path: [String]
  public let message: String

  public init(path: [String], message: String) {
    self.path = path
    self.message = message
  }

  private enum CodingKeys: String, CodingKey { case path, message }

  /// zod paths may contain numbers (array indices); they become strings.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    message = try c.decode(String.self, forKey: .message)
    var pathContainer = try c.nestedUnkeyedContainer(forKey: .path)
    var path: [String] = []
    while !pathContainer.isAtEnd {
      if let s = try? pathContainer.decode(String.self) {
        path.append(s)
      } else {
        path.append(String(try pathContainer.decode(Int.self)))
      }
    }
    self.path = path
  }
}
