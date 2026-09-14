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

/// What one row's button offers.
enum VerificationRowAction: Equatable {
    case run
    case rerun
    case stop
    case none
}

/// The per-row button, as a pure function of the live run and whether this check has a
/// recorded result.
///
/// A free function for the reason `verificationCanRun` is one: the branch order is the
/// thing worth pinning, and it should be testable without a view, a runner or a socket.
///
/// Three facts decide every branch, and all three are structural rather than stylistic:
///
/// - **One run per workstream.** `<id>-verify.sock` admits exactly one control server and
///   `Runner.start` refuses while `isLive`, so no row may offer to start anything while a
///   run is live.
/// - **There is no per-check stop.** `Runner.stop` is per-workstream and tears the whole
///   run down; stopping one check through the control API would report it `Completed` with
///   a non-zero code and seal it as a failure the user caused deliberately. So `.stop` is
///   offered **only** when this check is the entire live run, where stopping it and
///   stopping the run are the same act. During a Run all the rows show status and no
///   button, and the top bar's Stop is the only stop.
/// - **`isLive` is the runner's own bookkeeping, never `Run.isFinished`.** It stays true
///   through sealing and the socket teardown, which is the window a button keyed on
///   `isFinished` would re-enable in — letting a second `up` rebind the socket under the
///   run still tearing itself down.
///
/// `.rerun` is offered for *any* record, deliberately: `.passed`, `.failed`, `.skipped`
/// and `.stopped` all mean this check has been through a run, and re-running it is the
/// sensible next act in every one of them. A check that never started has no record, so it
/// offers `.run` — the honest offer rather than a "re-run" of nothing.
func verificationRowAction(
    liveRun: Verification.Run?,
    isLive: Bool,
    checkName: String,
    hasRecord: Bool
) -> VerificationRowAction {
    guard !isLive else {
        guard let liveRun, liveRun.checks.count == 1,
              liveRun.checks.first?.name == checkName
        else { return .none }
        return .stop
    }
    return hasRecord ? .rerun : .run
}

/// What one `refreshStaleness` call should do.
///
/// A free function for the reason `verificationAvailability` is one — "Pure,
/// so the branch order can be tested without an actor or a subprocess" — and
/// here the branch *order* is the whole of it, which is not a thing a
/// compiler can see.
///
/// **The in-flight guard comes first.** `hasRunOrRecord` is an `@autoclosure`
/// because that ordering is a promise about what is *not* evaluated: the
/// caller composes it from `currentRun != nil` and the workstream's own
/// `checkRecords`, and `currentRun` falls through to `Verification.Store.latest`
/// — a UserDefaults read plus a JSON decode of a run that may carry several
/// 200-line outputs — on the main actor. Evaluating it first meant the guard
/// that exists to absorb a ~5Hz burst of `.worktreeGitActivity` was paid for
/// by the very decode it was meant to avoid. Taking a plain `Bool` here would
/// put that cost back at every call site and leave nothing for a test to fail
/// on.
///
/// **Renamed from `hasRun`.** `CheckStore.save` fires per check, mid-run,
/// from `recordCompletion`, while `Verification.Store.save` fires only from
/// `seal` — so a session that quit after one check finished but before the
/// suite sealed leaves a `CheckRecord` behind with no stored `Verification.Run`.
/// `currentRun != nil` alone read that as "nothing to compare", which made
/// this skip forever on the next launch and left `currentStamp` nil — and
/// `verificationRecordIsStale` reads a nil `currentStamp` as stale, so every
/// row wore the marker permanently. The caller now passes `currentRun != nil
/// || !checkRecords.isEmpty`, which is what the parameter name has to say.
///
/// `.markPending` for a call with no run or record *and* a refresh in flight
/// is deliberate and costs at most one redundant refresh: the re-entrant call
/// at completion returns `.skip` without clearing the bit, so it stays set
/// until some later call gets past both guards. `currentRun` falls through to
/// the store, so it barely ever goes nil once a run has existed at all.
enum VerificationStalenessRefresh: Equatable {
    /// A hop is already in flight; record that another was asked for and let
    /// that hop's completion re-run this.
    case markPending
    /// Neither a run nor a record to compare a stamp against, so there is
    /// nothing to compute.
    case skip
    /// Start a `diffFingerprint` hop.
    case start
}

func verificationStalenessRefresh(
    isRefreshing: Bool, hasRunOrRecord: @autoclosure () -> Bool
) -> VerificationStalenessRefresh {
    guard !isRefreshing else { return .markPending }
    guard hasRunOrRecord() else { return .skip }
    return .start
}

