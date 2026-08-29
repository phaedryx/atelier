// ABOUTME: Tests for the CodingHarness enum.
// ABOUTME: Validates raw values, display metadata, and Codable stability.

@testable import Atelier
import XCTest

final class CodingHarnessTests: XCTestCase {
    func testRawValuesAreStable() {
        // Raw values persist in UserDefaults; changing them breaks stored workstreams.
        XCTAssertEqual(CodingHarness.claudeCode.rawValue, "claudeCode")
    }

    func testDecodeFromRawValue() {
        XCTAssertEqual(CodingHarness(rawValue: "claudeCode"), .claudeCode)
        XCTAssertNil(CodingHarness(rawValue: "unknown"))
    }

    func testCLINames() {
        XCTAssertEqual(CodingHarness.claudeCode.cliName, "claude")
    }

    func testAllCases() {
        XCTAssertEqual(CodingHarness.allCases, [.claudeCode])
    }

    /// Blobs written while OpenCode was supported must still load.
    func testRetiredHarnessFallsBackToClaudeCode() {
        XCTAssertEqual(CodingHarness.fromPersisted("opencode"), .claudeCode)
        XCTAssertEqual(CodingHarness.fromPersisted("unknown"), .claudeCode)
        XCTAssertEqual(CodingHarness.fromPersisted(nil), .claudeCode)
        XCTAssertEqual(CodingHarness.fromPersisted("claudeCode"), .claudeCode)
    }

    func testInstallURLsAreValid() {
        for harness in CodingHarness.allCases {
            XCTAssertNotNil(URL(string: harness.installURL.absoluteString))
        }
    }

    func testCodableRoundTrip() throws {
        for harness in CodingHarness.allCases {
            let data = try JSONEncoder().encode(harness)
            let decoded = try JSONDecoder().decode(CodingHarness.self, from: data)
            XCTAssertEqual(decoded, harness)
        }
    }
}
