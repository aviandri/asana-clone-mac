import MekariProjectFeatures
import MekariProjectKit
import XCTest
@testable import MekariProjectApp

/// Hosted unit tests for the app target: bundle identity (SPEC-MAC §2), the UI-test bootstrap, and the
/// small presentation helpers. Business logic is tested in the Features package.
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
    func testUITestBootSignsInWithTheFakeAPI() async {
        let session = AppBootstrap.makeSession(arguments: ["-UITestFakeAPI"])
        await session.start()
        guard case .signedIn(let me) = session.state else { return XCTFail("expected signed in, got \(session.state)") }
        XCTAssertEqual(me.email, "alice@example.com")
        XCTAssertNotNil(session.scope)
    }

    @MainActor
    func testUITestBootCanStartSignedOut() async {
        let session = AppBootstrap.makeSession(arguments: ["-UITestFakeAPI", "-UITestSignedOut"])
        await session.start()
        XCTAssertEqual(session.state, .signedOut)
    }

    func testHexColors() {
        let c = HexColor.rgb("#E0257F")
        XCTAssertEqual(c?.r ?? 0, 224.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(c?.g ?? 0, 37.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(c?.b ?? 0, 127.0 / 255, accuracy: 0.0001)
        XCTAssertNotNil(HexColor.rgb("4186e0"))
        XCTAssertNil(HexColor.rgb("#xyz"))
        XCTAssertNil(HexColor.rgb("#12345"))
        XCTAssertTrue(HexColor.prefersDarkText(on: "#F1BD6C"))   // light yellow tile
        XCTAssertFalse(HexColor.prefersDarkText(on: "#651FFF"))  // deep violet tile
    }

    func testInitials() {
        XCTAssertEqual(Initials.of("Alice Johnson"), "AJ")
        XCTAssertEqual(Initials.of("bob"), "B")
        XCTAssertEqual(Initials.of("Ada Lovelace King"), "AL")
        XCTAssertEqual(Initials.of(""), "?")
    }

    func testDueLabels() {
        let today = LocalDate(year: 2026, month: 10, day: 18)
        let locale = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(Formatting.due(today, today: today, calendar: calendar, locale: locale), "Today")
        XCTAssertEqual(Formatting.due(today.adding(days: 1), today: today, calendar: calendar, locale: locale), "Tomorrow")
        XCTAssertEqual(Formatting.due(today.adding(days: -1), today: today, calendar: calendar, locale: locale), "Yesterday")
        XCTAssertEqual(Formatting.due(today.adding(days: 3), today: today, calendar: calendar, locale: locale), "Wednesday")
        XCTAssertEqual(Formatting.due(today.adding(days: 20), today: today, calendar: calendar, locale: locale), "Nov 7")
        XCTAssertEqual(Formatting.due(LocalDate(year: 2027, month: 1, day: 5), today: today, calendar: calendar, locale: locale), "Jan 5, 2027")
        XCTAssertTrue(Formatting.isOverdue(today.adding(days: -2), today: today))
        XCTAssertFalse(Formatting.isOverdue(today, today: today))
    }

    func testCommentTextRendersMentionsAsTokens() {
        let text = CommentText.attributed([.text("Thanks "), .mention(name: "Alice Johnson", userID: "u1"), .text(" **now**")])
        XCTAssertEqual(String(text.characters), "Thanks @Alice Johnson now")
    }
}
