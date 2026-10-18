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

        // The App shell PR (4) adds the sidebar and honours -UITestFakeAPI. Strict, so this test
        // fails with "expected failure but passed" once it does: then delete this line.
        XCTExpectFailure("sidebar.myTasks arrives with the App shell PR (4)", strict: true)
        XCTAssertTrue(
            app.descendants(matching: .any)["sidebar.myTasks"].waitForExistence(timeout: 10),
            "no element with accessibilityIdentifier sidebar.myTasks"
        )
    }
}
