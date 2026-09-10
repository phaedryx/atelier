// ABOUTME: The Verification tab — runs a project's `verify` namespace and shows per-check results.
// ABOUTME: One-shot: the control server the run's own output lives in is torn down after sealing.

import SwiftUI

/// The glyph for one check's current state.
///
/// A pure lookup, tested for the property that actually matters: no two
/// states may share a glyph, because a skipped check reading as a failure —
/// or a not-run one reading as a pass — is a worse lie than an ugly icon.
/// Ignores `.failed`'s associated exit code on purpose: which code produced a
/// failure does not change that it is one.
func verificationRowGlyph(_ state: Verification.CheckResult.State) -> String {
    switch state {
    case .notRun:
        "circle.dashed"
    case .pending:
        "clock"
    case .running:
        "circle.dotted"
    case .passed:
        "checkmark.circle.fill"
    case .failed:
        "xmark.circle.fill"
    case .skipped:
        "arrow.uturn.forward.circle"
    case .stopped:
        "stop.circle"
    }
}

/// Whether Run may be pressed.
///
/// Gated on the runner's own liveness bookkeeping, never on `Run.isFinished`:
/// a run's rows all go terminal for the last stretch of its life, while the
/// spawn is still winding down and the control server is still up on
/// `<id>-verify.sock`. A button that re-enabled there would let a second
/// `start` rebind that socket out from under the run still tearing itself
/// down. `Verification.Runner.isLive` is the one correct answer to "is a run
/// live here"; this function's only job is to read it as a button state.
func verificationCanRun(isLive: Bool) -> Bool {
    !isLive
}

/// Whether `run`'s result no longer reflects the worktree's current content.
///
/// Compares `run.stamp` — `Git.Operations.diffFingerprint` at the moment the
/// run started — against `currentStamp`, the same fingerprint computed now.
/// `nil` for `currentStamp` is not evidence of freshness: it means the
/// fingerprint could not be computed this pass (or has not been computed
/// yet), which is a reason to distrust the result, not to trust it.
func verificationIsStale(run: Verification.Run, currentStamp: String?) -> Bool {
    guard let currentStamp else { return true }
    return currentStamp != run.stamp
}

/// Present-tense wording for the tab's own empty state, when nothing can run
/// yet.
///
/// Reads the same four preconditions `PhasePolicy.plan` evaluates — the
/// unattended-phase gate `Verification.Runner.start` calls before spawning
/// anything — in the same order, so the *decision* here is one copy with that
/// gate; only the *rendering* is separate. `PhasePolicy`'s own strings are
/// past tense ("so no `verify` ran"), because they report on bootstrap and
/// dispose after the fact; this tab has not run anything yet, so none of
/// these may read as a report on a run that already happened.
///
/// - Parameter declared: the checks the located config declares in the
///   `verify` namespace, or `nil` when the config exists but could not be
///   parsed — distinct from an empty array, which means it parsed and named
///   nothing. Only consulted once the first four preconditions all hold; a
///   caller must not pass a meaningful value here while any earlier
///   precondition is false; the guards below never reach it in that case.
func verificationUnavailableReason(
    isEnabled: Bool,
    hasConfig: Bool,
    hasBinary: Bool,
    isApproved: Bool,
    declared: [String]?
) -> String? {
    guard isEnabled else {
        return NSLocalizedString(
            "The process-compose integration is off. Turn it on in Settings to run checks.",
            comment: "Verification tab: unavailable because the integration is switched off"
        )
    }
    guard hasConfig else {
        return NSLocalizedString(
            "Add a process-compose.yaml to this worktree or the project directory to declare checks.",
            comment: "Verification tab: unavailable because no config was located"
        )
    }
    guard hasBinary else {
        // Same string `ProcessCompose.RunCommandPlan.unavailableReason` uses
        // for the same fact, and already present tense.
        return NSLocalizedString(
            "process-compose was not found. Install it, or set its path in Settings, then try again.",
            comment: ""
        )
    }
    guard isApproved else {
        return NSLocalizedString(
            "This project's process-compose files came with the repository and need your approval before checks can run.",
            comment: "Verification tab: unavailable because the repository-provided config is not approved"
        )
    }
    guard let declared else {
        // Same fact `Verification.Runner.Failure.unavailable` reports for a
        // parse failure, and deliberately the same string: this one is
        // already present tense, so there is nothing to reword.
        return NSLocalizedString(
            "This project's process-compose files could not be parsed, so its verify checks are unknown.",
            comment: ""
        )
    }
    guard !declared.isEmpty else {
        return NSLocalizedString(
            "This project declares no verify checks.",
            comment: "Verification tab: unavailable because the verify namespace is empty"
        )
    }
    return nil
}

