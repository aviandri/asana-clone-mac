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

/// Files dropped from Finder (or any app that drags file URLs). Folders are left out (`skipped`).
enum AttachmentDrop {
    static let types: [UTType] = [.fileURL]

    static func files(from providers: [NSItemProvider]) async -> (files: [AttachmentInputFile], skipped: Int) {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await fileURL(from: provider) { urls.append(url) }
        }
        let regular = urls.filter { !isDirectory($0) }
        return (regular.map { AttachmentInputFile(url: $0) }, urls.count - regular.count)
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// ⌘V of files or an image (SPEC-MAC §8 Add). Files copied in Finder are attached as they are; an
/// image (a screenshot, or copied from an image editor) becomes "Pasted image <date>.png" in a temp
/// folder. Clipboard text that also carries an image (copied from a web page, a document) stays an
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
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MekariProjectPaste", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch {
            return nil
        }
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
/// leaves the event alone (an ordinary text paste).
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

        static func isPaste(_ event: NSEvent) -> Bool {
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.charactersIgnoringModifiers == "v"
        }
    }
}

/// How many inspectors show each task's comment composer. The main window's inspector and a task window
/// share one store, so the composer's drafts are discarded only when the last of them goes (web: leaving
/// the composer deletes its drafts; the server sweeps whatever is left after 24 h).
@MainActor
enum ComposerPresence {
    private static var counts: [ObjectIdentifier: Int] = [:]

    static func appeared(_ composer: CommentComposer) {
        counts[ObjectIdentifier(composer), default: 0] += 1
    }

    static func disappeared(_ composer: CommentComposer) {
        let key = ObjectIdentifier(composer)
        let count = (counts[key] ?? 1) - 1
        if count > 0 {
            counts[key] = count
            return
        }
        counts[key] = nil
        Task { await composer.discard() }
    }

    static func count(_ composer: CommentComposer) -> Int { counts[ObjectIdentifier(composer)] ?? 0 }
}
