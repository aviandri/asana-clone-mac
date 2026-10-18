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
}
