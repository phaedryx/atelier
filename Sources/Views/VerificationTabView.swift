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

/// Whether the **Run** button may be pressed: no run is live, and the checklist
/// leaves at least one check to run.
///
/// Separate from `verificationCanRun` because "Run failed" is gated on liveness
/// alone — it runs `run.failedNames`, not the checklist's selection, so an empty
/// checklist has nothing to say about it.
///
/// The selection can be empty at all because every box may now be unchecked;
/// the last one used to be `.disabled`. `runAll` refuses the same state, from
/// the same store, so the button and the run agree — `Verification.Runner`
/// reads no check names as *run everything*, which is the opposite of what an
/// empty checklist asked for.
func verificationCanRunSelection(isLive: Bool, hasChecks: Bool) -> Bool {
    verificationCanRun(isLive: isLive) && hasChecks
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

/// What one check's disclosure group has to show.
///
/// A separate question from what state the check is in, and the reason it is
/// a value rather than a chain of `if`s in the row body: the same `.failed`
/// check shows live output mid-run, a captured tail once the run is sealed,
/// and — if the log fetch failed — nothing at all, and only the last of those
/// is visible in `CheckResult.State`. The row polls **iff** this is `.live`,
/// so it is also the gate that keeps a collapsed or sealed group off the wire.
enum VerificationOutputContent: Equatable {
    /// The control server is up and holds this check's output. Poll it.
    case live
    /// The run is sealed and a tail of this check's output was kept.
    case captured
    /// The check produced output and none of it survives.
    ///
    /// Not a failure to look: the log lived in the control server, which the
    /// run loop tears down once the run is sealed, and only a *failed* check's
    /// tail is captured on the way past — see `Runner.captureFailedOutput`.
    /// Re-running the check is the only way to see it, and the copy for this
    /// case has to say so rather than imply a fetch could still be made.
    case notKept
    /// The check has produced no output, and not because any was lost.
    case notStarted
}

/// Whether a check in this state has produced output at all.
///
/// `.skipped` is the one worth stating: process-compose reports it for a check
/// whose `depends_on` failed, so it never ran and has nothing to show — which
/// is `.notStarted` and emphatically not `.notKept`, since nothing was lost.
private func verificationStateProducedOutput(_ state: Verification.CheckResult.State) -> Bool {
    switch state {
    case .running, .passed, .failed, .stopped:
        true
    case .notRun, .pending, .skipped:
        false
    }
}

/// What a check's group shows, given the run's liveness and what it kept.
///
/// **Live wins over captured, and the order is the point.** A failed check
/// acquires its captured tail from `Runner.captureFailedOutput` in the window
/// before teardown, while `isLive` is still true — so for the last moments of
/// a run both sources exist, and the live one is the fuller of the two: the
/// capture is a tail taken once, and the server still has whatever arrived
/// after it.
///
/// A pure lookup for the reason the rest of this file's decisions are:
/// `Tests/VerificationTabViewTests.swift` can pin every state against both
/// liveness values without a view tree, a socket or a run.
func verificationOutputContent(
    state: Verification.CheckResult.State,
    hasCapturedOutput: Bool,
    isLive: Bool
) -> VerificationOutputContent {
    let produced = verificationStateProducedOutput(state)
    if isLive, produced {
        return .live
    }
    if hasCapturedOutput {
        return .captured
    }
    return produced ? .notKept : .notStarted
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
/// The call site — `ProcessCompose.ResolutionModel`, which resolves
/// `ExecutionTabView`'s equivalent state in the same pass — is required to
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
///   `verify` namespace **as parsed, before `Verification.Runner.runnableChecks`**,
///   or `nil` when the config exists but could not be parsed — distinct from an
///   empty array, which means it parsed and named nothing. Only consulted once
///   the first three preconditions all hold; a caller must not pass a meaningful
///   value here while any earlier precondition is false; the guards below never
///   reach it in that case.
///
///   **Unfiltered, and the distinction is the whole of the third case below.**
///   Handing the filtered list here is what made a project whose only checks
///   are named like flags report "This project declares no verify checks" —
///   untrue, and undiagnosable, because the checklist is empty and Run is
///   disabled so there is no request left that could explain itself. This
///   function applies the filter itself, through the same one copy
///   `Runner.start` uses, so the three cases stay three.
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
    // A third case, and not a restatement of the one above it: the namespace
    // declares checks and none of them can be started. `runnableChecks` is the
    // one copy of that filter — a flag-injection guard shared with `execute`,
    // never to be weakened here — so this reports the situation rather than
    // trying to run such a check, and it borrows the request path's own
    // sentence so the two cannot drift. Reached only when *every* declared name
    // is flag-shaped; one among several simply does not appear in the checklist.
    guard !Verification.Runner.runnableChecks(declared).isEmpty else {
        return Verification.Runner.unrunnableChecksMessage(declared)
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
    // Two lists, deliberately: the *offered* one is filtered, and the wording
    // needs the unfiltered one to tell "declares nothing" from "declares
    // nothing runnable". Both come off `plan`'s own returned config, so neither
    // is a second `locate`, and nil-for-unparseable survives into both.
    let parsed: [String]? = switch plan {
    case let .run(planConfig, _):
        planConfig.declaredProcesses(in: ProcessCompose.Phase.verify.namespace)
    case .nothingToDo:
        nil
    }
    return (
        declared: parsed.map(Verification.Runner.runnableChecks) ?? [],
        reason: verificationUnavailableReason(
            hasConfig: config != nil,
            hasBinary: binary != nil,
            isApproved: approvalHolds,
            declared: parsed
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
/// approval state changed without the tab happening to re-appear.
/// `ProcessCompose.ResolutionModel` holds all three facts and resolves this
/// tab's `declaredProcesses`/`unavailableReason` in the same pass as
/// `ExecutionTabView`'s — off the main actor, from the triggers
/// `TerminalContainerView` owns — and hands them in.
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
    /// Bumped whenever the checklist writes a selection.
    ///
    /// A trigger, not a value — `hasChecksToRun` re-reads the store, which is
    /// the one authoritative copy, the same shape `TerminalContainerView` uses
    /// for Execution's half. Never read; assigning any `@State` re-runs the
    /// body, which is all this has to do, and deleting it as unused would leave
    /// the Run button stuck on the selection the tab was built with.
    @State private var selectionChanges = 0
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
    /// Which checks have their output group open, by name.
    ///
    /// Held here rather than in the row for two reasons, and the second is the
    /// one that matters. `runner` republishes on every poll, so the rows are
    /// rebuilt once a second for the length of a run and a `@State` inside one
    /// would depend on SwiftUI keeping its identity across a value whose
    /// `state`, `duration` and `output` all change — recoverable, but not
    /// something to stake a scroll position on. And expansion is what gates
    /// `VerificationCheckRow`'s live polling, so it is the one decision that
    /// determines how many sockets this tab opens per second; a set of names
    /// in one place is inspectable, a bag of child states is not.
    ///
    /// Deliberately **not** cleared when a new run starts: the names are the
    /// same checks, and a user who opened `rspec` to watch it wants it open
    /// for the next run too.
    @State private var expandedChecks: Set<String> = []

    /// Watches the worktree itself for the edits `.worktreeGitActivity` cannot
    /// see — an ordinary save touches nothing inside `.git`, so a result on a
    /// tab the user is sitting on kept reading fresh. `@State` so it lives as
    /// long as this view does; armed and disarmed from the triggers below, never
    /// from `body`. See `Verification.StalenessWatcher` for what bounds its cost.
    @State private var worktreeWatcher: Verification.StalenessWatcher?

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
            syncWorktreeWatcher(hasRun: currentRun != nil)
        }
        .onDisappear {
            // The tab leaves the tree on every tab switch, and an FSEvents
            // stream on a whole worktree is not something to leave running for
            // a pane nobody is looking at. Released as well as disarmed: its
            // `onChange` captures this view, so a disarmed watcher still held
            // here is a retained view per mount — the same pairing
            // `stopFileTreeWatcherIfUnneeded` makes.
            worktreeWatcher?.disarm()
            worktreeWatcher = nil
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
            // The watcher is armed only while there is a run to compare
            // against, and the first run of a session is when that becomes
            // true.
            syncWorktreeWatcher(hasRun: run != nil)
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
    /// `detailBanner`/`actionRow`/`resultRows` would otherwise re-read
    /// `currentRun`, and with no live run that getter goes to UserDefaults.
    private func content(run: Verification.Run?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detail = run?.failureDetail {
                detailBanner(
                    headline: Text("The run itself failed to start its checks"), detail: detail
                )
            }
            // A second banner, not a second spelling of the first: the run did
            // report on some checks here, so "the run itself failed to start its
            // checks" is false — and dropping the executor's text with the
            // headline left the rows that say "not run" with no explanation
            // anywhere. `Run.unstartedChecksDetail` carries it. The two fields
            // are mutually exclusive where they are set (`Runner.execute`), so
            // at most one of these draws.
            if let detail = run?.unstartedChecksDetail {
                detailBanner(headline: Text("Some checks never started"), detail: detail)
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
                    onSelectionChange: { selectionChanges += 1 }
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
            .disabled(!verificationCanRunSelection(isLive: isLive, hasChecks: hasChecksToRun))

            // Beside the disabled button rather than in a tooltip on it: a
            // tooltip on a disabled control is how the checklist used to
            // explain its own dimmed checkbox, which is to say not at all.
            if !isLive, !hasChecksToRun {
                Text("Select a check to run.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

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
                VerificationCheckRow(
                    check: check,
                    workstreamID: workstreamID,
                    runID: run.id,
                    isLive: isLive,
                    // The expansion set lives in this view, not in the row.
                    // `runner` republishes at the poll cadence, so every row is
                    // rebuilt once a second for the length of a run; a `@State`
                    // in the row would survive that only for as long as SwiftUI
                    // kept its identity, which `ForEach` over a value whose
                    // `state` and `duration` both change is not a safe bet.
                    // Here it is a set of names, which nothing rebuilds.
                    isExpanded: expandedChecks.contains(check.name),
                    setExpanded: { expanded in
                        if expanded {
                            expandedChecks.insert(check.name)
                        } else {
                            expandedChecks.remove(check.name)
                        }
                    },
                    runner: runner
                )
                Divider()
            }
        }
    }

    /// One banner shape, two headlines — see the call site for why the headline
    /// is the part that has to differ.
    private func detailBanner(headline: Text, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                headline
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

    // MARK: - Actions

    /// Whether the checklist leaves anything for Run to run. Read from the
    /// store rather than held, so it cannot drift from what `runAll` resolves
    /// out of the same key a moment later.
    private var hasChecksToRun: Bool {
        Verification.selection(for: workstreamID).namesToRun != nil
    }

    private func runAll() {
        // The same store the Run button's enabled state is read from, so the
        // two cannot disagree. Nil is the checklist's "nothing", and it has to
        // stop here: `Runner.start` reads an empty list as every check.
        guard let checks = Verification.selection(for: workstreamID).namesToRun else { return }
        startRun(checks: checks)
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
    /// Arm the worktree watcher while there is a result to go stale, and not
    /// otherwise.
    ///
    /// Created lazily rather than in an initialiser: `@State` initial values are
    /// built for every view SwiftUI makes, and this one owns an FSEvents stream.
    private func syncWorktreeWatcher(hasRun: Bool) {
        guard hasRun else {
            worktreeWatcher?.disarm()
            worktreeWatcher = nil
            return
        }
        if worktreeWatcher == nil {
            worktreeWatcher = Verification.StalenessWatcher { refreshStaleness() }
        }
        worktreeWatcher?.arm(path: worktreePath)
    }

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

private func verificationStateColor(_ state: Verification.CheckResult.State) -> Color {
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

/// The word VoiceOver reads for a check's glyph — see `VerificationCheckRow`'s
/// accessibility label for why the glyph cannot carry this alone.
private func verificationStateWord(_ state: Verification.CheckResult.State) -> String {
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

private func verificationFormattedDuration(_ duration: TimeInterval) -> String {
    String(format: "%.1fs", duration)
}

/// One check's row: its state, its name, its duration, and a disclosure group
/// holding its output.
///
/// A `View` rather than a method on `VerificationTabView` because it has to
/// hold state — the lines read from the live control server, and the poll task
/// that reads them. Its own `@State` is only ever a cache of what the server
/// said; the decision of *whether* it may poll is `isExpanded` and
/// `verificationOutputContent`, both passed in.
struct VerificationCheckRow: View {
    let check: Verification.CheckResult
    let workstreamID: UUID
    /// The run these lines belong to. Part of the poll task's identity, so a
    /// second run discards the first one's output rather than appearing to
    /// resume it.
    let runID: String
    let isLive: Bool
    let isExpanded: Bool
    let setExpanded: (Bool) -> Void
    @ObservedObject var runner: Verification.Runner

    /// The last tail read from the live control server, newest last.
    ///
    /// **Kept after the run ends, and that is deliberate.** The server is torn
    /// down once the run seals, so these lines stop being refreshable — but
    /// they are real output that was really read, and clearing them would empty
    /// a window the user is in the middle of reading at the exact moment the
    /// run finishes. They are labelled as the last read rather than as live.
    ///
    /// The rule is "an open group keeps what it read while it was open": a new
    /// run replaces them, and closing the group ends the session that owned
    /// them — so a group opened for the first time after a run shows the honest
    /// `.notKept` note rather than a cache nothing told the user about.
    ///
    /// **The run id is stored beside the lines rather than used to clear them,
    /// and that is what makes the first half of that rule true without
    /// depending on SwiftUI.** Clearing on an `.onChange(of: runID)` would
    /// require this row to keep its view identity across two runs — `ForEach`
    /// keys on `CheckResult.id`, which is the check's *name*, so the same name
    /// in run 2 may or may not be the same view as in run 1, and only one of
    /// the three possible answers ("identity kept, change observed") clears
    /// anything. Carrying the id makes every answer correct: `displayedLines`
    /// hands back nothing for a read belonging to a run this row is no longer
    /// showing, whether or not any `onChange` ever fired.
    @State private var liveRead: LiveRead?

    /// A tail, and the run it was read from.
    private struct LiveRead: Equatable {
        let runID: String
        var lines: [String]
    }

    /// The live lines this row may show: the ones read from *this* run, and
    /// never a previous one's.
    private var displayedLines: [String] {
        guard let liveRead, liveRead.runID == runID else { return [] }
        return liveRead.lines
    }

    /// Gap between live reads. Matches `Verification.Runner`'s own poll and
    /// `ProcessCompose.TableModel`'s, which is the cadence this tab's rows are
    /// already republished at — a faster log poll would render into frames that
    /// do not exist.
    private static let pollInterval = Duration.seconds(1)

    /// Bound on the output window, for the reason the failed-check group has
    /// always had one: an unbounded block here walks the action row off the
    /// pane, the same failure `processChecklistHeight` prevents for the
    /// checklist.
    private static let outputHeight: CGFloat = 200

    private var content: VerificationOutputContent {
        verificationOutputContent(
            state: check.state, hasCapturedOutput: check.output != nil, isLive: isLive
        )
    }

    /// What restarts the poll task. Every input that can turn polling on or
    /// off, and nothing that merely changes with each poll — a `duration` or a
    /// line count in here would cancel and respawn the task it belongs to.
    private var pollKey: String {
        "\(runID)|\(check.name)|\(isExpanded)|\(content == .live)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            DisclosureGroup(
                isExpanded: Binding(get: { isExpanded }, set: setExpanded)
            ) {
                outputBody
            } label: {
                Text("Output")
            }
            .font(.system(size: 10))
        }
        .padding(.vertical, 4)
        .task(id: pollKey) {
            guard isExpanded, content == .live else { return }
            while !Task.isCancelled {
                // Nil is every reason there is nothing to read — the run
                // ended, the server went away, the check is not this run's.
                // `content` flips away from `.live` on the next republish and
                // cancels this task; until then, keep what was last read.
                if let lines = await runner.liveLog(workstreamID: workstreamID, check: check.name) {
                    let read = LiveRead(runID: runID, lines: lines)
                    if liveRead != read {
                        liveRead = read
                    }
                }
                // Awaited before sleeping rather than fired on a timer, for the
                // reason `TableModel.startPolling` gives: one request can block
                // for longer than the interval, and a timer would stack reads
                // on a server that is already slow.
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        // **Not cleared in the task above, and that is the point.** `pollKey`
        // carries liveness, so the task restarts the moment the run seals — a
        // reset there would empty the window at exactly the instant the user is
        // reading the end of it, which is what these lines are kept past the
        // run to avoid.
        //
        // Closing the group ends the session that owned the lines. A new run is
        // handled by `displayedLines` instead of by a second `onChange` here,
        // so it does not depend on this row keeping its identity across runs —
        // see `liveRead`.
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                liveRead = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: verificationRowGlyph(check.state))
                .foregroundStyle(verificationStateColor(check.state))
                .frame(width: 16)
                // The glyph alone is a thin signal: `.notRun`
                // (`circle.dashed`) and `.running` (`circle.dotted`)
                // differ by a few pixels at this size, with color as the
                // practical differentiator, and nowhere else in the row
                // does the state appear as text. VoiceOver gets the word
                // a sighted user reads from a glance at shape and hue.
                .accessibilityLabel(verificationStateWord(check.state))
            Text(check.name)
                .font(.system(size: 11, design: .monospaced))
            Spacer()
            if let duration = check.duration {
                Text(verificationFormattedDuration(duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// What the open group shows, in priority order: the live server, then the
    /// last thing read from it, then what the run captured, then why there is
    /// nothing.
    ///
    /// The middle branch is why this is not simply a switch over `content`:
    /// lines read live outlive the run that produced them for as long as the
    /// group stays open, and they are at least as fresh as the captured tail —
    /// `Runner.captureFailedOutput` takes its copy in the same window this was
    /// polling.
    @ViewBuilder
    private var outputBody: some View {
        let live = displayedLines
        if content == .live {
            if live.isEmpty {
                note(NSLocalizedString(
                    "No output yet.",
                    comment: "Verification tab: a live check that has printed nothing so far"
                ))
            } else {
                logWindow(live.joined(separator: "\n"))
            }
        } else if !live.isEmpty {
            logWindow(live.joined(separator: "\n"))
            note(NSLocalizedString(
                "The run has ended. This is the last output read from it.",
                comment: "Verification tab: live output kept on screen after its run finished"
            ))
        } else if let output = check.output {
            logWindow(output)
            if check.outputTruncated {
                note(NSLocalizedString(
                    "Showing the last lines captured. There is nothing more to fetch: the run's own output no longer exists anywhere.",
                    comment: ""
                ))
            }
        } else if content == .notKept {
            // Must not read as "we failed to fetch it" or imply a fetch could
            // still be made: the output lived in the control server, the run
            // loop tore that server down, and only a failed check's tail is
            // kept on the way past. Re-running is the honest pointer.
            //
            // A stopped check gets its own sentence because the general one is
            // wrong for it: "output is only kept for a check that failed" reads
            // as an explanation to someone who did not choose this, and a user
            // who pressed Stop did. Same fact, told to the person who caused it.
            note(check.state == .stopped
                ? NSLocalizedString(
                    "This check was stopped before its output could be kept. Re-run it to see the output.",
                    comment: "Verification tab: a check the user stopped, whose output was not kept"
                )
                : NSLocalizedString(
                    "Output is only kept for a check that failed. Re-run this check to see its output.",
                    comment: "Verification tab: a check whose output was not kept past its run"
                ))
        } else {
            note(NSLocalizedString(
                "This check has not produced any output.",
                comment: "Verification tab: a check that has not run, is waiting, or was skipped"
            ))
        }
    }

    /// The scrolling window itself, pinned to the newest line.
    ///
    /// One `Text` over joined lines rather than a `ForEach` of them: the tail
    /// is `Verification.Runner.logTailLines` long and this redraws once a
    /// second per open group, which is a few hundred view identities per second
    /// for nothing. The anchor below it is what `scrollTo` addresses, since a
    /// single `Text` has no per-line ids to aim at.
    private func logWindow(_ text: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
            }
            .frame(maxHeight: Self.outputHeight)
            // Follows the newest line, which is the whole point of watching a
            // check run. Keyed on the text rather than on a line count so a
            // rewritten last line — a progress bar, a spinner — still scrolls.
            .onChange(of: text) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private static let bottomAnchor = "verification-log-bottom"

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
