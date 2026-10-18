import AppKit
import MekariProjectFeatures
import MekariProjectKit
import Observation
import SwiftUI

/// Where the main window is and should go: sidebar item, selected task, the ⌘K palette. The sidebar,
/// deep links, notification clicks, the menu bar and search all navigate through it.
@MainActor @Observable
final class AppRouter {
    private(set) var item: SidebarItem? = .myTasks
    var selectedTask: String?
    var showSearch = false
    /// "You don't have access" and friends, shown as an alert by the main window.
    var alert: String?
    /// A link that arrived before the session was signed in (cold launch from a link or a banner);
    /// SessionWiring replays it once signed in.
    private(set) var pendingLink: DeepLink?

    /// Opens the main window (captured from a live view's `openWindow`; see `RootView` / the menu bar).
    @ObservationIgnored var openMainWindow: () -> Void = {}
    /// The workspace scope the current navigation belongs to. A deep link into another workspace
    /// switches first and then navigates, so the scope change it caused must not reset it.
    @ObservationIgnored private var navigationScopeID: String?

    /// A sidebar click: new section, no task.
    func select(_ item: SidebarItem?) {
        guard item != self.item else { return }
        self.item = item
        selectedTask = nil
    }

    func open(_ target: NavigationTarget) {
        switch target {
        case .task(let id, let projectID):
            item = projectID.map(SidebarItem.project) ?? .myTasks
            selectedTask = id
        case .project(let id):
            item = .project(id)
            selectedTask = nil
        }
        showSearch = false
    }

    func handle(_ result: DeepLinkResult) {
        switch result {
        case .open(let target): open(target)
        case .noAccess: alert = "You don't have access to this, or it no longer exists."
        }
    }

    /// A new workspace starts on My Tasks.
    func reset() {
        item = .myTasks
        selectedTask = nil
        showSearch = false
    }

    /// Call when the session's scope changes: a switch the user made (or lost access) starts over on
    /// My Tasks; a switch made by `follow` keeps the target it navigated to.
    func scopeChanged(to scopeID: String?) {
        if scopeID != navigationScopeID { reset() }
        navigationScopeID = scopeID
    }

    /// Opens a `mekariproject://` link (or a notification's task) in the main window. Before sign-in
    /// has finished (restoring, or signed out) the link waits and is replayed afterwards.
    func follow(_ link: DeepLink, in session: AppSession) async {
        openMainWindow()
        NSApp.activate()
        guard Self.isWellFormed(link) else {
            alert = "That link isn't a Mekari Project task or project link."
            return
        }
        guard case .signedIn = session.state else {
            pendingLink = link
            return
        }
        let result = await session.resolve(link)
        navigationScopeID = session.scope?.id
        handle(result)
    }

    /// Called by SessionWiring once signed in.
    func replayPendingLink(in session: AppSession) async {
        guard let link = pendingLink else { return }
        pendingLink = nil
        await follow(link, in: session)
    }

    /// Deep-link ids are BE UUIDs; anything else (e.g. `task/..%2Fusers`) never reaches a request path.
    static func isWellFormed(_ link: DeepLink) -> Bool {
        switch link {
        case .task(let id), .project(let id): UUID(uuidString: id) != nil
        }
    }
}

/// The current project, for ⇧⌘O.
struct CurrentProjectKey: FocusedValueKey { typealias Value = String }

extension FocusedValues {
    var currentProjectID: String? {
        get { self[CurrentProjectKey.self] }
        set { self[CurrentProjectKey.self] = newValue }
    }
}

/// "Open in Browser" (⇧⌘O, SPEC-MAC §5): the selected task, else the current project, else My Tasks.
/// Every link carries `?workspace=<current>` so the web lands in the same workspace.
enum BrowserLinks {
    @MainActor
    static func url(session: AppSession, taskID: String?, projectID: String?) -> URL? {
        guard let server = session.settings.serverURL, let scope = session.scope else { return nil }
        if let taskID {
            if let task = scope.tasks[taskID] {
                return WebLinks.task(task, server: server, workspace: scope.id)
            }
            // Not cached (e.g. a task window opened from a link): the id alone is enough for the web.
            let base = projectID.map { WebLinks.project($0, server: server, workspace: scope.id) }
                ?? WebLinks.url(server, path: "/my-tasks", workspace: scope.id)
            return adding(task: taskID, to: base)
        }
        if let projectID {
            return WebLinks.project(projectID, server: server, workspace: scope.id)
        }
        return session.webURL(path: "/my-tasks")
    }

    private static func adding(task id: String, to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = [URLQueryItem(name: "task", value: id)] + (components.queryItems ?? [])
        return components.url ?? url
    }
}
