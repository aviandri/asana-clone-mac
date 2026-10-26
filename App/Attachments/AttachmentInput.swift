import AppKit
import MekariProjectFeatures
import SwiftUI
import UniformTypeIdentifiers

/// A file to attach: where it is, the name to upload it under, and whether it's our temp file (a pasted
/// image), which the upload deletes once it's done.
struct AttachmentInputFile: Equatable {
    let url: URL
    var name: String?
    var deletesFile = false
}

/// Files dropped from Finder (file URLs), and files other apps promise rather than hand over (Mail
/// attachments, Photos, images dragged out of Safari), copied to a temp file we own while the provider's
/// copy still exists. Folders and packages are left out (`skipped`). Main actor: the providers come from a
/// SwiftUI drop and stay there.
@MainActor
enum AttachmentDrop {
    nonisolated static let types: [UTType] = [.fileURL, .data]

    static func files(from providers: [NSItemProvider]) async -> (files: [AttachmentInputFile], skipped: Int) {
        var files: [AttachmentInputFile] = []
        var skipped = 0
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                guard let url = await fileURL(from: provider) else { continue }
                if isDirectory(url) { skipped += 1 } else { files.append(AttachmentInputFile(url: url)) }
            } else if let type = promisedType(provider), let file = await promisedFile(from: provider, type: type) {
                files.append(file)
            }
        }
        return (files, skipped)
    }

    /// The type to ask a provider without a file URL for: data, but not plain text or a web link dragged on
    /// its own (those stay text).
    static func promisedType(_ provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { id in
            guard let type = UTType(id), type.conforms(to: .data) else { return false }
            return !type.conforms(to: .text) && !type.conforms(to: .url)
        }
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            // @Sendable: the provider calls back on its own queue, so the closure mustn't be main-actor.
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { @Sendable data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    /// The provider's file exists only inside its callback: copy it to a temp file of ours (deleted with the
    /// upload), uploaded under the provider's name.
    private static func promisedFile(from provider: NSItemProvider, type: String) async -> AttachmentInputFile? {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { @Sendable url, _ in
                guard let url, !isDirectory(url) else { return continuation.resume(returning: nil) }
                var name = suggested ?? url.lastPathComponent
                if (name as NSString).pathExtension.isEmpty, let ext = UTType(type)?.preferredFilenameExtension {
                    name += ".\(ext)"
                }
                guard let copy = try? TempFiles.copy(url, extension: (name as NSString).pathExtension) else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: AttachmentInputFile(url: copy, name: name, deletesFile: true))
            }
        }
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// Our temp files (pasted images, promised drops): one flat folder, a random name each, so deleting the file
/// after its upload leaves nothing behind. The upload goes out under the real name (`fileName`).
enum TempFiles {
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MekariProjectAttachments-input", isDirectory: true)
    }

    static func url(extension ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        return folder.appendingPathComponent(name)
    }

    static func copy(_ file: URL, extension ext: String) throws -> URL {
        let target = try url(extension: ext)
        try FileManager.default.copyItem(at: file, to: target)
        return target
    }
}

/// ⌘V of files or an image (SPEC-MAC §8 Add). Files copied in Finder are attached as they are; an
/// image (a screenshot, or copied from an image editor) becomes "Pasted image <date>.png" (a temp file of
/// ours, see `TempFiles`). Clipboard text that also carries an image (copied from a web page, a document) stays an
/// ordinary text paste.
enum AttachmentPaste {
    static func files(from pasteboard: NSPasteboard, now: Date = .now) -> [AttachmentInputFile]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let regular = urls.filter { !AttachmentDrop.isDirectory($0) }
            return regular.isEmpty ? nil : regular.map { AttachmentInputFile(url: $0) }
        }
        guard pasteboard.string(forType: .string) == nil, let png = pngData(from: pasteboard) else { return nil }
        let name = "Pasted image \(stamp(now)).png"
        guard let url = try? TempFiles.url(extension: "png"), (try? png.write(to: url, options: .atomic)) != nil else { return nil }
        return [AttachmentInputFile(url: url, name: name, deletesFile: true)]
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// "2026-10-26 at 10.02.03", like a macOS screenshot's name.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}

/// Catches ⌘V in its window before the text system does, so files and images on the clipboard can be
/// attached. `handle` gets the window's first responder and returns true when it took the paste; false
/// leaves the event alone (an ordinary text paste). Use it zero-sized (`.frame(width: 0, height: 0)`).
@MainActor
struct PasteCatcher: NSViewRepresentable {
    let handle: @MainActor (NSResponder?) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.handle = handle
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.removeMonitor()
    }

    final class CatcherView: NSView {
        var handle: (@MainActor (NSResponder?) -> Bool)?
        private var monitor: Any?

        // It only listens for keys: invisible to clicks and to accessibility, so nothing it sits near (an
        // AppKit view in a SwiftUI background still hit-tests before SwiftUI content) is covered by it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityChildren() -> [Any]? { [] }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, Self.isPaste(event) else { return event }
                return self.handle?(window.firstResponder) == true ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// ⌘V, whatever Caps Lock (or the fn/numeric-pad flags) say: only ⌘⇧⌥⌃ count.
        static func isPaste(_ event: NSEvent) -> Bool {
            event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command && event.charactersIgnoringModifiers?.lowercased() == "v"
        }
    }
}

/// Which task's composer each place shows: the main window (its selected task, per workspace scope) and each
/// task window. A composer's drafts are discarded when no place shows its task any more, i.e. the task was
/// left (another task selected, its window closed), not when an inspector is merely hidden (web: leaving the
/// composer deletes its drafts; the server sweeps whatever is left after 24 h).
@MainActor
enum ComposerPresence {
    private static var shown: [String: CommentComposer] = [:]
    /// Discards started (tests await them).
    private(set) static var pendingDiscard: Task<Void, Never>?

    /// `owner` now shows `composer` (nil: nothing, e.g. no task selected or the window closed).
    static func show(_ composer: CommentComposer?, owner: String) {
        let previous = shown[owner]
        shown[owner] = composer
        guard let previous, previous !== composer else { return }
        pendingDiscard = Task { @MainActor in
            // Shown again meanwhile (by another place, or back here): keep the drafts.
            guard count(previous) == 0 else { return }
            await previous.discard()
        }
    }

    static func count(_ composer: CommentComposer) -> Int { shown.values.filter { $0 === composer }.count }
}
