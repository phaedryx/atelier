// ABOUTME: The Verification tab — one row per declared check, each with its own terminal.
// ABOUTME: A check's output lives in that surface and nowhere else; it dies with the app.

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

/// What one row's button offers.
enum VerificationRowAction: Equatable {
    /// Start a check that has no result, or whose last result was a stop.
    case run
    /// Start a check that has been through a run.
    case rerun
    /// Stop the check running in this row.
    case stop
}

/// The per-row button, as a pure function of this check's own state.
///
/// **Per check, never per run.** Checks are independent — one terminal surface
/// each, no shared server and no shared lifetime — so a row offers Stop exactly
/// when *that* check is running, and every other row keeps its own offer. The
/// predecessor of this function could only offer `.stop` when the check was the
/// entire live run, because stopping meant tearing down a process-compose server
/// the whole suite shared; nothing is shared now.
///
/// **A stopped check offers `.run`, not `.rerun`, and that is the one branch a
/// reader would get wrong.** `hasRecord` alone said "re-run" for it, since a stop
/// does record a result. But a stop is the user deciding this check should not
/// have run, so the honest next offer is the same one an untouched check gets.
/// `.rerun` is for a check that actually produced a verdict — passed, failed, or
/// skipped.
func verificationRowAction(
    isRunning: Bool,
    recordedState: Verification.CheckResult.State?
) -> VerificationRowAction {
    guard !isRunning else { return .stop }
    switch recordedState {
    case .none, .some(.notRun), .some(.stopped), .some(.pending), .some(.running):
        return .run
    case .some(.passed), .some(.failed), .some(.skipped):
        return .rerun
    }
}

/// What one `refreshStaleness` call should do.
///
/// A free function so the branch *order* can be tested without an actor or a
/// subprocess, which is the whole of it and not a thing a compiler can see.
///
/// **The in-flight guard comes first.** `hasRunOrRecord` is an `@autoclosure`
/// because that ordering is a promise about what is *not* evaluated: the caller
/// composes it from the runner's own state, and evaluating it first would pay
/// for the very work the guard exists to avoid when a burst of
/// `.worktreeGitActivity` arrives.
enum VerificationStalenessRefresh: Equatable {
    /// A hop is already in flight; record that another was asked for and let
    /// that hop's completion re-run this.
    case markPending
    /// No record to compare a stamp against, so there is nothing to compute.
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

/// Whether one check's recorded result still describes the worktree.
///
/// `nil` for `currentStamp` is not evidence of freshness: it means the
/// fingerprint could not be computed this pass (or has not been computed yet),
/// which is a reason to distrust the result, not to trust it.
///
/// An empty `record.stamp` is the other direction and is not the same fact: it
/// means the run's own baseline was never captured, so there is nothing to
/// compare against rather than something that failed to match. A real
/// fingerprint is always `head|count|digest`, so `""` cannot arise any other
/// way.
func verificationRecordIsStale(record: Verification.CheckRecord, currentStamp: String?) -> Bool {
    guard !record.stamp.isEmpty else { return false }
    guard let currentStamp else { return true }
    return currentStamp != record.stamp
}

/// Whether a whole run's results still describe the worktree.
///
/// The run-shaped sibling of `verificationRecordIsStale`, kept because
/// `IPC.VerificationRunnerBridge.isStale` asks the question about a run. The
/// empty-stamp rule is the same and equally load-bearing.
func verificationIsStale(run: Verification.Run, currentStamp: String?) -> Bool {
    guard !run.stamp.isEmpty else { return false }
    guard let currentStamp else { return true }
    return currentStamp != run.stamp
}

struct VerificationTabView: View {
    let workstreamID: UUID
    let worktreePath: String
    let projectDirectory: String
    let projectName: String
    let workstreamName: String
    /// The checks `verification.yaml` declares, **in file order**. Empty when
    /// `unavailableReason` is non-nil.
    let declaredProcesses: [String]
    /// Present-tense wording for why nothing can run yet, or nil when it can.
    /// `Verification.Config.Load.unavailableReason`, produced by the caller from
    /// the same load `Verification.Runner.start` performs — so the tab's empty
    /// state cannot disagree with what `start` will refuse.
    let unavailableReason: String?
    @ObservedObject var runner: Verification.Runner

