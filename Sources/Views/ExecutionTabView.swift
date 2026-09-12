// ABOUTME: View for the run script / dev server in the Execution tab.
// ABOUTME: Shows a terminal for the running server, or start instructions when not configured.

import SwiftUI

func shouldRestoreRunSession(useTmux: Bool, hasRunScript: Bool, hasExistingRunSession: Bool, wasStoppedManually: Bool) -> Bool {
    useTmux && hasRunScript && hasExistingRunSession && !wasStoppedManually
}

/// Whether closing `tab` stops this workstream's run.
///
/// The Execution tab is the run's sole owner. It is the pane that lists the
/// processes and the pane Stop lives on, and `beginRun` opens one for every
/// run, so no other tab has to stand in as the way out.
///
/// A browser tab used to claim the same ownership, guarded by a "no browser
/// tabs left" check that matched only browser tabs and so could not see an open
/// Execution tab. Closing the last browser therefore stopped a run that tab
/// was still watching, and set `runStoppedManually` on the way out, so it did
/// not come back on the next launch either.
///
/// `runStarted` is folded in here rather than left to the caller because
/// forgetting it is the same defect in a second place: `stopRun` sets
/// `runStoppedManually`, and closing a tab that was running nothing must not
/// suppress the next launch's tmux restore.
///
/// A free function, like its neighbours, so which tab owns the run can be
/// tested without standing up a view.
func closingTabStopsRun(_ tab: WorkspaceTab, runStarted: Bool) -> Bool {
    guard runStarted else { return false }
    if case .execution = tab {
        return true
    }
    return false
}

/// What the Execution pane shows for the effective dev command.
///
/// An override is shown as the command it is — the user typed it, and it is what
/// Start runs. A process-compose config is shown as the **files** that will be
/// loaded, and deliberately not as a command, because the string
/// `DevCommand.Resolver` builds for that source is
/// `process-compose up -U -f <files>` — no `-n`, so running it runs *every*
/// namespace including `bootstrap` and `dispose`, past `PhasePolicy` and past
/// `ScriptTrust`. `ProcessCompose.RunCommandPlan` makes it unreachable from Start; rendering it
/// here made it reachable by hand, in a monospaced font that invites exactly
/// that. The files are what `ProcessCompose.RunCommandPlan` meant the user to be able to see.
///
/// A free function, like its neighbours, so the property that matters — no
/// output of this is ever a runnable process-compose command — can be tested
/// without a view.
func devCommandDisplayText(devCommand: DevCommand?, loadedFiles: [String]) -> String? {
    guard let devCommand else { return nil }
    switch devCommand.source {
    case .override:
        return devCommand.command
    case .processCompose:
        guard !loadedFiles.isEmpty else { return devCommand.sourceDescription }
        return loadedFiles.map(\.abbreviatedPath).joined(separator: "  ")
    }
}

/// Whether the process checklist above Start should render.
///
/// Visible before a run and hidden during one, and both halves are defects
/// that have already shipped, in opposite directions.
///
/// The list first lived inside `ProcessTableView`, which renders only once a
/// run exists, so the control for choosing what to start was unreachable until
/// after starting — the one moment it is no use. Fixing that by making
/// visibility independent of the run then left it editable *during* a run,
/// where it is equally useless: the selection is read when Start is pressed
/// (`TerminalContainerView`), so changing a checkbox mid-run silently affects
/// nothing until the next Stop and Start.
///
/// So the gate is two-sided, and both sides are pinned by tests. Neither
/// direction is the safe default to guess at.
func showsProcessSelection(
    runStarted: Bool,
    showsProcessTable: Bool,
    declaredProcesses: [String]
) -> Bool {
    !runStarted && showsProcessTable && !declaredProcesses.isEmpty
}

/// Wraps a command for a login shell, so it sees the PATH and shell functions
/// the user's own terminal would. Used when the `atelier-run` launcher is
/// unavailable and the command has to be run bare.
func scriptCommand(script: String, shell: String = CommandBuilder.userShell) -> String {
    // POSIX quoting for the same reason `RunLauncher.runScriptCommand` uses it:
    // the outer shell that strips this layer is ghostty's `/bin/bash -c`, not
    // the login shell named here, and double quotes would leave backticks in
    // the script live for bash to substitute.
    "\(shell) -lic \(CommandBuilder.shellQuote(script))"
}

