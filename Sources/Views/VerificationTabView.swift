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

/// Whether the process checklist should render.
///
/// Hidden while live, not merely disabled: `Verification.Runner.start` reads
/// the stored selection once, when Run is pressed, so a checkbox toggled
/// mid-run silently affects nothing until the next Run — the same reasoning
/// `showsProcessSelection` gives for hiding Execution's checklist
/// (`ExecutionTabView.swift:83`). This tab used to keep the list visible and
/// merely `.disabled(isLive)` it; that let a user click a box that could not
/// take effect, which is a confusing state to be in while a run is going.
///
/// The empty-list guard is not cosmetic: an empty list would make
/// `ProcessSelectionView`'s own `.onAppear` read the stored selection as
/// "nothing survived" and overwrite it with the canonical "all" — see
/// `processSelectionOnLoad`.
func verificationShowsChecklist(isLive: Bool, declaredProcesses: [String]) -> Bool {
    !isLive && !declaredProcesses.isEmpty
}

/// Whether `run`'s result no longer reflects the worktree's current content.
///
/// Compares `run.stamp` — `Git.Operations.diffFingerprint` at the moment the
/// run started — against `currentStamp`, the same fingerprint computed now.
/// `nil` for `currentStamp` is not evidence of freshness: it means the
/// fingerprint could not be computed this pass (or has not been computed
/// yet), which is a reason to distrust the result, not to trust it.
///
/// An empty `run.stamp` is the other direction, and is not the same fact: it
/// means the run's own baseline has not been captured yet — `Runner.start`
/// leaves it empty and `Runner.execute` fills it off the main actor, within
/// milliseconds — so there is nothing to compare against rather than something
/// that failed to match. A real fingerprint is always `head|count|digest`, so
/// `""` cannot arise any other way. Without this branch a run rendered the
/// "no longer reflects the worktree's current content" banner for the first
/// instant of its life, over a suite that had not even started.
func verificationIsStale(run: Verification.Run, currentStamp: String?) -> Bool {
    guard !run.stamp.isEmpty else { return false }
    guard let currentStamp else { return true }
    return currentStamp != run.stamp
}

