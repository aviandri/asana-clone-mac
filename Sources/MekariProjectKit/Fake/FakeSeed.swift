import Foundation

/// Stable ids in `FakeSeed.demo`, for previews and the XCUITest smoke.
public enum DemoIDs {
  public static let mekari = "10000000-0000-4000-8000-000000000001"
  public static let acmePilot = "10000000-0000-4000-8000-000000000002"

  public static let admin = "20000000-0000-4000-8000-000000000001"
  public static let alice = "20000000-0000-4000-8000-000000000002"
  public static let bob = "20000000-0000-4000-8000-000000000003"
  public static let guest = "20000000-0000-4000-8000-000000000004"

  public static let engineering = "30000000-0000-4000-8000-000000000001"
  public static let marketing = "30000000-0000-4000-8000-000000000002"
  public static let pilotTeam = "30000000-0000-4000-8000-000000000003"

  /// "Mobile App v2" (Mekari): 3 sections with tasks in each; alice is EDITOR.
  public static let boardProject = "40000000-0000-4000-8000-000000000001"
  /// "Website Redesign" (Mekari): alice is COMMENTER, so it's read-only for her.
  public static let readOnlyProject = "40000000-0000-4000-8000-000000000002"
  /// "Q4 Campaign" (Mekari, TEAM privacy, Marketing).
  public static let campaignProject = "40000000-0000-4000-8000-000000000003"
  /// "Pilot Rollout" (Acme Pilot); the guest is an EDITOR there.
  public static let pilotProject = "40000000-0000-4000-8000-000000000004"

  /// "Fix login redirect" in Mobile App v2: a comment that mentions bob, 2 subtasks, followers.
  public static let taskWithStories = "50000000-0000-4000-8000-000000000001"

  /// The task with the seeded attachments (BE §13 seed): a PNG, a PDF, a text file and a LINK, plus an
  /// image on bob's comment. Same task as `taskWithStories`.
  public static let taskWithAttachments = taskWithStories
  public static let attachmentPNG = "a0000000-0000-4000-8000-000000000001"
  public static let attachmentPDF = "a0000000-0000-4000-8000-000000000002"
  public static let attachmentText = "a0000000-0000-4000-8000-000000000003"
  public static let attachmentLink = "a0000000-0000-4000-8000-000000000004"
  public static let attachmentCommentImage = "a0000000-0000-4000-8000-000000000005"

  public static let guestEmail = "guest@partner.test"
  public static let password = "password123"
}

/// The data a `FakeMekariAPI` starts with.
public struct FakeSeed: Sendable {
  public struct UserRecord: Sendable, Hashable {
    public var summary: UserSummary
    public var password: String
    public var isActive: Bool
    public var createdAt: Date
  }

  public struct Membership: Sendable, Hashable {
    public var workspaceId: String
    public var userId: String
    public var role: WorkspaceRole
    public var isActive: Bool
  }

  public struct TeamRecord: Sendable, Hashable {
    public var id: String
    public var workspaceId: String
    public var name: String
    public var memberIds: [String]
  }

  public struct ProjectRecord: Sendable, Hashable {
    /// `myRole` is filled per viewer by the fake.
    public var project: Project
    public var sections: [Section]
    public var members: [ProjectMember]
  }

  public struct NotificationRecord: Sendable, Hashable {
    public var userId: String
    public var notification: InboxNotification
  }

  public var users: [UserRecord]
  /// `myRole` and `memberCount` are filled per viewer by the fake.
  public var workspaces: [Workspace]
  public var memberships: [Membership]
  public var teams: [TeamRecord]
  public var projects: [ProjectRecord]
  /// Counts (subtasks, comments) and `project` refs are recomputed by the fake.
  public var tasks: [TaskItem]
  public var followers: [String: [String]]
  public var stories: [String: [Story]]
  public var notifications: [NotificationRecord]
  /// Every attachment, drafts and comment ones included. Comments get theirs when the fake renders them.
  public var attachments: [Attachment] = []

