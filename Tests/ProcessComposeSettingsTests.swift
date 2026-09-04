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
        for key in [ProcessCompose.Settings.enabledKey, ProcessCompose.Settings.binaryPathKey] {
            saved[key] = UserDefaults.standard.object(forKey: key)
        }
        clearSettings()
    }

    override func tearDown() {
        clearSettings()
        for (key, value) in saved {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        saved.removeAll()
        super.tearDown()
    }

    private func clearSettings() {
        UserDefaults.standard.removeObject(forKey: ProcessCompose.Settings.enabledKey)
        UserDefaults.standard.removeObject(forKey: ProcessCompose.Settings.binaryPathKey)
    }

    /// Reads the *default*, which means clearing the key rather than writing
    /// `false` into it first. The previous version assigned `false` and then
    /// asserted `false`, so it passed for any implementation — including one
    /// defaulting to `true`. That matters more here than in most places: this
    /// setting defaulting off is what makes a fresh project get no worktree
    /// setup, which is the load-bearing product decision on this branch.
    func testDisabledByDefault() {
        clearSettings()

        XCTAssertFalse(ProcessCompose.Settings.isEnabled)
    }

    /// Only `true` was written and read back, so a setter that ignored its argument
    /// passed. Both values have to round-trip.
    func testEnabledRoundTrips() {
        ProcessCompose.Settings.isEnabled = true
        XCTAssertTrue(ProcessCompose.Settings.isEnabled)

        ProcessCompose.Settings.isEnabled = false
        XCTAssertFalse(ProcessCompose.Settings.isEnabled)
    }

    func testConfiguredBinaryWins() {
        // /bin/ls stands in for a real install: the assertion is that a configured,
        // executable path is returned instead of anything from searchPaths. The
        // brief named /usr/local/bin/process-compose, which does not exist on this
        // machine (or reliably in CI), so the original test asserted filesystem
        // state rather than behavior.
        ProcessCompose.Settings.binaryPath = "/bin/ls"
        XCTAssertEqual(ProcessCompose.Settings.resolveBinary(), "/bin/ls")
    }

    /// A path the user typed that no longer exists must not silently fall back
    /// to a different binary — that would run something they did not choose.
    func testConfiguredButMissingBinaryResolvesToNil() {
        ProcessCompose.Settings.binaryPath = "/nonexistent/process-compose"
        XCTAssertNil(ProcessCompose.Settings.resolveBinary())
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
    /// returned; untrimmed, `isExecutableFile` fails on the padded string, and a
    /// configured-but-missing path returns nil rather than falling through to
    /// the search — so the result is nil whatever the host has installed.
    ///
    /// The blank-path half of the behaviour (fall through *to the search*) is
    /// deliberately still unasserted: it can only be proved on a host that has
    /// process-compose installed, and pinning it would mean adding a
    /// search-paths injection point to production for one test.
    func testAPaddedConfiguredPathIsTrimmedRatherThanTreatedAsMissing() {
        ProcessCompose.Settings.binaryPath = "  /bin/ls  "
        XCTAssertEqual(ProcessCompose.Settings.resolveBinary(), "/bin/ls")
    }

    /// A whitespace-only path is not a configured path: it must not be handed to
    /// `isExecutableFile` as-is, and it must never resolve to itself.
    ///
    /// `XCTAssertNotEqual(resolveBinary(), "   ")` held for `nil` too — which is what
    /// this returns on any host without process-compose in the three search paths —
    /// so it could not fail. Asserting that a blank path resolves *identically to an
    /// unset one* states the same contract and is load-bearing wherever the search
    /// can actually find something; CI installs process-compose for exactly that
    /// reason, so that is where this discriminates.
    func testAWhitespaceOnlyPathIsNeverReturned() {
        clearSettings()
        let unset = ProcessCompose.Settings.resolveBinary()

        ProcessCompose.Settings.binaryPath = "   "

        XCTAssertNotEqual(ProcessCompose.Settings.resolveBinary(), "   ")
        XCTAssertEqual(
            ProcessCompose.Settings.resolveBinary(),
            unset,
            "a blank path must fall through to the search, exactly as an unset one does"
        )
    }

    // MARK: - Configured path hygiene

    func testAcceptsAPathWithATrailingNewline() throws {
        // A path pasted out of a terminal carries one. `.whitespaces` does not
        // strip it, so the check ran against "<path>\n" and reported the binary
        // as gone — the one outcome `resolveBinary` documents it will not do
        // silently.
        let binary = try makeExecutable(named: "process-compose")
        ProcessCompose.Settings.binaryPath = binary + "\n"

        XCTAssertEqual(ProcessCompose.Settings.resolveBinary(), binary)
    }

    func testRejectsAConfiguredPathThatIsADirectory() throws {
        // `isExecutableFile` is true for a searchable directory, so pointing the
        // setting at /usr/local/bin instead of the binary inside it passed.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pc-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        ProcessCompose.Settings.binaryPath = directory.path

        XCTAssertNil(ProcessCompose.Settings.resolveBinary())
    }

    private func makeExecutable(named name: String) throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pc-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent(name)
        FileManager.default.createFile(
            atPath: binary.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        return binary.path
    }
}
