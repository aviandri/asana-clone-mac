import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MekariProjectKit
import XCTest

/// Contract tests against a real, seeded backend (BE `npm run seed`). Skipped unless MP_BASE_URL is
/// set, e.g. `MP_BASE_URL=http://127.0.0.1:3000 swift test --filter ContractTests`.
/// The scaffold only checks /health and the cookie session flow from SPEC-MAC §4; the Kit and
/// Features PRs grow this into the full suite.
final class HealthAndLoginContractTests: XCTestCase {
    private var server: ServerConfiguration!
    private var session: URLSession!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["MP_BASE_URL"], let url = URL(string: base) else {
            throw XCTSkip("MP_BASE_URL not set; skipping contract tests")
        }
        server = ServerConfiguration(serverURL: url)
        // SPEC-MAC §4: no automatic cookie handling; the client carries `sid` itself.
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    func testHealth() async throws {
        let (_, response) = try await session.data(for: URLRequest(url: server.healthURL))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testLoginReturnsSidCookieThatAuthenticatesMe() async throws {
        let env = ProcessInfo.processInfo.environment
        let email = env["MP_EMAIL"] ?? "admin@example.com"
        let password = env["MP_PASSWORD"] ?? "password123"

        var login = URLRequest(url: server.apiBaseURL.appendingPathComponent("auth/login"))
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (_, loginResponse) = try await session.data(for: login)
        let http = try XCTUnwrap(loginResponse as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        let setCookie = try XCTUnwrap(http.value(forHTTPHeaderField: "Set-Cookie"), "login sets no cookie")
        let sid = try XCTUnwrap(
            setCookie.split(separator: ";").first.flatMap { pair -> String? in
                let parts = pair.split(separator: "=", maxSplits: 1)
                return parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces) == "sid" ? String(parts[1]) : nil
            },
            "no sid in Set-Cookie: \(setCookie)"
        )

        var me = URLRequest(url: server.apiBaseURL.appendingPathComponent("auth/me"))
        me.setValue("sid=\(sid)", forHTTPHeaderField: "Cookie")
        let (body, meResponse) = try await session.data(for: me)
        XCTAssertEqual((meResponse as? HTTPURLResponse)?.statusCode, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["email"] as? String, email)

        var anonymous = URLRequest(url: server.apiBaseURL.appendingPathComponent("auth/me"))
        anonymous.setValue(nil, forHTTPHeaderField: "Cookie")
        let (_, anonResponse) = try await session.data(for: anonymous)
        XCTAssertEqual((anonResponse as? HTTPURLResponse)?.statusCode, 401, "without the cookie /auth/me must be 401")
    }
}
