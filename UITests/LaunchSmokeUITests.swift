import XCTest

/// XCUITest smoke (SPEC-MAC §6): launch against FakeMekariAPI and find the sidebar.
final class LaunchSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchWithFakeAPIShowsMyTasks() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFakeAPI"]
        app.launch()

        // -UITestFakeAPI boots FakeMekariAPI signed in as alice (AppBootstrap), straight into the main window.
        XCTAssertTrue(
            app.descendants(matching: .any)["sidebar.myTasks"].waitForExistence(timeout: 10),
            "no element with accessibilityIdentifier sidebar.myTasks"
        )
    }
}
