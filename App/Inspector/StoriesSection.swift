import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// Comments and activity, oldest first (`GET /tasks/:id/stories`).
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
                let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                out += (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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
struct CommentComposerView: View {
    @Bindable var composer: CommentComposer

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
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Add a comment… (@ to mention)", text: $composer.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Comment")
                Button {
                    Task { await composer.send() }
                } label: {
                    Label("Comment", systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!composer.canSend)
                .help("Send (⌘↩)")
            }
        }
    }
}