struct ExecutionTabView: View {
    let workstreamID: UUID
    let workingDirectory: String
    let useTmux: Bool
    let environmentVars: [String: String]
    /// Final assembled run command (atelier-run + tmux wrap), set once the session starts.
    let runCommand: String?
    /// The resolved dev command: the user's override, or the located
    /// process-compose config.
    let devCommand: DevCommand?
    @Binding var devCommandOverride: String?
    @Binding var runStarted: Bool
    let runGeneration: Int
    /// Live process state from process-compose. Only rendered when the run is a
    /// process-compose run; otherwise nothing is polling it.
    @ObservedObject var processTable: ProcessCompose.TableModel
    let showsProcessTable: Bool
    /// The worktree's port plan, so each row can show the port it owns.
    let portsByName: [String: String]
    /// Processes the config declares in `execute`, for the selection list.
    let declaredProcesses: [String]
    /// Whether Start may run anything. **Passed in, never re-derived here.**
    /// This is `ProcessCompose.RunCommandPlan.canRun` for the same plan `doStartRun` executes,
    /// so the button's enablement and the run's guard are one decision. They
    /// used to be two — enabled on `devCommand?.command != nil`, executed on the
    /// resolved command — and an unresolvable process-compose binary rendered an
    /// enabled Start that did nothing and explained nothing.
    let canStart: Bool
    /// Whether the checklist leaves `execute` anything to start.
    ///
    /// **Passed in, never re-derived here**, for the same reason `canStart` is:
    /// this is `runnableExecuteSelection != nil` for the very selection
    /// `resolvedRunCommand` will resolve, so Start's enabled state and the
    /// run's own guard are one answer asked once.
    ///
    /// Separate from `canStart` rather than folded into it, because the two
    /// mean different things to the pane: `canStart` decides whether a Start
    /// button exists at all — there is nothing runnable, and
    /// `scriptInstructions` explains that instead — while this one leaves the
    /// button in place and disabled, with a line beside it saying what to do.
    /// Folding it in would take the checklist with it: `declaredExecuteProcesses`
    /// reads the run plan, so a plan that went `.nothing` on an empty selection
    /// would hide the very checkboxes needed to make it non-empty.
    let hasRunnableSelection: Bool
    /// Whether Start is currently shutting down a server that still holds this
    /// workstream's execute socket, before it can run anything.
    ///
    /// Start is otherwise instant — the pane swaps to a terminal on the same
    /// press — so an unchanged button that ignores a press is read as a broken
    /// button rather than as work in progress. `TerminalContainerView.doStartRun`
    /// already refuses the second press; this is what says why.
    let isReclaimingSocket: Bool
    /// Every file process-compose will load for this workstream, or empty when
    /// the run is not a process-compose run. Shown instead of a command string:
    /// see `devCommandDisplay`.
    let devCommandFiles: [String]
    /// Why Start can do nothing, when the copy below does not already say. The
    /// states that reach this were all silent: an integration switched off, a
    /// config that vanished, and a binary the search paths do not cover.
    let startUnavailableReason: String?
    /// The repository-provided process-compose files whose unattended phases the
    /// user has not approved, or empty when there is nothing to ask about.
    let unapprovedConfigFiles: [String]
    let onReviewConfig: () -> Void
    /// The checklist wrote a new selection. Forwarded so the owner can re-read
    /// the store and re-decide `hasRunnableSelection`; see
    /// `ProcessSelectionView.onSelectionChange`.
    let onSelectionChange: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    @EnvironmentObject var surfaceCache: TerminalSurfaceCache
    @State private var isCustomizingDevCommand = false
    @State private var devCommandEditText = ""

    private var runID: UUID {
        derivedUUID(from: workstreamID, salt: "env-run-\(runGeneration)")
    }

