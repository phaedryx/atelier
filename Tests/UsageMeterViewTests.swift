// ABOUTME: Tests for the sidebar usage meter's color banding.

@testable import Atelier
import SwiftUI
import XCTest

final class UsageMeterViewTests: XCTestCase {
    func testBandBoundaries() {
        XCTAssertEqual(UsageMeterView.band(percentUsed: 0), 0)
        XCTAssertEqual(UsageMeterView.band(percentUsed: 19), 0)
        XCTAssertEqual(UsageMeterView.band(percentUsed: 20), 1)
        XCTAssertEqual(UsageMeterView.band(percentUsed: 39), 1)
        XCTAssertEqual(UsageMeterView.band(percentUsed: 40), 2)
        XCTAssertEqual(UsageMeterView.band(percentUsed: 59), 2)
        XCTAssertEqual(UsageMeterView.band(percentUsed: 60), 3)
        XCTAssertEqual(UsageMeterView.band(percentUsed: 79), 3)
        XCTAssertEqual(UsageMeterView.band(percentUsed: 80), 4)
        XCTAssertEqual(UsageMeterView.band(percentUsed: 100), 4)
    }

    func testBandColorsRunBlueToRed() {
        XCTAssertEqual(UsageMeterView.bandColor(0), .blue)
        XCTAssertEqual(UsageMeterView.bandColor(1), .green)
        XCTAssertEqual(UsageMeterView.bandColor(2), .yellow)
        XCTAssertEqual(UsageMeterView.bandColor(3), .orange)
        XCTAssertEqual(UsageMeterView.bandColor(4), .red)
    }

    func testBandColorClampsOutOfRangeIndexes() {
        XCTAssertEqual(UsageMeterView.bandColor(-1), .blue)
        XCTAssertEqual(UsageMeterView.bandColor(99), .red)
    }
}
