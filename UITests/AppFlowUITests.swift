import XCTest

/// XCUITest flows beyond the launch smoke, against FakeMekariAPI (`-UITestFakeAPI`, signed in as alice).
/// IDs are FakeSeed's DemoIDs (the UI test target doesn't link Kit).
final class AppFlowUITests: XCTestCase {
    private let boardProject = "40000000-0000-4000-8000-000000000001"   // "Mobile App v2"
    private let fixLogin = "50000000-0000-4000-8000-000000000001"       // "Fix login redirect" (alice, overdue)

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches against the fake API with the main window up and the app frontmost. On a busy real
    /// desktop the first window can be slow and another app can keep focus, so typeKey and menu
    /// clicks would fail ("is not foreground"); CI runners behave the same either way.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // No restored window state from earlier runs (e.g. the test that closes the main window).
        app.launchArguments = ["-UITestFakeAPI", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        let sidebar = element(app, "sidebar.myTasks")
        if !sidebar.waitForExistence(timeout: 20) {
            // Last resort: the Window menu lists the main window and reopens it.
            let item = app.menuBars.menuBarItems["Window"].menuItems["Mekari Project"]
            if item.exists {
                app.menuBars.menuBarItems["Window"].click()
                item.click()
            }
        }
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "main window didn't appear")
        app.activate()
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

    /// Waits until `field` has keyboard focus again (the add field takes it back on the next turn).
    private func waitForFocus(_ field: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        return XCTWaiter().wait(for: [focused], timeout: timeout) == .completed
    }

    private func openBoardProjectAsList(_ app: XCUIApplication) {
        element(app, "sidebar.project.\(boardProject)").click()
        // Mobile App v2 opens as a Board; switch to the List view (sections with inline add rows).
        let listMode = app.toolbars.descendants(matching: .any)["List"].firstMatch
        XCTAssertTrue(listMode.waitForExistence(timeout: 10), "List/Board picker missing")
        listMode.click()
    }

    /// rc1 QA crash: rapid inline Add task in My Tasks and in a project's List view. Return adds,
    /// clears the field and keeps focus for the next one.
    @MainActor
    func testRapidInlineAddTaskInMyTasksAndAProject() {
        let app = launch()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'task.row.'"))
        let field = element(app, "addTask.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "My Tasks add field missing")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let before = rows.count
        field.click()
        for n in 1...3 {
            XCTAssertTrue(waitForFocus(field), "add field lost focus before add \(n)")
            field.typeText("Quick task \(n)\r")
        }
        let added = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", before + 3), object: rows)
        XCTAssertEqual(XCTWaiter().wait(for: [added], timeout: 10), .completed, "My Tasks rows: \(rows.count), expected \(before + 3)")
        XCTAssertEqual(field.value as? String ?? "", "", "the field clears after adding")

        openBoardProjectAsList(app)
        let projectField = element(app, "addTask.field")
        XCTAssertTrue(projectField.waitForExistence(timeout: 10), "section add row missing")
        let projectBefore = rows.count
        projectField.click()
        for n in 1...3 {
            XCTAssertTrue(waitForFocus(projectField), "section add field lost focus before add \(n)")
            projectField.typeText("Section task \(n)\r")
        }
        let projectAdded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", projectBefore + 3), object: rows)
        XCTAssertEqual(XCTWaiter().wait(for: [projectAdded], timeout: 10), .completed, "project rows: \(rows.count), expected \(projectBefore + 3)")
    }

    /// rc1 QA crash: typing in an inline add field while the List updates around it (a task completed
    /// in the same project) must neither throw nor lose the typed text.
    @MainActor
    func testTypingInTheAddFieldWhileTheListUpdates() {
        let app = launch()
        openBoardProjectAsList(app)
        let field = element(app, "addTask.field")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "section add row missing")
        field.click()
        field.typeText("Typed while")
        let toggle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mark ' AND label ENDSWITH ' complete'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no task to complete")
        toggle.click() // the List updates (row restyled or removed) while the field holds a draft
        if !waitForFocus(field, timeout: 2) { field.click() }
        field.typeText(" rows change\r")
        XCTAssertTrue(waitForFocus(field), "add field didn't keep focus")
        XCTAssertEqual(field.value as? String ?? "", "", "the field clears after adding")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
