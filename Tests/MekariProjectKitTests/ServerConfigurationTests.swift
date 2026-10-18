import Foundation
import XCTest
@testable import MekariProjectKit

final class ServerConfigurationTests: XCTestCase {
    func testAPIBaseURLAppendsAPIV1() {
        for server in ["https://project.example.com", "https://project.example.com/"] {
            let config = ServerConfiguration(serverURL: URL(string: server)!)
            XCTAssertEqual(config.apiBaseURL.absoluteString, "https://project.example.com/api/v1")
            XCTAssertEqual(config.healthURL.absoluteString, "https://project.example.com/health")
        }
    }
}
