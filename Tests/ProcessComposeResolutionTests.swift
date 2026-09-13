// ABOUTME: Tests the one resolution the Execution and Verification panes read from.
// ABOUTME: The invariant is agreement — one pass, one value, the same answers as before the move.

@testable import Atelier
import XCTest

@MainActor
final class ProcessComposeResolutionTests: XCTestCase {
    /// These keys live in the app's own defaults domain and the test host *is*
    /// the app, so they are saved and put back — the same care
    /// `ProcessComposeSettingsTests` takes.
    private var savedSettings: [String: Any?] = [:]
    private var projectDirectory: URL!
    private var worktree: URL!

    /// Stands in for a real install: what matters is that `resolveBinary()`
    /// returns something, not what it is.
    private let binary = "/bin/ls"

    override func setUp() async throws {
        try await super.setUp()
        for key in [ProcessCompose.Settings.enabledKey, ProcessCompose.Settings.binaryPathKey] {
            savedSettings[key] = UserDefaults.standard.object(forKey: key)
        }
        ProcessCompose.Settings.isEnabled = true
        ProcessCompose.Settings.binaryPath = binary

        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resolution-" + UUID().uuidString)
        projectDirectory = base.appendingPathComponent("project")
        worktree = base.appendingPathComponent("project/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectDirectory.deletingLastPathComponent())
        for key in [ProcessCompose.Settings.enabledKey, ProcessCompose.Settings.binaryPathKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for (key, value) in savedSettings {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        savedSettings.removeAll()
        try await super.tearDown()
    }

    private static let config = """
    version: "0.5"
    processes:
      web:
        namespace: execute
        command: echo web
      rspec:
        namespace: verify
        command: echo rspec
    """

    /// In the *project directory*, which is the tier that needs no approval:
    /// a config placed there was put there by hand, outside git.
    @discardableResult
    private func writeProjectConfig(_ yaml: String = config) throws -> String {
        let path = projectDirectory.appendingPathComponent("process-compose.yaml").path
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func resolve() -> ProcessCompose.Resolution {
        ProcessCompose.ResolutionModel.resolve(
            worktree: worktree.path, projectDirectory: projectDirectory.path, override: nil
        )
    }

    // MARK: - One pass, the same answers

    func test_resolve_answersEveryPaneFromOneConfig() throws {
        let path = try writeProjectConfig()

        let resolution = resolve()

        XCTAssertTrue(resolution.plan.canRun)
        XCTAssertNil(resolution.startUnavailableReason)
        XCTAssertEqual(resolution.loadedFiles, [path])
        XCTAssertEqual(resolution.declaredExecuteProcesses, ["web"])
        XCTAssertEqual(resolution.declaredVerifyChecks, ["rspec"])
        XCTAssertNil(resolution.verifyUnavailableReason)
        XCTAssertTrue(resolution.usesProcessCompose)
        // Nothing to approve: this config is the user's own, in the project
        // directory, and approval is gated by location rather than content.
        XCTAssertEqual(resolution.repositoryConfigFiles, [])
        XCTAssertFalse(resolution.isApproved)
    }

    /// **The regression guard for moving this out of the view.** The decision
    /// is still `verificationAvailability`'s — which asks the same
    /// `PhasePolicy.plan` that `Verification.Runner.start` calls — so resolving
    /// it here must produce exactly what asking it directly does. A resolution
    /// that quietly answered a different question would put an enabled Run in
    /// front of a project `start` refuses.
    func test_resolve_verifyHalfAgreesWithVerificationAvailability() throws {
        try writeProjectConfig()
        let located = try XCTUnwrap(ProcessCompose.Config.locate(
            worktree: worktree.path, projectDirectory: projectDirectory.path
        ))
        let direct = verificationAvailability(
            isEnabled: true, config: located, binary: binary,
            isApproved: { ScriptTrust.isApproved(
                configFiles: $0.repositoryProvidedFiles, for: self.projectDirectory.path
            ) }
        )

        let resolution = resolve()

        XCTAssertEqual(resolution.declaredVerifyChecks, direct.declared)
        XCTAssertEqual(resolution.verifyUnavailableReason, direct.reason)
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

    /// With the integration off nothing may run, nothing is offered, and — the
    /// part that is easy to lose — nothing is asked for approval either, since
    /// no phase will load those files.
    func test_resolve_refusesEverythingWhileTheIntegrationIsOff() throws {
        try writeProjectConfig()
        ProcessCompose.Settings.isEnabled = false

        let resolution = resolve()

        XCTAssertFalse(resolution.plan.canRun)
        XCTAssertFalse(resolution.usesProcessCompose)
        XCTAssertEqual(resolution.declaredExecuteProcesses, [])
        XCTAssertEqual(resolution.declaredVerifyChecks, [])
        XCTAssertNotNil(resolution.verifyUnavailableReason)
        XCTAssertEqual(resolution.repositoryConfigFiles, [])
        XCTAssertFalse(resolution.isApproved)
    }

    /// A config that arrived with the repository is the one the user is asked
    /// about, and until they answer, verify says so rather than offering checks.
    func test_resolve_asksForApprovalOfARepositoryProvidedConfig() throws {
        let path = worktree.appendingPathComponent("process-compose.yaml").path
        try Self.config.write(toFile: path, atomically: true, encoding: .utf8)

        let resolution = resolve()

        XCTAssertEqual(resolution.repositoryConfigFiles, [path])
        XCTAssertFalse(resolution.isApproved)
        XCTAssertEqual(resolution.declaredVerifyChecks, [])
        XCTAssertNotNil(resolution.verifyUnavailableReason)
    }

    // MARK: - The model around it

    /// **The window the async refresh must not open.** A pane with nothing
    /// resolved is not a neutral state: a nil verify reason reads as "everything
    /// is fine" and puts an enabled Run over an empty check list. So the first
    /// resolution is synchronous, in `init`, and is readable on the line after
    /// it with nothing awaited.
    func test_init_resolvesSynchronously() throws {
        try writeProjectConfig()

        let model = ProcessCompose.ResolutionModel(
            worktree: worktree.path, projectDirectory: projectDirectory.path, override: nil
        )

        XCTAssertTrue(model.resolution.plan.canRun)
        XCTAssertEqual(model.resolution.declaredVerifyChecks, ["rspec"])
    }

    /// And the asynchronous path does land: a config that changes on disk is
    /// picked up by a refresh, which is the trigger every tab switch now uses.
    func test_refresh_publishesTheNewAnswer() async throws {
        try writeProjectConfig()
        let model = ProcessCompose.ResolutionModel(
            worktree: worktree.path, projectDirectory: projectDirectory.path, override: nil
        )
        XCTAssertEqual(model.resolution.declaredVerifyChecks, ["rspec"])

        try writeProjectConfig("""
        version: "0.5"
        processes:
          web:
            namespace: execute
            command: echo web
          rubocop:
            namespace: verify
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
        let model = ProcessCompose.ResolutionModel(
            worktree: worktree.path, projectDirectory: projectDirectory.path, override: nil
        )

        model.refresh(override: nil)
        try writeProjectConfig("""
        version: "0.5"
        processes:
          rubocop:
            namespace: verify
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
