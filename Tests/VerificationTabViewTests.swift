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

    // MARK: - Checklist visibility

    // Hidden while live, not merely disabled: clicking a box that cannot take
    // effect is the confusing state, and Execution already resolves it this way
    // (ExecutionTabView.swift:83 gates its own checklist on `!runStarted`).
    func test_showsChecklist_hiddenWhileARunIsLive() {
        XCTAssertFalse(verificationShowsChecklist(isLive: true, declaredProcesses: ["rspec"]))
    }

    func test_showsChecklist_visibleWhenIdleWithChecks() {
        XCTAssertTrue(verificationShowsChecklist(isLive: false, declaredProcesses: ["rspec"]))
    }

    /// The empty-list guard stays. It is not cosmetic: an empty list would make
    /// ProcessSelectionView's own .onAppear read the stored selection as "nothing
    /// survived" and overwrite it with the canonical "all" — see
    /// processSelectionOnLoad.
    func test_showsChecklist_hiddenWhenNothingIsDeclared() {
        XCTAssertFalse(verificationShowsChecklist(isLive: false, declaredProcesses: []))
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

    /// A run whose own baseline has not been captured yet is not stale, and
    /// that is the opposite direction from a missing `currentStamp`.
    /// `Runner.start` publishes the run with an empty stamp and `Runner.execute`
    /// fills it off the main actor a few milliseconds later — computing it on
    /// the actor was four-plus serial git spawns on every press. Without this
    /// branch the "no longer reflects the worktree's current content" banner
    /// rendered over a suite that had not even started. A real fingerprint is
    /// always `head|count|digest`, so "" cannot mean anything else.
    func test_isStale_treatsAnUncapturedStampAsNotYetComparable() {
        let run = Verification.Run(
            id: "abcd1234", workstreamID: UUID(), startedAt: Date(), stamp: "",
            checks: [], wasStopped: false
        )
        XCTAssertFalse(verificationIsStale(run: run, currentStamp: "head|10|aaaa"))
        XCTAssertFalse(verificationIsStale(run: run, currentStamp: nil))
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

    /// Reads the same three preconditions `PhasePolicy.plan` evaluates, in the
    /// same order, so the *decision* is one copy with that gate and only the
    /// *rendering* is separate. `PhasePolicy`'s own strings are past tense
    /// ("so no `verify` ran"); this tab has not run anything yet, so none of
    /// these may read as a report on a run that already happened.
    func test_unavailableReason_isNilOnceEveryPreconditionHolds() {
        XCTAssertNil(verificationUnavailableReason(
            hasConfig: true, hasBinary: true, isApproved: true,
            declared: ["rspec", "rubocop"]
        ))
    }

    /// There is no integration switch to report any more; a missing config is
    /// the first precondition. The present-tense assertion travels with it,
    /// because it was the switch's test that carried it.
    func test_unavailableReason_reportsAMissingConfig() {
        let reason = verificationUnavailableReason(
            hasConfig: false, hasBinary: true, isApproved: true, declared: nil
        )
        XCTAssertNotNil(reason)
        XCTAssertFalse(reason?.contains(" ran") ?? true, "must not read as a report on a run that already happened: \(reason ?? "")")
    }

    func test_unavailableReason_reportsAMissingBinary() {
        XCTAssertNotNil(verificationUnavailableReason(
            hasConfig: true, hasBinary: false, isApproved: true, declared: nil
        ))
    }

    func test_unavailableReason_reportsAnUnapprovedConfig() {
        XCTAssertNotNil(verificationUnavailableReason(
            hasConfig: true, hasBinary: true, isApproved: false, declared: nil
        ))
    }

    /// `declared == nil` is a parse failure, distinct from a config that
    /// parsed and named nothing — both are unavailable, but they are not the
    /// same fact and must not collapse to the same nil-vs-empty confusion the
    /// runner itself refuses to make (see `Verification.Runner.start`, which
    /// never folds an unparseable config into "declares no verify processes").
    func test_unavailableReason_distinguishesParseFailureFromNoChecksDeclared() {
        let parseFailure = verificationUnavailableReason(
            hasConfig: true, hasBinary: true, isApproved: true, declared: nil
        )
        let noneDeclared = verificationUnavailableReason(
            hasConfig: true, hasBinary: true, isApproved: true, declared: []
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
            path: path, isRepositoryProvided: isRepositoryProvided
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
            config: makeConfig(yaml: Self.twoChecks),
            binary: Self.binaryPath, isApproved: { _ in true }
        )
        XCTAssertNil(result.reason)
        // Only the `verify` namespace, sorted — `execute`'s process is not a check.
        XCTAssertEqual(result.declared, ["rspec", "rubocop"])
    }

    /// A process named like a flag is legal YAML and `declaredProcesses` finds
    /// it — but `PhaseRunner.command` drops a trailing name beginning with `-`
    /// as a flag-injection guard, so process-compose never sees it. Offering it
    /// in the checklist made "one of several" seal `.notRun` for no stated
    /// reason, and the *only* selection run the entire namespace. The checklist
    /// and `Runner.start` filter through the one shared function, so what is
    /// offered here is exactly what a run can address.
    func test_availability_doesNotOfferAFlagShapedCheck() throws {
        let result = try verificationAvailability(
            config: makeConfig(yaml: """
            version: "0.5"
            processes:
              "-n":
                namespace: verify
                command: echo a
              rspec:
                namespace: verify
                command: echo b
            """),
            binary: Self.binaryPath, isApproved: { _ in true }
        )
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.declared, ["rspec"])
    }

    /// One case per precondition `PhasePolicy.plan` evaluates — three now that
    /// process-compose is a requirement and the switch is gone. Each is
    /// unavailable, offers nothing, and says so in the present tense — the
    /// gate's own strings are past tense ("so no `verify` ran") and reporting
    /// on a run that never happened is the specific wrongness being excluded.
    func test_availability_reportsEachPreconditionInPresentTense() throws {
        let config = try makeConfig(yaml: Self.twoChecks)
        // Approval only applies to a config that arrived with the repository.
        let repositoryConfig = try makeConfig(yaml: Self.twoChecks, isRepositoryProvided: true)
        let cases: [(String, (declared: [String], reason: String?))] = [
            ("no config", verificationAvailability(
                config: nil, binary: Self.binaryPath, isApproved: { _ in true }
            )),
            ("no binary", verificationAvailability(
                config: config, binary: nil, isApproved: { _ in true }
            )),
            ("not approved", verificationAvailability(
                config: repositoryConfig, binary: Self.binaryPath,
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
            config: makeConfig(yaml: Self.twoChecks),
            binary: Self.binaryPath, isApproved: { _ in false }
        )
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.declared, ["rspec", "rubocop"])
    }

    /// `plan` answers three preconditions and stops, so it returns `.run` for a
    /// config whose `verify` namespace is empty — while `Runner.start` refuses
    /// it, because `up -n verify` on an empty namespace never exits. Taking
    /// `.run` as the whole of availability is what would put an enabled Run in
    /// front of the user here.
    func test_availability_refusesAConfigThatDeclaresNoChecks() throws {
        let result = try verificationAvailability(
            config: makeConfig(yaml: Self.noChecks),
            binary: Self.binaryPath, isApproved: { _ in true }
        )
        XCTAssertNotNil(result.reason)
        XCTAssertEqual(result.declared, [])
    }

    /// The same for a config that does not parse: `plan` never reads it, so it
    /// still says `.run`. Its wording must differ from the empty case above —
    /// the two are not the same fact, and `Runner.start` does not conflate them.
    ///
    /// The fixture has to be YAML that genuinely fails to *decode*.
    /// `processes:` given as a sequence is that; a mapping of unrelated keys is
    /// not — it decodes fine with no `processes:` key, which
    /// `Config.declaredProcesses` now skips rather than calling the whole config
    /// unknown, because that is the shape of a legal override setting only
    /// `environment:` or `version:`. This test used such a mapping and passed
    /// for the wrong reason.
    func test_availability_refusesAnUnparseableConfigWithItsOwnWording() throws {
        let parseFailure = try verificationAvailability(
            config: makeConfig(yaml: "processes: [this, is, not, a, mapping]\n"),
            binary: Self.binaryPath, isApproved: { _ in true }
        )
        let noneDeclared = try verificationAvailability(
            config: makeConfig(yaml: Self.noChecks),
            binary: Self.binaryPath, isApproved: { _ in true }
        )
        XCTAssertNotNil(parseFailure.reason)
        XCTAssertEqual(parseFailure.declared, [])
        XCTAssertNotEqual(parseFailure.reason, noneDeclared.reason)
    }

    /// A config with no `processes:` key at all declares nothing; it is not a
    /// parse failure, and must not be reported as one. The tab used to say "this
    /// project's process-compose files could not be parsed" for it — for the
    /// override half of a perfectly ordinary base-plus-override pair, which
    /// `namespacePresence` calls `.present`.
    func test_availability_treatsAMissingProcessesKeyAsDeclaringNothing() throws {
        let noProcessesKey = try verificationAvailability(
            config: makeConfig(yaml: "version: \"0.5\"\nenvironment:\n  - A=b\n"),
            binary: Self.binaryPath, isApproved: { _ in true }
        )
        let noneDeclared = try verificationAvailability(
            config: makeConfig(yaml: Self.noChecks),
            binary: Self.binaryPath, isApproved: { _ in true }
        )
        XCTAssertEqual(noProcessesKey.declared, [])
        XCTAssertEqual(noProcessesKey.reason, noneDeclared.reason)
    }

    /// **The biconditional this whole split rests on.** Across every
    /// combination of the three facts, `reason == nil` must hold exactly when
    /// `plan` says `.run` *and* the config declares at least one check.
    /// Nothing in the types enforces that — `verificationUnavailableReason`
    /// hand-mirrors `plan`'s preconditions and cannot check that it agrees —
    /// so it is pinned here against `plan` itself rather than against a copy
    /// of its branch order. The config is repository-provided so that the
    /// approval fact actually changes `plan`'s answer.
    func test_availability_agreesWithPhasePolicyOnEveryCombination() throws {
        let config = try makeConfig(yaml: Self.twoChecks, isRepositoryProvided: true)
        for hasConfig in [true, false] {
            for hasBinary in [true, false] {
                for isApproved in [true, false] {
                    let suppliedConfig = hasConfig ? config : nil
                    let binary = hasBinary ? Self.binaryPath : nil
                    let plan = PhasePolicy.plan(
                        phase: .verify, config: suppliedConfig,
                        binary: binary, isApproved: { _ in isApproved }
                    )
                    let result = verificationAvailability(
                        config: suppliedConfig,
                        binary: binary, isApproved: { _ in isApproved }
                    )
                    let label = "config=\(hasConfig) binary=\(hasBinary) approved=\(isApproved)"
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
