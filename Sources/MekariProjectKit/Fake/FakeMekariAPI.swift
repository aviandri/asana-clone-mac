import Foundation

/// The endpoints `FakeMekariAPI` records and can be told to fail.
public enum FakeEndpoint: String, Sendable, Hashable, CaseIterable {
  case health, login, logout, me, switchWorkspace, users, projects, project, projectTasks
  case createSection, updateSection, deleteSection, myTasks, task, createTask, updateTask, deleteTask
  case addFollower, removeFollower, stories, addComment, editComment, deleteComment
  case notifications, markRead, markAllRead, search
}

public struct FakeCall: Sendable, Hashable {
  public let endpoint: FakeEndpoint
  /// The workspace header in effect (nil for unscoped endpoints).
  public let workspaceID: String?
}

/// An in-memory `MekariAPI` seeded with demo data (SPEC-MAC §3), for previews, unit tests and the
/// `-UITestFakeAPI` UI test. It applies the BE rules the UI depends on: sessions (401), workspace
/// scoping and lost access, project visibility per role (§4, §12 guests), COMMENTER read-only (403),
/// cross-workspace checks (400), notifications for assignments, comments and mentions.
public actor FakeMekariAPI: MekariAPI {
  public nonisolated let events: AsyncStream<APIEvent>
  private nonisolated let eventSink: AsyncStream<APIEvent>.Continuation

  private var db: FakeSeed
  private var lastWorkspace: [String: String] = [:]
  private var currentUserID: String?
  private var workspaceID: String?
  private var failures: [FakeEndpoint: APIError] = [:]
  private var latency: Duration = .zero
  private var holds: Set<FakeEndpoint> = []
  private var parked: [FakeEndpoint: [CheckedContinuation<Void, Never>]] = [:]
  public private(set) var calls: [FakeCall] = []

  /// - Parameter signedInAs: an email to start signed in as, or nil to start signed out.
  public init(seed: FakeSeed = .demo, signedInAs email: String? = "alice@example.com") {
    db = seed
    (events, eventSink) = AsyncStream.makeStream(of: APIEvent.self)
    currentUserID = email.flatMap { e in seed.users.first { $0.summary.email == e.lowercased() }?.summary.id }
  }

  // MARK: - Test knobs

  public func failNext(_ endpoint: FakeEndpoint, with error: APIError) {
    failures[endpoint] = error
  }

  public func setLatency(_ duration: Duration) {
    latency = duration
  }

  /// Parks every later call to `endpoint` (after it is recorded, before it runs) until `release`.
  /// Lets tests interleave concurrent requests deterministically, without sleeps.
  public func hold(_ endpoint: FakeEndpoint) {
    holds.insert(endpoint)
  }

  /// Lets the oldest (or `newest`) parked call to `endpoint` continue. With `all`, releases every
  /// parked call and stops holding new ones.
  public func release(_ endpoint: FakeEndpoint, all: Bool = false, newest: Bool = false) {
    if all { holds.remove(endpoint) }
    var waiting = parked[endpoint] ?? []
    guard !waiting.isEmpty else { return }
    if all {
      parked[endpoint] = nil
      waiting.forEach { $0.resume() }
    } else {
      let next = newest ? waiting.removeLast() : waiting.removeFirst()
      parked[endpoint] = waiting
      next.resume()
    }
  }

  /// How many calls to `endpoint` are parked right now.
  public func parkedCount(_ endpoint: FakeEndpoint) -> Int {
    parked[endpoint]?.count ?? 0
  }

  public func emit(_ event: APIEvent) {
    eventSink.yield(event)
  }

  public func addNotification(_ notification: InboxNotification, for userID: String) {
    db.notifications.append(FakeSeed.NotificationRecord(userId: userID, notification: notification))
  }

  /// Removes a user's membership (to simulate losing access mid-session).
  public func removeMembership(userID: String, workspaceID: String) {
    db.memberships.removeAll { $0.userId == userID && $0.workspaceId == workspaceID }
  }

  public func currentTasks() -> [TaskItem] { db.tasks.map(render) }

  // MARK: - MekariAPI: session

  public func setWorkspace(_ id: String?) {
    workspaceID = id
  }

  public var hasSession: Bool { currentUserID != nil }

  public func health() async throws {
    try await gate(.health, scoped: false)
  }

  public func login(email: String, password: String) async throws -> Me {
    try await gate(.login, scoped: false)
    guard let user = db.users.first(where: { $0.summary.email == email.lowercased() && $0.password == password }) else {
      throw APIError(code: .unauthorized, status: 401, message: "Invalid email or password")
    }
    guard user.isActive else { throw APIError(code: .unauthorized, status: 401, message: "This account has been deactivated") }
    currentUserID = user.summary.id
    return try makeMe(header: nil)
  }

  public func logout() async {
    try? await gate(.logout, scoped: false)
    currentUserID = nil
  }

  public func me() async throws -> Me {
    try await gate(.me, scoped: false)
    _ = try requireUser()
    return try makeMe(header: nil)
  }

  public func switchWorkspace(_ id: String) async throws -> Workspace {
    try await gate(.switchWorkspace, scoped: false)
    let user = try requireUser()
    guard let membership = activeMembership(user, id) else { throw notFound("Workspace") }
    lastWorkspace[user] = id
    return workspaceShape(id, role: membership.role)
  }

  // MARK: - Users

  public func users(query: String?) async throws -> [PickableUser] {
    try await gate(.users)
    let (user, ws, role) = try scope(collection: true)
    let q = query?.lowercased() ?? ""
    return pickable(user: user, ws: ws, role: role)
      .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.email.lowercased().contains(q) }
      .sorted { $0.name < $1.name }
  }

  // MARK: - Projects & sections

  public func projects(archived: Bool) async throws -> [Project] {
    try await gate(.projects)
    let (user, ws, role) = try scope(collection: true)
    return db.projects
      .filter { $0.project.workspaceId == ws && $0.project.archived == archived && canSee($0, user: user, role: role) }
      .map { render($0, for: user) }
      .sorted { $0.name < $1.name }
  }

  public func project(_ id: String) async throws -> ProjectDetail {
    try await gate(.project, scoped: false)
    let (record, user, _) = try visibleProject(id)
    return ProjectDetail(project: render(record, for: user), sections: record.sections.sorted { $0.position < $1.position },
                         members: record.members, team: TeamRef(id: record.project.teamId, name: teamName(record.project.teamId)))
  }

  public func projectTasks(_ projectID: String, completed: Bool?) async throws -> [TaskItem] {
    try await gate(.projectTasks, scoped: false)
    let (record, _, _) = try visibleProject(projectID)
    let sectionPos = Dictionary(uniqueKeysWithValues: record.sections.map { ($0.id, $0.position) })
    return db.tasks
      .filter { $0.projectId == projectID && $0.parentId == nil && (completed == nil || $0.completed == completed) }
      .sorted {
        let a = $0.sectionId.flatMap { sectionPos[$0] } ?? .infinity, b = $1.sectionId.flatMap { sectionPos[$0] } ?? .infinity
        return a != b ? a < b : $0.position < $1.position
      }
      .map(render)
  }

  public func createSection(projectID: String, name: String, position: Double?) async throws -> Section {
    try await gate(.createSection, scoped: false)
    let (record, user, role) = try visibleProject(projectID)
    try requireEdit(record, user: user, role: role)
    let last = record.sections.map(\.position).max()
    let section = Section(id: newID(), projectId: projectID, name: try nonEmpty(name, "name"),
                          position: position ?? Reorder.position(between: last, and: nil))
    mutateProject(projectID) { $0.sections.append(section) }
    return section
  }

  public func updateSection(_ id: String, _ changes: SectionChanges) async throws -> Section {
    try await gate(.updateSection, scoped: false)
    guard let record = db.projects.first(where: { $0.sections.contains { $0.id == id } }) else { throw notFound("Section") }
    let (_, user, role) = try visibleProject(record.project.id)
    try requireEdit(record, user: user, role: role)
    var updated: Section?
    mutateProject(record.project.id) { p in
      guard let i = p.sections.firstIndex(where: { $0.id == id }) else { return }
      if let name = changes.name { p.sections[i].name = name }
      if let position = changes.position { p.sections[i].position = position }
      updated = p.sections[i]
    }
    return updated!
  }

  public func deleteSection(_ id: String) async throws {
    try await gate(.deleteSection, scoped: false)
    guard let record = db.projects.first(where: { $0.sections.contains { $0.id == id } }) else { throw notFound("Section") }
    let (_, user, role) = try visibleProject(record.project.id)
    try requireEdit(record, user: user, role: role)
    mutateProject(record.project.id) { $0.sections.removeAll { $0.id == id } }
    for i in db.tasks.indices where db.tasks[i].sectionId == id { db.tasks[i].sectionId = nil }
  }

  // MARK: - Tasks

  public func myTasks(includeCompleted: Bool) async throws -> [TaskItem] {
    try await gate(.myTasks)
    let (user, ws, _) = try scope(collection: true)
    return db.tasks
      .filter { $0.workspaceId == ws && $0.assignee?.id == user && (includeCompleted || !$0.completed) }
      .map(render)
  }

  public func task(_ id: String) async throws -> TaskDetail {
    try await gate(.task, scoped: false)
    let (task, _) = try visibleTask(id)
    return detail(task)
  }

  public func createTask(_ input: NewTask) async throws -> TaskDetail {
    try await gate(.createTask)
    let user = try requireUser()
    let title = try nonEmpty(input.title, "title")
    var projectID = input.projectId
    var workspace: String
    if let parentID = input.parentId {
      let (parent, _) = try visibleTask(parentID)
      try requireEditTask(parent, user: user)
      if parent.parentId != nil { throw validation("parentId", "Subtasks cannot have subtasks") }
      if input.sectionId != nil, parent.projectId == nil { throw validation("sectionId", "Parent is a personal task") }
      projectID = parent.projectId
      workspace = parent.workspaceId
    } else if let pid = projectID {
      let (record, _, role) = try visibleProject(pid)
      try requireEdit(record, user: user, role: role)
      workspace = record.project.workspaceId
    } else {
      workspace = try scope(collection: true).ws
    }
    if let sectionID = input.sectionId {
      guard let record = db.projects.first(where: { $0.sections.contains { $0.id == sectionID } }) else { throw notFound("Section") }
      if let pid = projectID, record.project.id != pid { throw validation("sectionId", "Wrong project") }
      let (_, _, role) = try visibleProject(record.project.id)
      try requireEdit(record, user: user, role: role)
      projectID = record.project.id
      workspace = record.project.workspaceId
    }
    if let assigneeID = input.assigneeId, activeMembership(assigneeID, workspace) == nil {
      throw validation("assigneeId", "Not an active workspace member")
    }
    let siblings = db.tasks.filter { $0.projectId == projectID && $0.sectionId == input.sectionId && $0.parentId == input.parentId }
    let now = Date()
    let task = TaskItem(id: newID(), workspaceId: workspace, projectId: projectID, sectionId: input.sectionId, parentId: input.parentId,
                        title: title, description: input.description, assignee: input.assigneeId.flatMap(summary),
                        creator: summary(user)!, dueDate: input.dueDate, startDate: input.startDate,
                        priority: input.priority ?? .none,
                        position: input.position ?? Reorder.position(between: siblings.map(\.position).max(), and: nil),
                        createdAt: now, updatedAt: now)
    db.tasks.append(task)
    db.followers[task.id] = Array(Set([user] + (input.assigneeId.map { [$0] } ?? []))).sorted()
    appendActivity(task.id, actor: user, .created)
    if let assignee = input.assigneeId { notify([assignee], .assigned, actor: user, task: task) }
    return detail(task)
  }

  public func updateTask(_ id: String, _ changes: TaskChanges) async throws -> TaskDetail {
    try await gate(.updateTask, scoped: false)
    let user = try requireUser()
    let (task, _) = try visibleTask(id)
    try requireEditTask(task, user: user)
    if let title = changes.title { _ = try nonEmpty(title, "title") }
    var assignee: UserSummary?? = .none
    if let patch = changes.assigneeId {
      if case .set(let assigneeID) = patch {
        guard activeMembership(assigneeID, task.workspaceId) != nil else { throw validation("assigneeId", "Not an active workspace member") }
        assignee = .some(summary(assigneeID))
      } else {
        assignee = .some(nil)
      }
    }
    var effective = changes
    if let projectPatch = changes.projectId, projectPatch.value != task.projectId {
      // Moving between projects (BE): subtasks follow their parent; the target must be visible,
      // editable and in the same workspace; the old section never carries over.
      if task.parentId != nil { throw validation("projectId", "Move the parent instead") }
      if case .set(let projectID) = projectPatch {
        guard let target = db.projects.first(where: { $0.project.id == projectID }) else { throw notFound("Project") }
        if target.project.workspaceId != task.workspaceId { throw validation("projectId", "Project is in another workspace") }
        let (_, _, role) = try visibleProject(projectID)
        try requireEdit(target, user: user, role: role)
      }
      if changes.sectionId == nil { effective.sectionId = .clear }
    }
    if case .set(let sectionID)? = effective.sectionId {
      let projectID = effective.projectId.map { $0.value } ?? task.projectId
      guard let record = db.projects.first(where: { $0.project.id == projectID }), record.sections.contains(where: { $0.id == sectionID })
      else { throw validation("sectionId", "Section belongs to a different project") }
    }
    guard let index = db.tasks.firstIndex(where: { $0.id == id }) else { throw notFound("Task") }
    var updated = effective.applied(to: db.tasks[index], assignee: assignee)
    updated.updatedAt = Date()
    db.tasks[index] = updated
    if effective.projectId != nil {
      for i in db.tasks.indices where db.tasks[i].parentId == id { db.tasks[i].projectId = updated.projectId }
    }
    if let completed = changes.completed, completed != task.completed {
      appendActivity(id, actor: user, completed ? .completed : .reopened)
      if completed { notify(db.followers[id] ?? [], .completed, actor: user, task: updated) }
    }
    if case .some(.some(let newAssignee)) = assignee, newAssignee.id != task.assignee?.id {
      db.followers[id] = Array(Set((db.followers[id] ?? []) + [newAssignee.id])).sorted()
      appendActivity(id, actor: user, .assigned, data: .object(["assigneeId": .string(newAssignee.id)]))
      notify([newAssignee.id], .assigned, actor: user, task: updated)
    } else if case .some(.none) = assignee, let previous = task.assignee {
      appendActivity(id, actor: user, .unassigned, data: .object(["assigneeId": .string(previous.id)]))
    }
    return detail(updated)
  }

  public func deleteTask(_ id: String) async throws {
    try await gate(.deleteTask, scoped: false)
    let user = try requireUser()
    let (task, _) = try visibleTask(id)
    try requireEditTask(task, user: user)
    db.tasks.removeAll { $0.id == id || $0.parentId == id }
  }

  public func addFollower(taskID: String, userID: String) async throws -> TaskDetail {
    try await gate(.addFollower, scoped: false)
    let (task, _) = try visibleTask(taskID)
    guard activeMembership(userID, task.workspaceId) != nil else { throw validation("userId", "Not an active workspace member") }
    db.followers[taskID] = Array(Set((db.followers[taskID] ?? []) + [userID])).sorted()
    return detail(task)
  }

  public func removeFollower(taskID: String, userID: String) async throws -> TaskDetail {
    try await gate(.removeFollower, scoped: false)
    let (task, _) = try visibleTask(taskID)
    db.followers[taskID]?.removeAll { $0 == userID }
    return detail(task)
  }

  // MARK: - Stories

  public func stories(taskID: String) async throws -> [Story] {
    try await gate(.stories, scoped: false)
    _ = try visibleTask(taskID)
    return (db.stories[taskID] ?? []).sorted { $0.createdAt < $1.createdAt }
  }

  public func addComment(taskID: String, body: String) async throws -> Comment {
    try await gate(.addComment, scoped: false)
    let user = try requireUser()
    let (task, _) = try visibleTask(taskID)
    let comment = Comment(id: newID(), author: summary(user)!, body: try nonEmpty(body, "body"), createdAt: Date())
    let mentioned = comment.segments.compactMap { segment -> String? in
      if case .mention(_, let id) = segment { return id }
      return nil
    }
    // BE: only members of the task's workspace can be mentioned.
    if mentioned.contains(where: { activeMembership($0, task.workspaceId) == nil }) {
      throw validation("body", "Only members of this workspace can be mentioned")
    }
    db.stories[taskID, default: []].append(.comment(comment))
    notify(mentioned, .mentioned, actor: user, task: task)
    notify((db.followers[taskID] ?? []).filter { !mentioned.contains($0) }, .commented, actor: user, task: task)
    db.followers[taskID] = Array(Set((db.followers[taskID] ?? []) + [user])).sorted()
    return comment
  }

  public func editComment(_ id: String, body: String) async throws -> Comment {
    try await gate(.editComment, scoped: false)
    let user = try requireUser()
    let (taskID, comment) = try findComment(id)
    guard comment.author.id == user else { throw APIError(code: .forbidden, status: 403, message: "Only the author can edit a comment") }
    var edited = comment
    edited.body = try nonEmpty(body, "body")
    edited.editedAt = Date()
    replaceComment(taskID, id) { _ in .comment(edited) }
    return edited
  }

  public func deleteComment(_ id: String) async throws {
    try await gate(.deleteComment, scoped: false)
    let user = try requireUser()
    let (taskID, comment) = try findComment(id)
    let task = db.tasks.first { $0.id == taskID }
    let isAdmin = task.flatMap { activeMembership(user, $0.workspaceId)?.role } == .admin
    guard comment.author.id == user || isAdmin else {
      throw APIError(code: .forbidden, status: 403, message: "Only the author or an admin can delete a comment")
    }
    replaceComment(taskID, id) { _ in nil }
  }

  // MARK: - Inbox & search

  public func notifications(unreadOnly: Bool, limit: Int) async throws -> InboxPage {
    try await gate(.notifications)
    let (user, ws, _) = try scope(collection: true)
    let mine = db.notifications.filter { $0.userId == user && $0.notification.workspaceId == ws }.map(\.notification)
    let unread = mine.filter { !$0.read }.count
    let list = mine.filter { !unreadOnly || !$0.read }.sorted { $0.createdAt > $1.createdAt }
    return InboxPage(data: Array(list.prefix(limit)), unreadCount: unread)
  }

  public func markRead(_ notificationID: String) async throws {
    try await gate(.markRead, scoped: false)
    let user = try requireUser()
    guard let i = db.notifications.firstIndex(where: { $0.notification.id == notificationID && $0.userId == user }) else {
      throw notFound("Notification")
    }
    db.notifications[i].notification.read = true
  }

  public func markAllRead() async throws {
    try await gate(.markAllRead)
    let (user, ws, _) = try scope(collection: true)
    for i in db.notifications.indices where db.notifications[i].userId == user && db.notifications[i].notification.workspaceId == ws {
      db.notifications[i].notification.read = true
    }
  }

  public func search(_ query: String) async throws -> SearchResults {
    try await gate(.search)
    let (user, ws, role) = try scope(collection: true)
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard q.count >= 2 else { throw validation("q", "At least 2 characters") }
    let projects = db.projects.filter { $0.project.workspaceId == ws && canSee($0, user: user, role: role) }
    let visibleIDs = Set(projects.map(\.project.id))
    let tasks = db.tasks.filter { t in
      t.workspaceId == ws && t.title.lowercased().contains(q) && taskVisible(t, user: user, role: role, visibleProjects: visibleIDs)
    }
    let people = pickable(user: user, ws: ws, role: role).filter { $0.name.lowercased().contains(q) || $0.email.lowercased().contains(q) }
    return SearchResults(tasks: Array(tasks.prefix(10)).map(render),
                         projects: Array(projects.filter { $0.project.name.lowercased().contains(q) }.prefix(10)).map { render($0, for: user) },
                         users: Array(people.prefix(10)).map(\.user))
  }

  // MARK: - Rules

  private func gate(_ endpoint: FakeEndpoint, scoped: Bool = true) async throws {
    calls.append(FakeCall(endpoint: endpoint, workspaceID: scoped ? workspaceID : nil))
    if holds.contains(endpoint) {
      await withCheckedContinuation { parked[endpoint, default: []].append($0) }
      // Like the live client: a caller cancelled while waiting gets CancellationError.
      if Task.isCancelled { throw CancellationError() }
    }
    if latency > .zero { try? await Task.sleep(for: latency) }
    if let failure = failures.removeValue(forKey: endpoint) {
      if failure.code == .unauthorized, endpoint != .login {
        currentUserID = nil
        eventSink.yield(.unauthorized)
      }
      throw failure
    }
  }

  private func requireUser() throws -> String {
    guard let user = currentUserID else {
      eventSink.yield(.unauthorized)
      throw APIError(code: .unauthorized, status: 401, message: "Not signed in")
    }
    return user
  }

  private func activeMembership(_ userID: String, _ workspaceID: String) -> FakeSeed.Membership? {
    guard db.users.contains(where: { $0.summary.id == userID && $0.isActive }) else { return nil }
    return db.memberships.first { $0.userId == userID && $0.workspaceId == workspaceID && $0.isActive }
  }

  /// The current workspace for a scoped request: header → last used → first membership (BE §12).
  private func scope(collection: Bool) throws -> (user: String, ws: String, role: WorkspaceRole) {
    let user = try requireUser()
    if let header = workspaceID {
      guard let m = activeMembership(user, header) else {
        if collection { eventSink.yield(.workspaceLost(workspaceID: header)) }
        throw notFound("Workspace")
      }
      return (user, header, m.role)
    }
    guard let ws = currentWorkspaceID(user), let m = activeMembership(user, ws) else {
      throw APIError(code: .forbidden, status: 403, message: "You are not a member of any workspace",
                     issues: [FieldIssue(path: ["workspace"], message: "NO_WORKSPACE")])
    }
    return (user, ws, m.role)
  }

  private func currentWorkspaceID(_ user: String) -> String? {
    if let last = lastWorkspace[user], activeMembership(user, last) != nil { return last }
    return db.memberships.first { $0.userId == user && activeMembership(user, $0.workspaceId) != nil }?.workspaceId
  }

  private func canSee(_ record: FakeSeed.ProjectRecord, user: String, role: WorkspaceRole) -> Bool {
    let isMember = record.members.contains { $0.user.id == user }
    switch role {
    case .admin: return true
    case .guest, .other: return isMember
    case .member:
      switch record.project.privacy {
      case .public: return true
      case .team: return isMember || db.teams.first { $0.id == record.project.teamId }?.memberIds.contains(user) == true
      case .private, .other: return isMember
      }
    }
  }

  private func visibleProject(_ id: String) throws -> (FakeSeed.ProjectRecord, String, WorkspaceRole) {
    let user = try requireUser()
    guard let record = db.projects.first(where: { $0.project.id == id }),
          let m = activeMembership(user, record.project.workspaceId), canSee(record, user: user, role: m.role)
    else { throw notFound("Project") }
    return (record, user, m.role)
  }

  private func requireEdit(_ record: FakeSeed.ProjectRecord, user: String, role: WorkspaceRole) throws {
    let myRole = record.members.first { $0.user.id == user }?.role
    if role != .admin && myRole == .commenter {
      throw APIError(code: .forbidden, status: 403, message: "Commenters can only add comments in this project")
    }
  }

  private func requireEditTask(_ task: TaskItem, user: String) throws {
    guard let projectID = task.projectId else { return }
    let (record, _, role) = try visibleProject(projectID)
    try requireEdit(record, user: user, role: role)
  }

  private func taskVisible(_ task: TaskItem, user: String, role: WorkspaceRole, visibleProjects: Set<String>) -> Bool {
    if let projectID = task.projectId { return visibleProjects.contains(projectID) }
    if role == .admin { return true }
    var root = task
    while let parentID = root.parentId, let parent = db.tasks.first(where: { $0.id == parentID }) { root = parent }
    return root.creator.id == user || root.assignee?.id == user || (db.followers[root.id] ?? []).contains(user)
  }

  private func visibleTask(_ id: String) throws -> (TaskItem, WorkspaceRole) {
    let user = try requireUser()
    guard let task = db.tasks.first(where: { $0.id == id }), let m = activeMembership(user, task.workspaceId) else {
      throw notFound("Task")
    }
    let visibleProjects = Set(db.projects.filter { $0.project.workspaceId == task.workspaceId && canSee($0, user: user, role: m.role) }
      .map(\.project.id))
    guard taskVisible(task, user: user, role: m.role, visibleProjects: visibleProjects) else { throw notFound("Task") }
    return (task, m.role)
  }

  /// W8 pickers: guests only see people who share a project with them.
  private func pickable(user: String, ws: String, role: WorkspaceRole) -> [PickableUser] {
    let coMembers: Set<String>? = role == .guest
      ? Set(db.projects.filter { $0.project.workspaceId == ws && $0.members.contains { $0.user.id == user } }
          .flatMap { $0.members.map(\.user.id) } + [user])
      : nil
    return db.memberships.filter { $0.workspaceId == ws && activeMembership($0.userId, ws) != nil }
      .filter { coMembers?.contains($0.userId) ?? true }
      .compactMap { m in summary(m.userId).map { PickableUser(user: $0, role: m.role) } }
  }

  // MARK: - Shapes & mutation helpers

  private func makeMe(header: String?) throws -> Me {
    let user = try requireUser()
    guard let record = db.users.first(where: { $0.summary.id == user }) else { throw notFound("User") }
    let mine = db.memberships.filter { $0.userId == user && activeMembership(user, $0.workspaceId) != nil }
    let workspaces = mine.map { workspaceShape($0.workspaceId, role: $0.role) }.sorted { $0.name < $1.name }
    let current = currentWorkspaceID(user).flatMap { id in workspaces.first { $0.id == id } }
    let u = record.summary
    return Me(user: User(id: u.id, name: u.name, email: u.email, avatarColor: u.avatarColor, role: current?.myRole ?? .member,
                         isActive: record.isActive, createdAt: record.createdAt),
              currentWorkspace: current, workspaces: workspaces)
  }

  private func workspaceShape(_ id: String, role: WorkspaceRole) -> Workspace {
    var w = db.workspaces.first { $0.id == id }!
    w.myRole = role
    w.memberCount = db.memberships.filter { $0.workspaceId == id && activeMembership($0.userId, id) != nil }.count
    return w
  }

  private func render(_ record: FakeSeed.ProjectRecord, for user: String) -> Project {
    var p = record.project
    p.myRole = record.members.first { $0.user.id == user }?.role
    return p
  }

  private func render(_ task: TaskItem) -> TaskItem {
    var t = task
    let subtasks = db.tasks.filter { $0.parentId == task.id }
    t.subtaskCount = subtasks.count
    t.completedSubtaskCount = subtasks.filter(\.completed).count
    t.commentCount = (db.stories[task.id] ?? []).filter { if case .comment = $0 { return true } else { return false } }.count
    t.project = task.projectId.flatMap { id in db.projects.first { $0.project.id == id }?.project.ref }
    return t
  }

  private func detail(_ task: TaskItem) -> TaskDetail {
    let current = db.tasks.first { $0.id == task.id } ?? task
    return TaskDetail(task: render(current),
                      followers: (db.followers[task.id] ?? []).compactMap(summary).sorted { $0.name < $1.name },
                      subtasks: db.tasks.filter { $0.parentId == task.id }.sorted { $0.position < $1.position }.map(render),
                      parent: current.parentId.flatMap { id in db.tasks.first { $0.id == id } }.map { TaskParentRef(id: $0.id, title: $0.title) })
  }

  private func summary(_ id: String) -> UserSummary? {
    db.users.first { $0.summary.id == id }?.summary
  }

  private func teamName(_ id: String) -> String {
    db.teams.first { $0.id == id }?.name ?? "Team"
  }

  private func mutateProject(_ id: String, _ change: (inout FakeSeed.ProjectRecord) -> Void) {
    guard let i = db.projects.firstIndex(where: { $0.project.id == id }) else { return }
    change(&db.projects[i])
  }

  private func findComment(_ id: String) throws -> (String, Comment) {
    for (taskID, stories) in db.stories {
      for story in stories {
        if case .comment(let comment) = story, comment.id == id {
          _ = try visibleTask(taskID)
          return (taskID, comment)
        }
      }
    }
    throw notFound("Comment")
  }

  private func replaceComment(_ taskID: String, _ commentID: String, _ replace: (Story) -> Story?) {
    db.stories[taskID] = (db.stories[taskID] ?? []).compactMap { story in
      if case .comment(let c) = story, c.id == commentID { return replace(story) }
      return story
    }
  }

  private func appendActivity(_ taskID: String, actor: String, _ type: ActivityType, data: JSONValue = .null) {
    guard let actor = summary(actor) else { return }
    db.stories[taskID, default: []].append(.activity(Activity(id: newID(), actor: actor, type: type, data: data, createdAt: Date())))
  }

  /// Nobody is notified about their own actions (BE §3).
  private func notify(_ userIDs: [String], _ type: NotificationType, actor: String, task: TaskItem) {
    guard let actorSummary = summary(actor) else { return }
    for userID in Set(userIDs) where userID != actor {
      db.notifications.append(FakeSeed.NotificationRecord(userId: userID, notification: InboxNotification(
        id: newID(), workspaceId: task.workspaceId, type: type, read: false, createdAt: Date(), actor: actorSummary,
        task: NotificationTaskRef(id: task.id, title: task.title, projectId: task.projectId))))
    }
  }

  private func newID() -> String { UUID().uuidString.lowercased() }

  private func notFound(_ what: String) -> APIError {
    APIError(code: .notFound, status: 404, message: "\(what) not found")
  }

  private func validation(_ field: String, _ message: String) -> APIError {
    APIError(code: .validation, status: 400, message: message, issues: [FieldIssue(path: [field], message: message)])
  }

  private func nonEmpty(_ value: String, _ field: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw validation(field, "Required") }
    return trimmed
  }
}
