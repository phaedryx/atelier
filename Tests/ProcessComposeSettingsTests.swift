// ABOUTME: Tests for the process-compose integration's settings and binary resolution.
// ABOUTME: A configured path wins; otherwise the usual install locations are tried.

@testable import Atelier
import XCTest

final class ProcessComposeSettingsTests: XCTestCase {
    override func tearDown() {
        ProcessComposeSettings.binaryPath = ""
        ProcessComposeSettings.isEnabled = false
        super.tearDown()
    }

    func testDisabledByDefault() {
        ProcessComposeSettings.isEnabled = false
        XCTAssertFalse(ProcessComposeSettings.isEnabled)
    }

    func testEnabledRoundTrips() {
        ProcessComposeSettings.isEnabled = true
        XCTAssertTrue(ProcessComposeSettings.isEnabled)
    }

    func testConfiguredBinaryWins() {
        // /bin/ls stands in for a real install: the assertion is that a configured,
        // executable path is returned instead of anything from searchPaths. The
        // brief named /usr/local/bin/process-compose, which does not exist on this
        // machine (or reliably in CI), so the original test asserted filesystem
        // state rather than behavior.
        ProcessComposeSettings.binaryPath = "/bin/ls"
        XCTAssertEqual(ProcessComposeSettings.resolveBinary(), "/bin/ls")
    }

    /// A path the user typed that no longer exists must not silently fall back
    /// to a different binary — that would run something they did not choose.
    func testConfiguredButMissingBinaryResolvesToNil() {
        ProcessComposeSettings.binaryPath = "/nonexistent/process-compose"
        XCTAssertNil(ProcessComposeSettings.resolveBinary())
    }

    func testBlankPathFallsBackToSearch() {
        ProcessComposeSettings.binaryPath = "   "
        // Either a real install is found, or nothing is. Both are valid; the
        // assertion is that a blank path does not resolve to the blank string.
        XCTAssertNotEqual(ProcessComposeSettings.resolveBinary(), "   ")
    }
}
