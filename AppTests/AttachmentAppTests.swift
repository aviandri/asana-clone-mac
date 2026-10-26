import AppKit
import MekariProjectFeatures
import MekariProjectKit
import UniformTypeIdentifiers
import XCTest
@testable import MekariProjectApp

/// The attachment UI's helpers (formatting, copy, Open With, paste/drop input, composer presence) and the
/// session's cache wipe as the app sees it. The stores themselves are tested in the Features package.
final class AttachmentAppTests: XCTestCase {
    private let alice = UserSummary(id: DemoIDs.alice, name: "Alice", email: "alice@example.com", avatarColor: "#336699")

    private func file(_ name: String, size: Int64 = 2_411_724) -> Attachment {
        Attachment(id: DemoIDs.attachmentPDF, workspaceId: DemoIDs.mekari, taskId: DemoIDs.taskWithAttachments, kind: .file,
                   uploader: alice, createdAt: .now, name: name, mimeType: "application/pdf", size: size,
                   contentPath: "/api/v1/attachments/\(DemoIDs.attachmentPDF)/content")
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    // MARK: Formatting and copy

    func testSizesUseBinaryUnitsLikeTheLimit() {
        XCTAssertEqual(AttachmentFormatting.bytes(nil), "")
        XCTAssertEqual(AttachmentFormatting.bytes(0), "0 B")
        XCTAssertEqual(AttachmentFormatting.bytes(1023), "1023 B")
        XCTAssertEqual(AttachmentFormatting.bytes(1024), "1 KB")
        XCTAssertEqual(AttachmentFormatting.bytes(1536), "1.5 KB")
        XCTAssertEqual(AttachmentFormatting.bytes(2_411_724), "2.3 MB")
        XCTAssertEqual(AttachmentFormatting.bytes(AttachmentLimits.maxUploadBytes), "100 MB")
    }

    func testUploadErrorsUseTheWebCopyAndTheServersWordsFor429And507() {
        let tooLarge = AttachmentLimits.tooLarge()
        XCTAssertEqual(AttachmentFormatting.errorMessage(tooLarge, name: "big.mov"), "big.mov is larger than 100 MB.")
        XCTAssertFalse(AttachmentFormatting.isRetryable(tooLarge))

        let busy = APIError(code: .rateLimited, status: 429, message: "You already have 3 uploads running.")
        XCTAssertEqual(AttachmentFormatting.errorMessage(busy, name: "a.png"), "You already have 3 uploads running.")
        XCTAssertTrue(AttachmentFormatting.isRetryable(busy))
        XCTAssertEqual(AttachmentFormatting.errorMessage(APIError(code: .rateLimited, message: ""), name: "a.png"),
                       "Too many uploads. Try again in a few minutes.")

        let full = APIError(code: .insufficientStorage, status: 507, message: "The server is low on space.")
        XCTAssertEqual(AttachmentFormatting.errorMessage(full, name: "a.png"), "The server is low on space.")
        XCTAssertEqual(AttachmentFormatting.errorMessage(APIError(code: .forbidden, status: 403, message: "nope"), name: "a.png"),
                       "You can't add attachments here.")
        XCTAssertEqual(AttachmentFormatting.errorMessage(.transport(), name: "a.png"), "Can't reach the server")
    }

    func testLinkProblemsPreferTheUrlIssue() {
        let invalid = APIError(code: .validation, status: 400, message: "Invalid input",
                               issues: [FieldIssue(path: ["url"], message: "Only http and https links can be added")])
        XCTAssertEqual(AttachmentFormatting.linkProblem(invalid), "Only http and https links can be added")
        XCTAssertEqual(AttachmentFormatting.linkProblem(APIError(code: .validation, message: AttachmentFormatting.commentFullMessage)),
                       "A comment can have up to 20 attachments.")
        XCTAssertEqual(AttachmentFormatting.linkProblem(CancellationError()), "Couldn't add the link.")
    }

    func testTileLabelsForVoiceOver() {
        XCTAssertEqual(AttachmentFormatting.accessibilityLabel(file("report.pdf")), "Attachment, report.pdf, 2.3 MB")
        let link = Attachment(id: DemoIDs.attachmentLink, workspaceId: DemoIDs.mekari, taskId: DemoIDs.taskWithAttachments, kind: .link,
                              uploader: alice, createdAt: .now, url: "https://www.figma.com/file/abc", title: "Design spec", provider: "figma")
        XCTAssertEqual(AttachmentFormatting.accessibilityLabel(link), "Link, Design spec")
    }

    func testTypesComeFromTheSniffedMimeTypeThenTheExtension() {
        XCTAssertEqual(AttachmentFormatting.contentType(mimeType: "application/pdf", name: "x.bin"), .pdf)
        XCTAssertEqual(AttachmentFormatting.contentType(mimeType: "text/plain; charset=utf-8", name: "console.log"), .plainText)
        XCTAssertEqual(AttachmentFormatting.contentType(mimeType: "application/octet-stream", name: "notes.png"), .png)
        XCTAssertEqual(AttachmentFormatting.contentType(mimeType: nil, name: "noextension"), .data)
    }

    func testProviderBadgesAreNeutralInitials() {
        XCTAssertEqual(ProviderBadge.of("figma")?.initials, "Fg")
        XCTAssertEqual(ProviderBadge.of("google_sheets")?.name, "Google Sheets")
        XCTAssertNil(ProviderBadge.of("myspace"))
        XCTAssertNil(ProviderBadge.of(nil))
    }

    // MARK: Actions

    func testOpenWithPutsTheDefaultFirstThenSortsAndDedupes() {
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let acrobat = URL(fileURLWithPath: "/Applications/Adobe Acrobat.app")
        let zed = URL(fileURLWithPath: "/Applications/Zed.app")
        let apps = OpenWithApps.list([zed, acrobat, preview, zed], preferred: preview)
        XCTAssertEqual(apps.map(\.url), [preview, acrobat, zed])
        XCTAssertEqual(apps.map(\.isDefault), [true, false, false])
        XCTAssertEqual(OpenWithApps.displayName(preview), "Preview")
    }

    func testSavingToDownloadsNeverOverwrites() throws {
        let dir = try temporaryDirectory()
        XCTAssertEqual(AttachmentActions.uniqueURL(for: "a.pdf", in: dir).lastPathComponent, "a.pdf")
        try Data().write(to: dir.appendingPathComponent("a.pdf"))
        try Data().write(to: dir.appendingPathComponent("a 2.pdf"))
        XCTAssertEqual(AttachmentActions.uniqueURL(for: "a.pdf", in: dir).lastPathComponent, "a 3.pdf")
        try Data().write(to: dir.appendingPathComponent("README"))
        XCTAssertEqual(AttachmentActions.uniqueURL(for: "README", in: dir).lastPathComponent, "README 2")
    }

    #if canImport(Darwin)
    /// The quarantine xattr's value, nil when absent.
    private func quarantine(_ url: URL) -> String? {
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        _ = getxattr(url.path, "com.apple.quarantine", &buffer, size, 0, 0)
        return String(decoding: buffer, as: UTF8.self)
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testSavedCopiesKeepTheQuarantineFlagAndAreWritable() throws {
        let dir = try temporaryDirectory()
        // A cached download: quarantined, then read-only (AttachmentCache, mac#40).
        let cached = dir.appendingPathComponent("cached.pdf")
        try Data("pdf".utf8).write(to: cached)
        Quarantine.mark(cached)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: cached.path)
        let flag = try XCTUnwrap(quarantine(cached), "the test file isn't quarantined")

        let fresh = dir.appendingPathComponent("Saved.pdf")
        try AttachmentActions.copyOut(cached, to: fresh)
        XCTAssertEqual(quarantine(fresh), flag, "a new copy lost the quarantine flag")
        XCTAssertEqual(try mode(fresh), 0o644)

        // Save As over an existing, unquarantined file of the user's.
        let existing = dir.appendingPathComponent("Existing.pdf")
        try Data("old".utf8).write(to: existing)
        try AttachmentActions.copyOut(cached, to: existing)
        XCTAssertEqual(quarantine(existing), flag, "a replaced copy lost the quarantine flag")
        XCTAssertEqual(try mode(existing), 0o644)
        XCTAssertEqual(try Data(contentsOf: existing), Data("pdf".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }, [], "staged copy left behind")
    }
    #endif

    // MARK: Paste and drop

    private func scratchPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AttachmentAppTests-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        return pasteboard
    }