  public static let empty = FakeSeed(users: [], workspaces: [], memberships: [], teams: [], projects: [], tasks: [],
                                     followers: [:], stories: [:], notifications: [])

  /// The demo data, with due dates relative to today in the current calendar.
  public static var demo: FakeSeed { demo(today: LocalDate.today()) }

  /// The demo data with due dates relative to `today` (tests pin this).
  public static func demo(today: LocalDate) -> FakeSeed {
    var builder = DemoBuilder(today: today)
    return builder.build()
  }
}

/// Builds `FakeSeed.demo`: the BE seed (SPEC §7, §12) in miniature.
private struct DemoBuilder {
  let today: LocalDate
  let epoch = Date(timeIntervalSince1970: 1_790_000_000) // fixed timestamps keep previews stable

  var counter = 0

  init(today: LocalDate) {
    self.today = today
  }

  func at(_ minutes: Int) -> Date { epoch.addingTimeInterval(Double(minutes) * 60) }

  mutating func nextID(_ prefix: String) -> String {
    counter += 1
    let digits = String(counter)
    return prefix + "-0000-4000-8000-" + String(repeating: "0", count: max(0, 12 - digits.count)) + digits
  }

  mutating func build() -> FakeSeed {
    let admin = UserSummary(id: DemoIDs.admin, name: "Ada Admin", email: "admin@example.com", avatarColor: "#7a6ff0")
    let alice = UserSummary(id: DemoIDs.alice, name: "Alice Johnson", email: "alice@example.com", avatarColor: "#e8384f")
    let bob = UserSummary(id: DemoIDs.bob, name: "Bob Smith", email: "bob@example.com", avatarColor: "#20aaea")
    let guest = UserSummary(id: DemoIDs.guest, name: "Gita Guest", email: DemoIDs.guestEmail, avatarColor: "#aa62e3")
    let users = [admin, alice, bob, guest].map {
      FakeSeed.UserRecord(summary: $0, password: DemoIDs.password, isActive: true, createdAt: at(0))
    }

    let workspaces = [
      Workspace(id: DemoIDs.mekari, name: "Mekari", isOrganization: true, domain: "example.com", color: "#4186e0",
                myRole: .member, memberCount: 0, createdAt: at(0)),
      Workspace(id: DemoIDs.acmePilot, name: "Acme Pilot", isOrganization: false, domain: nil, color: "#f06a6a",
                myRole: .member, memberCount: 0, createdAt: at(10)),
    ]
    let memberships = [
      FakeSeed.Membership(workspaceId: DemoIDs.mekari, userId: DemoIDs.admin, role: .admin, isActive: true),
      FakeSeed.Membership(workspaceId: DemoIDs.mekari, userId: DemoIDs.alice, role: .member, isActive: true),
      FakeSeed.Membership(workspaceId: DemoIDs.mekari, userId: DemoIDs.bob, role: .member, isActive: true),
      FakeSeed.Membership(workspaceId: DemoIDs.acmePilot, userId: DemoIDs.alice, role: .admin, isActive: true),
      FakeSeed.Membership(workspaceId: DemoIDs.acmePilot, userId: DemoIDs.bob, role: .member, isActive: true),
      FakeSeed.Membership(workspaceId: DemoIDs.acmePilot, userId: DemoIDs.guest, role: .guest, isActive: true),
    ]
    let teams = [
      FakeSeed.TeamRecord(id: DemoIDs.engineering, workspaceId: DemoIDs.mekari, name: "Engineering",
                          memberIds: [DemoIDs.admin, DemoIDs.alice, DemoIDs.bob]),
      FakeSeed.TeamRecord(id: DemoIDs.marketing, workspaceId: DemoIDs.mekari, name: "Marketing", memberIds: [DemoIDs.bob]),
      FakeSeed.TeamRecord(id: DemoIDs.pilotTeam, workspaceId: DemoIDs.acmePilot, name: "Pilot Team",
                          memberIds: [DemoIDs.alice, DemoIDs.bob]),
    ]

    func project(_ id: String, _ ws: String, team: String, _ name: String, color: String, privacy: ProjectPrivacy,
                 view: ProjectView, owner: UserSummary) -> Project {
      Project(id: id, workspaceId: ws, teamId: team, name: name, description: nil, color: color, privacy: privacy,
              archived: false, defaultView: view, owner: owner, myRole: nil, createdAt: at(20), updatedAt: at(20))
    }
    func sections(_ projectID: String, _ names: [String]) -> [Section] {
      names.enumerated().map { i, name in
        Section(id: nextID("60000000"), projectId: projectID, name: name, position: Double(i + 1) * Reorder.step)
      }
    }

    let mobileSections = sections(DemoIDs.boardProject, ["To do", "In progress", "Done"])
    let webSections = sections(DemoIDs.readOnlyProject, ["Backlog", "Design", "Build"])
    let campaignSections = sections(DemoIDs.campaignProject, ["Ideas", "Scheduled"])
    let pilotSections = sections(DemoIDs.pilotProject, ["To do", "In progress", "Done"])

    let projects = [
      FakeSeed.ProjectRecord(
        project: project(DemoIDs.boardProject, DemoIDs.mekari, team: DemoIDs.engineering, "Mobile App v2", color: "#e0257f",
                         privacy: .public, view: .board, owner: admin),
        sections: mobileSections,
        members: [ProjectMember(user: admin, role: .owner), ProjectMember(user: alice, role: .editor), ProjectMember(user: bob, role: .editor)]),
      FakeSeed.ProjectRecord(
        project: project(DemoIDs.readOnlyProject, DemoIDs.mekari, team: DemoIDs.engineering, "Website Redesign", color: "#4186e0",
                         privacy: .private, view: .list, owner: bob),
        sections: webSections,
        members: [ProjectMember(user: bob, role: .owner), ProjectMember(user: alice, role: .commenter)]),
      FakeSeed.ProjectRecord(
        project: project(DemoIDs.campaignProject, DemoIDs.mekari, team: DemoIDs.marketing, "Q4 Campaign", color: "#f1bd6c",
                         privacy: .team, view: .list, owner: bob),
        sections: campaignSections,
        members: [ProjectMember(user: bob, role: .owner)]),
      FakeSeed.ProjectRecord(
        project: project(DemoIDs.pilotProject, DemoIDs.acmePilot, team: DemoIDs.pilotTeam, "Pilot Rollout", color: "#f06a6a",
                         privacy: .team, view: .board, owner: alice),
        sections: pilotSections,
        members: [ProjectMember(user: alice, role: .owner), ProjectMember(user: guest, role: .editor)]),
    ]

    var tasks: [TaskItem] = []
    var followers: [String: [String]] = [:]
    func add(_ ws: String, _ title: String, project: String? = nil, section: Section? = nil, parent: String? = nil,
                      assignee: UserSummary? = nil, creator: UserSummary, due: Int? = nil, priority: Priority = .none,
                      done: Bool = false, id: String? = nil, description: String? = nil) -> String {
      let taskID = id ?? nextID("50000000")
      let position = Double(tasks.filter { $0.sectionId == section?.id && $0.parentId == parent && $0.projectId == project }.count + 1) * Reorder.step
      tasks.append(TaskItem(id: taskID, workspaceId: ws, projectId: project, sectionId: section?.id, parentId: parent, title: title,
                            description: description, assignee: assignee, creator: creator, dueDate: due.map { today.adding(days: $0) },
                            priority: priority, completed: done, completedAt: done ? at(30) : nil, position: position,
                            createdAt: at(25 + tasks.count), updatedAt: at(25 + tasks.count)))
      followers[taskID] = Array(Set([creator.id] + (assignee.map { [$0.id] } ?? []))).sorted()
      return taskID
    }

    let mk = DemoIDs.mekari
    let m = DemoIDs.boardProject
    // Mobile App v2: every My Tasks bucket for alice.
    let login = add(mk, "Fix login redirect", project: m, section: mobileSections[1], assignee: alice, creator: admin, due: -2,
                    priority: .high, id: DemoIDs.taskWithStories,
                    description: "After signing in, users land on **/** instead of the page they came from.")
    _ = add(mk, "Reproduce on Safari", project: m, parent: login, assignee: alice, creator: alice, due: -3, done: true)
    _ = add(mk, "Keep the return URL through SSO", project: m, parent: login, assignee: bob, creator: alice, due: 1)
    _ = add(mk, "Push notification settings", project: m, section: mobileSections[0], assignee: alice, creator: admin, due: 0, priority: .medium)
    _ = add(mk, "Offline mode for task list", project: m, section: mobileSections[0], assignee: alice, creator: bob, due: 3)
    _ = add(mk, "Dark mode QA pass", project: m, section: mobileSections[0], assignee: bob, creator: admin, due: 5, priority: .low)
    _ = add(mk, "App Store screenshots", project: m, section: mobileSections[1], assignee: alice, creator: admin, due: 12)
    _ = add(mk, "Crash on empty inbox", project: m, section: mobileSections[1], assignee: bob, creator: alice, due: -1, priority: .high)
    _ = add(mk, "Upgrade analytics SDK", project: m, section: mobileSections[2], assignee: alice, creator: bob, due: -5, done: true)
    _ = add(mk, "Release 2.0 beta", project: m, section: mobileSections[2], assignee: admin, creator: admin, due: -10, done: true)
    _ = add(mk, "Tablet layout", project: m, section: mobileSections[0], creator: admin)

    let w = DemoIDs.readOnlyProject
    _ = add(mk, "New pricing page", project: w, section: webSections[0], assignee: bob, creator: bob, due: 9)
    _ = add(mk, "Homepage hero copy", project: w, section: webSections[1], assignee: alice, creator: bob, due: 2, priority: .medium)
    _ = add(mk, "Accessibility audit", project: w, section: webSections[2], assignee: bob, creator: bob, due: 20)
    _ = add(mk, "Footer links", project: w, section: webSections[2], creator: bob)

    let c = DemoIDs.campaignProject
    _ = add(mk, "Webinar landing page", project: c, section: campaignSections[0], assignee: bob, creator: bob, due: 6)
    _ = add(mk, "Newsletter draft", project: c, section: campaignSections[1], assignee: bob, creator: bob, due: 1)

    // Personal tasks.
    _ = add(mk, "Prepare 1:1 notes", assignee: alice, creator: alice, due: 0)
    _ = add(mk, "Expense report", assignee: alice, creator: alice)
    _ = add(mk, "Book team offsite venue", assignee: alice, creator: admin, due: 30, priority: .low)
    _ = add(mk, "Renew laptop warranty", assignee: bob, creator: bob, due: 14)

    // Acme Pilot.
    let ap = DemoIDs.acmePilot
    let p = DemoIDs.pilotProject
    _ = add(ap, "Kick-off call with Acme", project: p, section: pilotSections[2], assignee: alice, creator: alice, due: -6,
            priority: .high, done: true)
    _ = add(ap, "Provision pilot accounts", project: p, section: pilotSections[1], assignee: bob, creator: alice, due: -1, priority: .high)
    _ = add(ap, "Import Acme's existing projects", project: p, section: pilotSections[0], assignee: bob, creator: alice, due: 4,
            priority: .medium)
    _ = add(ap, "Train Acme team leads", project: p, section: pilotSections[0], assignee: alice, creator: alice, due: 8)
    _ = add(ap, "Collect pilot feedback", project: p, section: pilotSections[0], assignee: guest, creator: alice, due: 15)
    _ = add(ap, "Share SSO metadata", project: p, section: pilotSections[1], assignee: guest, creator: alice, due: 2)
    _ = add(ap, "Pilot success criteria", project: p, section: pilotSections[0], creator: alice)
    _ = add(ap, "Weekly pilot status email", assignee: alice, creator: alice, due: 1)

    followers[login] = [DemoIDs.admin, DemoIDs.alice, DemoIDs.bob]

    let createdID = nextID("70000000")
    let assignedID = nextID("70000000")
    let mentionCommentID = nextID("80000000")
    let bobCommentID = nextID("80000000")
    let stories: [String: [Story]] = [
      login: [
        .activity(Activity(id: createdID, actor: admin, type: .created, createdAt: at(40))),
        .activity(Activity(id: assignedID, actor: admin, type: .assigned,
                           data: .object(["assigneeId": .string(alice.id)]), createdAt: at(41))),
        .comment(Comment(id: mentionCommentID, author: admin,
                         body: "Seen on staging too. \(Mentions.token(for: bob)) can you check the SSO callback?", createdAt: at(42))),
        .comment(Comment(id: bobCommentID, author: bob, body: "On it, the `returnTo` param is dropped.", createdAt: at(50))),
      ],
    ]

    func file(_ id: String, _ name: String, _ mime: String, size: Int64, by uploader: UserSummary, minute: Int,
              comment: String? = nil, image: (Int, Int)? = nil) -> Attachment {
      let base = "/api/v1/attachments/\(id)"
      return Attachment(id: id, workspaceId: mk, taskId: login, commentId: comment, kind: .file, uploader: uploader,
                        createdAt: at(minute), name: name, mimeType: mime, size: size, width: image?.0, height: image?.1,
                        hasThumbnail: image != nil, contentPath: base + "/content", thumbnailPath: image != nil ? base + "/thumbnail" : nil)
    }
    let attachments = [
      file(DemoIDs.attachmentPNG, "login-redirect.png", "image/png", size: 48_213, by: admin, minute: 43, image: (1280, 800)),
      file(DemoIDs.attachmentPDF, "SSO flow.pdf", "application/pdf", size: 182_004, by: alice, minute: 44),
      file(DemoIDs.attachmentText, "console.log", "text/plain", size: 2_310, by: bob, minute: 45),
      Attachment(id: DemoIDs.attachmentLink, workspaceId: mk, taskId: login, kind: .link, uploader: alice, createdAt: at(46),
                 url: "https://www.figma.com/file/demo/Login-flow", title: "Login flow", description: "Sign-in and SSO screens",
                 siteName: "Figma", provider: "figma", previewStatus: .ready),
      file(DemoIDs.attachmentCommentImage, "returnTo.png", "image/png", size: 30_512, by: bob, minute: 50, comment: bobCommentID,
           image: (900, 600)),
    ]

    func notification(_ id: String, _ ws: String, _ type: NotificationType, read: Bool, actor: UserSummary, task taskID: String,
                      minute: Int) -> InboxNotification {
      let task = tasks.first { $0.id == taskID }!
      return InboxNotification(id: id, workspaceId: ws, type: type, read: read, createdAt: at(minute), actor: actor,
                               task: NotificationTaskRef(id: task.id, title: task.title, projectId: task.projectId))
    }
    let pilotTask = tasks.first { $0.title == "Provision pilot accounts" }!.id
    let notifications = [
      FakeSeed.NotificationRecord(userId: DemoIDs.alice, notification: notification(
        nextID("90000000"), mk, .assigned, read: true, actor: admin, task: login, minute: 41)),
      FakeSeed.NotificationRecord(userId: DemoIDs.alice, notification: notification(
        nextID("90000000"), mk, .commented, read: false, actor: bob, task: login, minute: 50)),
      FakeSeed.NotificationRecord(userId: DemoIDs.bob, notification: notification(
        nextID("90000000"), mk, .mentioned, read: false, actor: admin, task: login, minute: 42)),
      FakeSeed.NotificationRecord(userId: DemoIDs.alice, notification: notification(
        nextID("90000000"), ap, .commented, read: false, actor: bob, task: pilotTask, minute: 60)),
    ]

    return FakeSeed(users: users, workspaces: workspaces, memberships: memberships, teams: teams, projects: projects,
                    tasks: tasks, followers: followers, stories: stories, notifications: notifications, attachments: attachments)
  }
}
