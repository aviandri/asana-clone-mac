import Foundation

public struct Comment: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var author: UserSummary
  /// Markdown; mentions in storage form `@[Name](userId)`.
  public var body: String
  public var createdAt: Date
  public var editedAt: Date?

  public init(id: String, author: UserSummary, body: String, createdAt: Date, editedAt: Date? = nil) {
    self.id = id
    self.author = author
    self.body = body
    self.createdAt = createdAt
    self.editedAt = editedAt
  }

  /// `body` split into text and mention tokens (markdown is rendered by the app).
  public var segments: [Mentions.Segment] { Mentions.parse(body) }

  private enum CodingKeys: String, CodingKey { case kind, id, author, body, createdAt, editedAt }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    author = try c.decode(UserSummary.self, forKey: .author)
    body = try c.decode(String.self, forKey: .body)
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    editedAt = try c.decodeIfPresent(Date.self, forKey: .editedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode("comment", forKey: .kind)
    try c.encode(id, forKey: .id)
    try c.encode(author, forKey: .author)
    try c.encode(body, forKey: .body)
    try c.encode(createdAt, forKey: .createdAt)
    try c.encode(editedAt, forKey: .editedAt)
  }
}

public struct Activity: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var actor: UserSummary
  public var type: ActivityType
  public var data: JSONValue
  public var createdAt: Date

  public init(id: String, actor: UserSummary, type: ActivityType, data: JSONValue = .null, createdAt: Date) {
    self.id = id
    self.actor = actor
    self.type = type
    self.data = data
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey { case kind, id, actor, type, data, createdAt }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    actor = try c.decode(UserSummary.self, forKey: .actor)
    type = try c.decode(ActivityType.self, forKey: .type)
    data = try c.decodeIfPresent(JSONValue.self, forKey: .data) ?? .null
    createdAt = try c.decode(Date.self, forKey: .createdAt)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode("activity", forKey: .kind)
    try c.encode(id, forKey: .id)
    try c.encode(actor, forKey: .actor)
    try c.encode(type, forKey: .type)
    try c.encode(data, forKey: .data)
    try c.encode(createdAt, forKey: .createdAt)
  }
}

/// A task's comments and activity, oldest first (`GET /tasks/:id/stories`), discriminated by `kind`.
public enum Story: Codable, Sendable, Hashable, Identifiable {
  case comment(Comment)
  case activity(Activity)

  public var id: String {
    switch self {
    case .comment(let comment): return "comment-\(comment.id)"
    case .activity(let activity): return "activity-\(activity.id)"
    }
  }

  public var createdAt: Date {
    switch self {
    case .comment(let comment): return comment.createdAt
    case .activity(let activity): return activity.createdAt
    }
  }

  /// Thrown for a `kind` this build doesn't know; feeds skip such stories (`StoryFeed`).
  public struct UnknownKind: Error, Equatable { public let kind: String }

  private enum CodingKeys: String, CodingKey { case kind }

  public init(from decoder: Decoder) throws {
    let kind = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .kind)
    switch kind {
    case "comment": self = .comment(try Comment(from: decoder))
    case "activity": self = .activity(try Activity(from: decoder))
    default: throw UnknownKind(kind: kind)
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .comment(let comment): try comment.encode(to: encoder)
    case .activity(let activity): try activity.encode(to: encoder)
    }
  }
}

/// `{ "data": [Story] }` from `GET /tasks/:id/stories`, skipping stories of an unknown `kind` instead
/// of failing the whole feed. Malformed stories of a known kind still fail.
struct StoryFeed: Decodable {
  let data: [Story]

  private enum CodingKeys: String, CodingKey { case data }

  private struct Entry: Decodable {
    let story: Story?
    init(from decoder: Decoder) throws {
      do {
        story = try Story(from: decoder)
      } catch is Story.UnknownKind {
        story = nil
      }
    }
  }

  init(from decoder: Decoder) throws {
    let entries = try decoder.container(keyedBy: CodingKeys.self).decode([Entry].self, forKey: .data)
    data = entries.compactMap(\.story)
  }
}

/// Mentions in comment bodies: `@[Name](userId)` (BE SPEC §6 stories).
public enum Mentions {
  public enum Segment: Sendable, Hashable {
    case text(String)
    case mention(name: String, userID: String)
  }

  /// Splits `body` into plain text and mention tokens. Malformed tokens stay text.
  public static func parse(_ body: String) -> [Segment] {
    var segments: [Segment] = []
    var text = ""
    var rest = Substring(body)
    while let at = rest.range(of: "@[") {
      text += rest[..<at.lowerBound]
      let afterOpen = rest[at.upperBound...]
      if let close = afterOpen.range(of: "]("),
         let end = afterOpen[close.upperBound...].firstIndex(of: ")"),
         !afterOpen[..<close.lowerBound].contains("]") {
        let name = String(afterOpen[..<close.lowerBound])
        let id = String(afterOpen[close.upperBound..<end])
        if !name.isEmpty, !id.isEmpty, !id.contains(where: { $0.isWhitespace }) {
          if !text.isEmpty { segments.append(.text(text)); text = "" }
          segments.append(.mention(name: name, userID: id))
          rest = afterOpen[afterOpen.index(after: end)...]
          continue
        }
      }
      text += "@["
      rest = afterOpen
    }
    text += rest
    if !text.isEmpty { segments.append(.text(text)) }
    return segments
  }

  /// The storage form for a mention: `@[Alice Johnson](id)`. Brackets in names would break the
  /// token, so they are dropped.
  public static func token(for user: UserSummary) -> String {
    let name = user.name.filter { $0 != "[" && $0 != "]" }
    return "@[\(name)](\(user.id))"
  }
}
