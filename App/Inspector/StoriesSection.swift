import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// Comments and activity, oldest first (`GET /tasks/:id/stories`).
@MainActor
struct StoriesSection: View {
    let stories: [Story]
    let me: UserSummary
    let canDelete: (Comment) -> Bool
    let onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comments and activity").font(.headline)
            if stories.isEmpty {
                Text("No comments yet.").foregroundStyle(.secondary)
            }
            ForEach(stories) { story in
                switch story {
                case .comment(let comment):
                    CommentRow(comment: comment)
                        .contextMenu {
                            if canDelete(comment) {
                                Button("Delete Comment", role: .destructive) { onDelete(comment.id) }
                            }
                        }
                case .activity(let activity):
                    ActivityRow(activity: activity)
                }
            }
        }
    }
}

@MainActor
struct CommentRow: View {
    let comment: Comment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(user: comment.author, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.author.name).fontWeight(.semibold)
                    Text(Formatting.relative(comment.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if comment.editedAt != nil {
                        Text("(edited)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(CommentText.attributed(comment.segments))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Comment bodies: basic inline markdown for text, mentions as accent-coloured tokens.
enum CommentText {
    static func attributed(_ segments: [Mentions.Segment]) -> AttributedString {
        var out = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let text):
                out += Formatting.markdown(text)
            case .mention(let name, _):
                var token = AttributedString("@\(name)")
                token.foregroundColor = .accentColor
                token.font = .body.weight(.semibold)
                out += token
            }
        }
        return out
    }
}

@MainActor
struct ActivityRow: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 26)
            Text("\(activity.actor.name) \(verb)")
            Text(Formatting.relative(activity.createdAt))
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var verb: String {
        switch activity.type {
        case .created: "created this task"
        case .completed: "completed this task"
        case .reopened: "reopened this task"
        case .assigned: "changed the assignee"
        case .unassigned: "removed the assignee"
        case .dueDateChanged: "changed the due date"
        case .movedSection: "moved this task"
        case .renamed: "renamed this task"
        case .priorityChanged: "changed the priority"
        case .descriptionChanged: "updated the description"
        case .other: "updated this task"
        }
    }

    private var icon: String {
        switch activity.type {
        case .created: "plus.circle"
        case .completed: "checkmark.circle"
        case .reopened: "arrow.uturn.backward.circle"
        case .assigned, .unassigned: "person.crop.circle"
        case .dueDateChanged: "calendar"
        case .movedSection: "arrow.right.circle"
        case .renamed, .descriptionChanged: "pencil"
        case .priorityChanged: "flag"
        case .other: "circle.dotted"
        }
    }
}

/// Composer pinned under the stories: ⌘↩ sends; a trailing "@word" offers people to mention.
/// The field sits in a raised box with a visible border (rc1 QA U1: a roundedBorder field and a
/// default-style button were dark grey on dark grey) and gets the full width.
@MainActor
struct CommentComposerView: View {
    @Bindable var composer: CommentComposer
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ErrorBanner(error: composer.lastError) { composer.clearError() }
            if composer.mentionQuery != nil, !composer.users.results.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(composer.users.results.prefix(6)) { person in
                        Button {
                            composer.insertMention(person)
                        } label: {
                            PersonRow(person: person)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .accessibilityLabel("Mention someone")
            }
            TextField("Add a comment…", text: $composer.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(fieldFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(strokeOpacity), lineWidth: focused ? 2 : 1)
                )
                .accessibilityLabel("Comment")
                .accessibilityHint("Type @ to mention someone. Command-Return sends.")
            HStack(spacing: 8) {
                Text("@ to mention · ⌘↩ to send")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Button {
                    Task { await composer.send() }
                } label: {
                    Label("Comment", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!composer.canSend)
                .help("Send (⌘↩)")
            }
        }
    }

    /// Dark: lifted above the inspector background (white 8%, about #424242 on #323232). Light: the
    /// usual white text background.
    private var fieldFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color(nsColor: .textBackgroundColor)
    }

    /// Field edge at about 3:1 against its surroundings in both appearances.
    private var strokeOpacity: Double { colorScheme == .dark ? 0.3 : 0.4 }
}
