import Foundation

// MARK: - Enums (BE SPEC §5, §12)

/// A string enum that decodes unknown values to `.other(raw)` instead of failing, so one new BE value
/// never breaks a whole list. `allCases` lists only the known cases (for pickers).
public protocol OpenEnum: Codable, Sendable, Hashable {
  static var allCases: [Self] { get }
  static func other(_ raw: String) -> Self
  var rawValue: String { get }
}

extension OpenEnum {
  public init(rawValue: String) {
    self = Self.allCases.first { $0.rawValue == rawValue } ?? Self.other(rawValue)
  }

  public init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  /// False for `.other`.
  public var isKnown: Bool { Self.allCases.contains(self) }
}

/// Unknown roles get no extra rights: `isAdmin` and `isGuest` are both false.
public enum WorkspaceRole: OpenEnum, CaseIterable {
  case admin, member, guest
  /// A value this build doesn't know (the BE added it later).
  case other(String)

  public static let allCases: [WorkspaceRole] = [.admin, .member, .guest]

  public var rawValue: String {
    switch self {
    case .admin: return "ADMIN"
    case .member: return "MEMBER"
    case .guest: return "GUEST"
    case .other(let raw): return raw
    }
  }
}

public enum ProjectRole: OpenEnum, CaseIterable {
  case owner, editor, commenter
  /// A value this build doesn't know (the BE added it later).
  case other(String)

  public static let allCases: [ProjectRole] = [.owner, .editor, .commenter]

  public var rawValue: String {
    switch self {
    case .owner: return "OWNER"
    case .editor: return "EDITOR"
    case .commenter: return "COMMENTER"
    case .other(let raw): return raw
    }
  }
}

public enum ProjectPrivacy: OpenEnum, CaseIterable {
  case `public`, team, `private`
  /// A value this build doesn't know (the BE added it later).
  case other(String)

  public static let allCases: [ProjectPrivacy] = [.`public`, .team, .`private`]

  public var rawValue: String {
    switch self {
    case .`public`: return "PUBLIC"
    case .team: return "TEAM"
    case .`private`: return "PRIVATE"
    case .other(let raw): return raw
    }
  }
}

/// Unknown views open as a list.
public enum ProjectView: OpenEnum, CaseIterable {
  case list, board, calendar
  /// A value this build doesn't know (the BE added it later).
  case other(String)

  public static let allCases: [ProjectView] = [.list, .board, .calendar]

  public var rawValue: String {
    switch self {
    case .list: return "LIST"
    case .board: return "BOARD"
    case .calendar: return "CALENDAR"
    case .other(let raw): return raw
    }
  }
}

public enum Priority: OpenEnum, CaseIterable {
  case none, low, medium, high
  /// A value this build doesn't know (the BE added it later).
  case other(String)

  public static let allCases: [Priority] = [.none, .low, .medium, .high]

  public var rawValue: String {
    switch self {
    case .none: return "NONE"
    case .low: return "LOW"
    case .medium: return "MEDIUM"
    case .high: return "HIGH"
    case .other(let raw): return raw
    }
  }
}

public enum NotificationType: OpenEnum, CaseIterable {
  case assigned, commented, completed, mentioned
  /// A value this build doesn't know (the BE added it later).
  case other(String)

  public static let allCases: [NotificationType] = [.assigned, .commented, .completed, .mentioned]

  public var rawValue: String {
    switch self {
    case .assigned: return "ASSIGNED"
    case .commented: return "COMMENTED"
    case .completed: return "COMPLETED"
    case .mentioned: return "MENTIONED"
    case .other(let raw): return raw
    }
  }
}

public enum ActivityType: OpenEnum, CaseIterable {
  case created, completed, reopened, assigned, unassigned, dueDateChanged, movedSection, renamed, priorityChanged, descriptionChanged
  /// A value this build doesn't know (the BE added it later).
  case other(String)

  public static let allCases: [ActivityType] = [.created, .completed, .reopened, .assigned, .unassigned, .dueDateChanged, .movedSection, .renamed, .priorityChanged, .descriptionChanged]

  public var rawValue: String {
    switch self {
    case .created: return "CREATED"
    case .completed: return "COMPLETED"
    case .reopened: return "REOPENED"
    case .assigned: return "ASSIGNED"
    case .unassigned: return "UNASSIGNED"
    case .dueDateChanged: return "DUE_DATE_CHANGED"
    case .movedSection: return "MOVED_SECTION"
    case .renamed: return "RENAMED"
    case .priorityChanged: return "PRIORITY_CHANGED"
    case .descriptionChanged: return "DESCRIPTION_CHANGED"
    case .other(let raw): return raw
    }
  }
}

// MARK: - Users & workspaces

