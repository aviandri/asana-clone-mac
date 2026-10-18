import AppKit
import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// Workspace menu, My Tasks, Inbox (unread badge), and the workspace's projects (SPEC-MAC §5).
@MainActor
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
                    .accessibilityIdentifier("sidebar.project.\(project.id)")
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

/// The workspace switcher at the top of the sidebar: colour tile + name (SPEC-MAC §5). ⌘1…⌘9 live in
/// the Workspace menu (AppCommands).
@MainActor
struct WorkspaceMenu: View {
    let session: AppSession
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 6) {
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
                // A macOS menu button keeps only one image and one text of its label (a custom HStack
                // came out as the tile's initial alone), so the tile goes in as a rendered image.
                if let current = session.current {
                    Label {
                        Text(current.isGuest ? "\(current.name) · Guest" : current.name)
                    } icon: {
                        tileImage(current)
                    }
                    .labelStyle(.titleAndIcon)
                } else {
                    Text("Workspace")
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Workspace menu")
            .accessibilityValue(session.isSwitching ? "Switching…" : (session.current?.name ?? ""))
            .accessibilityIdentifier("sidebar.workspaceMenu")
            .help("Switch workspace (⌘1…⌘9)")

            if session.isSwitching {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Switching workspace")
            }
        }
    }

    private func tileImage(_ workspace: Workspace) -> Image {
        let renderer = ImageRenderer(content: WorkspaceTile(name: workspace.name, color: workspace.color, size: 18))
        renderer.scale = displayScale
        guard let image = renderer.nsImage else { return Image(systemName: "square.fill") }
        return Image(nsImage: image)
    }
}