/// The `hasRunOrRecord` the view passes above.
///
/// A free function rather than inline arithmetic at the call site because the
/// composition is the fix: `currentRun != nil` alone read a workstream that
/// quit mid-suite — after `recordCompletion` wrote a `CheckRecord` but before
/// `seal` wrote a `Verification.Run` — as having nothing to compare, so
/// `refreshStaleness` skipped forever, `currentStamp` stayed nil, and
/// `verificationRecordIsStale` reads a nil `currentStamp` as stale for every
/// row, permanently.
func verificationHasStalenessSubject(hasRun: Bool, hasAnyRecord: Bool) -> Bool {
    hasRun || hasAnyRecord
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
    /// run loop tears down once the run is sealed, and the tail
    /// `Runner.recordCompletions` takes on the way past is all that survives —
    /// so this is a check whose own fetch of that tail did not succeed.
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
/// **Live wins over captured, and the order is the point.** A check acquires
/// its captured tail from `Runner.recordCompletions` the moment it completes,
/// while `isLive` is still true — so for the last moments of
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

/// Whether one check's recorded result still describes the worktree.
///
/// The record-shaped sibling of `verificationIsStale`, and the reason there are
/// two: checks now complete at different moments, so staleness is a property of
/// a record rather than of a run. The run-shaped one stays because
/// `IPC.VerificationRunnerBridge.isStale` still asks it about a whole run. The
/// empty-stamp rule is unchanged and load-bearing — `""` means "the run's
/// baseline had not been captured yet", never "no diff".
func verificationRecordIsStale(record: Verification.CheckRecord, currentStamp: String?) -> Bool {
    guard !record.stamp.isEmpty else { return false }
    guard let currentStamp else { return true }
    return currentStamp != record.stamp
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
    // user's selection against the same filtered list, so the rows cannot
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
            // Hydrates every row drawn before this session has run anything, so
            // a workstream reopened tomorrow still shows yesterday's verdicts.
            // A no-op once the workstream has an in-memory entry, so it cannot
            // overwrite a live run's records with the store's older copy.
            //
            // Must run before `refreshStaleness()` below, not after: that call
            // reads `hasStalenessSubject`, which consults `runner.checkRecords`
            // for this workstream, and a record can exist with no stored run —
            // see `verificationStalenessRefresh`'s doc. Widening the gate alone
            // does not fix the first paint if the records it widens on are not
            // loaded yet when the gate is asked.
            runner.loadCheckRecords(for: workstreamID)
            refreshStaleness()
            syncWorktreeWatcher(hasRunOrRecord: hasStalenessSubject)
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
            // The watcher is armed while there is a run or a record to
            // compare against — see `hasStalenessSubject`.
            syncWorktreeWatcher(hasRunOrRecord: hasStalenessSubject)
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

    /// Whether `refreshStaleness` and the worktree watcher have anything to
    /// compare a fresh stamp against: a run, or any check's own record.
    ///
    /// Widened from "a run" alone — see `verificationStalenessRefresh`'s doc
    /// for why `currentRun != nil` on its own left every row's marker stuck on
    /// `.stale` after a relaunch that followed a mid-suite quit. The
    /// composition itself is `verificationHasStalenessSubject`, a free
    /// function, so a test can pin it directly rather than re-deriving the
    /// same boolean.
    private var hasStalenessSubject: Bool {
        verificationHasStalenessSubject(
            hasRun: currentRun != nil,
            hasAnyRecord: !(runner.checkRecords[workstreamID] ?? [:]).isEmpty
        )
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

            actionRow()

            if let startError {
                Text(startError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            // Unconditional, where this used to be `if let run`: the rows come
            // from the project's declared checks now, so they exist whether or
            // not anything has ever run here. The `ScrollView` stays — one row
            // per declared check can outgrow the pane.
            ScrollView {
                resultRows(run: run)
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

    private func actionRow() -> some View {
        HStack(spacing: 8) {
            Button(action: runAll) {
                Text("Run all")
            }
            .buttonStyle(.borderedProminent)
            // `isLive` is true for a single-check run started from a row just as
            // much as for a Run all, so pressing one row's Run disables this
            // until that run seals *and* its socket teardown returns.
            .disabled(!verificationCanRun(isLive: isLive))

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

    /// Rows come from the project's **declared** checks, not from the live run's.
    ///
    /// That is the whole of the redesign: a run started for one check contains
    /// only that check, and `Verification.Store` keeps only the latest run — so
    /// rows read off `run.checks` lost every other check's result the moment a
    /// single row's Run was pressed. Status comes from `Runner.checkRecords`,
    /// overridden by the live run's own row while a run is in flight.
    ///
    /// Staleness moved here with them: it is a per-row marker now, because the
    /// records it is computed from were written at different moments, and one
    /// run-level banner would be wrong for every row the latest run did not
    /// cover.
    private func resultRows(run: Verification.Run?) -> some View {
        let records = runner.checkRecords[workstreamID] ?? [:]
        let liveByName = Dictionary(
            (run?.checks ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(declaredProcesses, id: \.self) { name in
                let record = records[name]
                // Nil the instant this check is covered by the live run, same
                // as `liveCheck` below — otherwise a mid-re-run row reads
                // "running" and "stale" at once: `state` already prefers the
                // live check over the (now superseded) record, but `isStale`
                // was still computed from that record alone. That fires on
                // every re-run-after-edit, not just the once-a-session case.
                let liveCheck = isLive ? liveByName[name] : nil
                VerificationCheckRow(
                    name: name,
                    liveCheck: liveCheck,
                    record: record,
                    workstreamID: workstreamID,
                    runID: isLive ? run?.id : nil,
                    isLive: isLive,
                    isStale: liveCheck == nil ? (record.map {
                        verificationRecordIsStale(record: $0, currentStamp: currentStamp)
                    } ?? false) : false,
                    action: verificationRowAction(
                        liveRun: run, isLive: isLive, checkName: name, hasRecord: record != nil
                    ),
                    onRun: { runOne(name) },
                    onStop: stop,
                    // The expansion set lives in this view, not in the row.
                    // `runner` republishes at the poll cadence, so every row is
                    // rebuilt once a second for the length of a run; a `@State`
                    // in the row would survive that only for as long as SwiftUI
                    // kept its identity, which `ForEach` over a value whose
                    // `state` and `duration` both change is not a safe bet.
                    // Here it is a set of names, which nothing rebuilds.
                    isExpanded: expandedChecks.contains(name),
                    setExpanded: { expanded in
                        if expanded {
                            expandedChecks.insert(name)
                        } else {
                            expandedChecks.remove(name)
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

    /// Every runnable declared check. Never empty when this is reachable —
    /// `unavailableReason` is non-nil otherwise and the tab renders
    /// `unavailableView`.
    private func runAll() {
        startRun(checks: declaredProcesses)
    }

    private func runOne(_ name: String) {
        startRun(checks: [name])
    }

    private func startRun(checks: [String]) {
        startError = nil
        // Never an empty list: `Verification.Runner.resolveChecks` reads no
        // names as *run everything*, so an empty array here would silently
        // invert a single row's press into a whole-suite run. `runAll` passes
        // the declared list explicitly rather than relying on that convention —
        // which is also what the deleted `runFailed`, with its `?? []`, got
        // wrong.
        guard !checks.isEmpty else { return }
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

    /// Arm the worktree watcher while there is a result to go stale, and not
    /// otherwise.
    ///
    /// Created lazily rather than in an initialiser: `@State` initial values are
    /// built for every view SwiftUI makes, and this one owns an FSEvents stream.
    private func syncWorktreeWatcher(hasRunOrRecord: Bool) {
        guard hasRunOrRecord else {
            worktreeWatcher?.disarm()
            worktreeWatcher = nil
            return
        }
        if worktreeWatcher == nil {
            worktreeWatcher = Verification.StalenessWatcher { refreshStaleness() }
        }
        worktreeWatcher?.arm(path: worktreePath)
    }

    /// Recomputes `currentStamp` off the main actor, the same way
    /// `ChangesView.fullLoad` computes its own fingerprint: `diffFingerprint`
    /// spawns `git hash-object` in batches over the dirty tree, and this is
    /// called from `.onAppear` and from a notification that fires on every
    /// git-activity event in the worktree — running that on the main actor
    /// would stall the tab's own redraw on every keystroke-adjacent save.
    ///
    /// Two guards keep that notification cheap rather than merely
    /// off-actor: nothing here is rendered without a run or a record to
    /// compare against — `currentStamp` is only read for a row that has a
    /// `CheckRecord`. **A record can exist where no run does**:
    /// `CheckStore.save` fires per check, mid-run, from `recordCompletion`,
    /// while `Verification.Store.save` fires only from `seal` — so a session
    /// that quit after one check finished but before the suite sealed leaves
    /// a `CheckRecord` with no stored `Verification.Run`, which is why
    /// `hasStalenessSubject` asks about both. (The two keys are still
    /// *cleared* together, by `Workstream.Archiver` — that half of the old
    /// claim here was right; only "cannot exist where no run does" was not.)
    /// And `HeadWatcher` can fire at up to ~5Hz during ordinary agent
    /// activity — its own doc says the watched directory is noisy — so a
    /// computation already in flight absorbs a burst instead of queuing a
    /// matching burst of `git` spawns behind it. Absorbed, not discarded: see
    /// `stalenessRefreshPending` for why the run-completion trigger cannot
    /// afford to have its request dropped.
    ///
    /// Those two guards, and the order they have to be asked in, are
    /// `verificationStalenessRefresh` — extracted so a test can fail on the
    /// order rather than only on the answer.
    private func refreshStaleness() {
        switch verificationStalenessRefresh(
            isRefreshing: isRefreshingStaleness, hasRunOrRecord: hasStalenessSubject
        ) {
        case .markPending:
            stalenessRefreshPending = true
            return
        case .skip:
            return
        case .start:
            break
        }
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
    let name: String
    /// This check's row in the run currently in flight, when there is one and it
    /// covers this check. Nil for every row while nothing is live.
    let liveCheck: Verification.CheckResult?
    /// The last recorded result for this check, from any run.
    let record: Verification.CheckRecord?
    let workstreamID: UUID
    /// The live run's id, when one is live. Part of the poll task's identity, so
    /// a second run discards the first one's output rather than appearing to
    /// resume it.
    let runID: String?
    let isLive: Bool
    let isStale: Bool
    let action: VerificationRowAction
    let onRun: () -> Void
    let onStop: () -> Void
    let isExpanded: Bool
    let setExpanded: (Bool) -> Void
    @ObservedObject var runner: Verification.Runner

    /// The live run wins while it covers this check; otherwise the record;
    /// otherwise the check has never run.
    private var state: Verification.CheckResult.State {
        liveCheck?.state ?? record?.state ?? .notRun
    }

    private var duration: TimeInterval? {
        liveCheck?.duration ?? record?.duration
    }

    private var output: String? {
        liveCheck?.output ?? record?.output
    }

    private var outputTruncated: Bool {
        liveCheck?.outputTruncated ?? record?.outputTruncated ?? false
    }

    /// The last tail read from the live control server, newest last.
    ///
    /// **Does not survive the run ending, and that is a consequence of
    /// `runID` itself going nil at seal** (`runID: isLive ? run?.id : nil`,
    /// where this row is built) rather than a separate decision made here.
    /// `displayedLines` requires a non-nil `runID` that matches what was
    /// stored, so the instant the run stops being live these lines stop being
    /// shown — nothing is labelled "the last output read from it"; the row
    /// falls straight through to the captured tail.
    ///
    /// That is an acceptable loss rather than a regression, because a
    /// replacement exists on the other side of the fall-through:
    /// `Runner.recordCompletions` now takes the captured tail for **every**
    /// check at its own completion edge, not only for failures the way it did
    /// before this tab read from `checkRecords`. So sealing loses a few
    /// seconds of "freshest possible" text, not the output itself — the one
    /// case with no replacement is `.notKept`, where the log fetch itself
    /// threw and no tail was ever captured to fall through to.
    ///
    /// The run id is still stored beside the lines rather than cleared on
    /// `.onChange(of: runID)`, because `ForEach` keys on `CheckResult.id`
    /// (the check's name), so the same name in run 2 may or may not be the
    /// same view as in run 1 — only one of the three possible answers
    /// ("identity kept, change observed") would clear anything. Carrying the
    /// id makes every answer correct: `displayedLines` hands back nothing for
    /// a read belonging to a run this row is no longer showing, whether or
    /// not any `onChange` ever fired — including the seal itself, which is
    /// just another case of "no longer showing that run".
    @State private var liveRead: LiveRead?

    /// A tail, and the run it was read from.
    private struct LiveRead: Equatable {
        let runID: String
        var lines: [String]
    }

    /// The live lines this row may show: the ones read from *this* run, and
    /// never a previous one's.
    ///
    /// `runID` is nil whenever nothing is live, so this also hands back nothing
    /// once the run that produced the lines has sealed.
    private var displayedLines: [String] {
        guard let liveRead, let runID, liveRead.runID == runID else { return [] }
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

    /// Fixed, so the `.none` placeholder above can hold the column open.
    private static let buttonWidth: CGFloat = 20

    private var content: VerificationOutputContent {
        // `isLive && liveCheck != nil`, not `isLive` alone: during a single-check
        // run every *other* row is live-adjacent but has nothing on the server to
        // read, and polling for it would be a socket round trip per second for a
        // check this run never started.
        verificationOutputContent(
            state: state, hasCapturedOutput: output != nil, isLive: isLive && liveCheck != nil
        )
    }

    /// What restarts the poll task. Every input that can turn polling on or
    /// off, and nothing that merely changes with each poll — a `duration` or a
    /// line count in here would cancel and respawn the task it belongs to.
    private var pollKey: String {
        "\(runID ?? "-")|\(name)|\(isExpanded)|\(content == .live)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if isExpanded {
                // Indented to the name above it, which is what a disclosure
                // triangle used to do for free. There is no triangle now: the
                // row *is* the control — see `header`.
                outputBody
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
        .task(id: pollKey) {
            guard isExpanded, content == .live, let runID else { return }
            while !Task.isCancelled {
                // Nil is every reason there is nothing to read — the run
                // ended, the server went away, the check is not this run's.
                // `content` flips away from `.live` on the next republish and
                // cancels this task; until then, keep what was last read.
                if let lines = await runner.liveLog(workstreamID: workstreamID, check: name) {
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
        // **Not cleared here on seal, and that is deliberate — but it does
        // not need to be, because `displayedLines` already stops showing
        // these lines the instant `runID` goes nil.** `pollKey` carries
        // liveness, so the task restarts the moment the run seals; clearing
        // `liveRead` here too would be redundant with that, not protective of
        // anything the user is reading — see `liveRead`'s own comment for why
        // sealing already ends the window.
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
            // **The row is the disclosure control.** There is no triangle: the
            // tappable area is the whole row bar the run button, because a
            // check's own button must not collapse the output the user pressed
            // it to watch. A `Button` rather than an `.onTapGesture` on the
            // `HStack`, since a tap gesture is invisible to VoiceOver and
            // unreachable from the keyboard — and with the triangle gone this
            // is the only way to open a check's output at all.
            Button {
                setExpanded(!isExpanded)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: verificationRowGlyph(state))
                        .foregroundStyle(verificationStateColor(state))
                        .frame(width: 16)
                        // The glyph alone is a thin signal: `.notRun`
                        // (`circle.dashed`) and `.running` (`circle.dotted`)
                        // differ by a few pixels at this size, with color as the
                        // practical differentiator, and nowhere else in the row
                        // does the state appear as text. VoiceOver gets the word
                        // a sighted user reads from a glance at shape and hue.
                        //
                        // Inside the toggle `Button`, SwiftUI merges this with
                        // the name, the stale marker and the duration into one
                        // accessibility element — intended, not incidental: the
                        // row is one control now, and its label should read as
                        // one sentence ("failed, rspec, stale, 12.4s") rather
                        // than as four stops.
                        .accessibilityLabel(verificationStateWord(state))
                    Text(name)
                        .font(.system(size: 11, design: .monospaced))
                    // Per row rather than per run, because the records behind the
                    // rows were written at different moments — a suite-wide banner
                    // would be wrong for every check the latest run did not cover.
                    if isStale {
                        Text("stale")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .accessibilityLabel(
                                Text("This result no longer reflects the worktree's current content.")
                            )
                    }
                    Spacer()
                    if let duration {
                        Text(verificationFormattedDuration(duration))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                // Explicit rather than inferred from the `Spacer` above: the
                // label has to *be* full width before `.contentShape` has a
                // full-width rectangle to shape, and whether `.buttonStyle(.plain)`
                // propagates a label's flexibility is not something a build
                // failure would tell us about. Without it the row looks
                // clickable across its width and is not.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded
                ? Text("Hides this check's output.")
                : Text("Shows this check's output."))
            .help(isExpanded ? Text("Hide output") : Text("Show output"))

            runButton
        }
    }

    /// The row's one button, icon-only.
    ///
    /// `Run` and `Re-run` share `play.fill` deliberately, where they used to be
    /// two words: the distinction between them is "has this check a result
    /// already", which is exactly what the status glyph at the other end of the
    /// row draws — a second rendering of the same fact, in the one column whose
    /// meaning should be "press this to start this check". The words survive as
    /// the accessibility label and the tooltip, which is where a distinction a
    /// glyph cannot carry belongs. `verificationRowAction` is untouched: it
    /// still decides *which* act is offered, including the `.stop` that is only
    /// legal when this check is the whole live run.
    @ViewBuilder
    private var runButton: some View {
        switch action {
        case .run:
            iconButton(systemName: "play.fill", label: Text("Run"), action: onRun)
        case .rerun:
            iconButton(systemName: "play.fill", label: Text("Re-run"), action: onRun)
        case .stop:
            iconButton(systemName: "stop.fill", label: Text("Stop"), action: onStop)
        case .none:
            // A placeholder rather than nothing. Every row loses its button for
            // the length of a run, and the duration beside it is right-aligned
            // against it — so an `EmptyView` here would slide every row's timing
            // sideways the moment a run starts, and back again when it seals.
            //
            // The placeholder is the *same button*, hidden, rather than a
            // `Color.clear` of `buttonWidth`: `.borderless` adds insets of its
            // own, so a bare spacer sized to the image's frame is narrower than
            // what it stands in for and the column still jogs.
            iconButton(systemName: "play.fill", label: Text("Run"), action: {})
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private func iconButton(
        systemName: String, label: Text, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .frame(width: Self.buttonWidth, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .help(label)
    }

    /// What the open group shows, in priority order: the live server, then
    /// what the run captured, then why there is nothing.
    ///
    /// This is not simply a switch over `content` because the first branch
    /// also has to say something for a live check with nothing printed yet —
    /// `content == .live` covers both. There is no separate "just sealed"
    /// branch: `displayedLines` already goes empty the instant `runID` does
    /// (see `liveRead`), so a row falls straight from `.live` to `.captured`
    /// or `.notKept` with nothing shown in between.
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
        } else if let output, !output.isEmpty {
            // **`!isEmpty`, and the guard is not decoration.** A check whose log
            // came back empty is recorded with `output: ""` rather than nil —
            // which is what keeps `.notKept` out of reach for a check that
            // completed — so `let output` alone rendered an empty scrolling box
            // with nothing to say about it. The concrete case is a skipped
            // check: a `depends_on` failure produces no lines by definition.
            // Such a row falls through to the final branch instead, which is
            // the sentence that fits it.
            logWindow(output)
            if outputTruncated {
                note(NSLocalizedString(
                    "Showing the last lines captured. There is nothing more to fetch: the run's own output no longer exists anywhere.",
                    comment: ""
                ))
            }
        } else if content == .notKept {
            // Must not read as "we failed to fetch it" or imply a fetch could
            // still be made: the output lived in the control server, the run
            // loop tore that server down, and the window is one-shot.
            //
            // **Reachable only for a check that ran** — `.notKept` requires
            // `verificationStateProducedOutput`, which is false for `.notRun`,
            // so a never-run check lands in the final branch and not here. The
            // non-stopped case is a check that completed while its tail could
            // not be fetched: `Runner.recordCompletions` catches a failing
            // `client.logs` and records `output: nil`, and `seal` passes a nil
            // `check.output` through for a check whose server died between
            // polls. That loss is permanent, which is why the runner logs it as
            // a warning, and this is the only surface that tells the user.
            //
            // A stopped check gets its own sentence because it is the one case
            // the user caused: same fact, told to the person who chose it.
            note(state == .stopped
                ? NSLocalizedString(
                    "This check was stopped before its output could be kept. Re-run it to see the output.",
                    comment: "Verification tab: a check the user stopped, whose output was not kept"
                )
                : NSLocalizedString(
                    "This check's output was not kept. Re-run it to see the output.",
                    comment: "Verification tab: a completed check whose output could not be captured"
                ))
        } else {
            // `.notStarted`, plus the empty-captured-output fall-through above —
            // so `content` is not always `.notStarted` here, and a check that
            // *did* run can reach this. `.notRun` is the one state that has a
            // next step to offer; `.pending`, `.skipped` and a check that ran
            // and printed nothing all get the plain statement.
            note(state == .notRun
                ? NSLocalizedString(
                    "This check has not run yet. Run it to see its output.",
                    comment: "Verification tab: a check with no recorded result"
                )
                : NSLocalizedString(
                    "This check has not produced any output.",
                    comment: "Verification tab: a check that is waiting, was skipped, or printed nothing"
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
