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

    /// Opens a `mekariproject://` link (or a notification's task) in the main window.
    func follow(_ link: DeepLink, in session: AppSession) async {
        openMainWindow()
        NSApp.activate()
        let result = await session.resolve(link)
        navigationScopeID = session.scope?.id
        handle(result)
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
        if let taskID, let task = scope.tasks[taskID] {
            return WebLinks.task(task, server: server, workspace: scope.id)
        }
        if let projectID {
            return WebLinks.project(projectID, server: server, workspace: scope.id)
        }
        return session.webURL(path: "/my-tasks")
    }
}