/// Present-tense wording for the tab's own empty state, when nothing can run
/// yet.
///
/// A present-tense rendering of the same three preconditions `PhasePolicy.plan`
/// evaluates — the unattended-phase gate `Verification.Runner.start` calls
/// before spawning anything — in the same order. `PhasePolicy`'s own strings
/// are past tense ("so no `verify` ran"), because they report on bootstrap
/// and dispose after the fact; this tab has not run anything yet, so none of
/// these may read as a report on a run that already happened. This function
/// takes facts its caller has already resolved rather than doing any I/O
/// itself — no config lookup, no binary resolution, no approval hash.
///
/// **This function is not the decision, and must not be treated as one.**
/// The call site — `TerminalContainerView`, the same way `refreshDevCommand`
/// already resolves `ExecutionTabView`'s equivalent state — is required to
/// take *whether anything can run* from `PhasePolicy.plan(phase: .verify, …)`
/// itself, and to call this function only for the copy, only once `plan`
/// has returned `.nothingToDo`. `ExecutionTabView.swift:117-122` is this
/// codebase's own ruling on exactly that split: "Passed in, never re-derived
/// here... the button's enablement and the run's guard are one decision."
/// An unresolvable binary rendering an enabled button that explains nothing
/// is the failure that ruling exists to prevent, and it is reachable again
/// here if a caller lets this function's three booleans stand in for `plan`'s
/// own verdict instead of following it.
///
/// **Nothing enforces that split.** This function hand-mirrors `plan`'s three
/// preconditions in the same order; it does not call `plan` and cannot check
/// that it agrees with it. The agreement is a convention the call site must
/// honour, not a compiler-checked property — if `PhasePolicy` ever gains a
/// fourth precondition, it has to be added here too, by hand, and nothing
/// will fail to compile if that step is missed. It lost one the other way when
/// the process-compose switch was removed, and that removal had to be made
/// here by hand too.
///
/// - Parameter declared: the checks the located config declares in the
///   `verify` namespace, or `nil` when the config exists but could not be
///   parsed — distinct from an empty array, which means it parsed and named
///   nothing. Only consulted once the first three preconditions all hold; a
///   caller must not pass a meaningful value here while any earlier
///   precondition is false; the guards below never reach it in that case.
func verificationUnavailableReason(
    hasConfig: Bool,
    hasBinary: Bool,
    isApproved: Bool,
    declared: [String]?
) -> String? {
    guard hasConfig else {
        return NSLocalizedString(
            "Add an atelier.process-compose.yaml to this worktree or the project directory to declare checks.",
            comment: "Verification tab: unavailable because no config was located"
        )
    }
    guard hasBinary else {
        // Same string `ProcessCompose.RunCommandPlan.unavailableReason` uses
        // for the same fact, and already present tense.
        return NSLocalizedString(
            "process-compose was not found. Install it, then refresh Detected Tools in Settings.",
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

/// Everything the Verification tab needs to know about whether it can run:
/// the checks to offer, and the wording for why it cannot.
///
/// **The decision is `PhasePolicy.plan`'s.** `Verification.Runner.start` calls
/// `plan(phase: .verify, …)` before it spawns anything, so this asks the same
/// question of the same function rather than re-deriving an answer beside it —
/// `ExecutionTabView.canStart`'s doc records what the second copy cost: "They
/// used to be two […] and an unresolvable process-compose binary rendered an
/// enabled Start that did nothing and explained nothing."
/// `verificationUnavailableReason` is called for the *wording* only, from the
/// very parameters `plan` was handed, so the two cannot disagree about the
/// facts. `plan`'s own strings are past tense ("so no `verify` ran") and never
/// reach this surface.
///
/// The agreement is structural rather than hopeful. `isApproved` is taken as
/// `plan`'s own closure — asked only where a config exists — and the one
/// expression below folds in `requiresApproval` exactly as `plan`'s guard
/// does, then feeds *that* to both `plan` and the wording. So `plan` returns
/// `.run` **iff** all three preconditions hold, which is **iff**
/// `verificationUnavailableReason`'s first three guards all fall through, and
/// `VerificationTabViewTests` pins that biconditional against `plan` itself.
/// A `Bool` parameter here could not promise it: passing `false` for a config
/// in the project directory, which needs no approval, made this function
/// refuse what `plan` was happily running — caught by that test, which is the
/// reason this parameter is a closure.
///
/// **`.run` is not the whole of availability**, and that is why the declared
/// list is consulted here rather than left to the caller. `plan` answers three
/// preconditions and stops, so a config whose `verify` namespace is empty — or
/// that could not be parsed at all — still comes back `.run`, while `start`
/// refuses both: `Failure.unavailable` for the parse failure, and
/// `resolveChecks` for an empty declared list, because `up -n verify` on an
/// empty namespace never exits. The list is read off `plan`'s **own returned
/// config**, never a second `locate`, so the checks offered and the config
/// `start` will run are one config, and nil-for-unparseable survives the trip.
///
/// A free function for the reason `PhasePolicy` gives for being one — "Pure, so
/// the branch order can be tested without an actor or a subprocess". It takes
/// facts its caller has already resolved and performs no lookup of its own
/// beyond reading the located config's own files.
///
/// - Parameter isApproved: whether the user has approved this config's
///   repository-provided files. Passed as a closure, and with no default, for
///   the reasons `PhasePolicy.plan` gives for its own: it is only asked where a
///   config exists, and every call site has to state its policy.
/// - Returns: `declared` is empty whenever nothing can run, and `reason` is nil
///   exactly when something can.
func verificationAvailability(
    config: ProcessCompose.Config?,
    binary: String?,
    isApproved: (ProcessCompose.Config) -> Bool
) -> (declared: [String], reason: String?) {
    // `plan`'s approval guard, as a value: a config the user placed in the
    // project directory needs no approval, so "not approved" is not a refusal
    // there. Computed once and handed to both `plan` and the wording below, so
    // neither can be judging a different fact from the other.
    let approvalHolds = config.map { !$0.requiresApproval || isApproved($0) } ?? false
    let plan = PhasePolicy.plan(
        phase: .verify,
        config: config,
        binary: binary,
        isApproved: { _ in approvalHolds }
    )
    // `runnableChecks` is `Verification.Runner`'s own filter, and calling it
    // here rather than repeating it is the point: `Runner.start` resolves the
    // user's selection against the same filtered list, so the checklist cannot
    // offer a check the runner would refuse or silently drop. A process named
    // like a flag — `-n` is legal YAML — is dropped by `PhaseRunner.command`
    // before it reaches the shell, and offering it made the *only*-selected
    // case run the entire namespace. See `runnableChecks`.
    let declared: [String]? = switch plan {
    case let .run(planConfig, _):
        planConfig.declaredProcesses(in: ProcessCompose.Phase.verify.namespace)
            .map(Verification.Runner.runnableChecks)
    case .nothingToDo:
        nil
    }
    return (
        declared: declared ?? [],
        reason: verificationUnavailableReason(
            hasConfig: config != nil,
            hasBinary: binary != nil,
            isApproved: approvalHolds,
            declared: declared
        )
    )
}

/// The Verification tab. Runs a project's declared `verify` checks and shows
/// each one's result.
///
/// Availability is **passed in, never re-derived here** — the same ruling
/// `ExecutionTabView.canStart`'s own doc states for its equivalent state:
/// "They used to be two [...] and an unresolvable process-compose binary
/// rendered an enabled Start that did nothing and explained nothing." A first
/// implementation of this view resolved `declaredProcesses` and
/// `unavailableReason` itself, on every `.onAppear`, by calling
/// `ProcessCompose.Config.locate`, `ProcessCompose.Settings.resolveBinary()`
/// and `ScriptTrust.isApproved` directly — a config lookup, a file stat and a
/// SHA-256 over the approval-relevant files, all on the main actor, and stale
/// the moment either Settings' process-compose binary path or the config's
/// approval state changed without the tab happening to
/// re-appear. `TerminalContainerView` already holds all three facts as
/// trigger-refreshed state for `ExecutionTabView`'s sake
/// (`refreshDevCommand`); Task 10 is expected to resolve this tab's
/// `declaredProcesses`/`unavailableReason` the same way, from the same
/// triggers, and hand them in.
struct VerificationTabView: View {
    let workstreamID: UUID
    let worktreePath: String
    let projectDirectory: String
    let projectName: String
    let workstreamName: String
    /// The checks the located config declares in the `verify` namespace, or
    /// empty when there is nothing to run (including when `unavailableReason`
    /// is non-nil — the caller is not required to have anything meaningful
    /// here in that case).
    let declaredProcesses: [String]
    /// Present-tense wording for why nothing can run yet, or nil when it can.
    /// Produced by the caller from `verificationUnavailableReason`, fed the
    /// same three facts `PhasePolicy.plan` — the gate `Verification.Runner.start`
    /// itself calls — evaluates, so this tab's idea of "nothing to run" can
    /// never disagree with what `start` will actually refuse.
    let unavailableReason: String?
    @ObservedObject var runner: Verification.Runner

    /// `Git.Operations.diffFingerprint` computed just now, or nil before the
    /// first computation lands. Compared against a run's own `stamp` by
    /// `verificationIsStale`.
    @State private var currentStamp: String?
    @State private var startError: String?
    /// Bumped on every staleness refresh; a completion whose token no longer
    /// matches belongs to a refresh this view has already superseded — the
    /// same guard `ChangesView.fullLoad` uses against its own git hop.
    @State private var stalenessGeneration = 0
    /// Set for the lifetime of one `diffFingerprint` hop. `HeadWatcher`
    /// debounces at only 200ms and its own doc warns the watched directory is
    /// noisy — ordinary agent activity rewrites `index` with HEAD unchanged —
    /// so a burst of git-activity notifications must not queue up a matching
    /// burst of `git diff --stat` / `hash-object` spawns. A newly-arrived
    /// request while one is already in flight is redundant: the in-flight one
    /// will read whatever the tree looks like when it actually runs `git`,
    /// which is at least as current as a request queued behind it.
    @State private var isRefreshingStaleness = false
    /// A refresh that arrived while one was already in flight, to be run once
    /// it lands.
    ///
    /// The in-flight guard alone is right for a burst of git-activity
    /// notifications — the running hop reads the tree at least as late as a
    /// request queued behind it — but it is wrong for the run-completion
    /// trigger, and silently so: a hop started when the run *began* may have
    /// read the tree before a check that writes to it had finished, and
    /// dropping the completion request would leave that pre-run answer
    /// standing. One pending bit rather than a queue, because every waiting
    /// request wants the same thing: one more read, after this one.
    @State private var stalenessRefreshPending = false

    var body: some View {
        // One read of `currentRun` per body evaluation, threaded through both
        // the content subviews and the run-appearing trigger below. That getter
        // falls through to `Verification.Store.latest` whenever there is no live
        // run — a UserDefaults read plus a JSON decode — and it used to be
        // evaluated twice per body: once here for `.onChange(of:)` and once
        // inside `content`.
        let run = currentRun
        return Group {
            if let unavailableReason {
                unavailableView(reason: unavailableReason)
            } else {
                content(run: run)
            }
        }
        .onAppear {
            refreshStaleness()
        }
        .onReceive(NotificationCenter.default.publisher(for: .worktreeGitActivity)) { notification in
            guard notification.object as? String == worktreePath else { return }
            refreshStaleness()
        }
        // A run appearing. `.onAppear` cannot cover this: `refreshStaleness`
        // bails while there is no run to compare against, so on the first run
        // of a session nothing had ever computed `currentStamp` and
        // `verificationIsStale` read nil as stale — a result rendered stale the
        // instant it arrived. It also covers a run started after uncommitted
        // edits that caused no git-directory activity, where the last computed
        // stamp predates the edits and a current result would read as stale.
        .onChange(of: run?.id) {
            refreshStaleness()
        }
        // A run *ending*, which is the case the trigger above cannot answer: a
        // check that writes to the tree — a formatter, codegen — leaves
        // `run.stamp` at what the tree looked like before it ran, so a
        // genuinely stale result would render fresh until something else
        // recomputed. Keyed on the runner's own liveness for the reason
        // `verificationCanRun` is: every row goes terminal a moment before the
        // run seals, so `Run.isFinished` would fire this too early.
        .onChange(of: isLive) {
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

    /// The run is passed in rather than read here, so `body` reads it once for
    /// the whole evaluation — see the note there. Each of
    /// `failureDetailBanner`/`actionRow`/`resultRows` would otherwise re-read
    /// `currentRun`, and with no live run that getter goes to UserDefaults.
    private func content(run: Verification.Run?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detail = run?.failureDetail {
                failureDetailBanner(detail)
            }

            // Hidden, not merely disabled, while a run is live —
            // `verificationShowsChecklist`'s own doc. The gate folds in the
            // empty-list guard too: a momentarily-empty list would make
            // `ProcessSelectionView`'s own `.onAppear` read the stored
            // selection as "nothing survived" and overwrite it with the
            // canonical "all" — see `processSelectionOnLoad`.
            if verificationShowsChecklist(isLive: isLive, declaredProcesses: declaredProcesses) {
                ProcessSelectionView(
                    workstreamID: workstreamID,
                    declaredProcesses: declaredProcesses,
                    store: .verify,
                    lastSelectedHelp: NSLocalizedString("At least one check has to run.", comment: "")
                )
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
        // `alignment: .top` is `Alignment(.center, .top)`, so this frame centres
        // its content horizontally by default. The VStack above stays
        // left-aligned only because `actionRow`'s `HStack` ends in a `Spacer()`
        // that forces the row — and with it the VStack — to full width.
        // Removing that `Spacer()` in an unrelated change would silently
        // re-centre the whole tab.
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

            // Load-bearing: this is what keeps `content`'s outer frame from
            // centring the whole VStack — see the comment on that frame.
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
                    // The glyph alone is a thin signal: `.notRun`
                    // (`circle.dashed`) and `.running` (`circle.dotted`)
                    // differ by a few pixels at this size, with color as the
                    // practical differentiator, and nowhere else in the row
                    // does the state appear as text. VoiceOver gets the word
                    // a sighted user reads from a glance at shape and hue.
                    .accessibilityLabel(stateWord(check.state))
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
                // Bounded, not left to grow with `detail`: `PhaseExecutor`
                // keeps up to 2000 characters of process output for exactly
                // this message (`PhaseExecutor.detailLimit`), and an
                // unbounded block here would steal the pane from the results
                // below it and walk the action row down — the same failure
                // the per-check output `ScrollView` below is already bounded
                // against.
                ScrollView {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
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

    /// The word VoiceOver reads for a check's glyph — see `resultRow`'s
    /// accessibility label for why the glyph cannot carry this alone.
    private func stateWord(_ state: Verification.CheckResult.State) -> String {
        switch state {
        case .notRun:
            NSLocalizedString("Not run", comment: "Verification tab: check state, accessibility label")
        case .pending:
            NSLocalizedString("Pending", comment: "Verification tab: check state, accessibility label")
        case .running:
            NSLocalizedString("Running", comment: "Verification tab: check state, accessibility label")
        case .passed:
            NSLocalizedString("Passed", comment: "Verification tab: check state, accessibility label")
        case .failed:
            NSLocalizedString("Failed", comment: "Verification tab: check state, accessibility label")
        case .skipped:
            NSLocalizedString("Skipped", comment: "Verification tab: check state, accessibility label")
        case .stopped:
            NSLocalizedString("Stopped", comment: "Verification tab: check state, accessibility label")
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

    /// Recomputes `currentStamp` off the main actor, the same way
    /// `ChangesView.fullLoad` computes its own fingerprint: `diffFingerprint`
    /// spawns `git hash-object` in batches over the dirty tree, and this is
    /// called from `.onAppear` and from a notification that fires on every
    /// git-activity event in the worktree — running that on the main actor
    /// would stall the tab's own redraw on every keystroke-adjacent save.
    ///
    /// Two guards keep that notification cheap rather than merely
    /// off-actor: nothing here is rendered without a run to compare against
    /// (`currentStamp` is only read by `resultRows`, which only exists when
    /// `currentRun` does), and `HeadWatcher` can fire at up to ~5Hz during
    /// ordinary agent activity — its own doc says the watched directory is
    /// noisy — so a computation already in flight absorbs a burst instead of
    /// queuing a matching burst of `git` spawns behind it. Absorbed, not
    /// discarded: see `stalenessRefreshPending` for why the run-completion
    /// trigger cannot afford to have its request dropped.
    private func refreshStaleness() {
        // **The in-flight guard comes first, and the order is the whole point.**
        // `currentRun` falls through to `Verification.Store.latest` — a
        // UserDefaults read plus a JSON decode of a run that may carry several
        // 200-line outputs — on the main actor. Evaluating it first meant the
        // guard that exists to absorb a ~5Hz burst of `.worktreeGitActivity`
        // was paid for by the very decode it was meant to avoid.
        //
        // Semantics are unchanged: the pending re-run re-evaluates
        // `currentRun` for itself. The one difference is that a call arriving
        // with no run *and* a refresh in flight now sets the pending bit, and
        // the re-entrant call at completion returns on the nil guard without
        // clearing it — so the bit stays set until some later call gets past
        // both guards and clears it, costing at most one redundant refresh at
        // the tail of a future hop. `currentRun` falls through to the store, so
        // it barely ever goes nil once a run has existed at all.
        guard !isRefreshingStaleness else {
            stalenessRefreshPending = true
            return
        }
        guard currentRun != nil else { return }
        isRefreshingStaleness = true
        stalenessRefreshPending = false
        stalenessGeneration += 1
        let token = stalenessGeneration
        let path = worktreePath
        let projectPath = projectDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let stamp = Git.Operations.diffFingerprint(
                worktreePath: path, projectPath: projectPath, mode: "uncommitted"
            )
            DispatchQueue.main.async {
                isRefreshingStaleness = false
                // A later refresh (another activity event, or the view
                // reappearing) may have started and finished while this git
                // hop was in flight; an older completion must not overwrite
                // its answer.
                if token == stalenessGeneration {
                    currentStamp = stamp
                }
                // Runs after the assignment above, so a pending request only
                // ever replaces this answer with a later one.
                if stalenessRefreshPending {
                    refreshStaleness()
                }
            }
        }
    }
}