/// The Verification tab. Runs a project's declared `verify` checks and shows
/// each one's result.
///
/// Self-sufficient by design, unlike `ExecutionTabView`: that view is fed its
/// availability by `TerminalContainerView` because it shares state with the
/// live process table and the run terminal. Verification has neither — a run
/// here is headless and one-shot — so this view resolves its own config,
/// binary and approval state from `worktreePath` and `projectDirectory`
/// rather than taking them as parameters.
struct VerificationTabView: View {
    let workstreamID: UUID
    let worktreePath: String
    let projectDirectory: String
    let projectName: String
    let workstreamName: String
    @ObservedObject var runner: Verification.Runner

    @State private var declaredProcesses: [String]
    @State private var unavailableReason: String?
    /// `Git.Operations.diffFingerprint` computed just now, or nil before the
    /// first computation lands. Compared against a run's own `stamp` by
    /// `verificationIsStale`.
    @State private var currentStamp: String?
    @State private var startError: String?
    /// Bumped on every staleness refresh; a completion whose token no longer
    /// matches belongs to a refresh this view has already superseded — the
    /// same guard `ChangesView.fullLoad` uses against its own git hop.
    @State private var stalenessGeneration = 0

    /// Resolves availability *before* the first render, not only in
    /// `.onAppear`.
    ///
    /// `onAppear` fires after SwiftUI has already built the view tree for
    /// that first pass, so writing `declaredProcesses` there only takes
    /// effect on the *next* render. In between, the first `ProcessSelectionView`
    /// this view constructs would see an empty `declaredProcesses` — no
    /// preconditions failed, the real list just has not been read yet — and
    /// its own `.onAppear` reconciles the stored selection against that empty
    /// list: `processSelectionOnLoad(stored: [...], declared: [])` finds no
    /// survivors and writes the canonical "all" back over whatever the user
    /// had unchecked. Computing here means the list `ProcessSelectionView`
    /// first sees is already the real one.
    init(
        workstreamID: UUID,
        worktreePath: String,
        projectDirectory: String,
        projectName: String,
        workstreamName: String,
        runner: Verification.Runner
    ) {
        self.workstreamID = workstreamID
        self.worktreePath = worktreePath
        self.projectDirectory = projectDirectory
        self.projectName = projectName
        self.workstreamName = workstreamName
        self.runner = runner
        let resolved = Self.resolveAvailability(worktreePath: worktreePath, projectDirectory: projectDirectory)
        _declaredProcesses = State(initialValue: resolved.declared)
        _unavailableReason = State(initialValue: resolved.reason)
    }

    var body: some View {
        Group {
            if let unavailableReason {
                unavailableView(reason: unavailableReason)
            } else {
                content
            }
        }
        .onAppear {
            refreshAvailability()
            refreshStaleness()
        }
        .onReceive(NotificationCenter.default.publisher(for: .worktreeGitActivity)) { notification in
            guard notification.object as? String == worktreePath else { return }
            refreshStaleness()
        }
    }

    // MARK: - Content

    private var currentRun: Verification.Run? {
        runner.runs[workstreamID] ?? Verification.Store.latest(for: workstreamID)
    }

    private var isLive: Bool {
        runner.isLive(workstreamID)
    }

