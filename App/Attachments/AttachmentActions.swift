import AppKit
import MekariProjectFeatures
import MekariProjectKit
import Observation
import UniformTypeIdentifiers

/// What the attachment buttons and context menus do (SPEC-MAC §8 Actions). Files are downloaded through
/// the workspace's `AttachmentFiles` (cached, quarantined) before they are opened, saved or revealed; a
/// failed download shows in its task's banner (`AttachmentErrors`). Only http/https links are ever opened.
@MainActor
struct AttachmentActions {
    let session: AppSession
    let scope: WorkspaceScope
    let store: TaskDetailStore

    var files: AttachmentFiles { scope.attachmentFiles }

    /// The local copy; a failure is recorded for the attachment's task (not workspace-wide).
    func download(_ a: Attachment, revalidate: Bool = true) async -> URL? {
        await AttachmentErrors.shared.download(a, files: files, revalidate: revalidate)
    }

    /// FILE: the default app for the downloaded copy. LINK: the default browser.
    func open(_ a: Attachment) {
        if a.kind == .link {
            if let url = a.linkURL { NSWorkspace.shared.open(url) }
            return
        }
        Task {
            guard let file = await download(a) else { return }
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
            guard let file = await download(a) else { return }
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
            guard let file = await download(a) else { return }
            copy(file, to: destination)
        }
    }

    /// Save to Downloads, with a unique name ("report 2.pdf"), then bounce the Downloads stack.
    func saveToDownloads(_ a: Attachment) {
        Task {
            guard let file = await download(a),
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
            guard let file = await download(a, revalidate: false) else { return }
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

    /// Copies the cached download out, reporting a failure.
    @discardableResult
    private func copy(_ file: URL, to destination: URL) -> Bool {
        do {
            try Self.copyOut(file, to: destination)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// The user's own copy of a cached download: xattrs come along (so the quarantine flag does, as with a
    /// Safari download), and it's made writable (0644) afterwards: the cache's copy is read-only, so apps
    /// opening it can't edit what the app serves back. Replaces what's at `destination` (the save panel
    /// already asked), with the new file's metadata only.
    nonisolated static func copyOut(_ file: URL, to destination: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: destination.path) {
            let staged = try stagedCopy(of: file, near: destination, fileManager: fileManager)
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
        } else {
            try fileManager.copyItem(at: file, to: destination)
        }
        // chmod after the copy: a mode change doesn't touch xattrs.
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
    }

    /// A copy next to the destination, for an atomic replace that leaves the cached file alone.
    private nonisolated static func stagedCopy(of file: URL, near destination: URL, fileManager: FileManager) throws -> URL {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
        try fileManager.copyItem(at: file, to: staged)
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

    /// Looked up once per content type (or once for links) and kept: LaunchServices queries are slow, and menus
    /// are built as views render.
    @MainActor
    static func apps(for a: Attachment, workspace: NSWorkspace = .shared) -> [App] {
        if a.kind == .link {
            guard let url = a.linkURL else { return [] }
            return cached("scheme:\(url.scheme ?? "https")") {
                list(workspace.urlsForApplications(toOpen: url), preferred: workspace.urlForApplication(toOpen: url))
            }
        }
        let type = AttachmentFormatting.contentType(mimeType: a.mimeType, name: a.name)
        return cached("type:\(type.identifier)") {
            list(workspace.urlsForApplications(toOpen: type), preferred: workspace.urlForApplication(toOpen: type))
        }
    }

    @MainActor private static var cache: [String: [App]] = [:]

    @MainActor
    static func cached(_ key: String, _ lookup: () -> [App]) -> [App] {
        if let apps = cache[key] { return apps }
        let apps = lookup()
        cache[key] = apps
        return apps
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

/// Download failures, per task: the workspace's `AttachmentFiles.lastError` is shared by every task, so
/// it's moved here (and cleared there) as soon as a download for a known task fails, and each task's
/// Attachments section shows only its own.
@MainActor @Observable
final class AttachmentErrors {
    static let shared = AttachmentErrors()

    private(set) var byTask: [String: APIError] = [:]

    func error(for taskID: String) -> APIError? { byTask[taskID] }

    func clear(taskID: String) { byTask[taskID] = nil }

    func record(_ error: APIError, taskID: String) { byTask[taskID] = error }

    /// `files.file(for:)`, with a failure recorded for `a`'s task.
    func download(_ a: Attachment, files: AttachmentFiles, revalidate: Bool = true) async -> URL? {
        let url = await files.file(for: a, revalidate: revalidate)
        if url == nil, let error = files.lastError {
            record(error, taskID: a.taskId)
            files.clearError()
        }
        return url
    }
}
