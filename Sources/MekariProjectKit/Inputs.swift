import Foundation

/// A PATCH field that is either set to a value or cleared (JSON `null`). Leaving the property `nil`
/// omits the field, so the BE leaves it unchanged.
public enum Patch<Value: Encodable & Sendable & Equatable>: Sendable, Equatable {
  case set(Value)
  case clear

  public var value: Value? {
    if case .set(let value) = self { return value }
    return nil
  }
}

/// `POST /tasks`.
public struct NewTask: Encodable, Sendable, Equatable {
  public var title: String
  public var projectId: String?
  public var sectionId: String?
  public var parentId: String?
  public var description: String?
  public var assigneeId: String?
  public var dueDate: LocalDate?
  public var startDate: LocalDate?
  public var priority: Priority?
  public var position: Double?

  public init(title: String, projectId: String? = nil, sectionId: String? = nil, parentId: String? = nil,
              description: String? = nil, assigneeId: String? = nil, dueDate: LocalDate? = nil,
              startDate: LocalDate? = nil, priority: Priority? = nil, position: Double? = nil) {
    self.title = title
    self.projectId = projectId
    self.sectionId = sectionId
    self.parentId = parentId
    self.description = description
    self.assigneeId = assigneeId
    self.dueDate = dueDate
    self.startDate = startDate
    self.priority = priority
    self.position = position
  }
}

/// `PATCH /tasks/:id`. `nil` properties are omitted.
public struct TaskChanges: Encodable, Sendable, Equatable {
  public var title: String?
  public var description: Patch<String>?
  public var projectId: Patch<String>?
  public var sectionId: Patch<String>?
  public var assigneeId: Patch<String>?
  public var dueDate: Patch<LocalDate>?
  public var startDate: Patch<LocalDate>?
  public var priority: Priority?
  public var completed: Bool?
  public var position: Double?

  public init(title: String? = nil, description: Patch<String>? = nil, projectId: Patch<String>? = nil,
              sectionId: Patch<String>? = nil, assigneeId: Patch<String>? = nil, dueDate: Patch<LocalDate>? = nil,
              startDate: Patch<LocalDate>? = nil, priority: Priority? = nil, completed: Bool? = nil, position: Double? = nil) {
    self.title = title
    self.description = description
    self.projectId = projectId
    self.sectionId = sectionId
    self.assigneeId = assigneeId
    self.dueDate = dueDate
    self.startDate = startDate
    self.priority = priority
    self.completed = completed
    self.position = position
  }

  public var isEmpty: Bool { self == TaskChanges() }

  private enum CodingKeys: String, CodingKey {
    case title, description, projectId, sectionId, assigneeId, dueDate, startDate, priority, completed, position
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(title, forKey: .title)
    try c.encodePatch(description, forKey: .description)
    try c.encodePatch(projectId, forKey: .projectId)
    try c.encodePatch(sectionId, forKey: .sectionId)
    try c.encodePatch(assigneeId, forKey: .assigneeId)
    try c.encodePatch(dueDate, forKey: .dueDate)
    try c.encodePatch(startDate, forKey: .startDate)
    try c.encodeIfPresent(priority, forKey: .priority)
    try c.encodeIfPresent(completed, forKey: .completed)
    try c.encodeIfPresent(position, forKey: .position)
  }

  /// Applies these changes to `task` locally (optimistic updates). `assignee` is resolved by the
  /// caller, because the patch only carries an id.
  public func applied(to task: TaskItem, assignee: UserSummary?? = .none) -> TaskItem {
    var t = task
    if let title { t.title = title }
    if let description { t.description = description.value }
    if let projectId { t.projectId = projectId.value }
    if let sectionId { t.sectionId = sectionId.value }
    if assigneeId != nil, case .some(let resolved) = assignee { t.assignee = resolved }
    if let dueDate { t.dueDate = dueDate.value }
    if let startDate { t.startDate = startDate.value }
    if let priority { t.priority = priority }
    if let completed {
      t.completed = completed
      t.completedAt = completed ? (t.completedAt ?? Date()) : nil
    }
    if let position { t.position = position }
    return t
  }
}

/// `PATCH /sections/:id`.
public struct SectionChanges: Encodable, Sendable, Equatable {
  public var name: String?
  public var position: Double?

  public init(name: String? = nil, position: Double? = nil) {
    self.name = name
    self.position = position
  }
}

extension KeyedEncodingContainer {
  mutating func encodePatch<Value>(_ patch: Patch<Value>?, forKey key: Key) throws {
    switch patch {
    case .none: break
    case .some(.clear): try encodeNil(forKey: key)
    case .some(.set(let value)): try encode(value, forKey: key)
    }
  }
}
