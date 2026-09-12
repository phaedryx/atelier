// ABOUTME: Tests how the process-compose binary is found, now that nothing configures it.
// ABOUTME: First match wins; a directory sitting where the binary should be is not a match.

@testable import Atelier
import XCTest

/// This file used to be about `atelier.processCompose.binaryPath` — six tests
/// covering trimming, a configured-but-missing path, a path that was really a
/// directory, and precedence over the search. The setting is gone:
/// process-compose is auto-detected, so all six described behaviour that no
/// longer exists.
///
/// What replaced them is the thing those tests deliberately left unasserted.
/// The old file's own comment declined to pin the search because "it can only
/// be proved on a host that has process-compose installed, and pinning it would
/// mean adding a search-paths injection point to production for one test" —
/// a fair trade while the search was the *fallback* behind a path the tests
/// could set. It is now the only resolution path there is, so declining the
/// seam would leave the whole of resolution unassertable on any host.
/// `resolveBinary(searchPaths:)` takes the list, defaulted, and these run
/// against a temp directory so they discriminate on every machine.
final class ProcessComposeSettingsTests: XCTestCase {
    func testReturnsTheFirstExecutableOnTheList() throws {
        let second = try makeExecutable(named: "process-compose")

        XCTAssertEqual(
            ProcessCompose.Settings.resolveBinary(
                searchPaths: ["/nonexistent/process-compose", second]
            ),
            second
        )
    }

    /// Order is precedence, not a set: an earlier hit wins even when a later one
    /// also exists. A `contains`-style implementation would pass the test above
    /// and fail this one.
    func testAnEarlierPathWinsOverALaterOne() throws {
        let first = try makeExecutable(named: "process-compose")
        let second = try makeExecutable(named: "process-compose")

        XCTAssertEqual(
            ProcessCompose.Settings.resolveBinary(searchPaths: [first, second]),
            first
        )
    }

    /// Nothing installed is nil, not a path that does not exist. `PhasePolicy`
    /// reads this nil as its binary precondition, and the Detected Tools row
    /// reads it as "not found".
    func testResolvesToNilWhenNothingOnTheListExists() {
        XCTAssertNil(ProcessCompose.Settings.resolveBinary(
            searchPaths: ["/nonexistent/process-compose", "/also/nonexistent"]
        ))
    }

    /// `isExecutableFile` is true for a *searchable directory* as well as for a
    /// program, so a directory named `process-compose` sitting on the search path
    /// would resolve and then fail at spawn time. This is the only surviving way
    /// to exercise that guard — it used to be reached by pointing the setting at
    /// a directory.
    func testADirectoryWhereTheBinaryShouldBeIsNotAMatch() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pc-bin-\(UUID().uuidString)")
            .appendingPathComponent("process-compose")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(ProcessCompose.Settings.resolveBinary(searchPaths: [directory.path]))
    }

    /// The default argument is the production list, so a caller that passes
    /// nothing searches the three documented locations. Asserted by agreement
    /// rather than by value: what matters is that the default is *that* list,
    /// and on a host without process-compose both sides are nil, which is still
    /// the same answer.
    func testTheDefaultIsTheDocumentedSearchPaths() {
        XCTAssertEqual(
            ProcessCompose.Settings.resolveBinary(),
            ProcessCompose.Settings.resolveBinary(searchPaths: ProcessCompose.Settings.searchPaths)
        )
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
