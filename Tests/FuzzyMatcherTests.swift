// ABOUTME: Tests for the palette's fuzzy scorer.
// ABOUTME: Pins subsequence matching, prefix/word-boundary bonuses, and case folding.

@testable import Atelier
import XCTest

final class FuzzyMatcherTests: XCTestCase {
    func testEmptyQueryMatchesEverything() {
        XCTAssertGreaterThan(FuzzyMatcher.score(query: "", candidate: "New Terminal"), 0)
    }

    func testNonSubsequenceScoresZero() {
        XCTAssertEqual(FuzzyMatcher.score(query: "xyz", candidate: "New Terminal"), 0)
        // Right letters, wrong order: still zero.
        XCTAssertEqual(FuzzyMatcher.score(query: "tn", candidate: "nt"), 0)
    }

    func testCaseInsensitive() {
        XCTAssertGreaterThan(FuzzyMatcher.score(query: "TERM", candidate: "new terminal"), 0)
    }

    func testPrefixBeatsInteriorMatch() {
        let prefix = FuzzyMatcher.score(query: "new", candidate: "New Terminal")
        let interior = FuzzyMatcher.score(query: "new", candidate: "Renew Terminal")
        XCTAssertGreaterThan(prefix, interior)
    }

    func testWordBoundaryBeatsMidWord() {
        let boundary = FuzzyMatcher.score(query: "t", candidate: "New Terminal")
        let midWord = FuzzyMatcher.score(query: "t", candidate: "Sweater")
        XCTAssertGreaterThan(boundary, midWord)
    }

    func testConsecutiveRunBeatsScattered() {
        let consecutive = FuzzyMatcher.score(query: "term", candidate: "Terminal")
        let scattered = FuzzyMatcher.score(query: "term", candidate: "The extra room")
        XCTAssertGreaterThan(consecutive, scattered)
    }
}
