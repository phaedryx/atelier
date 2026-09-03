// ABOUTME: Tests for Shortcut.StoryID.parse, which reads a story id from user input.
// ABOUTME: The new-workstream Shortcut dialog accepts a bare id, an sc- prefix, or a story URL.

@testable import Atelier
import XCTest

final class ShortcutStoryIDTests: XCTestCase {
    func testParsesBareDigits() {
        XCTAssertEqual(Shortcut.StoryID.parse("17411"), 17411)
    }

    func testParsesScPrefix() {
        XCTAssertEqual(Shortcut.StoryID.parse("sc-17411"), 17411)
    }

    func testScPrefixIsCaseInsensitive() {
        XCTAssertEqual(Shortcut.StoryID.parse("SC-17411"), 17411)
    }

    func testParsesStoryURL() {
        XCTAssertEqual(Shortcut.StoryID.parse("https://app.shortcut.com/sixfifty/story/17411"), 17411)
    }

    func testParsesStoryURLWithSlug() {
        let input = "https://app.shortcut.com/sixfifty/story/17411/org-import-run-card-reads-as-nothing-happened"
        XCTAssertEqual(Shortcut.StoryID.parse(input), 17411)
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(Shortcut.StoryID.parse("  17411  "), 17411)
        XCTAssertEqual(Shortcut.StoryID.parse("\tsc-17411\n"), 17411)
    }

    func testRejectsEmptyInput() {
        XCTAssertNil(Shortcut.StoryID.parse(""))
        XCTAssertNil(Shortcut.StoryID.parse("   "))
    }

    func testRejectsPlainWorkstreamNames() {
        // These are ordinary branch names a user might type into the other dialog;
        // none should be mistaken for a story id.
        for input in ["merge-quick-pipe", "feat/foo", "abc", "sc-", "sc-abc", "release-2"] {
            XCTAssertNil(Shortcut.StoryID.parse(input), "expected \(input) to be rejected")
        }
    }

    func testRejectsNonStoryShortcutURLs() {
        XCTAssertNil(Shortcut.StoryID.parse("https://app.shortcut.com/sixfifty/epic/3915"))
        XCTAssertNil(Shortcut.StoryID.parse("https://app.shortcut.com/sixfifty/iteration/17032"))
    }

    func testRejectsZeroAndNegative() {
        // Story public ids are positive; 0 and negatives are malformed input, not ids.
        XCTAssertNil(Shortcut.StoryID.parse("0"))
        XCTAssertNil(Shortcut.StoryID.parse("-5"))
        XCTAssertNil(Shortcut.StoryID.parse("sc-0"))
    }
}
