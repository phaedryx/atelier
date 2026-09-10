// ABOUTME: Tests for ContextMeter's token formatting and the combined
// ABOUTME: capacity/quality band selection.

@testable import Atelier
import XCTest

final class ContextMeterTests: XCTestCase {
    // MARK: - Token formatting

    func testCompactTokenCountBoundaries() {
        XCTAssertEqual(ContextMeter.compactTokenCount(0), "0")
        XCTAssertEqual(ContextMeter.compactTokenCount(999), "999")
        XCTAssertEqual(ContextMeter.compactTokenCount(1_000), "1.0k")
        XCTAssertEqual(ContextMeter.compactTokenCount(12_340), "12.3k")
        XCTAssertEqual(ContextMeter.compactTokenCount(145_234), "145k")
        XCTAssertEqual(ContextMeter.compactTokenCount(999_999), "999k")
        XCTAssertEqual(ContextMeter.compactTokenCount(1_000_000), "1.0M")
        XCTAssertEqual(ContextMeter.compactTokenCount(1_234_567), "1.2M")
        // Defensive: negative counts clamp to zero.
        XCTAssertEqual(ContextMeter.compactTokenCount(-5), "0")
    }

    // MARK: - Token count: quality only

    private let caution = ContextLimits.qualityCautionThreshold
    private let critical = ContextLimits.qualityCriticalThreshold

    func testTokenCountIsUncoloredWhileHealthy() {
        XCTAssertNil(ContextMeter.qualityBand(usedTokens: 0))
        XCTAssertNil(ContextMeter.qualityBand(usedTokens: 106_000))
        // One token under caution is still healthy.
        XCTAssertNil(ContextMeter.qualityBand(usedTokens: caution - 1))
    }

    func testCautionThresholdTurnsTheTokenCountOrange() {
        XCTAssertEqual(ContextMeter.qualityBand(usedTokens: caution), 3)
        XCTAssertEqual(ContextMeter.qualityBand(usedTokens: 250_000), 3)
        XCTAssertEqual(ContextMeter.qualityBand(usedTokens: critical - 1), 3)
    }

    func testCriticalThresholdTurnsTheTokenCountRed() {
        XCTAssertEqual(ContextMeter.qualityBand(usedTokens: critical), 4)
        XCTAssertEqual(ContextMeter.qualityBand(usedTokens: 900_000), 4)
    }

    /// Quality reads the absolute count, so it says the same thing about 250k
    /// tokens whether they nearly fill a 200k window or take a quarter of a 1M
    /// one — the window size is the bar's business, not the number's.
    func testQualityIgnoresTheWindowSize() {
        XCTAssertEqual(ContextMeter.qualityBand(usedTokens: 250_000), 3)
        XCTAssertNil(ContextMeter.qualityBand(usedTokens: 190_000))
    }

    /// The two channels are independent: a nearly full small window is a red
    /// bar with an uncolored count, and a roomy window past caution is a blue
    /// bar with an orange count.
    func testTheTwoChannelsAreIndependent() {
        // 190k of a 200k window: 95% capacity, under the quality threshold.
        XCTAssertEqual(MeterBand.band(percentUsed: 95), 4)
        XCTAssertNil(ContextMeter.qualityBand(usedTokens: 190_000))
        // 250k of a 1M window: a quarter full, well into the decay zone.
        XCTAssertEqual(MeterBand.band(percentUsed: 25), 1)
        XCTAssertEqual(ContextMeter.qualityBand(usedTokens: 250_000), 3)
    }
}