    private var content: some View {
        // Read once per render and threaded through, rather than each of
        // `failureDetailBanner`/`actionRow`/`resultRows` re-reading
        // `currentRun`: with no live run, that getter falls through to
        // `Verification.Store.latest`, a UserDefaults read plus a JSON
        // decode, and three reads of an unchanging value in one render pass
        // buys nothing.
        let run = currentRun
        return VStack(spacing: 12) {
            if let detail = run?.failureDetail {
                failureDetailBanner(detail)
            }

            // Guarded on a non-empty list, not just on availability: the
            // first render after this view is constructed has already run
            // `resolveAvailability` (see `init`), but a defensive guard here
            // means a future caller of `refreshAvailability()` mid-lifetime
            // can never hand `ProcessSelectionView` a momentarily-empty list
            // either — which is what would make its own `.onAppear` read the
            // stored selection as "nothing survived" and overwrite it with
            // the canonical "all".
            if !declaredProcesses.isEmpty {
                ProcessSelectionView(
                    workstreamID: workstreamID,
                    declaredProcesses: declaredProcesses,
                    store: .verify,
                    lastSelectedHelp: NSLocalizedString("At least one check has to run.", comment: "")
                )
                .disabled(isLive)
            }

            actionRow(run: run)

            if let startError {
                Text(startError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            if let run {
                ScrollView {
                    resultRows(for: run)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func actionRow(run: Verification.Run?) -> some View {
        HStack(spacing: 8) {
            Button(action: runAll) {
                Text("Run")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!verificationCanRun(isLive: isLive))

            if let run, !run.failedNames.isEmpty {
                Button(action: runFailed) {
                    Text("Run failed")
                }
                .buttonStyle(.bordered)
                .disabled(!verificationCanRun(isLive: isLive))
            }

            if isLive {
                Button(action: stop) {
                    Text("Stop")
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
    }

    private func resultRows(for run: Verification.Run) -> some View {
        let stale = verificationIsStale(run: run, currentStamp: currentStamp)
        return VStack(alignment: .leading, spacing: 0) {
            if stale {
                Text("This result no longer reflects the worktree's current content.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.bottom, 6)
            }
            ForEach(run.checks) { check in
                resultRow(check)
                Divider()
            }
        }
    }

    private func resultRow(_ check: Verification.CheckResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: verificationRowGlyph(check.state))
                    .foregroundStyle(color(for: check.state))
                    .frame(width: 16)
                Text(check.name)
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                if let duration = check.duration {
                    Text(formattedDuration(duration))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if case .failed = check.state, let output = check.output {
                DisclosureGroup(NSLocalizedString("Output", comment: "Verification tab: failed check's captured output")) {
                    ScrollView {
                        Text(output)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    // Fixed, not `.infinity`: an unbounded block here would
                    // walk the action row off the pane — the same failure
                    // `processChecklistHeight` exists to prevent for the
                    // checklist above.
                    .frame(maxHeight: 200)
                    if check.outputTruncated {
                        Text(
                            "Showing the last lines captured. There is nothing more to fetch: the run's own output no longer exists anywhere."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 10))
            }
        }
        .padding(.vertical, 4)
    }

    private func failureDetailBanner(_ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("The run itself failed to start its checks")
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
    }

    private func unavailableView(reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Nothing to verify yet")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(for state: Verification.CheckResult.State) -> Color {
        switch state {
        case .passed:
            .green
        case .failed:
            .red
        case .running:
            .blue
        case .skipped, .stopped:
            .orange
        case .notRun, .pending:
            .secondary
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.1fs", duration)
    }

    // MARK: - Actions

    private func runAll() {
        startRun(checks: Verification.selected(for: workstreamID))
    }

    private func runFailed() {
        startRun(checks: currentRun?.failedNames ?? [])
    }

    private func startRun(checks: [String]) {
        startError = nil
        do {
            _ = try runner.start(
                workstreamID: workstreamID,
                projectName: projectName,
                workstreamName: workstreamName,
                worktreePath: worktreePath,
                projectDirectory: projectDirectory,
                checks: checks
            )
        } catch {
            startError = (error as? Verification.Runner.Failure)?.errorDescription ?? error.localizedDescription
        }
    }

    private func stop() {
        runner.stop(workstreamID: workstreamID)
    }

    // MARK: - Refresh

    /// Resolves the same four preconditions `PhasePolicy.plan` evaluates, so
    /// the tab's own empty state agrees with what `runner.start` will
    /// actually refuse. Cheap enough to run on the main actor — a config
    /// lookup and a file stat, the same calls
    /// `TerminalContainerView.refreshDevCommand` already makes synchronously
    /// for the Execution tab's equivalent state.
    ///
    /// A `static` function, not an instance method: `init` needs the same
    /// resolution before `self` exists (see `declaredProcesses`'s doc for
    /// why), so this takes its inputs as parameters instead of reading
    /// `worktreePath`/`projectDirectory` off `self`.
    private static func resolveAvailability(
        worktreePath: String, projectDirectory: String
    ) -> (declared: [String], reason: String?) {
        let isEnabled = ProcessCompose.Settings.isEnabled
        let config = ProcessCompose.Config.locate(worktree: worktreePath, projectDirectory: projectDirectory)
        let binary = ProcessCompose.Settings.resolveBinary()
        let isApproved = config.map {
            !$0.requiresApproval || ScriptTrust.isApproved(
                configFiles: $0.repositoryProvidedFiles, for: projectDirectory
            )
        } ?? true
        let declared = config?.declaredProcesses(in: ProcessCompose.Phase.verify.namespace)

        let reason = verificationUnavailableReason(
            isEnabled: isEnabled,
            hasConfig: config != nil,
            hasBinary: binary != nil,
            isApproved: isApproved,
            declared: declared
        )
        return (declared ?? [], reason)
    }

    private func refreshAvailability() {
        let resolved = Self.resolveAvailability(worktreePath: worktreePath, projectDirectory: projectDirectory)
        declaredProcesses = resolved.declared
        unavailableReason = resolved.reason
    }

    /// Recomputes `currentStamp` off the main actor, the same way
    /// `ChangesView.fullLoad` computes its own fingerprint: `diffFingerprint`
    /// spawns `git hash-object` in batches over the dirty tree, and this is
    /// called from `.onAppear` and from a notification that fires on every
    /// git-activity event in the worktree — running that on the main actor
    /// would stall the tab's own redraw on every keystroke-adjacent save.
    private func refreshStaleness() {
        stalenessGeneration += 1
        let token = stalenessGeneration
        let path = worktreePath
        let projectPath = projectDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let stamp = Git.Operations.diffFingerprint(
                worktreePath: path, projectPath: projectPath, mode: "uncommitted"
            )
            DispatchQueue.main.async {
                // A later refresh (another activity event, or the view
                // reappearing) may have started and finished while this git
                // hop was in flight; an older completion must not overwrite
                // its answer.
                guard token == stalenessGeneration else { return }
                currentStamp = stamp
            }
        }
    }
}
