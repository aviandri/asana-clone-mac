import AppKit
import MekariProjectFeatures
import MekariProjectKit
import UniformTypeIdentifiers

/// What the attachment buttons and context menus do (SPEC-MAC §8 Actions). Files are downloaded through
/// the workspace's `AttachmentFiles` (cached, quarantined) before they are opened, saved or revealed; a
/// failed download shows in the section's banner (`AttachmentFiles.lastError`). Only http/https links are
/// ever opened.
@MainActor
struct AttachmentActions {
    let session: AppSession
    let scope: WorkspaceScope
    let store: TaskDetailStore

    var files: AttachmentFiles { scope.attachmentFiles }

    /// FILE: the default app for the downloaded copy. LINK: the default browser.
    func open(_ a: Attachment) {
        if a.kind == .link {
            if let url = a.linkURL { NSWorkspace.shared.open(url) }
            return
        }
        Task {
            guard let file = await files.file(for: a) else { return }
            NSWorkspace.shared.open(file)
        }
    }

    /// Open With ▸ an app from the menu (or one picked with Other…).
    func open(_ a: Attachment, withApplicationAt app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        if a.kind == .link {
            guard let url = a.linkURL else { return }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration, completionHandler: nil)
            return
        }
        Task {
            guard let file = await files.file(for: a) else { return }
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration, completionHandler: nil)
        }
    }

    /// Open With ▸ Other…: any app from /Applications.
    func chooseApplicationAndOpen(_ a: Attachment) {
        let panel = NSOpenPanel()
        panel.title = "Open “\(a.displayName)” With"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(a, withApplicationAt: app)
    }

    /// Open in Browser: the task on the web, in this workspace (the file itself needs the app's session).
    var browserURL: URL? {
        BrowserLinks.url(session: session, taskID: store.taskID, projectID: scope.tasks[store.taskID]?.projectId)
    }

    func openInBrowser() {
        if let url = browserURL { NSWorkspace.shared.open(url) }
    }

    func saveAs(_ a: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.name ?? "file"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            guard let file = await files.file(for: a) else { return }
            copy(file, to: destination)
        }
    }

    /// Save to Downloads, with a unique name ("report 2.pdf"), then bounce the Downloads stack.
    func saveToDownloads(_ a: Attachment) {
        Task {
            guard let file = await files.file(for: a),
                  let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
            let destination = Self.uniqueURL(for: file.lastPathComponent, in: downloads)
            if copy(file, to: destination) {
                DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: destination.path)
            }
        }
    }

    /// Show in Finder: downloads first if needed (the copy lives in Caches/Attachments).
    func showInFinder(_ a: Attachment) {
        Task {
            guard let file = await files.file(for: a, revalidate: false) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }

    /// Copy Link: a LINK's URL (http/https only).
    func copyLink(_ a: Attachment) {
        guard let url = a.linkURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    /// Copies the cached download out (xattrs, so the quarantine flag, come along). Replaces what's there:
    /// the save panel already asked.
    @discardableResult
    private func copy(_ file: URL, to destination: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: Self.stagedCopy(of: file, near: destination))
            } else {
                try FileManager.default.copyItem(at: file, to: destination)
            }
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// A copy next to the destination, for an atomic replace that leaves the cached file alone.
    private static func stagedCopy(of file: URL, near destination: URL) throws -> URL {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
        try FileManager.default.copyItem(at: file, to: staged)
        return staged
    }

    /// "name.ext", else "name 2.ext", "name 3.ext"… (Safari's style).
    nonisolated static func uniqueURL(for name: String, in directory: URL, fileManager: FileManager = .default) -> URL {
        let first = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: first.path) else { return first }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

/// The apps for Open With ▸: the default first, then the others by name. Files are matched by type
/// (no download needed to build the menu), links by the https scheme (installed browsers).
enum OpenWithApps {
    struct App: Identifiable, Equatable {
        let url: URL
        let name: String
        let isDefault: Bool
        var id: URL { url }
    }

    @MainActor
    static func apps(for a: Attachment, workspace: NSWorkspace = .shared) -> [App] {
        let all: [URL]
        let preferred: URL?
        if a.kind == .link {
            guard let url = a.linkURL else { return [] }
            all = workspace.urlsForApplications(toOpen: url)
            preferred = workspace.urlForApplication(toOpen: url)
        } else {
            let type = AttachmentFormatting.contentType(mimeType: a.mimeType, name: a.name)
            all = workspace.urlsForApplications(toOpen: type)
            preferred = workspace.urlForApplication(toOpen: type)
        }
        return list(all, preferred: preferred)
    }

    /// Unique by path, the default first, the rest sorted by display name.
    static func list(_ urls: [URL], preferred: URL?) -> [App] {
        var seen = Set<String>()
        let apps = urls.compactMap { url -> App? in
            guard seen.insert(url.standardizedFileURL.path).inserted else { return nil }
            return App(url: url, name: displayName(url), isDefault: url.standardizedFileURL == preferred?.standardizedFileURL)
        }
        let defaults = apps.filter(\.isDefault)
        let others = apps.filter { !$0.isDefault }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return defaults + others
    }

    static func displayName(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// A 16 pt copy of the app's icon, for a menu item.
    @MainActor
    static func icon(_ app: URL) -> NSImage {
        let icon = (NSWorkspace.shared.icon(forFile: app.path).copy() as? NSImage) ?? NSImage()
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