    /// `Git.Operations.diffFingerprint` computed just now, or nil before the
    /// first computation lands.
    @State private var currentStamp: String?
    @State private var startError: String?
    /// Bumped on every staleness refresh; a completion whose token no longer
    /// matches belongs to a refresh this view has already superseded.
    @State private var stalenessGeneration = 0
    /// Set for the lifetime of one `diffFingerprint` hop. `HeadWatcher`
    /// debounces at only 200ms and ordinary agent activity rewrites `index`
    /// with HEAD unchanged, so a burst of git-activity notifications must not
    /// queue up a matching burst of `git diff --stat` spawns.
    @State private var isRefreshingStaleness = false
    /// A refresh that arrived while one was already in flight, to be run once it
    /// lands. One bit rather than a queue, because every waiting request wants
    /// the same thing: one more read, after this one.
    @State private var stalenessRefreshPending = false
    /// Which checks have their output group open, by name.
    ///
    /// Held here rather than in the row because the runner republishes while
    /// anything is running, so rows are rebuilt several times a second and a
    /// `@State` inside one would depend on SwiftUI keeping its identity across a
    /// value whose state and duration both change.
    ///
    /// Deliberately **not** cleared when a check is re-run: the name is the same
    /// check, and a user who opened `rspec` to watch it wants it open next time.
    @State private var expandedChecks: Set<String> = []

    /// Watches the worktree itself for the edits `.worktreeGitActivity` cannot
    /// see — an ordinary save touches nothing inside `.git`, so a result on a tab
    /// the user is sitting on kept reading fresh.
    @State private var worktreeWatcher: Verification.StalenessWatcher?

