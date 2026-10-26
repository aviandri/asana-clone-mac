import AppKit
import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// What attachment views need from the inspector: the actions, the task's store (permissions, the list
/// Quick Look steps through) and the workspace's downloads.
@MainActor
struct AttachmentContext {
    let actions: AttachmentActions
    var store: TaskDetailStore { actions.store }
    var files: AttachmentFiles { actions.files }
    /// Refresh Preview is for those who can edit the task (Q3).
    var canRefreshLinks: Bool { store.canAttach }

    /// Space / double-click: Quick Look, stepping through the task's files.
    func quickLook(_ a: Attachment) {
        QuickLookController.shared.toggle(a, in: store.attachments, files: files)
    }
}

/// The task's attachments (BE SPEC §13 Clients, SPEC-MAC §8): task-level and comment ones, newest first,
/// with Attach File and Add Link for editors, uploads in progress, and per-item actions. Drops and ⌘V
/// are handled by the inspector around it.
@MainActor
struct AttachmentsSection: View {
    let context: AttachmentContext
    /// A note about the last drop or paste on the inspector ("Folders can't be attached.").
    var notice: String? = nil
    @State private var addingLink = false
    @State private var pendingDelete: Attachment?

    private var store: TaskDetailStore { context.store }

    var body: some View {
        let attachments = store.attachments
        let uploads = store.uploads
        if store.canAttach || !attachments.isEmpty || !uploads.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header(count: attachments.count)
                // This task's download failures only (AttachmentErrors), not the workspace's.
                ErrorBanner(error: AttachmentErrors.shared.error(for: store.taskID)) { AttachmentErrors.shared.clear(taskID: store.taskID) }
                if let notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("attachments.notice")
                }
                if !uploads.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(uploads) { upload in
                            UploadRow(upload: upload, onCancel: { store.cancelUpload(upload.id) }, onRetry: { store.retryUpload(upload.id) })
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Uploads")
                }
                if !attachments.isEmpty {
                    AdaptiveGrid(minimum: 128, maximum: 220, spacing: 8) {
                        ForEach(attachments) { a in
                            AttachmentTile(a: a, context: context, canDelete: store.canDelete(a)) { pendingDelete = a }
                        }
                    }
                } else if uploads.isEmpty {
                    Text("Drop files here, paste a screenshot, or use Attach File or Add Link.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("attachments.section")
            .confirmationDialog(
                Text(pendingDelete.map { "Delete “\($0.displayName)”?" } ?? "Delete attachment?"),
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { a in
                Button("Delete", role: .destructive) {
                    Task { await store.deleteAttachment(a.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This can't be undone.")
            }
        }
    }

    @ViewBuilder private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            Text("Attachments").font(.headline)
            if count > 0 {
                Text("\(count)").foregroundStyle(.secondary)
            }
            Spacer()
            if store.canAttach {
                Button("Add Link", systemImage: "link") { addingLink = true }
                    .accessibilityIdentifier("attachments.addLink")
                    .popover(isPresented: $addingLink, arrowEdge: .bottom) {
                        LinkForm { url, title in
                            try await store.addLink(url, title: title)
                            addingLink = false
                        } cancel: {
                            addingLink = false
                        }
                    }
                Button("Attach File", systemImage: "paperclip") {
                    for url in AttachmentPicker.chooseFiles() { store.attach(fileAt: url) }
                }
                .accessibilityIdentifier("attachments.attachFile")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

/// NSOpenPanel for files to attach (several at once; no folders).
@MainActor
enum AttachmentPicker {
    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Attach Files"
        panel.prompt = "Attach"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// One attachment in a grid: a file tile, a link card, or a placeholder for a kind this build doesn't know.
@MainActor
struct AttachmentTile: View {
    let a: Attachment
    let context: AttachmentContext
    var compact = false
    var canDelete = false
    var onDelete: () -> Void = {}

    var body: some View {
        if a.kind == .file {
            FileTile(a: a, context: context, compact: compact, canDelete: canDelete, onDelete: onDelete)
        } else if a.kind == .link {
            LinkCard(a: a, context: context, compact: compact, canDelete: canDelete, onDelete: onDelete)
        } else {
            Text("Unsupported attachment")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contextMenu {
                    if canDelete { Button("Delete…", role: .destructive, action: onDelete) }
                }
                .accessibilityIdentifier("attachment.tile.\(a.id)")
        }
    }
}

/// A file: thumbnail (BE `thumbnailPath`) or Finder's icon for its type, name and size. Click selects;
/// Space or a double-click opens Quick Look, Return opens it in its default app. While its download
/// runs, a bar with Cancel sits on top (Q4).
@MainActor
struct FileTile: View {
    let a: Attachment
    let context: AttachmentContext
    var compact = false
    var canDelete = false
    var onDelete: () -> Void = {}

    @FocusState private var focused: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        tile
            .overlay(alignment: .top) { TileDownload(a: a, files: context.files) }
            .task(id: a.thumbnailPath ?? a.id) {
                guard a.hasThumbnail, let data = await context.files.thumbnail(for: a, size: .small) else { return }
                thumbnail = NSImage(data: data)
            }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.primary.opacity(0.04)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(nsImage: AttachmentFormatting.icon(mimeType: a.mimeType, name: a.name))
                        .resizable()
                        .scaledToFit()
                        .frame(width: compact ? 32 : 44, height: compact ? 32 : 44)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 64 : 84)
            .clipped()
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name ?? "file")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(AttachmentFormatting.bytes(a.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: focused ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture(count: 2) {
            focused = true
            context.quickLook(a)
        }
        .onTapGesture { focused = true }
        .onKeyPress(.space) {
            context.quickLook(a)
            return .handled
        }
        .onKeyPress(.return) {
            context.actions.open(a)
            return .handled
        }
        .contextMenu {
            AttachmentMenu(a: a, context: context, canDelete: canDelete, onDelete: onDelete)
        }
        .help(a.name ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AttachmentFormatting.accessibilityLabel(a))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { context.quickLook(a) }
        .accessibilityAction(named: "Open") { context.actions.open(a) }
        .accessibilityIdentifier("attachment.tile.\(a.id)")
    }
}

/// A tile's download bar. Its own view, so only it (not the whole tile) re-renders as downloads progress.
@MainActor
private struct TileDownload: View {
    let a: Attachment
    let files: AttachmentFiles

    var body: some View {
        if let progress = files.downloads[a.id] {
            DownloadBar(name: a.name ?? "file", progress: progress) { files.cancelDownload(a.id) }
                .padding(4)
                .accessibilityIdentifier("attachment.download.\(a.id)")
        }
    }
}

/// Download progress over a tile, with Cancel (it stops the shared download for every caller).
@MainActor
struct DownloadBar: View {
    let name: String
    let progress: TransferProgress
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().controlSize(.small)
                Spacer(minLength: 0)
            }
            Button("Cancel download of \(name)", systemImage: "xmark.circle.fill", action: cancel)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("attachment.download.cancel")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Downloading \(name)")
    }
}

/// A link's card: og image (not when compact), provider badge or site icon, title, site and two lines of
/// description. A preview that failed or is still pending falls back to the domain (BE §13). A click
/// opens the link in the default browser; only http/https links are ever opened.
@MainActor
struct LinkCard: View {
    let a: Attachment
    let context: AttachmentContext
    var compact = false
    var canDelete = false
    var onDelete: () -> Void = {}

    @State private var image: NSImage?
    @State private var icon: NSImage?

    var body: some View {
        let badge = ProviderBadge.of(a.provider)
        let title = a.displayName
        let site = a.siteName ?? badge?.name ?? a.host
        Button {
            context.actions.open(a)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if !compact, let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 84)
                        .clipped()
                }
                HStack(alignment: .top, spacing: 8) {
                    glyph(badge)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        if let site, site != title {
                            Text(site).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if a.previewStatus == .pending {
                            Text("Fetching preview…").font(.caption2).foregroundStyle(.secondary)
                        }
                        if !compact, let description = a.description, !description.isEmpty {
                            Text(description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .padding(.top, 1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            AttachmentMenu(a: a, context: context, canDelete: canDelete, onDelete: onDelete)
        }
        .help(a.url ?? "")
        .accessibilityLabel(AttachmentFormatting.accessibilityLabel(a))
        .accessibilityIdentifier("attachment.tile.\(a.id)")
        .task(id: "\(a.id)/\(a.imagePath ?? "")/\(a.iconPath ?? "")") {
            if !compact, a.hasImage, let data = await context.files.linkImage(for: a) { image = NSImage(data: data) }
            if badge == nil, a.hasIcon, let data = await context.files.linkIcon(for: a) { icon = NSImage(data: data) }
        }
    }

    /// The provider badge, else the server-cached site icon, else a generic link glyph.
    @ViewBuilder private func glyph(_ badge: ProviderBadge?) -> some View {
        if let badge {
            Text(badge.initials)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(badge.tone))
                .accessibilityHidden(true)
        } else if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "link")
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// The context menu of a tile (SPEC-MAC §8 Actions). Comment attachments pass `canDelete: false` (Q1:
/// deleting happens in the task's Attachments grid only).
@MainActor
struct AttachmentMenu: View {
    let a: Attachment
    let context: AttachmentContext
    var canDelete = false
    var onDelete: () -> Void = {}

    var body: some View {
        let actions = context.actions
        if a.kind == .file {
            Button("Quick Look") { context.quickLook(a) }
            Button("Open") { actions.open(a) }
            openWith
            Divider()
            Button("Open in Browser") { actions.openInBrowser() }
                .disabled(actions.browserURL == nil)
            Button("Save As…") { actions.saveAs(a) }
            Button("Save to Downloads") { actions.saveToDownloads(a) }
            Button("Show in Finder") { actions.showInFinder(a) }
        } else if a.kind == .link, a.linkURL != nil {
            Button("Open") { actions.open(a) }
            openWith
            Button("Copy Link") { actions.copyLink(a) }
            if context.canRefreshLinks {
                Button("Refresh Preview") { Task { await context.store.refreshLinkPreview(a.id) } }
            }
        }
        if canDelete {
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }

    /// Open With ▸: the default app first ("Preview (default)"), the others, then Other….
    private var openWith: some View {
        Menu("Open With") {
            let apps = OpenWithApps.apps(for: a)
            ForEach(apps) { app in
                Button {
                    context.actions.open(a, withApplicationAt: app.url)
                } label: {
                    Label {
                        Text(app.isDefault ? "\(app.name) (default)" : app.name)
                    } icon: {
                        Image(nsImage: OpenWithApps.icon(app.url))
                    }
                }
                if app.isDefault, apps.count > 1 { Divider() }
            }
            if !apps.isEmpty { Divider() }
            Button("Other…") { context.actions.chooseApplicationAndOpen(a) }
        }
    }
}

/// A task-level upload in the section: waiting, progress with Cancel, "Finishing…" (sent, so it can't be
/// cancelled any more), or the error with Retry and Dismiss. Finished ones leave (the task has them).
@MainActor
struct UploadRow: View {
    let upload: AttachmentUpload
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AttachmentFormatting.icon(mimeType: nil, name: upload.name))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(upload.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(AttachmentFormatting.bytes(upload.size)).font(.caption).foregroundStyle(.secondary)
                }
                status
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachments.upload")
    }

    @ViewBuilder private var status: some View {
        switch upload.state {
        case .queued:
            Text("Waiting to upload…").font(.caption).foregroundStyle(.secondary)
        case .uploading(let progress):
            if let fraction = progress.fraction {
                ProgressView(value: fraction).accessibilityLabel("Uploading \(upload.name)")
            } else {
                ProgressView().controlSize(.small).accessibilityLabel("Uploading \(upload.name)")
            }
        case .finishing:
            ProgressView(value: 0.99).accessibilityLabel("Uploading \(upload.name)")
        case .failed(let error):
            Text(AttachmentFormatting.errorMessage(error, name: upload.name))
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        switch upload.state {
        case .queued, .uploading:
            Button("Cancel", action: onCancel)
                .accessibilityLabel("Cancel uploading \(upload.name)")
        case .finishing:
            Text("Finishing…").font(.caption).foregroundStyle(.secondary)
        case .failed(let error):
            if AttachmentFormatting.isRetryable(error) {
                Button("Retry", action: onRetry).accessibilityLabel("Retry uploading \(upload.name)")
            }
            Button("Dismiss", action: onCancel).accessibilityLabel("Dismiss \(upload.name)")
        default:
            EmptyView()
        }
    }
}

/// URL + optional title (≤ 300). `submit` returns once the link exists (the server fetches its preview,
/// up to 6 s) and throws an `APIError` whose `url` issue shows here.
@MainActor
struct LinkForm: View {
    let submit: (String, String?) async throws -> Void
    let cancel: () -> Void

    @State private var url = ""
    @State private var title = ""
    @State private var problem: String?
    @State private var pending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Link").font(.headline)
            TextField("https://", text: $url)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Link URL")
                .accessibilityIdentifier("attachments.link.url")
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Link title (optional)")
                .accessibilityIdentifier("attachments.link.title")
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("attachments.link.problem")
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(pending ? "Adding…" : "Add Link") {
                    Task { await add() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pending)
                .accessibilityIdentifier("attachments.link.submit")
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private func add() async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            problem = "Enter a link."
            return
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        problem = nil
        pending = true
        do {
            try await submit(trimmed, name.isEmpty ? nil : String(name.prefix(300)))
        } catch {
            problem = AttachmentFormatting.linkProblem(error)
            pending = false
        }
    }
}

/// A posted comment's attachments, under its body (oldest first, as the server sends them). No Delete
/// here (Q1).
@MainActor
struct CommentAttachmentsView: View {
    let attachments: [Attachment]
    let context: AttachmentContext

    var body: some View {
        AdaptiveGrid(minimum: 112, maximum: 180, spacing: 6) {
            ForEach(attachments) { a in
                AttachmentTile(a: a, context: context, compact: true)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachments in this comment")
    }
}

/// Equal-width columns, as many as fit at `minimum` each (capped at `maximum`), rows as tall as their
/// tallest tile. Not lazy: a task has few attachments, and every tile stays in the accessibility tree
/// (a LazyVGrid drops off-screen tiles, which VoiceOver and UI tests then can't reach).
struct AdaptiveGrid: Layout {
    var minimum: CGFloat
    var maximum: CGFloat
    var spacing: CGFloat

    private func columns(_ width: CGFloat, count: Int) -> (count: Int, width: CGFloat) {
        guard width.isFinite else { return (max(count, 1), minimum) }
        let n = max(1, Int((width + spacing) / (minimum + spacing)))
        return (n, min(maximum, (width - spacing * CGFloat(n - 1)) / CGFloat(n)))
    }

    private func rowHeights(_ subviews: Subviews, columns: (count: Int, width: CGFloat)) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns.count).map { start in
            subviews[start..<min(start + columns.count, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: columns.width, height: nil)).height }
                .max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let layout = columns(width, count: subviews.count)
        let heights = rowHeights(subviews, columns: layout)
        let height = heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0))
        let used = CGFloat(min(layout.count, subviews.count)) * (layout.width + spacing) - spacing
        return CGSize(width: width.isFinite ? width : max(used, 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = columns(bounds.width, count: subviews.count)
        let heights = rowHeights(subviews, columns: layout)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<layout.count {
                let index = row * layout.count + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (layout.width + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: layout.width, height: height))
            }
            y += height + spacing
        }
    }
}
