import MekariProjectFeatures
import XCTest
@testable import MekariProjectApp

/// Hosted unit tests for the app target. The scaffold only checks that the app module links Kit
/// and Features and that the bundle carries the identity from SPEC-MAC §2.
final class MekariProjectAppTests: XCTestCase {
    func testBundleIdentity() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.mekari.project")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Mekari Project")
        let schemes = (info["CFBundleURLTypes"] as? [[String: Any]])?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, ["mekariproject"])
        XCTAssertEqual(info["LSUIElement"] as? Bool, false)
    }

    @MainActor
    func testHelloViewUsesTheAppModel() {
        XCTAssertEqual(HelloView(model: AppModel()).model.greeting, "Hello from Mekari Project")
    }
}
