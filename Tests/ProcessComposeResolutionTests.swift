// ABOUTME: Tests the one resolution the Execution and Verification panes read from.
// ABOUTME: The invariant is agreement — one pass, one value, the same answers as before the move.

@testable import Atelier
import XCTest

@MainActor
final class ProcessComposeResolutionTests: XCTestCase {
    private var projectDirectory: URL!
    private var worktree: URL!

    /// Stands in for a real install. The binary path stopped being
    /// configurable, so a resolution's search paths are injected instead —
    /// without that seam every assertion here would depend on whether the host
    /// running the suite happens to have process-compose installed.
    private let binary = "/bin/ls"
    private var searchPaths: [String] {
        [binary]
    }

    override func setUp() async throws {
        try await super.setUp()
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resolution-" + UUID().uuidString)
        projectDirectory = base.appendingPathComponent("project")
        worktree = base.appendingPathComponent("project/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectDirectory.deletingLastPathComponent())
        try await super.tearDown()
    }

    private static let config = """
    version: "0.5"
    processes:
      web:
        namespace: execute
        command: echo web
    """

    /// Verification's own config, and a different file entirely: checks come
    /// from `verification.yaml` in the project directory, never from
    /// process-compose. Written here beside the other one because this
    /// resolution answers both panes in one pass.
    @discardableResult
    private func writeVerificationConfig(_ yaml: String = """
    rspec:
      command: echo rspec
    """) throws -> String {
        let path = projectDirectory.appendingPathComponent("verification.yaml").path
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// In the project directory, which is the only place `Config.locate` reads.
    @discardableResult
    private func writeProjectConfig(_ yaml: String = config) throws -> String {
        let path = projectDirectory.appendingPathComponent("execution.process-compose.yaml").path
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func resolve() -> ProcessCompose.Resolution {
        ProcessCompose.ResolutionModel.resolve(
            projectDirectory: projectDirectory.path, override: nil,
            searchPaths: searchPaths
        )
    }

    private func makeModel() -> ProcessCompose.ResolutionModel {
        ProcessCompose.ResolutionModel(
            projectDirectory: projectDirectory.path, override: nil,
            searchPaths: searchPaths
        )
    }

    // MARK: - One pass, the same answers

    func test_resolve_answersEveryPaneInOnePass() throws {
        let path = try writeProjectConfig()
        try writeVerificationConfig()

        let resolution = resolve()

        XCTAssertTrue(resolution.plan.canRun)
        XCTAssertNil(resolution.startUnavailableReason)
        XCTAssertEqual(resolution.loadedFiles, [path])
        XCTAssertEqual(resolution.declaredExecuteProcesses, ["web"])
        XCTAssertEqual(resolution.declaredVerifyChecks, ["rspec"])
        XCTAssertNil(resolution.verifyUnavailableReason)
        XCTAssertTrue(resolution.usesProcessCompose)
    }

    /// **Verification's half does not depend on process-compose at all.** Checks
    /// come from `verification.yaml` in the project directory, so a project with
    /// no process-compose config, or no binary to run one with, still offers every
    /// check it declares. The two halves ride in one resolution because they share
    /// a refresh trigger, not because they share an input.
    func test_resolve_offersChecksWithNoProcessComposeConfigAtAll() throws {
        try writeVerificationConfig("""
        rspec:
          command: bundle exec rspec
        rubocop:
          shell: fish
          command: bundle exec rubocop
        """)

        let resolution = resolve()

        XCTAssertEqual(resolution.declaredVerifyChecks, ["rspec", "rubocop"])
        XCTAssertNil(resolution.verifyUnavailableReason)
        // And the Execution half is correctly unavailable, which is what proves
        // the two were resolved independently rather than together.
        XCTAssertFalse(resolution.plan.canRun)
    }

    /// File order, not alphabetical and not a dictionary's arbitrary order: the
    /// rows are drawn in the order the user wrote them.
    func test_resolve_keepsTheChecksInFileOrder() throws {
        try writeVerificationConfig("""
        zebra:
          command: echo z
        alpha:
          command: echo a
        middle:
          command: echo m
        """)

        XCTAssertEqual(resolve().declaredVerifyChecks, ["zebra", "alpha", "middle"])
    }

    /// A broken `verification.yaml` must not read as "this project declares no
    /// checks" — that is the same sentence a project with none gets, and it is the
    /// only diagnostic either one has.
    func test_resolve_distinguishesABrokenConfigFromAnEmptyOne() throws {
        try writeVerificationConfig("rspec: [not, a, mapping]")

        let broken = try XCTUnwrap(resolve().verifyUnavailableReason)
        XCTAssertTrue(broken.contains("rspec"), broken)

        try writeVerificationConfig("# nothing here")
        let empty = try XCTUnwrap(resolve().verifyUnavailableReason)
        XCTAssertNotEqual(broken, empty)
    }

    /// `PhaseRunner.runnableProcesses` is a flag-injection guard, and the
    /// checklist must not be able to offer a name the command would drop —
    /// selected alone it emptied the name list, and `up -n execute` with no
    /// names runs the whole namespace. The filter moved with the property.
    func test_resolve_doesNotOfferAFlagShapedExecuteProcess() throws {
        try writeProjectConfig("""
        version: "0.5"
        processes:
          "-web":
            namespace: execute
            command: echo nope
          web:
            namespace: execute
            command: echo web
        """)

        XCTAssertEqual(resolve().declaredExecuteProcesses, ["web"])
    }

    /// With no process-compose on the machine nothing may run, and the pane has
    /// to say so rather than offer checks it cannot start. The integration
    /// switch this case used to test is gone — process-compose is a
    /// requirement — so detection is the precondition that survived it.
    func test_resolve_refusesEverythingWithNoBinary() throws {
        try writeProjectConfig()

        let resolution = ProcessCompose.ResolutionModel.resolve(
            projectDirectory: projectDirectory.path, override: nil,
            searchPaths: ["/nonexistent/process-compose"]
        )

        XCTAssertFalse(resolution.plan.canRun)
        XCTAssertEqual(resolution.declaredExecuteProcesses, [])
        XCTAssertNotNil(resolution.startUnavailableReason)
    }

    /// **Nothing in the worktree is resolved.** A config sitting in a work tree
    /// used to be located and then held behind an approval; now it is not
    /// located, and the pane says there is nothing to start. That is the whole of
    /// the trust decision, so a resolution that found one would be running
    /// repository content with no gate left behind it.
    func test_resolve_ignoresAConfigInTheWorktree() throws {
        try Self.config.write(
            toFile: worktree.appendingPathComponent("execution.process-compose.yaml").path,
            atomically: true, encoding: .utf8
        )

        let resolution = resolve()

        XCTAssertFalse(resolution.plan.canRun)
        XCTAssertEqual(resolution.loadedFiles, [])
        // Nothing was detected at all, which is the one state
        // `unavailableReason` deliberately leaves to the pane's own "Nothing to
        // start" copy — and that copy is what names the file to create.
        XCTAssertNil(resolution.devCommand)
        XCTAssertNil(resolution.startUnavailableReason)
    }

    // MARK: - The model around it

    /// **The window the async refresh must not open.** A pane with nothing
    /// resolved is not a neutral state: a nil verify reason reads as "everything
    /// is fine" and puts an enabled Run over an empty check list. So the first
    /// resolution is synchronous, in `init`, and is readable on the line after
    /// it with nothing awaited.
    func test_init_resolvesSynchronously() throws {
        try writeProjectConfig()
        try writeVerificationConfig()

        let model = makeModel()

        XCTAssertTrue(model.resolution.plan.canRun)
        XCTAssertEqual(model.resolution.declaredVerifyChecks, ["rspec"])
    }

    /// And the asynchronous path does land: a config that changes on disk is
    /// picked up by a refresh, which is the trigger every tab switch now uses.
    func test_refresh_publishesTheNewAnswer() async throws {
        try writeProjectConfig()
        try writeVerificationConfig()
        let model = makeModel()
        XCTAssertEqual(model.resolution.declaredVerifyChecks, ["rspec"])

        try writeVerificationConfig("""
        rubocop:
          command: echo rubocop
        """)
        model.refresh(override: nil)

        try await waitUntil("the refresh lands") {
            model.resolution.declaredVerifyChecks == ["rubocop"]
        }
    }

    /// An approval reads the result of the write it just made, so its refresh
    /// is synchronous — and it supersedes a refresh already in flight rather
    /// than being overwritten by one that started earlier.
    func test_refreshNow_winsOverARefreshAlreadyInFlight() async throws {
        try writeProjectConfig()
        try writeVerificationConfig()
        let model = makeModel()

        model.refresh(override: nil)
        try writeVerificationConfig("""
        rubocop:
          command: echo rubocop
        """)
        let now = model.refreshNow(override: nil)

        XCTAssertEqual(now.declaredVerifyChecks, ["rubocop"])
        XCTAssertEqual(model.resolution.declaredVerifyChecks, ["rubocop"])
        // The in-flight pass read the file before it changed; its landing must
        // not replace the newer answer.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.resolution.declaredVerifyChecks, ["rubocop"])
    }

    private func waitUntil(
        _ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
