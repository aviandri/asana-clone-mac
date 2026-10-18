import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

enum SidebarItem: Hashable {
    case myTasks, inbox, project(String)
}

/// Sidebar | content | inspector (SPEC-MAC §5). One instance per workspace scope; navigation state
/// lives in the AppRouter so deep links, notifications and the menu bar can drive it.
struct MainView: View {
    let session: AppSession
    let scope: WorkspaceScope
    @Bindable var router: AppRouter

    @State private var showInspector = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            SidebarView(session: session, scope: scope, selection: Binding(get: { router.item }, set: { router.select($0) }))
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            content
                // No edits against a workspace that's about to be replaced.
                .disabled(session.isSwitching)
                .navigationSubtitle(session.isSwitching ? "Switching workspace…" : "")
                .inspector(isPresented: $showInspector) {
                    inspector
                        .disabled(session.isSwitching)
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 560)
                }
        }
        .focusedSceneValue(\.selectedTaskID, router.selectedTask)
        .focusedSceneValue(\.currentProjectID, currentProjectID)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.showSearch = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help("Search tasks, projects and people (⌘K)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label(showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide the task inspector")
            }
        }
        .sheet(isPresented: $router.showSearch) {
            SearchPalette(search: scope.search) { target in
                router.open(target)
            }
        }
        .onChange(of: router.selectedTask, initial: true) { _, new in
            if new != nil { showInspector = true }
        }
        .onChange(of: scenePhase) { _, phase in
            scope.poller.setMode(phase == .active ? .active : .background)
            if phase == .active { Task { await scope.refresh() } }
        }
        .task(id: session.generation) { await scope.sidebar.load() }
    }

    private var currentProjectID: String? {
        if case .project(let id) = router.item { return id }
        return nil
    }

    @ViewBuilder private var content: some View {
        switch router.item ?? .myTasks {
        case .myTasks:
            MyTasksView(scope: scope, store: scope.myTasks, selection: $router.selectedTask)
        case .inbox:
            InboxView(session: session, inbox: scope.inbox, router: router)
        case .project(let id):
            ProjectView(session: session, scope: scope, store: scope.project(id), selection: $router.selectedTask)
                .id(id)
        }
    }

    @ViewBuilder private var inspector: some View {
        if let id = router.selectedTask {
            TaskInspectorView(session: session, scope: scope, store: scope.taskDetail(id), onOpenTask: { router.selectedTask = $0 })
                .id(id)
        } else {
            ContentUnavailableView("No Task Selected", systemImage: "sidebar.trailing", description: Text("Select a task to see its details."))
        }
    }
}
