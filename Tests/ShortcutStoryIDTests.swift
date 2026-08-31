// ABOUTME: Tests for ShortcutStoryID.parse, which reads a story id from user input.
// ABOUTME: The new-workstream Shortcut dialog accepts a bare id, an sc- prefix, or a story URL.

@testable import Atelier
import XCTest

final class ShortcutStoryIDTests: XCTestCase {
    func testParsesBareDigits() {
        XCTAssertEqual(ShortcutStoryID.parse("17411"), 17411)
    }

    func testParsesScPrefix() {
        XCTAssertEqual(ShortcutStoryID.parse("sc-17411"), 17411)
    }

    func testScPrefixIsCaseInsensitive() {
        XCTAssertEqual(ShortcutStoryID.parse("SC-17411"), 17411)
    }

    func testParsesStoryURL() {
        XCTAssertEqual(ShortcutStoryID.parse("https://app.shortcut.com/sixfifty/story/17411"), 17411)
    }

    func testParsesStoryURLWithSlug() {
        let input = "https://app.shortcut.com/sixfifty/story/17411/org-import-run-card-reads-as-nothing-happened"
        XCTAssertEqual(ShortcutStoryID.parse(input), 17411)
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(ShortcutStoryID.parse("  17411  "), 17411)
        XCTAssertEqual(ShortcutStoryID.parse("\tsc-17411\n"), 17411)
    }

    func testRejectsEmptyInput() {
        XCTAssertNil(ShortcutStoryID.parse(""))
        XCTAssertNil(ShortcutStoryID.parse("   "))
    }

    func testRejectsPlainWorkstreamNames() {
        // These are ordinary branch names a user might type into the other dialog;
        // none should be mistaken for a story id.
        for input in ["merge-quick-pipe", "feat/foo", "abc", "sc-", "sc-abc", "release-2"] {
            XCTAssertNil(ShortcutStoryID.parse(input), "expected \(input) to be rejected")
        }
    }

    func testRejectsNonStoryShortcutURLs() {
        XCTAssertNil(ShortcutStoryID.parse("https://app.shortcut.com/sixfifty/epic/3915"))
        XCTAssertNil(ShortcutStoryID.parse("https://app.shortcut.com/sixfifty/iteration/17032"))
    }

    func testRejectsZeroAndNegative() {
        // Story public ids are positive; 0 and negatives are malformed input, not ids.
        XCTAssertNil(ShortcutStoryID.parse("0"))
        XCTAssertNil(ShortcutStoryID.parse("-5"))
        XCTAssertNil(ShortcutStoryID.parse("sc-0"))
    }
}
