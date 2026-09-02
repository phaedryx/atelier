// ABOUTME: Tests for running a headless process-compose phase to completion.
// ABOUTME: Uses a real process-compose when present; skips cleanly when absent.

@testable import Atelier
import XCTest

final class PhaseExecutorTests: XCTestCase {
    private var dir: URL!
    private var binary = ""
    private let workstreamID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let found = ProcessComposeSettings.searchPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw XCTSkip("process-compose is not installed")
        }
        binary = found
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func writeConfig(_ body: String) throws -> ProcessComposeConfig {
        let path = dir.appendingPathComponent("process-compose.yaml")
        try body.write(to: path, atomically: true, encoding: .utf8)
        return ProcessComposeConfig(path: path.path, isRepositoryProvided: true, overridePath: nil)
    }

    private func runBootstrap(_ config: ProcessComposeConfig) -> PhaseExecutor.Outcome {
        PhaseExecutor.run(
            phase: .bootstrap,
            config: config,
            binary: binary,
            workstreamID: workstreamID,
            workingDirectory: dir.path,
            // Deliberately short. Every config here declares a `bootstrap`
            // process that exits at once, so nothing should approach this — and
            // the production deadline (`Timeout.install`, half an hour) would
            // wedge the suite if one of them ever did.
            timeout: 60
        )
    }

    func testSucceedingBootstrapReports() throws {
        let config = try writeConfig("""
        version: "0.5"
        processes:
          ok:
            namespace: bootstrap
            command: sh -c 'exit 0'
            availability: { restart: "no" }
        """)

        XCTAssertEqual(runBootstrap(config), .succeeded)
    }

    /// A failing bootstrap is only reported when the config asks for it.
    /// `availability.restart: exit_on_failure` is what makes process-compose
    /// propagate the process's exit code; see the companion test below.
    func testFailingBootstrapReportsFailure() throws {
        let config = try writeConfig("""
        version: "0.5"
        processes:
          bad:
            namespace: bootstrap
            command: sh -c 'echo boom >&2; exit 3'
            availability: { restart: "exit_on_failure" }
        """)

        let outcome = runBootstrap(config)
        guard case let .failed(detail) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("boom"), detail)
        // process-compose sets the terminal title even with the TUI off; the
        // escape sequence must not reach a message shown to the user.
        XCTAssertFalse(detail.contains("\u{1B}"), detail)
    }

    /// The surprising half of the contract, pinned so it is not mistaken for a
    /// bug: under the default `restart: "no"`, `process-compose up` exits 0 even
    /// though the process exited 3, so Atelier reports success. There is no
    /// after-the-fact query — the server dies with the run — so a project that
    /// wants a broken bootstrap reported has to say so in its own YAML.
    func testFailureWithoutAnExitPolicyIsNotReported() throws {
        let config = try writeConfig("""
        version: "0.5"
        processes:
          bad:
            namespace: bootstrap
            command: sh -c 'exit 3'
            availability: { restart: "no" }
        """)

        XCTAssertEqual(runBootstrap(config), .succeeded)
    }

    /// A config with no processes in the namespace is not an error — most
    /// projects will not use every phase. It must also never be *run*:
    /// `process-compose up -n` on an empty namespace does not exit, it idles
    /// forever, so skipping is what keeps this bounded.
    func testAbsentNamespaceIsSkipped() throws {
        let config = try writeConfig("""
        version: "0.5"
        processes:
          web:
            namespace: execute
            command: sh -c 'exit 0'
        """)

        XCTAssertEqual(runBootstrap(config), .skipped)
    }

    /// A config that predates namespaces entirely declares none, so every phase
    /// is skipped rather than hanging on an empty namespace.
    func testConfigWithNoNamespacesIsSkipped() throws {
        let config = try writeConfig("""
        version: "0.5"
        processes:
          web:
            command: sh -c 'exit 0'
        """)

        XCTAssertEqual(runBootstrap(config), .skipped)
    }
}
