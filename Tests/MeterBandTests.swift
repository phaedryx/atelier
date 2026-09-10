// ABOUTME: Tests for the shared five-band meter color scale used by the sidebar's
// ABOUTME: plan usage bars and workstream context bar.

@testable import Atelier
import SwiftUI
import XCTest

final class MeterBandTests: XCTestCase {
    func testBandBoundaries() {
        XCTAssertEqual(MeterBand.band(percentUsed: 0), 0)
        XCTAssertEqual(MeterBand.band(percentUsed: 19), 0)
        XCTAssertEqual(MeterBand.band(percentUsed: 20), 1)
        XCTAssertEqual(MeterBand.band(percentUsed: 39), 1)
        XCTAssertEqual(MeterBand.band(percentUsed: 40), 2)
        XCTAssertEqual(MeterBand.band(percentUsed: 59), 2)
        XCTAssertEqual(MeterBand.band(percentUsed: 60), 3)
        XCTAssertEqual(MeterBand.band(percentUsed: 79), 3)
        XCTAssertEqual(MeterBand.band(percentUsed: 80), 4)
        XCTAssertEqual(MeterBand.band(percentUsed: 100), 4)
    }

    func testBandClampsOutOfRangePercentages() {
        XCTAssertEqual(MeterBand.band(percentUsed: -10), 0)
        XCTAssertEqual(MeterBand.band(percentUsed: 250), 4)
    }

    func testBandColorsRunBlueToRed() {
        XCTAssertEqual(MeterBand.color(0), .blue)
        XCTAssertEqual(MeterBand.color(1), .green)
        XCTAssertEqual(MeterBand.color(2), .yellow)
        XCTAssertEqual(MeterBand.color(3), .orange)
        XCTAssertEqual(MeterBand.color(4), .red)
    }

    func testBandColorClampsOutOfRangeIndexes() {
        XCTAssertEqual(MeterBand.color(-1), .blue)
        XCTAssertEqual(MeterBand.color(99), .red)
    }
}
