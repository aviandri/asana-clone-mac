import AppKit
import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// Workspace menu, My Tasks, Inbox (unread badge), and the workspace's projects (SPEC-MAC §5).
struct SidebarView: View {
    let session: AppSession
    let scope: WorkspaceScope
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("My Tasks", systemImage: "checkmark.circle")
                    .tag(SidebarItem.myTasks)
                    .accessibilityIdentifier("sidebar.myTasks")
                Label("Inbox", systemImage: "tray")
                    .badge(scope.inbox.unreadCount)
                    .tag(SidebarItem.inbox)
                    .accessibilityIdentifier("sidebar.inbox")
            }

            Section("Projects") {
                ForEach(scope.sidebar.projects) { project in
                    Label {
                        Text(project.name)
                    } icon: {
                        Circle()
                            .fill(Color(hex: project.color))
                            .frame(width: 9, height: 9)
                    }
                    .tag(SidebarItem.project(project.id))
                }
                if scope.sidebar.projects.isEmpty, scope.sidebar.phase == .loaded {
                    Text(session.isGuest ? "No projects shared with you yet" : "No projects yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            WorkspaceMenu(session: session)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if session.isGuest, let name = session.current?.name {
                Text("You're a guest in \(name). You see only the projects you've been added to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) {
            ErrorBanner(error: scope.sidebar.lastError) { scope.sidebar.clearError() }
                .padding(8)
        }
    }
}

/// The workspace switcher at the top of the sidebar. ⌘1…⌘9 live in the Workspace menu (AppCommands).
struct WorkspaceMenu: View {
    let session: AppSession

    var body: some View {
        Menu {
            ForEach(session.all) { workspace in
                Toggle(isOn: Binding(
                    get: { workspace.id == session.current?.id },
                    set: { on in if on { Task { await session.switchWorkspace(to: workspace.id) } } }
                )) {
                    Text(workspace.isGuest ? "\(workspace.name) (Guest)" : workspace.name)
                }
            }
            if session.isAdmin {
                Divider()
                Button("Open Workspace Settings in Browser") {
                    if let url = session.webURL(path: "/workspace/settings") { NSWorkspace.shared.open(url) }
                }
            }
            Divider()
            Button("Sign Out") { Task { await session.signOut() } }
        } label: {
            HStack(spacing: 8) {
                if let current = session.current {
                    WorkspaceTile(name: current.name, color: current.color)
                    Text(current.name)
                        .font(.headline)
                        .lineLimit(1)
                    if current.isGuest { GuestPill() }
                }
                Spacer(minLength: 0)
                if session.isSwitching {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Switching workspace")
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Workspace menu")
        .accessibilityValue(session.isSwitching ? "Switching…" : (session.current?.name ?? ""))
        .accessibilityIdentifier("sidebar.workspaceMenu")
        .help("Switch workspace (⌘1…⌘9)")
    }
}
