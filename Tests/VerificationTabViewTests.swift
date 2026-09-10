// ABOUTME: Tests for the Verification tab's extracted decisions: Run's gate, staleness, glyphs.
// ABOUTME: Follows ExecutionTabViewTests' precedent — free functions, no view tree.

@testable import Atelier
import XCTest

final class VerificationTabViewTests: XCTestCase {
    // MARK: - Run's gate

    /// Gated on the runner's liveness, never on `Run.isFinished` — see
    /// VerificationRunner.swift's own doc on `isLive`. A run whose rows have
    /// all gone terminal is still live until it seals, and a button that
    /// re-enabled there would let a second `up` rebind a live socket.
    func test_canRun_isFalseWhileTheRunnerReportsLive() {
        XCTAssertFalse(verificationCanRun(isLive: true))
    }

    func test_canRun_isTrueWhenNothingIsLive() {
        XCTAssertTrue(verificationCanRun(isLive: false))
    }

    // MARK: - Staleness

    func test_isStale_comparesTheStamp() {
        let run = Verification.Run(
            id: "abcd1234", workstreamID: UUID(), startedAt: Date(), stamp: "head|10|aaaa",
            checks: [], wasStopped: false
        )
        XCTAssertFalse(verificationIsStale(run: run, currentStamp: "head|10|aaaa"))
        XCTAssertTrue(verificationIsStale(run: run, currentStamp: "head|11|bbbb"))
        // No stamp to compare against is not evidence of freshness.
        XCTAssertTrue(verificationIsStale(run: run, currentStamp: nil))
    }

    // MARK: - Row glyphs

    func test_rowGlyph_distinguishesEveryState() {
        let states: [Verification.CheckResult.State] =
            [.notRun, .pending, .running, .passed, .failed(1), .skipped, .stopped]
        let glyphs = states.map(verificationRowGlyph)
        // A skipped check must not look like a failure, and a not-run one must not
        // look like a pass.
        XCTAssertEqual(Set(glyphs).count, glyphs.count, "\(glyphs)")
    }

    /// The associated exit code must not affect which glyph a failure gets —
    /// every failure reads the same regardless of what code produced it.
    func test_rowGlyph_ignoresTheFailedExitCode() {
        XCTAssertEqual(verificationRowGlyph(.failed(1)), verificationRowGlyph(.failed(137)))
    }

    // MARK: - The unavailable state

    /// Reads the same four preconditions `PhasePolicy.plan` evaluates, in the
    /// same order, so the *decision* is one copy with that gate and only the
    /// *rendering* is separate. `PhasePolicy`'s own strings are past tense
    /// ("so no `verify` ran"); this tab has not run anything yet, so none of
    /// these may read as a report on a run that already happened.
    func test_unavailableReason_isNilOnceEveryPreconditionHolds() {
        XCTAssertNil(verificationUnavailableReason(
            isEnabled: true, hasConfig: true, hasBinary: true, isApproved: true,
            declared: ["rspec", "rubocop"]
        ))
    }

    func test_unavailableReason_reportsTheIntegrationSwitch() {
        let reason = verificationUnavailableReason(
            isEnabled: false, hasConfig: true, hasBinary: true, isApproved: true, declared: ["rspec"]
        )
        XCTAssertNotNil(reason)
        XCTAssertFalse(reason?.contains("ran") ?? true, "must not read as a report on a run that already happened: \(reason ?? "")")
    }

    func test_unavailableReason_reportsAMissingConfig() {
        XCTAssertNotNil(verificationUnavailableReason(
            isEnabled: true, hasConfig: false, hasBinary: true, isApproved: true, declared: nil
        ))
    }

    func test_unavailableReason_reportsAMissingBinary() {
        XCTAssertNotNil(verificationUnavailableReason(
            isEnabled: true, hasConfig: true, hasBinary: false, isApproved: true, declared: nil
        ))
    }

    func test_unavailableReason_reportsAnUnapprovedConfig() {
        XCTAssertNotNil(verificationUnavailableReason(
            isEnabled: true, hasConfig: true, hasBinary: true, isApproved: false, declared: nil
        ))
    }

