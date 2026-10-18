import AppKit
import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// The menu bar icon: unread count when there is something new.
@MainActor
struct MenuBarLabel: View {
    let session: AppSession
    let router: AppRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let unread = session.scope?.inbox.unreadCount ?? 0
        HStack(spacing: 2) {
            Image(systemName: unread > 0 ? "checklist.unchecked" : "checklist")
            if unread > 0 { Text("\(unread)") }
        }
        .accessibilityLabel(unread > 0 ? "Mekari Project, \(unread) unread" : "Mekari Project")
        // The menu bar stays alive with the main window closed, so it provides the "open main window" action.
        .onAppear { router.openMainWindow = { openWindow(id: WindowID.main) } }
    }
}

/// MenuBarExtra (window style, SPEC-MAC §5): overdue + due today with inline complete, quick add,
/// and "Open Mekari Project".
@MainActor
struct MenuBarContent: View {
    let session: AppSession
    let router: AppRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let scope = session.scope {
                header(scope)
                QuickAddView(model: scope.quickAdd)
                Divider()
                DueSoonList(scope: scope) { id in
                    showMain()
                    router.open(.task(id: id, projectID: scope.tasks[id]?.projectId))
                }
            } else if session.me != nil {
                Text("No workspace yet").foregroundStyle(.secondary)
            } else {
                Text("Not signed in").foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Open Mekari Project") { showMain() }
                    .keyboardShortcut("o")
                Spacer()
                if let unread = session.scope?.inbox.unreadCount, unread > 0 {
                    Button("\(unread) unread") {
                        showMain()
                        router.select(.inbox)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder private func header(_ scope: WorkspaceScope) -> some View {
        HStack(spacing: 8) {
            WorkspaceTile(name: scope.workspace.name, color: scope.workspace.color, size: 18)
            Text(scope.workspace.name).font(.headline)
            if scope.workspace.isGuest { GuestPill() }
            Spacer()
        }
    }

    private func showMain() {
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}

/// Title + optional due date; creates a personal task assigned to me.
@MainActor
private struct QuickAddView: View {
    @Bindable var model: QuickAddModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Quick add a task", text: $model.title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                    .accessibilityIdentifier("menubar.quickAdd")
                Menu {
                    Button("No date") { model.dueDate = nil }
                    Button("Today") { model.dueDate = .today() }
                    Button("Tomorrow") { model.dueDate = LocalDate.today().adding(days: 1) }
                    Button("Next week") { model.dueDate = LocalDate.today().adding(days: 7) }
                } label: {
                    Image(systemName: model.dueDate == nil ? "calendar" : "calendar.badge.checkmark")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(model.dueDate.map { "Due \(Formatting.due($0, today: .today()))" } ?? "Set a due date")
                .accessibilityLabel(model.dueDate.map { "Due date: \(Formatting.due($0, today: .today()))" } ?? "Due date: none")
            }
            if let due = model.dueDate {
                Text("Due \(Formatting.due(due, today: .today()))").font(.caption).foregroundStyle(.secondary)
            }
            ErrorBanner(error: model.lastError) { model.clearError() }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard model.canSubmit else { return }
        Task { await model.submit() }
    }
}

/// Overdue and due-today tasks (MyTasksStore.dueSoon), completable inline.
@MainActor
private struct DueSoonList: View {
    let scope: WorkspaceScope
    let onOpen: (String) -> Void

    var body: some View {
        let ids = scope.myTasks.dueSoon
        VStack(alignment: .leading, spacing: 4) {
            Text("Due today and overdue").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if ids.isEmpty {
                Text(scope.myTasks.phase == .loading ? "Loading…" : "Nothing due today.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(ids.prefix(12), id: \.self) { id in
                if let task = scope.tasks[id] {
                    TaskRow(task: task, canEdit: scope.canEdit(task: task)) {
                        Task { await scope.myTasks.toggleComplete(id) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onOpen(id) }
                    .contextMenu { Button("Open in Mekari Project") { onOpen(id) } }
                }
            }
        }
        .task(id: scope.id) { await scope.myTasks.refresh() }
    }
}
