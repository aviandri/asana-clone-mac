import AppKit
import XCTest

/// Attachment flows (SPEC-MAC §8) against FakeMekariAPI: the seeded files on "Fix login redirect" (a PNG
/// and a text file by others, a PDF and a LINK by alice), Quick Look, Open With, delete, and ⌘V of an image
/// into the comment composer. Drag and drop from Finder can't be driven from XCUITest; the drop parsing
/// is covered in AttachmentAppTests.
final class AttachmentUITests: XCTestCase {
    private let fixLogin = "50000000-0000-4000-8000-000000000001"
    private let png = "a0000000-0000-4000-8000-000000000001"   // login-redirect.png
    private let pdf = "a0000000-0000-4000-8000-000000000002"   // SSO flow.pdf (alice's)

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func waitForNonExistence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Launches against the fake API and opens "Fix login redirect" in the inspector.
    private func launchIntoTask() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFakeAPI", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        // As in AppFlowUITests.launch(): a slow first window, or one restored closed, comes back from the Window menu.
        if !element(app, "sidebar.myTasks").waitForExistence(timeout: 20) {
            let item = app.menuBars.menuBarItems["Window"].menuItems["Mekari Project"]
            if item.exists {
                app.menuBars.menuBarItems["Window"].click()
                item.click()
            }
        }
        app.activate()
        let row = element(app, "task.row.\(fixLogin)")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "My Tasks row missing")
        row.click()
        XCTAssertTrue(element(app, "attachments.section").waitForExistence(timeout: 10), "attachments section missing")
        return app
    }

    @MainActor
    func testSeededAttachmentsShowInTheInspectorAndUnderTheComment() {
        let app = launchIntoTask()
        for id in [png, pdf, "a0000000-0000-4000-8000-000000000003", "a0000000-0000-4000-8000-000000000004"] {
            XCTAssertTrue(element(app, "attachment.tile.\(id)").waitForExistence(timeout: 5), "tile \(id) missing")
        }
        // bob's comment carries returnTo.png: it is in the grid and under the comment.
        let commentImage = app.descendants(matching: .any).matching(identifier: "attachment.tile.a0000000-0000-4000-8000-000000000005")
        XCTAssertTrue(commentImage.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(commentImage.count, 2, "the comment's image should show in the grid and under the comment")
    }

    @MainActor
    func testSpaceOnASelectedFileOpensQuickLook() {
        let app = launchIntoTask()
        let tile = element(app, "attachment.tile.\(png)")
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.click()
        app.typeKey(" ", modifierFlags: [])
        // The panel's window is titled "Quick Look" (the file name is inside it).
        let panel = app.windows["Quick Look"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Quick Look didn't open: \(app.windows.debugDescription)")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(of: panel, timeout: 5), "Space didn't close Quick Look")
    }

    @MainActor
    func testOpenWithListsTheDefaultAppAndOther() {
        let app = launchIntoTask()
        let tile = element(app, "attachment.tile.\(pdf)")
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.rightClick()
        let openWith = app.menuItems["Open With"]
        XCTAssertTrue(openWith.waitForExistence(timeout: 5), "no Open With item")
        openWith.hover()
        XCTAssertTrue(app.menuItems["Other…"].waitForExistence(timeout: 5), "Open With has no Other…")
        let defaults = app.menuItems.matching(NSPredicate(format: "title ENDSWITH ' (default)'"))
        XCTAssertGreaterThanOrEqual(defaults.count, 1, "no default app for a PDF: \(app.menuItems.debugDescription)")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testDeletingAnAttachmentAsksFirstThenRemovesIt() {
        let app = launchIntoTask()
        let tile = element(app, "attachment.tile.\(pdf)")
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.rightClick()
        let delete = app.menuItems["Delete…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "alice uploaded the PDF, so she can delete it")
        delete.click()
        // The sheet's button, not the Touch Bar's copy of it.
        let inSheet = app.sheets.buttons["Delete"].firstMatch
        let inDialog = app.dialogs.buttons["Delete"].firstMatch
        let confirm = inSheet.waitForExistence(timeout: 5) ? inSheet : inDialog
        XCTAssertTrue(confirm.waitForExistence(timeout: 2), "no confirmation: \(app.windows.debugDescription)")
        confirm.click()
        XCTAssertTrue(waitForNonExistence(of: tile, timeout: 5), "the PDF is still there")
    }

    @MainActor
    func testOthersFilesHaveNoDeleteForAnEditor() {
        let app = launchIntoTask()
        let tile = element(app, "attachment.tile.\(png)")
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.rightClick()
        XCTAssertTrue(app.menuItems["Quick Look"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Delete…"].exists, "admin's PNG isn't alice's to delete")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testPastingAnImageIntoTheComposerAddsAChipThatPostsWithTheComment() {
        let app = launchIntoTask()
        let field = element(app, "composer.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        // Real PNG bytes, not an NSImage: an image's data is promised and read from this (test) process
        // on demand, which is blocked in typeKey while the app asks for it.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(png, forType: .png))

        // A plain click: the ⌘V catcher once covered the composer ("not hittable" on macOS 15), so this also checks
        // that nothing sits over the field.
        XCTAssertTrue(field.isHittable, "something covers the comment field")
        field.click()
        app.typeKey("v", modifierFlags: .command)
        // The chip's container isn't an accessibility element of its own; its × button names the file.
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove Pasted image '")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no finished chip after ⌘V: \(element(app, "task.inspector").debugDescription)")
        let send = element(app, "composer.send")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: send)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed, "Comment stayed disabled after the upload")
        XCTAssertTrue(send.isHittable, "something covers the Comment button")
        send.click()
        XCTAssertTrue(waitForNonExistence(of: chip, timeout: 10), "the chip didn't go with the comment")
    }
}