    /// `declared == nil` is a parse failure, distinct from a config that
    /// parsed and named nothing — both are unavailable, but they are not the
    /// same fact and must not collapse to the same nil-vs-empty confusion the
    /// runner itself refuses to make (see `Verification.Runner.start`, which
    /// never folds an unparseable config into "declares no verify processes").
    func test_unavailableReason_distinguishesParseFailureFromNoChecksDeclared() {
        let parseFailure = verificationUnavailableReason(
            isEnabled: true, hasConfig: true, hasBinary: true, isApproved: true, declared: nil
        )
        let noneDeclared = verificationUnavailableReason(
            isEnabled: true, hasConfig: true, hasBinary: true, isApproved: true, declared: []
        )
        XCTAssertNotNil(parseFailure)
        XCTAssertNotNil(noneDeclared)
        XCTAssertNotEqual(parseFailure, noneDeclared)
    }

    // MARK: - Availability, as one decision

    private static let binaryPath = "/opt/homebrew/bin/process-compose"

    /// Writes a config into a fresh temp directory and returns it located.
    ///
    /// `isRepositoryProvided` decides whether approval applies at all —
    /// `requiresApproval` is derived from it — so a test about the approval
    /// gate has to ask for a repository-provided one.
    private func makeConfig(
        yaml: String, isRepositoryProvided: Bool = false
    ) throws -> ProcessCompose.Config {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("process-compose.yaml").path
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        return ProcessCompose.Config(
            path: path, isRepositoryProvided: isRepositoryProvided, overridePath: nil
        )
    }

    private static let twoChecks = """
    version: "0.5"
    processes:
      rubocop:
        namespace: verify
        command: echo a
      rspec:
        namespace: verify
        command: echo b
      app:
        namespace: execute
        command: echo c
    """

    private static let noChecks = """
    version: "0.5"
    processes:
      app:
        namespace: execute
        command: echo c
    """

    func test_availability_offersTheDeclaredChecksWhenEveryPreconditionHolds() throws {
        let result = try verificationAvailability(
            isEnabled: true, config: makeConfig(yaml: Self.twoChecks),
            binary: Self.binaryPath, isApproved: { _ in true }
        )
        XCTAssertNil(result.reason)
        // Only the `verify` namespace, sorted — `execute`'s process is not a check.
        XCTAssertEqual(result.declared, ["rspec", "rubocop"])
    }

    /// One case per precondition `PhasePolicy.plan` evaluates. Each is
    /// unavailable, offers nothing, and says so in the present tense — the
    /// gate's own strings are past tense ("so no `verify` ran") and reporting
    /// on a run that never happened is the specific wrongness being excluded.
    func test_availability_reportsEachPreconditionInPresentTense() throws {
        let config = try makeConfig(yaml: Self.twoChecks)
        // Approval only applies to a config that arrived with the repository.
        let repositoryConfig = try makeConfig(yaml: Self.twoChecks, isRepositoryProvided: true)
        let cases: [(String, (declared: [String], reason: String?))] = [
            ("integration off", verificationAvailability(
                isEnabled: false, config: config, binary: Self.binaryPath, isApproved: { _ in true }
            )),
            ("no config", verificationAvailability(
                isEnabled: true, config: nil, binary: Self.binaryPath, isApproved: { _ in true }
            )),
            ("no binary", verificationAvailability(
                isEnabled: true, config: config, binary: nil, isApproved: { _ in true }
            )),
            ("not approved", verificationAvailability(
                isEnabled: true, config: repositoryConfig, binary: Self.binaryPath,
                isApproved: { _ in false }
            )),
        ]
        for (name, result) in cases {
            XCTAssertNotNil(result.reason, "\(name) must explain itself")
            XCTAssertEqual(result.declared, [], "\(name) must offer no checks")
            XCTAssertFalse(
                result.reason?.contains(" ran") ?? true,
                "\(name) must not read as a report on a run that already happened: \(result.reason ?? "")"
            )
        }
    }