    var body: some View {
        Group {
            if let unavailableReason {
                unavailableView(reason: unavailableReason)
            } else {
                content
            }
        }
        .onAppear {
            // Hydrates every row drawn before this session has run anything, so
            // a workstream reopened tomorrow still shows yesterday's verdicts.
            // A no-op once the workstream has an in-memory entry, so it cannot
            // overwrite a live check's record with the store's older copy.
            //
            // Must run before `refreshStaleness()`, which reads
            // `hasStalenessSubject` — and that consults exactly these records.
            runner.loadRecords(for: workstreamID)
            refreshStaleness()
            syncWorktreeWatcher(hasRunOrRecord: hasStalenessSubject)
        }
        .onDisappear {
            // The tab leaves the tree on every tab switch, and an FSEvents stream
            // over a whole worktree is not something to leave running for a pane
            // nobody is looking at. Released as well as disarmed: its `onChange`
            // captures this view, so a disarmed watcher still held here is a
            // retained view per mount.
            worktreeWatcher?.disarm()
            worktreeWatcher = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .worktreeGitActivity)) { notification in
            guard notification.object as? String == worktreePath else { return }
            refreshStaleness()
        }
        // A check *ending* is the trigger that matters and the one nothing else
        // covers: a check that writes to the tree — a formatter, codegen — leaves
        // its own stamp at what the tree looked like before it ran, so a
        // genuinely stale result would render fresh until something else
        // recomputed.
        .onChange(of: runner.isLive(workstreamID)) {
            refreshStaleness()
            syncWorktreeWatcher(hasRunOrRecord: hasStalenessSubject)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let startError {
                Text(startError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.bottom, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(declaredProcesses, id: \.self) { name in
                        row(for: name)
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(for name: String) -> some View {
        let isRunning = runner.isRunning(workstreamID, check: name)
        let record = runner.records(for: workstreamID)[name]
        return VerificationCheckRow(
            name: name,
            state: runner.state(workstreamID, check: name),
            // Nil while the check is running: a mid-re-run row reading "running"
            // and "stale" at once is two answers to one question, and the record
            // the marker was computed from has already been superseded.
            isStale: isRunning
                ? false
                : (record.map { verificationRecordIsStale(record: $0, currentStamp: currentStamp) } ?? false),
            duration: isRunning ? runner.elapsed(workstreamID, check: name) : record?.duration,
            action: verificationRowAction(isRunning: isRunning, recordedState: record?.state),
            surfaceID: runner.surfaceID(workstreamID, check: name),
            onRun: { run(name) },
            onStop: { runner.stop(workstreamID: workstreamID, check: name) },
            isExpanded: expandedChecks.contains(name),
            setExpanded: { expanded in
                if expanded {
                    expandedChecks.insert(name)
                } else {
                    expandedChecks.remove(name)
                }
            }
        )
    }

    private func unavailableView(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing to verify")
                .font(.system(size: 13, weight: .medium))
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Actions

    private func run(_ name: String) {
        startError = nil
        do {
            try runner.start(
                workstreamID: workstreamID,
                projectName: projectName,
                workstreamName: workstreamName,
                worktreePath: worktreePath,
                projectDirectory: projectDirectory,
                defaultBranch: Git.Operations.defaultBranch(at: worktreePath),
                checks: [name]
            )
            // A check that has just started has nothing to show yet, but the user
            // pressed the button to watch it — so opening the group is the act
            // they were reaching for, not an extra one.
            expandedChecks.insert(name)
        } catch {
            startError = error.localizedDescription
        }
    }

    // MARK: - Refresh

    /// Whether there is anything a staleness comparison could be about.
    private var hasStalenessSubject: Bool {
        !runner.records(for: workstreamID).isEmpty
    }

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
        stalenessGeneration += 1
        let generation = stalenessGeneration
        let worktree = worktreePath
        let project = projectDirectory
        Task {
            let stamp = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Git.Operations.diffFingerprint(
                        worktreePath: worktree, projectPath: project, mode: "uncommitted"
                    ))
                }
            }
            await MainActor.run {
                isRefreshingStaleness = false
                guard generation == stalenessGeneration else { return }
                currentStamp = stamp
                if stalenessRefreshPending {
                    stalenessRefreshPending = false
                    refreshStaleness()
                }
            }
        }
    }

    private func syncWorktreeWatcher(hasRunOrRecord: Bool) {
        guard hasRunOrRecord else {
            worktreeWatcher?.disarm()
            return
        }
        if worktreeWatcher == nil {
            worktreeWatcher = Verification.StalenessWatcher(onChange: { refreshStaleness() })
        }
        worktreeWatcher?.arm(path: worktreePath)
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

/// One check's row, and the group holding its terminal.
///
/// ```
/// ▸  ◯ rspec ▶                                        stale   12.4s
/// ```
///
/// **The triangle is the only toggle.** Clicking the glyph, the name or the
/// empty space does nothing — which is a deliberate reversal of the shape this
/// replaced, where the whole row was an invisible button and there was no
/// triangle at all. A disclosure group is a thing users know how to operate, and
/// the run button sitting inline meant a row-wide toggle would have to carve an
/// exception around it.
///
/// **The run button follows the name rather than the trailing edge**, so it is
/// unmistakably *this check's* button, and the column it forms is ragged by
/// design. The trailing edge belongs to the stale marker and the duration, which
/// are the two things worth scanning down.
struct VerificationCheckRow: View {
    let name: String
    let state: Verification.CheckResult.State
    let isStale: Bool
    let duration: TimeInterval?
    let action: VerificationRowAction
    /// The surface this check's output is in, or nil when it has not run this
    /// session. Nil is what the open group renders its "nothing to show" line
    /// for; it never spawns anything.
    let surfaceID: UUID?
    let onRun: () -> Void
    let onStop: () -> Void
    let isExpanded: Bool
    let setExpanded: (Bool) -> Void

    /// How tall an open group's terminal is. Fixed rather than grown to fit,
    /// because a terminal has its own scrollback and the rows live in a
    /// `ScrollView`: a group sized to its content would put a scroll region
    /// inside a scroll region with no boundary between them.
    private static let terminalHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                outputBody
                    .padding(.leading, 20)
                    .padding(.vertical, 6)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            disclosureButton
            Image(systemName: verificationRowGlyph(state))
                .foregroundStyle(verificationStateColor(state))
                .frame(width: 16)
                // The glyph alone is a thin signal: `.notRun` (`circle.dashed`)
                // and `.running` (`circle.dotted`) differ by a few pixels at this
                // size, with colour as the practical differentiator, and nowhere
                // else in the row does the state appear as text.
                .accessibilityLabel(verificationStateWord(state))
            Text(name)
                .font(.system(size: 11, design: .monospaced))
            runButton
            Spacer()
            // Per row rather than per suite, because the records behind the rows
            // were written at different moments — a tab-wide banner would be
            // wrong for every check the last press did not cover.
            if isStale {
                Text("stale")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(
                        Text("This result no longer reflects the worktree's current content.")
                    )
            }
            if let duration {
                Text(verificationFormattedDuration(duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    /// A `Button` rather than an `.onTapGesture` on the glyph: a tap gesture is
    /// invisible to VoiceOver and unreachable from the keyboard, and this is the
    /// only way to open a check's output at all.
    private var disclosureButton: some View {
        Button {
            setExpanded(!isExpanded)
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded
            ? Text("Hide this check's output")
            : Text("Show this check's output"))
        .help(isExpanded ? Text("Hide output") : Text("Show output"))
    }

    /// The row's one action, icon-only, immediately after the name.
    ///
    /// Three glyphs for three offers, where the pair this replaced drew `play.fill`
    /// for both run and re-run: with a check's history now deciding *which* of them
    /// is offered — a stopped check goes back to plain Run — the distinction has to
    /// be visible, or the rule means nothing on screen. Green is only for starting;
    /// re-running a check that already has a verdict is the neutral act, and Stop
    /// borrows the row's own `.stopped` colour.
    @ViewBuilder
    private var runButton: some View {
        switch action {
        case .run:
            iconButton("play.fill", tint: .green, label: Text("Run"), action: onRun)
        case .rerun:
            iconButton("arrow.clockwise", tint: .secondary, label: Text("Re-run"), action: onRun)
        case .stop:
            iconButton("stop.fill", tint: .orange, label: Text("Stop"), action: onStop)
        }
    }

    private func iconButton(
        _ systemName: String, tint: Color, label: Text, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .help(label)
    }

    /// What the open group shows: this check's terminal, or the sentence for a
    /// check that has none.
    ///
    /// **There is no third case.** Output is not captured anywhere — it lives in
    /// the surface, which is created when the check starts and kept until the
    /// workstream is purged or Atelier quits. So either the surface is there and
    /// holds everything the check has printed, live or finished, or the check has
    /// not run in this session and there is nothing to show. Nothing here may
    /// imply the output could be fetched from somewhere.
    @ViewBuilder
    private var outputBody: some View {
        if let surfaceID {
            VerificationSurfaceView(surfaceID: surfaceID)
                .frame(height: Self.terminalHeight)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Text("This check has not run since Atelier started, so there is no output to show. Run it to see one.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Attaches an existing check surface, read-only.
///
/// Deliberately **not** `SingleTerminalView`: that one creates a surface on a
/// miss, which for a row means a check that has never run would spawn a terminal
/// running the wrapper the moment its group was opened. Here a missing surface is
/// an ordinary state the row draws a sentence for, and the runner is the only
/// thing that ever starts one.
private struct VerificationSurfaceView: NSViewRepresentable {
    let surfaceID: UUID

    @EnvironmentObject var surfaceCache: TerminalSurfaceCache

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        guard let terminalView = surfaceCache.existingSurface(for: surfaceID) else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        // Set on every pass rather than at creation: the surface is made by the
        // runner, which has no opinion about who will render it, and a surface
        // re-attached after being detached must not come back writable.
        terminalView.isReadOnly = true

        if terminalView.superview !== container {
            terminalView.removeFromSuperview()
            container.subviews.forEach { $0.removeFromSuperview() }
            container.addSubview(terminalView)
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                terminalView.topAnchor.constraint(equalTo: container.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        // SwiftUI does not reliably call `setFrameSize` on resize, so the size is
        // pushed explicitly — the same reason `TerminalSurfaceView` does it.
        if terminalView.window != nil, container.bounds.size.width > 0 {
            terminalView.notifySizeChanged(container.bounds.size)
        }
    }
}

/// Gives `Verification.Runner` somewhere to put a check's terminal.
///
/// The runner lives in `Sources/Models` and `TerminalSurfaceCache` lives here, so
/// the dependency goes through `Verification.SurfaceHosting` rather than straight
/// across. Installed once, by `ContentView`, beside the IPC bridge.
@MainActor
final class VerificationSurfaceHost: Verification.SurfaceHosting {
    private let cache: TerminalSurfaceCache

    init(cache: TerminalSurfaceCache) {
        self.cache = cache
    }

    /// **Destroys any existing surface first, so a re-run is a fresh terminal.**
    /// `surface(for:…)` returns a cached surface untouched and ignores the command
    /// it was handed, so without this a second press would re-attach the first
    /// run's dead terminal and nothing would happen — visibly nothing, since the
    /// row would go `.running` on a check that was never started.
    ///
    /// The cost is that the previous run's output is gone the moment the next one
    /// starts. That is the same bargain the whole feature makes — output lives in
    /// the surface and nowhere else — and scrolling back past a boundary into a
    /// previous run's output is worth less than knowing that what is on screen is
    /// this run's.
    func startSurface(
        id: UUID,
        command: String,
        workingDirectory: String,
        environment: [String: String]
    ) -> Bool {
        guard let app = TerminalApp.shared.app else { return false }
        cache.removeSurface(for: id)
        let view = cache.surface(
            for: id,
            app: app,
            workingDirectory: workingDirectory,
            command: command,
            environmentVars: environment
        )
        // Set here as well as in the view, because the surface exists and is
        // running from this moment — the row may not be rendered at all, and a
        // check started by an agent in a workstream nobody is looking at must not
        // be typeable the instant someone opens it.
        view.isReadOnly = true
        // `surface` reports failure by leaving the ghostty surface nil and
        // recording the command in `failedSurfaces`; the runner turns that into a
        // refusal the user sees rather than a row that silently never starts.
        return view.surface != nil
    }

    func disposeSurface(id: UUID) {
        cache.removeSurface(for: id)
    }
}
