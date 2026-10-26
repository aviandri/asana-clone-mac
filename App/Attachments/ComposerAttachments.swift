import AppKit
import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// The comment composer's attachment chips (BE §13 Clients): upload progress, "Finishing…", Retry for a
/// failed file, × to cancel or remove. Chips being posted keep their × disabled. They live outside the
/// text field (SPEC-MAC §8: don't touch the composer's text view).
@MainActor
struct ComposerAttachmentsView: View {
    let composer: CommentComposer

    var body: some View {
        if !composer.attachments.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(composer.attachments) { chip in
                    AttachmentChip(chip: chip, sending: composer.sendingIDs.contains(chip.id)) {
                        Task { await composer.remove(chip.id) }
                    } retry: {
                        composer.retry(chip.id)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Comment attachments")
            .accessibilityIdentifier("composer.attachments")
        }
    }
}

@MainActor
struct AttachmentChip: View {
    let chip: AttachmentUpload
    let sending: Bool
    let remove: () -> Void
    let retry: () -> Void

    private var isLink: Bool {
        if case .link = chip.source { return true }
        return false
    }

    private var title: String { chip.attachment?.displayName ?? chip.name }

    var body: some View {
        HStack(spacing: 5) {
            if isLink {
                Image(systemName: "link")
                    .font(.caption)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                Image(nsImage: AttachmentFormatting.icon(mimeType: chip.attachment?.mimeType, name: chip.name))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            status
            removeButton
        }
        .font(.caption)
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(chip.isFailed ? Color.red.opacity(0.6) : Color.primary.opacity(0.18)))
        .help(failureMessage ?? title)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.chip")
    }

    private var failureMessage: String? {
        if case .failed(let error) = chip.state { return AttachmentFormatting.errorMessage(error, name: chip.name) }
        return nil
    }

    @ViewBuilder private var status: some View {
        switch chip.state {
        case .queued:
            Text("Waiting…").foregroundStyle(.secondary)
        case .uploading(let progress):
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .frame(width: 48)
                    .accessibilityLabel("Uploading \(chip.name)")
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(isLink ? "Adding \(chip.name)" : "Uploading \(chip.name)")
            }
        case .finishing:
            Text("Finishing…").foregroundStyle(.secondary)
        case .finished(let attachment):
            if attachment.kind == .file {
                Text(AttachmentFormatting.bytes(attachment.size)).foregroundStyle(.secondary)
            }
        case .failed(let error):
            Text(AttachmentFormatting.errorMessage(error, name: chip.name))
                .foregroundStyle(.red)
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if !isLink, AttachmentFormatting.isRetryable(error) {
                Button("Retry", action: retry)
                    .buttonStyle(.link)
                    .accessibilityLabel("Retry uploading \(chip.name)")
            }
        }
    }

    /// × cancels a running upload, dismisses a failed one, or removes (deletes) a finished draft. Disabled
    /// while it's finishing (it lands anyway) or being posted (it belongs to the comment now).
    private var removeButton: some View {
        let label: String
        switch chip.state {
        case .queued, .uploading, .finishing: label = "Cancel uploading \(title)"
        case .failed: label = "Dismiss \(title)"
        default: label = "Remove \(title)"
        }
        return Button(label, systemImage: "xmark.circle.fill", action: remove)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(sending || chip.isFinishing)
    }
}

/// The composer's paperclip: Attach Files… (NSOpenPanel) and Add Link… (popover).
@MainActor
struct ComposerAttachMenu: View {
    let composer: CommentComposer
    /// Reports how a batch of files went: the number refused because the comment is full.
    let attachFiles: ([AttachmentInputFile]) -> Void
    @State private var addingLink = false

    var body: some View {
        Menu {
            Button("Attach Files…") {
                attachFiles(AttachmentPicker.chooseFiles().map { AttachmentInputFile(url: $0) })
            }
            Button("Add Link…") { addingLink = true }
        } label: {
            Image(systemName: "paperclip")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!composer.hasRoomForAnother)
        .help(composer.hasRoomForAnother ? "Attach files or a link" : AttachmentFormatting.commentFullMessage)
        .accessibilityLabel("Attach")
        .accessibilityIdentifier("composer.attach")
        .popover(isPresented: $addingLink, arrowEdge: .top) {
            LinkForm { url, title in
                if try await composer.attachLink(url, title: title) {
                    addingLink = false
                } else {
                    throw APIError(code: .validation, message: AttachmentFormatting.commentFullMessage)
                }
            } cancel: {
                addingLink = false
            }
        }
    }
}

/// Lays chips out in rows, wrapping to the next row when one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            if !row.indices.isEmpty, row.width + spacing + itemWidth > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + itemWidth
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