    private func smallImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return image
    }

    func testPastingFilesAttachesThemAsTheyAre() throws {
        let dir = try temporaryDirectory()
        let report = dir.appendingPathComponent("report.pdf")
        try Data("pdf".utf8).write(to: report)
        let pasteboard = scratchPasteboard()
        pasteboard.writeObjects([report as NSURL, dir as NSURL])
        // Finder also puts the names on the clipboard as text; the files still win. Folders are left out.
        pasteboard.setString("report.pdf", forType: .string)
        XCTAssertEqual(AttachmentPaste.files(from: pasteboard), [AttachmentInputFile(url: report)])
    }

    func testPastingAnImageMakesAPastedImageFileWeDeleteLater() throws {
        let pasteboard = scratchPasteboard()
        pasteboard.writeObjects([smallImage()])
        let files = try XCTUnwrap(AttachmentPaste.files(from: pasteboard))
        XCTAssertEqual(files.count, 1)
        let pasted = try XCTUnwrap(files.first)
        addTeardownBlock { try? FileManager.default.removeItem(at: pasted.url) }
        XCTAssertTrue(pasted.deletesFile)
        XCTAssertTrue(pasted.name?.hasPrefix("Pasted image ") == true)
        XCTAssertEqual(pasted.url.pathExtension, "png")
        // A random name in one flat folder: deleting the file after its upload leaves nothing behind.
        XCTAssertEqual(pasted.url.deletingLastPathComponent().standardizedFileURL, TempFiles.folder.standardizedFileURL)
        let data = try Data(contentsOf: pasted.url)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "not a PNG")
    }

    func testRichTextWithAnImageStaysATextPaste() {
        let pasteboard = scratchPasteboard()
        pasteboard.writeObjects([smallImage()])
        pasteboard.setString("Some copied paragraph", forType: .string)
        XCTAssertNil(AttachmentPaste.files(from: pasteboard))

        let textOnly = scratchPasteboard()
        textOnly.setString("hello", forType: .string)
        XCTAssertNil(AttachmentPaste.files(from: textOnly))
    }

    func testPastedImageNamesLookLikeScreenshots() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9, minute: 5, second: 3))!
        XCTAssertEqual(AttachmentPaste.stamp(date), "2026-10-26 at 09.05.03")
    }

    @MainActor
    func testDroppedFoldersAreLeftOut() async throws {
        let dir = try temporaryDirectory()
        let notes = dir.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: notes)
        let folder = dir.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dropped = await AttachmentDrop.files(from: [NSItemProvider(object: notes as NSURL), NSItemProvider(object: folder as NSURL)])
        XCTAssertEqual(dropped.files.map { $0.url.standardizedFileURL }, [notes.standardizedFileURL])
        XCTAssertEqual(dropped.skipped, 1)
    }

    @MainActor
    func testPromisedDropsAreCopiedToOurOwnTempFile() async throws {
        // Mail, Photos and Safari drag file promises: no file URL, a file that exists only in the callback.
        let source = try temporaryDirectory().appendingPathComponent("IMG_0001")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
        let promise = NSItemProvider()
        promise.suggestedName = "Holiday"
        promise.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { done in
            done(source, false, nil)
            return nil
        }
        let text = NSItemProvider(object: "just some text" as NSString)
        let dropped = await AttachmentDrop.files(from: [promise, text])
        XCTAssertEqual(dropped.files.count, 1, "text stays text")
        let file = try XCTUnwrap(dropped.files.first)
        addTeardownBlock { try? FileManager.default.removeItem(at: file.url) }
        XCTAssertEqual(file.name, "Holiday.png")
        XCTAssertTrue(file.deletesFile)
        XCTAssertEqual(file.url.deletingLastPathComponent().standardizedFileURL, TempFiles.folder.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: file.url), try Data(contentsOf: source))
    }

    func testPasteShortcutIsCommandVOnly() throws {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: 9))
        }
        XCTAssertTrue(PasteCatcher.CatcherView.isPaste(try key("v", .command)))
        XCTAssertFalse(PasteCatcher.CatcherView.isPaste(try key("v", [.command, .shift])))
        XCTAssertFalse(PasteCatcher.CatcherView.isPaste(try key("v", [])))
        XCTAssertFalse(PasteCatcher.CatcherView.isPaste(try key("c", .command)))
        // Caps Lock (and the fn/numeric-pad flags) don't stop ⌘V.
        XCTAssertTrue(PasteCatcher.CatcherView.isPaste(try key("V", [.command, .capsLock])))
        XCTAssertTrue(PasteCatcher.CatcherView.isPaste(try key("v", [.command, .function])))
        XCTAssertFalse(PasteCatcher.CatcherView.isPaste(try key("v", [.command, .option])))
    }

    @MainActor
    func testThePasteCatcherNeverTakesClicksOrAccessibilityFocus() {
        // It sits in the composer's background; an AppKit view there hit-tests before SwiftUI content.
        let view = PasteCatcher.CatcherView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        XCTAssertNil(view.hitTest(NSPoint(x: 150, y: 50)))
        XCTAssertFalse(view.isAccessibilityElement())
    }

    // MARK: Session

    @MainActor
    func testDraftsGoOnlyWhenNoPlaceShowsTheTaskAnyMore() async throws {
        let session = AppBootstrap.makeSession(arguments: ["-UITestFakeAPI"])
        await session.start()
        let scope = try XCTUnwrap(session.scope)
        let store = scope.taskDetail(DemoIDs.taskWithAttachments)
        await store.load()
        let composer = store.composer
        let other = scope.taskDetail("50000000-0000-4000-8000-000000000002").composer   // another task's composer
        let note = try temporaryDirectory().appendingPathComponent("note.txt")
        try Data("draft".utf8).write(to: note)
        XCTAssertTrue(composer.attach(fileAt: note))
        let finished = await waitUntil { composer.attachments.first?.isFinished == true }
        XCTAssertTrue(finished, "draft didn't finish: \(composer.attachments.map(\.state))")

        // The main window selects the task, and a task window shows it too.
        ComposerPresence.show(composer, owner: "main.test")
        ComposerPresence.show(composer, owner: "window.test")
        // Hiding the inspector changes nothing here: only the selection and windows drive this.
        ComposerPresence.show(other, owner: "main.test")
        await ComposerPresence.pendingDiscard?.value
        XCTAssertEqual(composer.attachments.count, 1, "the task window still shows the task")

        // Selected away and back before the discard ran: kept.
        ComposerPresence.show(nil, owner: "window.test")
        ComposerPresence.show(composer, owner: "main.test")
        await ComposerPresence.pendingDiscard?.value
        XCTAssertEqual(composer.attachments.count, 1, "shown again: kept")

        // Left everywhere: discarded.
        ComposerPresence.show(nil, owner: "main.test")
        await ComposerPresence.pendingDiscard?.value
        XCTAssertTrue(composer.attachments.isEmpty)
        XCTAssertEqual(ComposerPresence.count(composer), 0)
    }

    @MainActor
    func testADownloadFailureShowsOnlyOnItsOwnTask() async throws {
        let fake = FakeMekariAPI(signedInAs: "alice@example.com")
        let session = AppSession(settings: InMemoryServerSettings(serverURL: URL(string: "https://demo.invalid")),
                                 tokens: InMemoryTokenStore(), apiFactory: { _, _ in fake }, attachmentCache: .scratch())
        await session.start()
        let scope = try XCTUnwrap(session.scope)
        let store = scope.taskDetail(DemoIDs.taskWithAttachments)
        await store.load()
        let pdf = try XCTUnwrap(store.attachments.first { $0.id == DemoIDs.attachmentPDF })
        await fake.failNext(.download, with: APIError(code: .internal, status: 500, message: "Disk on fire"))
        let url = await AttachmentErrors.shared.download(pdf, files: scope.attachmentFiles)
        XCTAssertNil(url)
        XCTAssertEqual(AttachmentErrors.shared.error(for: DemoIDs.taskWithAttachments)?.message, "Disk on fire")
        XCTAssertNil(scope.attachmentFiles.lastError, "moved off the workspace-wide error")
        XCTAssertNil(AttachmentErrors.shared.error(for: "50000000-0000-4000-8000-000000000099"), "other tasks stay clear")
        AttachmentErrors.shared.clear(taskID: DemoIDs.taskWithAttachments)
    }

    @MainActor
    func testSignOutEmptiesTheAttachmentCache() async throws {
        let session = AppBootstrap.makeSession(arguments: ["-UITestFakeAPI"])
        await session.start()
        let scope = try XCTUnwrap(session.scope)
        let store = scope.taskDetail(DemoIDs.taskWithAttachments)
        await store.load()
        let png = try XCTUnwrap(store.attachments.first { $0.id == DemoIDs.attachmentPNG })
        let local = await scope.attachmentFiles.file(for: png)
        let file = try XCTUnwrap(local, "download failed: \(String(describing: scope.attachmentFiles.lastError))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        await session.signOut()
        let cache = session.attachmentCache
        let wiped = await waitUntil { await cache.diskUsage == 0 && !FileManager.default.fileExists(atPath: file.path) }
        XCTAssertTrue(wiped, "the cache still has files after sign-out")
    }
}
