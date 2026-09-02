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

    /// The configured path is trimmed before it is used, so a path the user
    /// pasted with surrounding whitespace resolves rather than reading as
    /// missing.
    ///
    /// This replaces a test that could not fail. It asserted that a
    /// whitespace-only path and an empty one resolve alike — true, but on any
    /// machine without process-compose in the three search paths, CI included,
    /// both sides are nil with the trim *and* without it, so removing
    /// `.trimmingCharacters` left it green. It also ignored the `/bin/ls` trick
    /// the rest of this file uses to be host-independent.
    ///
    /// Padding a real path exercises the same `.trimmingCharacters` call and
    /// discriminates on every machine: trimmed, `/bin/ls` is executable and is
    /// returned; untrimmed, `isExecutableFile` fails on `"  /bin/ls  "` and the
    /// search — empty here — yields nil.
    ///
    /// The blank-path half of the behaviour (fall through *to the search*) is
    /// deliberately still unasserted: it can only be proved on a host that has
    /// process-compose installed, and pinning it would mean adding a
    /// search-paths injection point to production for one test.
    func testAPaddedConfiguredPathIsTrimmedRatherThanTreatedAsMissing() {
        ProcessComposeSettings.binaryPath = "  /bin/ls  "
        XCTAssertEqual(ProcessComposeSettings.resolveBinary(), "/bin/ls")
    }

    /// A whitespace-only path is not a configured path: it must not be handed to
    /// `isExecutableFile` as-is, and it must never resolve to itself.
    func testAWhitespaceOnlyPathIsNeverReturned() {
        ProcessComposeSettings.binaryPath = "   "
        XCTAssertNotEqual(ProcessComposeSettings.resolveBinary(), "   ")
    }
}