public struct UserSummary: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  public var email: String
  public var avatarColor: String

  public init(id: String, name: String, email: String, avatarColor: String) {
    self.id = id
    self.name = name
    self.email = email
    self.avatarColor = avatarColor
  }
}

/// The key path type for the `@dynamicMemberLookup` wrappers below. Swift 6 wants `& Sendable` (key
/// paths cross isolation under strict concurrency), but Swift 5.10 (Xcode 15.4) rejects a composition
/// as a dynamic-member parameter, so 5.10 gets a plain `KeyPath`.
#if compiler(>=6.0)
public typealias MemberKeyPath<Root, Value> = KeyPath<Root, Value> & Sendable
#else
public typealias MemberKeyPath<Root, Value> = KeyPath<Root, Value>
#endif

/// A `GET /users` entry: the person plus their role in the current workspace (W8). Flat in JSON.
@dynamicMemberLookup
public struct PickableUser: Sendable, Hashable, Identifiable {
  public var user: UserSummary
  public var role: WorkspaceRole

  public init(user: UserSummary, role: WorkspaceRole) {
    self.user = user
    self.role = role
  }

  public var id: String { user.id }
  public var isGuest: Bool { role == .guest }
  public subscript<T>(dynamicMember keyPath: MemberKeyPath<UserSummary, T>) -> T { user[keyPath: keyPath] }
}

extension PickableUser: Codable {
  private enum Keys: String, CodingKey { case role }
  public init(from decoder: Decoder) throws {
    user = try UserSummary(from: decoder)
    role = try decoder.container(keyedBy: Keys.self).decode(WorkspaceRole.self, forKey: .role)
  }
  public func encode(to encoder: Encoder) throws {
    try user.encode(to: encoder)
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(role, forKey: .role)
  }
}

/// A user with their role in the current workspace (or, under `/admin/users`, membership state).
public struct User: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  public var email: String
  public var avatarColor: String
  public var role: WorkspaceRole
  public var isActive: Bool
  public var createdAt: Date

  public init(id: String, name: String, email: String, avatarColor: String, role: WorkspaceRole, isActive: Bool, createdAt: Date) {
    self.id = id
    self.name = name
    self.email = email
    self.avatarColor = avatarColor
    self.role = role
    self.isActive = isActive
    self.createdAt = createdAt
  }

  public var summary: UserSummary { UserSummary(id: id, name: name, email: email, avatarColor: avatarColor) }
}

public struct Workspace: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  public var isOrganization: Bool
  public var domain: String?
  public var color: String
  public var myRole: WorkspaceRole
  public var memberCount: Int
  public var createdAt: Date

  public init(id: String, name: String, isOrganization: Bool, domain: String?, color: String, myRole: WorkspaceRole,
              memberCount: Int, createdAt: Date) {
    self.id = id
    self.name = name
    self.isOrganization = isOrganization
    self.domain = domain
    self.color = color
    self.myRole = myRole
    self.memberCount = memberCount
    self.createdAt = createdAt
  }

  public var isGuest: Bool { myRole == .guest }
  public var isAdmin: Bool { myRole == .admin }
}

/// `GET /auth/me`: the user (role = in the current workspace) plus their workspaces. Flat in JSON.
@dynamicMemberLookup
public struct Me: Sendable, Hashable {
  public var user: User
  public var currentWorkspace: Workspace?
  /// By name, as the BE sends them; ⌘1…⌘9 follow this order.
  public var workspaces: [Workspace]

  public init(user: User, currentWorkspace: Workspace?, workspaces: [Workspace]) {
    self.user = user
    self.currentWorkspace = currentWorkspace
    self.workspaces = workspaces
  }

  public subscript<T>(dynamicMember keyPath: MemberKeyPath<User, T>) -> T { user[keyPath: keyPath] }
}

extension Me: Codable {
  private enum Keys: String, CodingKey { case currentWorkspace, workspaces }
  public init(from decoder: Decoder) throws {
    user = try User(from: decoder)
    let container = try decoder.container(keyedBy: Keys.self)
    currentWorkspace = try container.decodeIfPresent(Workspace.self, forKey: .currentWorkspace)
    workspaces = try container.decode([Workspace].self, forKey: .workspaces)
  }
  public func encode(to encoder: Encoder) throws {
    try user.encode(to: encoder)
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(currentWorkspace, forKey: .currentWorkspace)
    try container.encode(workspaces, forKey: .workspaces)
  }
}

// MARK: - Projects

public struct Section: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var projectId: String
  public var name: String
  public var position: Double

  public init(id: String, projectId: String, name: String, position: Double) {
    self.id = id
    self.projectId = projectId
    self.name = name
    self.position = position
  }
}

public struct ProjectMember: Codable, Sendable, Hashable {
  public var user: UserSummary
  public var role: ProjectRole

  public init(user: UserSummary, role: ProjectRole) {
    self.user = user
    self.role = role
  }
}

