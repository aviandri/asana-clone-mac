import XCTest

/// XCUITest flows beyond the launch smoke, against FakeMekariAPI (`-UITestFakeAPI`, signed in as alice).
/// IDs are FakeSeed's DemoIDs (the UI test target doesn't link Kit).
final class AppFlowUITests: XCTestCase {
    private let boardProject = "40000000-0000-4000-8000-000000000001"   // "Mobile App v2"
    private let fixLogin = "50000000-0000-4000-8000-000000000001"       // "Fix login redirect" (alice, overdue)

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFakeAPI"]
        app.launch()
        XCTAssertTrue(element(app, "sidebar.myTasks").waitForExistence(timeout: 10), "main window didn't appear")
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// `XCUIElement.waitForNonExistence(timeout:)` is Xcode 16+; this works on Xcode 15.4 too.
    private func waitForNonExistence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    @MainActor
    func testOpeningAProjectFromTheSidebarShowsItsTasks() {
        let app = launch()
        let project = element(app, "sidebar.project.\(boardProject)")
        XCTAssertTrue(project.waitForExistence(timeout: 10), "project missing from the sidebar")
        project.click()
        XCTAssertTrue(element(app, "task.row.\(fixLogin)").waitForExistence(timeout: 10), "project rows didn't load")
    }

    @MainActor
    func testSelectingATaskOpensTheInspector() {
        let app = launch()
        let row = element(app, "task.row.\(fixLogin)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "My Tasks row missing")
        row.click()
        XCTAssertTrue(element(app, "task.inspector").waitForExistence(timeout: 10), "inspector didn't open")
    }

    @MainActor
    func testSearchPaletteFindsATask() {
        let app = launch()
        app.typeKey("k", modifierFlags: .command)
        let field = element(app, "search.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "search palette didn't open")
        field.typeText("login")
        // The palette's own result row (the same title is also in My Tasks behind the sheet).
        XCTAssertTrue(element(app, "search.result.task.\(fixLogin)").waitForExistence(timeout: 10), "no search result in the palette")
    }

    @MainActor
    func testPaletteArrowKeysMoveTheSelection() {
        let app = launch()
        app.typeKey("k", modifierFlags: .command)
        let field = element(app, "search.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("mode") // "Offline mode for task list", "Dark mode QA pass"
        let results = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.task.'"))
        XCTAssertTrue(results.element(boundBy: 1).waitForExistence(timeout: 10), "expected two task results")
        XCTAssertTrue(results.element(boundBy: 0).isSelected, "first result starts selected")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(results.element(boundBy: 1).isSelected, "↓ didn't move the selection")
        XCTAssertFalse(results.element(boundBy: 0).isSelected)
    }

    /// The URL scheme path with the main window closed: SwiftUI must route it to the main Window
    /// (handlesExternalEvents), not an empty Task window, and open the task there.
    @MainActor
    func testDeepLinkWithTheMainWindowClosedOpensTheTask() throws {
        let app = launch()
        app.typeKey("w", modifierFlags: .command) // close the main window; the menu bar keeps the app alive
        let sidebar = element(app, "sidebar.myTasks")
        XCTAssertTrue(waitForNonExistence(of: sidebar, timeout: 5), "main window didn't close")

        app.open(try XCTUnwrap(URL(string: "mekariproject://task/\(fixLogin)")))
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "main window didn't reopen for the link")
        XCTAssertTrue(element(app, "task.inspector").waitForExistence(timeout: 10), "linked task not opened")
        XCTAssertFalse(app.staticTexts["Can't Open"].exists, "link reported no access")
        XCTAssertEqual(app.windows.count, 1, "the link opened an extra (Task) window")
    }

    /// rc1 QA S1: a CommandGroup anchored to a placement the app doesn't have is dropped silently,
    /// so check every command is actually in its menu.
    @MainActor
    func testEveryCommandIsInItsMenu() {
        let app = launch()
        let expected = [
            ("File", "Open Task in New Window"),
            ("File", "Open in Browser"),
            ("Edit", "Search…"),
            ("View", "Refresh"),
            ("Workspace", "Mekari"),
        ]
        for (menu, item) in expected {
            XCTAssertTrue(app.menuBars.menuBarItems[menu].menuItems[item].exists, "\(menu) → \(item) missing")
        }
        XCTAssertTrue(app.menuBars.menuItems["Sign Out"].exists, "app menu → Sign Out missing")
    }

    /// rc1 QA S1: ⇧⌘O through the real menu (Commands), for My Tasks and then a selected project.
    @MainActor
    func testOpenInBrowserShortcutOpensTheCurrentPage() {
        let app = launch()
        let file = app.menuBars.menuBarItems["File"]
        let item = file.menuItems["Open in Browser"]
        XCTAssertTrue(item.exists, "File → Open in Browser missing")
        XCTAssertTrue(item.isEnabled, "File → Open in Browser is disabled")
        let opened = element(app, "uitest.openedURL")
        app.typeKey("o", modifierFlags: [.command, .shift])
        if !opened.waitForExistence(timeout: 5) {
            // Tell "the shortcut isn't delivered" apart from "the command does nothing".
            file.click()
            item.click()
            XCTAssertTrue(opened.waitForExistence(timeout: 5), "File → Open in Browser did nothing (clicked)")
            XCTFail("⇧⌘O did nothing, but clicking the menu item worked")
        }
        // A macOS static text carries its string in `value` (its `label` is empty).
        let url = opened.value as? String ?? ""
        XCTAssertTrue(url.contains("/my-tasks") && url.contains("workspace="), url)

        let project = element(app, "sidebar.project.\(boardProject)")
        XCTAssertTrue(project.waitForExistence(timeout: 10), "project missing from the sidebar")
        project.click()
        app.typeKey("o", modifierFlags: [.command, .shift])
        let predicate = NSPredicate(format: "value CONTAINS %@", "/projects/\(boardProject)")
        let projectLink = XCTNSPredicateExpectation(predicate: predicate, object: opened)
        XCTAssertEqual(XCTWaiter().wait(for: [projectLink], timeout: 5), .completed, opened.value as? String ?? "")
    }
}