    /// Approval is gated by the config's **location**, not its content: one in
    /// the project directory was placed there by hand, outside git, and is
    /// never asked about. So "the user has approved nothing" is not a refusal
    /// for such a config, and this is not a hypothetical — an earlier version
    /// of `verificationAvailability` took approval as a plain `Bool`, refused
    /// here, and disagreed with the `plan` that was happily running.
    func test_availability_doesNotAskApprovalOfAProjectDirectoryConfig() throws {
        let result = try verificationAvailability(
            isEnabled: true, config: makeConfig(yaml: Self.twoChecks),
            binary: Self.binaryPath, isApproved: { _ in false }
        )
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.declared, ["rspec", "rubocop"])
    }

    /// `plan` answers four preconditions and stops, so it returns `.run` for a
    /// config whose `verify` namespace is empty — while `Runner.start` refuses
    /// it, because `up -n verify` on an empty namespace never exits. Taking
    /// `.run` as the whole of availability is what would put an enabled Run in
    /// front of the user here.
    func test_availability_refusesAConfigThatDeclaresNoChecks() throws {
        let result = try verificationAvailability(
            isEnabled: true, config: makeConfig(yaml: Self.noChecks),
            binary: Self.binaryPath, isApproved: { _ in true }
        )
        XCTAssertNotNil(result.reason)
        XCTAssertEqual(result.declared, [])
    }

    /// The same for a config that does not parse: `plan` never reads it, so it
    /// still says `.run`. Its wording must differ from the empty case above —
    /// the two are not the same fact, and `Runner.start` does not conflate them.
    func test_availability_refusesAnUnparseableConfigWithItsOwnWording() throws {
        let parseFailure = try verificationAvailability(
            isEnabled: true, config: makeConfig(yaml: "this: is not a process-compose config\n"),
            binary: Self.binaryPath, isApproved: { _ in true }
        )
        let noneDeclared = try verificationAvailability(
            isEnabled: true, config: makeConfig(yaml: Self.noChecks),
            binary: Self.binaryPath, isApproved: { _ in true }
        )
        XCTAssertNotNil(parseFailure.reason)
        XCTAssertEqual(parseFailure.declared, [])
        XCTAssertNotEqual(parseFailure.reason, noneDeclared.reason)
    }

    /// **The biconditional this whole split rests on.** Across every
    /// combination of the four facts, `reason == nil` must hold exactly when
    /// `plan` says `.run` *and* the config declares at least one check.
    /// Nothing in the types enforces that — `verificationUnavailableReason`
    /// hand-mirrors `plan`'s preconditions and cannot check that it agrees —
    /// so it is pinned here against `plan` itself rather than against a copy
    /// of its branch order. The config is repository-provided so that the
    /// approval fact actually changes `plan`'s answer.
    func test_availability_agreesWithPhasePolicyOnEveryCombination() throws {
        let config = try makeConfig(yaml: Self.twoChecks, isRepositoryProvided: true)
        for isEnabled in [true, false] {
            for hasConfig in [true, false] {
                for hasBinary in [true, false] {
                    for isApproved in [true, false] {
                        let suppliedConfig = hasConfig ? config : nil
                        let binary = hasBinary ? Self.binaryPath : nil
                        let plan = PhasePolicy.plan(
                            phase: .verify, isEnabled: isEnabled, config: suppliedConfig,
                            binary: binary, isApproved: { _ in isApproved }
                        )
                        let result = verificationAvailability(
                            isEnabled: isEnabled, config: suppliedConfig,
                            binary: binary, isApproved: { _ in isApproved }
                        )
                        let label = "enabled=\(isEnabled) config=\(hasConfig) binary=\(hasBinary) approved=\(isApproved)"
                        switch plan {
                        case .run:
                            // The fixture declares two checks, so `.run` is the
                            // whole of availability for this config.
                            XCTAssertNil(result.reason, "plan said .run but the tab refuses: \(label)")
                            XCTAssertEqual(result.declared, ["rspec", "rubocop"], label)
                        case .nothingToDo:
                            XCTAssertNotNil(result.reason, "plan refused but the tab would run: \(label)")
                            XCTAssertEqual(result.declared, [], label)
                        }
                    }
                }
            }
        }
    }
}
