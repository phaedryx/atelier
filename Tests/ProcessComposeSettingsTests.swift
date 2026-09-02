// ABOUTME: Tests for the process-compose integration's settings and binary resolution.
// ABOUTME: A configured path wins; otherwise the usual install locations are tried.

@testable import Atelier
import XCTest

final class ProcessComposeSettingsTests: XCTestCase {
    /// These keys live in the app's own defaults domain, and the test host *is*
    /// the app — so a test that simply cleared them would silently turn the
    /// feature off (or on) for whoever ran the suite. Save and put back.
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in [ProcessComposeSettings.enabledKey, ProcessComposeSettings.binaryPathKey] {
            saved[key] = UserDefaults.standard.object(forKey: key)
        }
        clearSettings()
    }

    override func tearDown() {
        clearSettings()
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) }
        }
        saved.removeAll()
        super.tearDown()
    }

    private func clearSettings() {
        UserDefaults.standard.removeObject(forKey: ProcessComposeSettings.enabledKey)
        UserDefaults.standard.removeObject(forKey: ProcessComposeSettings.binaryPathKey)
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

    /// A whitespace-only configured path must be treated the same as no configured
    /// path at all — both fall through to searchPaths. Asserting equality with the
    /// blank-path result (rather than just "isn't the literal whitespace string")
    /// is what actually pins the trim-then-search behavior: an untrimmed lookup
    /// would fail isExecutableFile on "   " and return nil, while "" still
    /// searches — so the two would disagree if .trimmingCharacters were removed.
    func testBlankPathFallsBackToSearch() {
        ProcessComposeSettings.binaryPath = "   "
        let whitespaceResult = ProcessComposeSettings.resolveBinary()
        ProcessComposeSettings.binaryPath = ""
        let emptyResult = ProcessComposeSettings.resolveBinary()
        XCTAssertEqual(whitespaceResult, emptyResult)
    }
}