public struct TeamRef: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

/// `Task.project`.
public struct ProjectRef: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  public var color: String

  public init(id: String, name: String, color: String) {
    self.id = id
    self.name = name
    self.color = color
  }
}

public struct Project: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var workspaceId: String
  public var teamId: String
  public var name: String
  public var description: String?
  public var color: String
  public var privacy: ProjectPrivacy
  public var archived: Bool
  public var defaultView: ProjectView
  public var owner: UserSummary
  /// nil = access through the team or a public project.
  public var myRole: ProjectRole?
  public var createdAt: Date
  public var updatedAt: Date

  public init(id: String, workspaceId: String, teamId: String, name: String, description: String?, color: String,
              privacy: ProjectPrivacy, archived: Bool, defaultView: ProjectView, owner: UserSummary, myRole: ProjectRole?,
              createdAt: Date, updatedAt: Date) {
    self.id = id
    self.workspaceId = workspaceId
    self.teamId = teamId
    self.name = name
    self.description = description
    self.color = color
    self.privacy = privacy
    self.archived = archived
    self.defaultView = defaultView
    self.owner = owner
    self.myRole = myRole
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var ref: ProjectRef { ProjectRef(id: id, name: name, color: color) }
}

/// `GET /projects/:id`. Flat in JSON (`Project & {...}`).
@dynamicMemberLookup
public struct ProjectDetail: Sendable, Hashable, Identifiable {
  public var project: Project
  /// Ordered by position.
  public var sections: [Section]
  public var members: [ProjectMember]
  public var team: TeamRef

  public init(project: Project, sections: [Section], members: [ProjectMember], team: TeamRef) {
    self.project = project
    self.sections = sections
    self.members = members
    self.team = team
  }

  public var id: String { project.id }
  public subscript<T>(dynamicMember keyPath: MemberKeyPath<Project, T>) -> T { project[keyPath: keyPath] }
}

extension ProjectDetail: Codable {
  private enum Keys: String, CodingKey { case sections, members, team }
  public init(from decoder: Decoder) throws {
    project = try Project(from: decoder)
    let container = try decoder.container(keyedBy: Keys.self)
    sections = try container.decode([Section].self, forKey: .sections)
    members = try container.decode([ProjectMember].self, forKey: .members)
    team = try container.decode(TeamRef.self, forKey: .team)
  }
  public func encode(to encoder: Encoder) throws {
    try project.encode(to: encoder)
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(sections, forKey: .sections)
    try container.encode(members, forKey: .members)
    try container.encode(team, forKey: .team)
  }
}

// MARK: - Tasks

/// A BE `Task`. (Named `TaskItem` because Swift's `Task` is concurrency.)
public struct TaskItem: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var workspaceId: String
  public var projectId: String?
  public var sectionId: String?
  public var parentId: String?
  public var title: String
  public var description: String?
  public var assignee: UserSummary?
  public var creator: UserSummary
  public var dueDate: LocalDate?
  public var startDate: LocalDate?
  public var priority: Priority
  public var completed: Bool
  public var completedAt: Date?
  public var position: Double
  public var subtaskCount: Int
  public var completedSubtaskCount: Int
  public var commentCount: Int
  public var project: ProjectRef?
  public var createdAt: Date
  public var updatedAt: Date

  public init(id: String, workspaceId: String, projectId: String? = nil, sectionId: String? = nil, parentId: String? = nil,
              title: String, description: String? = nil, assignee: UserSummary? = nil, creator: UserSummary,
              dueDate: LocalDate? = nil, startDate: LocalDate? = nil, priority: Priority = .none, completed: Bool = false,
              completedAt: Date? = nil, position: Double = 1000, subtaskCount: Int = 0, completedSubtaskCount: Int = 0,
              commentCount: Int = 0, project: ProjectRef? = nil, createdAt: Date, updatedAt: Date) {
    self.id = id
    self.workspaceId = workspaceId
    self.projectId = projectId
    self.sectionId = sectionId
    self.parentId = parentId
    self.title = title
    self.description = description
    self.assignee = assignee
    self.creator = creator
    self.dueDate = dueDate
    self.startDate = startDate
    self.priority = priority
    self.completed = completed
    self.completedAt = completedAt
    self.position = position
    self.subtaskCount = subtaskCount
    self.completedSubtaskCount = completedSubtaskCount
    self.commentCount = commentCount
    self.project = project
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  // Optional fields are always present in BE JSON (as null); encode them that way too.
  private enum CodingKeys: String, CodingKey {
    case id, workspaceId, projectId, sectionId, parentId, title, description, assignee, creator, dueDate, startDate
    case priority, completed, completedAt, position, subtaskCount, completedSubtaskCount, commentCount, project
    case createdAt, updatedAt
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(workspaceId, forKey: .workspaceId)
    try c.encode(projectId, forKey: .projectId)
    try c.encode(sectionId, forKey: .sectionId)
    try c.encode(parentId, forKey: .parentId)
    try c.encode(title, forKey: .title)
    try c.encode(description, forKey: .description)
    try c.encode(assignee, forKey: .assignee)
    try c.encode(creator, forKey: .creator)
    try c.encode(dueDate, forKey: .dueDate)
    try c.encode(startDate, forKey: .startDate)
    try c.encode(priority, forKey: .priority)
    try c.encode(completed, forKey: .completed)
    try c.encode(completedAt, forKey: .completedAt)
    try c.encode(position, forKey: .position)
    try c.encode(subtaskCount, forKey: .subtaskCount)
    try c.encode(completedSubtaskCount, forKey: .completedSubtaskCount)
    try c.encode(commentCount, forKey: .commentCount)
    try c.encode(project, forKey: .project)
    try c.encode(createdAt, forKey: .createdAt)
    try c.encode(updatedAt, forKey: .updatedAt)
  }
}