    private var devCommandDisplay: String? {
        devCommandDisplayText(devCommand: devCommand, loadedFiles: devCommandFiles)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !unapprovedConfigFiles.isEmpty {
                configApprovalBanner(paths: unapprovedConfigFiles)
                Divider()
            }
            executionContent
        }
    }

    private var executionContent: some View {
        runPane()
    }

    /// One control section in the upper left, and the run itself below it.
    ///
    /// The dev command, the checklist of what Start will run, and the buttons
    /// that run it are three parts of one decision, so they are one stack in
    /// one corner. They used to be three places: a full-width bar carrying the
    /// section title, Stop and Rerun; a "Dev command" band under it; and — a
    /// pane-height away — a centred stack holding the checklist and Start. Which
    /// of those were on screen changed with the run state, so pressing Start
    /// moved the controls from the middle of the pane to a bar at the top.
    ///
    /// Everything below the divider belongs to the run: the process table and
    /// the terminal while one is up, the "nothing to start" copy when there is
    /// nothing to run. Before a run that area is deliberately empty — the
    /// controls are all in the corner, and a second Start in the middle of the
    /// pane is the duplication this replaced.
    private func runPane() -> some View {
        VStack(spacing: 0) {
            controlSection
            Divider()

            if runStarted, let runCommand {
                if showsProcessTable {
                    ProcessTableView(model: processTable, portsByName: portsByName)
                    Divider()
                }
                SingleTerminalView(
                    surfaceID: runID,
                    workingDirectory: workingDirectory,
                    command: runCommand,
                    isFocused: false,
                    environmentVars: environmentVars
                )
                .id(runID)
            } else if canStart {
                // Nothing to draw before a run: Start is in the section above,
                // and this is the space the run will fill.
                Spacer()
            } else {
                scriptInstructions(reason: startUnavailableReason)
            }
        }
    }

    /// The upper-left group: what will run, which parts of it, and the buttons
    /// that start and stop it, in that order and always in that place.
    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            devCommandSection

            if showsProcessSelection(
                runStarted: runStarted,
                showsProcessTable: showsProcessTable,
                declaredProcesses: declaredProcesses
            ) {
                ProcessSelectionView(
                    workstreamID: workstreamID,
                    declaredProcesses: declaredProcesses,
                    store: .execute,
                    onSelectionChange: onSelectionChange
                )
            }

            runControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Start before a run, Stop and Rerun during one — in the same corner
    /// either way, so starting something does not move the buttons.
    ///
    /// Neither arm renders when Start can do nothing and no run is up:
    /// `scriptInstructions` below the divider is the surface that explains
    /// that, and a disabled button beside its explanation says nothing extra.
    ///
    /// Stop and Rerun are ordinary chromed controls — `.borderedProminent` and
    /// `.bordered`, the shapes `VerificationTabView.actionRow` already uses.
    /// They were borderless and transparent until hovered, at 10/11pt, so the
    /// two buttons that matter while a stack is up were the least visible
    /// things in the pane, and Start — a filled accent button — was the only
    /// one that looked pressable. Stop takes the prominent slot because while a
    /// run is up it is the primary action, and the red tint is what makes it
    /// readable at a glance; Verification's Stop stays `.bordered` because Run
    /// is the primary action in that pane. Do not restyle these as borderless
    /// again to match some other bar: the point is that they read as buttons.
    @ViewBuilder
    private var runControls: some View {
        let shortcut = "⌘⇧⏎"
        if runStarted {
            HStack(spacing: 8) {
                // Stop's precondition is that something is running, and that is
                // all. It used to be gated on `canStart` alongside Rerun, so
                // toggling the integration off — or breaking the binary path —
                // mid-run took the Stop button away from a live stack, leaving
                // Ctrl+C in the surface as the only way out. Only Rerun needs to
                // know a run can be started.
                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityLabel(NSLocalizedString("Stop", comment: ""))

                if runControlsEnabled {
                    Button(action: onRestart) {
                        Label("Rerun", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(NSLocalizedString("Rerun", comment: ""))

                    Text(shortcut)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Only while something is running: it warns that the browser
                // will not retarget on a detected port, which means nothing
                // until a server is actually up.
                if canStart, RunLauncher.executableURL() == nil {
                    Text("No port detection")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("atelier-run helper not found. Run scripts will work but port detection is unavailable.")
                }
            }
        } else if canStart {
            HStack(spacing: 8) {
                Button(action: onStart) {
                    HStack(spacing: 6) {
                        if isReclaimingSocket {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12))
                        }
                        Text(isReclaimingSocket ? "Reclaiming…" : "Start")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(startEnabled ? 1 : 0.6)
                }
                .buttonStyle(.borderless)
                .disabled(!startEnabled)

                // The shortcut gives way to the reason, rather than sitting
                // beside it: ⌘⇧⏎ goes through `resolvedRunCommand`, which
                // refuses the same empty selection, so advertising it next to a
                // disabled button would name a second way to press it that is
                // just as inert.
                if hasRunnableSelection {
                    Text(shortcut)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select a process to start.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Shows the effective dev command — the located process-compose config, or
    /// the user's per-workstream override — and lets the user change it.
    private var devCommandSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Dev command")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(isCustomizingDevCommand ? "Cancel" : "Customize") {
                    if isCustomizingDevCommand {
                        isCustomizingDevCommand = false
                    } else {
                        // Seeded only from an override — the user's own text.
                        // Seeding it from a `.processCompose` command handed the
                        // user the un-`-n`'d string in an editable field, and
                        // Save turns whatever is in that field into an
                        // `.override`, which `ProcessCompose.RunCommandPlan` runs literally.
                        // Three clicks, no typing, and `bootstrap` and `dispose`
                        // run with no approval.
                        devCommandEditText = devCommand?.source == .override
                            ? (devCommand?.command ?? "")
                            : ""
                        isCustomizingDevCommand = true
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }

            if let devCommand, let display = devCommandDisplay {
                HStack(spacing: 6) {
                    Text(display)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    sourceTag(for: devCommand.source)
                }
            } else {
                Text("No dev command found. Add an atelier.process-compose.yaml, or set a command below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if isCustomizingDevCommand {
                HStack(spacing: 6) {
                    TextField("Command", text: $devCommandEditText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Save") {
                        let trimmed = devCommandEditText.trimmingCharacters(in: .whitespacesAndNewlines)
                        devCommandOverride = trimmed.isEmpty ? nil : trimmed
                        isCustomizingDevCommand = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if devCommand == nil, !isCustomizingDevCommand {
                Text("Open the command palette (\u{2318}\u{21E7}P) and run New Browser to start the dev server.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sourceTag(for source: DevCommand.Source) -> some View {
        let text: String = switch source {
        case .override:
            NSLocalizedString("Custom", comment: "")
        case .processCompose:
            // The file name, since a repository can carry either spelling.
            devCommand?.sourceDescription ?? "process-compose.yaml"
        }
        return Text(text)
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
            .foregroundStyle(.tertiary)
    }

    /// A banner, not a gate. The unattended phases — bootstrap at creation,
    /// dispose at archive — are the ones that need approval, because nobody is
    /// there when they run. Start is attended: the user presses it deliberately,
    /// the stack's output lands in a terminal surface in front of them, and Stop
    /// is right there — so it stays available whether or not the file has been
    /// approved.
    ///
    /// That, and not "the pane shows the command Start runs", is the reason. The
    /// pane never showed it: what Start runs is the phase-scoped
    /// `prepare && execute`, assembled by `ProcessCompose.PhaseRunner`, while the string the
    /// pane used to render was a display-only one that must never execute. The
    /// decision to leave `execute` ungated stands; only the stated reason was
    /// false, and it was load-bearing in four places.
    private func configApprovalBanner(paths: [String]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    format: NSLocalizedString("%@ came with this repository and has not been approved", comment: ""),
                    paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                ))
                .font(.system(size: 12, weight: .semibold))
                Text("Its bootstrap and dispose phases will not run until you review it. Start is unaffected.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review") { onReviewConfig() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
    }

    /// Shown whenever Start cannot run. Two shapes, one surface: with no
    /// `reason` it names the two things that would make Start work — a
    /// process-compose.yaml in either home, or a per-workstream override —
    /// and with one it says what is actually in the way.
    ///
    /// Deliberately not a new pane. Every state that lands here was previously
    /// silent, and the review that found them was specific that they belong in
    /// the surface that already renders for "nothing to run".
    private func scriptInstructions(reason: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Nothing to start")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(reason ?? NSLocalizedString(
                "Add an atelier.process-compose.yaml to this worktree or the project directory, or set a command with Customize above.",
                comment: ""
            ))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Whether Rerun may be pressed.
    ///
    /// The selection half is defensive rather than a case anyone can reach
    /// today, and it is worth knowing which: the checklist is hidden during a
    /// run, and the one path that sets `runStarted` without a Start press — the
    /// tmux restore in `TerminalContainerView` — passes
    /// `hasRunScript: resolvedRunCommand != nil`, which is already nil for an
    /// empty selection. So a run cannot currently be live over one.
    ///
    /// It is gated anyway because `restartRun` guards on `resolvedRunCommand`,
    /// and a Rerun offered over an empty selection would stop the run and then
    /// decline to start one — a Stop wearing Rerun's label. That is the failure
    /// this button already had once, for the neighbouring reason, and a future
    /// restore path that stopped consulting the command should not be able to
    /// bring it back.
    private var runControlsEnabled: Bool {
        canStart && hasRunnableSelection
    }

    /// Start is pressable when there is something to start and no socket is
    /// being reclaimed. Both halves dim the button rather than removing it —
    /// removing it is `canStart`'s job, and it comes with an explanation
    /// elsewhere on the pane.
    private var startEnabled: Bool {
        hasRunnableSelection && !isReclaimingSocket
    }
}

extension Notification.Name {
    static let rerunScript = Notification.Name("atelier.rerunScript")
}
