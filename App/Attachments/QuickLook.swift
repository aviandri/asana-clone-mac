import AppKit
import MekariProjectFeatures
import MekariProjectKit
import Quartz

/// Quick Look for attachments (SPEC-MAC §8 Preview): Space on a selected tile, ←/→ through the task's
/// files. Each item is downloaded on demand (a cached copy is used as is, `revalidate: false`); until it
/// arrives the panel shows a placeholder with the name, and the tile shows the download's progress
/// with Cancel (Q4).
///
/// The panel finds its controller through the responder chain, so the controller inserts itself right
/// after the key window when it shows the panel.
@MainActor
final class QuickLookController: NSResponder {
    static let shared = QuickLookController()

    private var items: [Attachment] = []
    private var index = 0
    private weak var files: AttachmentFiles?
    /// Downloaded copies, by attachment id.
    private var local: [String: URL] = [:]
    private var loading: Set<String> = []
    private weak var window: NSWindow?

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Shows (or, when already showing this attachment, hides) the panel on `selected`, stepping through `all`.
    func toggle(_ selected: Attachment, in all: [Attachment], files: AttachmentFiles) {
        if isVisible, items.indices.contains(index), items[index].id == selected.id {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        show(selected, in: all, files: files)
    }

    func show(_ selected: Attachment, in all: [Attachment], files: AttachmentFiles) {
        let previewable = all.filter { $0.kind == .file && $0.contentPath != nil }
        items = previewable.contains(where: { $0.id == selected.id }) ? previewable : [selected]
        index = items.firstIndex { $0.id == selected.id } ?? 0
        if self.files !== files { local = [:] }
        self.files = files
        if let key = NSApp.keyWindow, !(key is QLPreviewPanel) { attach(to: key) }
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = index
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Puts the controller in `window`'s responder chain (once): window → controller → what came after.
    private func attach(to window: NSWindow) {
        if self.window === window { return }
        detach()
        nextResponder = window.nextResponder
        window.nextResponder = self
        self.window = window
    }

    private func detach() {
        guard let window, window.nextResponder === self else { return }
        window.nextResponder = nextResponder
        nextResponder = nil
        self.window = nil
    }

    /// The item for the panel: the downloaded copy, else a placeholder while it downloads.
    fileprivate func previewItem(at i: Int) -> QLPreviewItem {
        guard items.indices.contains(i) else { return Placeholder(title: "") }
        let a = items[i]
        // A sign-out or a lost workspace wipes the cache: a stale path downloads again.
        if let url = local[a.id], FileManager.default.fileExists(atPath: url.path) { return url as NSURL }
        load(a)
        return Placeholder(title: a.displayName)
    }

    private func load(_ a: Attachment) {
        guard let files, loading.insert(a.id).inserted else { return }
        Task {
            let url = await AttachmentErrors.shared.download(a, files: files, revalidate: false)
            loading.remove(a.id)
            guard let url else { return }   // failed (banner) or cancelled (tile)
            local[a.id] = url
            guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
            if items.indices.contains(panel.currentPreviewItemIndex), items[panel.currentPreviewItemIndex].id == a.id {
                panel.refreshCurrentPreviewItem()
            }
        }
    }

    // MARK: QLPreviewPanelController (informal protocol on NSObject)

    // The NSObject category is nonisolated; the panel calls it on the main thread.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
            panel.currentPreviewItemIndex = index
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

extension QuickLookController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            self.index = index
            return previewItem(at: index)
        }
    }

    /// Space closes the panel again (Finder's toggle); the arrow keys step (the panel handles those).
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, event.charactersIgnoringModifiers == " " else { return false }
        MainActor.assumeIsolated { panel.orderOut(nil) }
        return true
    }
}

/// A Quick Look item with no file yet: the panel shows its title while the download runs.
private final class Placeholder: NSObject, QLPreviewItem {
    let title: String
    init(title: String) { self.title = title }
    var previewItemURL: URL! { nil }
    var previewItemTitle: String! { title }
}
