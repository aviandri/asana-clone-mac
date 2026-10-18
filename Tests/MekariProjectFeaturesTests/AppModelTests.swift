import Foundation
import MekariProjectKit
import Observation
import XCTest
@testable import MekariProjectFeatures

final class AppModelTests: XCTestCase {
    // Tests of @MainActor models are `async` + `@MainActor` per method: on Linux, XCTest can't call
    // a synchronous test of a @MainActor class (see README).
    @MainActor
    func testConnectUpdatesGreetingAndNotifiesObservers() async {
        let model = AppModel()
        XCTAssertEqual(model.greeting, "Hello from Mekari Project")

        let changed = expectation(description: "server change observed")
        withObservationTracking { _ = model.server } onChange: { changed.fulfill() }
        model.connect(to: ServerConfiguration(serverURL: URL(string: "https://project.example.com")!))

        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(model.greeting, "Hello from Mekari Project (project.example.com)")
    }
}
