import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

enum SidebarItem: Hashable {
    case myTasks, inbox, project(String)
}

/// Sidebar | content | inspector (SPEC-MAC §5). One instance per workspace scope.
struct MainView: View {
    let session: AppSession
    let scope: WorkspaceScope

    @State private var item: SidebarItem? = .myTasks
    @State private var selectedTask: String?
    @State private var showInspector = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            SidebarView(session: session, scope: scope, selection: $item)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            content
                .inspector(isPresented: $showInspector) {
                    inspector
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 560)
                }
        }
        .focusedSceneValue(\.selectedTaskID, selectedTask)
        .toolbar {
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
        .onChange(of: selectedTask) { _, new in
            if new != nil { showInspector = true }
        }
        .onChange(of: item) { _, _ in selectedTask = nil }
        .onChange(of: scenePhase) { _, phase in
            scope.poller.setMode(phase == .active ? .active : .background)
            if phase == .active { Task { await scope.refresh() } }
        }
        .task { await scope.sidebar.load() }
    }

    @ViewBuilder private var content: some View {
        switch item ?? .myTasks {
        case .myTasks:
            MyTasksView(scope: scope, store: scope.myTasks, selection: $selectedTask)
        case .inbox:
            ComingSoonView(title: "Inbox", systemImage: "tray", webURL: session.webURL(path: "/inbox"))
        case .project(let id):
            let name = scope.sidebar.projects.first { $0.id == id }?.name ?? "Project"
            ComingSoonView(title: name, systemImage: "list.bullet.rectangle", webURL: session.webURL(path: "/projects/\(id)"))
        }
    }

    @ViewBuilder private var inspector: some View {
        if let id = selectedTask {
            TaskInspectorView(scope: scope, store: scope.taskDetail(id), onOpenTask: { selectedTask = $0 })
                .id(id)
        } else {
            ContentUnavailableView("No Task Selected", systemImage: "sidebar.trailing", description: Text("Select a task to see its details."))
        }
    }
}

/// Interim content for screens that arrive with the next app PR (SPEC-MAC §7, PR 5).
struct ComingSoonView: View {
    let title: String
    let systemImage: String
    let webURL: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text("This view is coming to the Mac app soon. Meanwhile, open it in the browser.")
        } actions: {
            if let webURL {
                Button("Open in Browser") { openURL(webURL) }
            }
        }
        .navigationTitle(title)
    }
}
