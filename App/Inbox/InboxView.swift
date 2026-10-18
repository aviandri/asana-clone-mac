import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// Notifications, newest first; unread in bold. A click marks it read and opens the task (SPEC-MAC §5).
@MainActor
struct InboxView: View {
    let session: AppSession
    let inbox: InboxStore
    let router: AppRouter

    var body: some View {
        List {
            ForEach(inbox.notifications) { notification in
                Button {
                    Task {
                        if let target = await inbox.open(notification.id) { router.open(target) }
                    }
                } label: {
                    InboxRow(notification: notification)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inbox.row.\(notification.id)")
            }
        }
        .listStyle(.inset)
        .overlay {
            if inbox.notifications.isEmpty {
                switch inbox.phase {
                case .idle, .loading:
                    ProgressView()
                case .failed(let error):
                    ContentUnavailableView("Couldn't Load Inbox", systemImage: "exclamationmark.triangle", description: Text(error.message))
                case .loaded:
                    ContentUnavailableView("You're All Caught Up", systemImage: "tray", description: Text("Assignments, comments and mentions show up here."))
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ErrorBanner(error: inbox.lastError) { inbox.clearError() }
                .padding(.horizontal)
                .padding(.top, inbox.lastError == nil ? 0 : 8)
        }
        .navigationTitle("Inbox")
        .navigationSubtitle(inbox.unreadCount > 0 ? "\(inbox.unreadCount) unread" : "")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await inbox.markAllRead() }
                } label: {
                    Label("Mark All as Read", systemImage: "envelope.open")
                }
                .disabled(inbox.unreadCount == 0)
                .help("Mark all as read")
            }
        }
        .task(id: session.generation) { await inbox.load() }
    }
}

@MainActor
private struct InboxRow: View {
    let notification: InboxNotification

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(notification.read ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)
            Avatar(user: notification.actor, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.summary)
                    .fontWeight(notification.read ? .regular : .semibold)
                    .lineLimit(2)
                Text(Formatting.relative(notification.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(notification.read ? "" : "Unread: ")\(notification.summary)")
    }

    private var icon: String {
        switch notification.type {
        case .assigned: "person.crop.circle.badge.checkmark"
        case .commented: "bubble.left"
        case .completed: "checkmark.circle"
        case .mentioned: "at"
        default: "bell"
        }
    }
}