public struct TaskParentRef: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var title: String

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

/// `GET /tasks/:id`. Flat in JSON (`Task & {...}`).
@dynamicMemberLookup
public struct TaskDetail: Sendable, Hashable, Identifiable {
  public var task: TaskItem
  public var followers: [UserSummary]
  public var subtasks: [TaskItem]
  public var parent: TaskParentRef?

  public init(task: TaskItem, followers: [UserSummary] = [], subtasks: [TaskItem] = [], parent: TaskParentRef? = nil) {
    self.task = task
    self.followers = followers
    self.subtasks = subtasks
    self.parent = parent
  }

  public var id: String { task.id }
  public subscript<T>(dynamicMember keyPath: MemberKeyPath<TaskItem, T>) -> T { task[keyPath: keyPath] }
}

extension TaskDetail: Codable {
  private enum Keys: String, CodingKey { case followers, subtasks, parent }
  public init(from decoder: Decoder) throws {
    task = try TaskItem(from: decoder)
    let container = try decoder.container(keyedBy: Keys.self)
    followers = try container.decode([UserSummary].self, forKey: .followers)
    subtasks = try container.decode([TaskItem].self, forKey: .subtasks)
    parent = try container.decodeIfPresent(TaskParentRef.self, forKey: .parent)
  }
  public func encode(to encoder: Encoder) throws {
    try task.encode(to: encoder)
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(followers, forKey: .followers)
    try container.encode(subtasks, forKey: .subtasks)
    try container.encode(parent, forKey: .parent)
  }
}

// MARK: - Inbox & search

public struct NotificationTaskRef: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var title: String
  public var projectId: String?

  public init(id: String, title: String, projectId: String?) {
    self.id = id
    self.title = title
    self.projectId = projectId
  }
}

/// A BE `Notification`. (Named `InboxNotification` because Foundation has `Notification`.)
public struct InboxNotification: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var workspaceId: String
  public var type: NotificationType
  public var read: Bool
  public var createdAt: Date
  public var actor: UserSummary
  public var task: NotificationTaskRef?

  public init(id: String, workspaceId: String, type: NotificationType, read: Bool, createdAt: Date, actor: UserSummary,
              task: NotificationTaskRef?) {
    self.id = id
    self.workspaceId = workspaceId
    self.type = type
    self.read = read
    self.createdAt = createdAt
    self.actor = actor
    self.task = task
  }

  /// "Alice Johnson commented on Fix login" (local notification banners, inbox rows).
  public var summary: String {
    let verb: String
    switch type {
    case .assigned: verb = "assigned you"
    case .commented: verb = "commented on"
    case .completed: verb = "completed"
    case .mentioned: verb = "mentioned you on"
    case .other: verb = "updated"
    }
    guard let task else { return "\(actor.name) \(verb)" }
    return "\(actor.name) \(verb) \(task.title)"
  }
}

public struct InboxPage: Codable, Sendable, Hashable {
  public var data: [InboxNotification]
  public var unreadCount: Int

  public init(data: [InboxNotification], unreadCount: Int) {
    self.data = data
    self.unreadCount = unreadCount
  }
}

public struct SearchResults: Codable, Sendable, Hashable {
  public var tasks: [TaskItem]
  public var projects: [Project]
  public var users: [UserSummary]

  public init(tasks: [TaskItem] = [], projects: [Project] = [], users: [UserSummary] = []) {
    self.tasks = tasks
    self.projects = projects
    self.users = users
  }

  public var isEmpty: Bool { tasks.isEmpty && projects.isEmpty && users.isEmpty }
}

/// `{ "data": [...] }`.
struct ListResponse<Item: Decodable>: Decodable {
  var data: [Item]
}
