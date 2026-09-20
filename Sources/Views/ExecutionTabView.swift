// ABOUTME: View for the run script / dev server in the Execution tab.
// ABOUTME: Shows a terminal for the running server, or start instructions when not configured.

import SwiftUI

/// What the Execution pane shows for the effective dev command.
///
/// An override is shown as the command it is — the user typed it, and it is what
/// Start runs. A process-compose config is shown as the **files** that will be
/// loaded, and deliberately not as a command, because the string
/// `DevCommand.Resolver` builds for that source is
/// `process-compose up -U -f <files>` — no `-n`, so running it runs *every*
/// namespace including `dispose`, past `PhasePolicy`.
/// `ProcessCompose.RunCommandPlan` makes it unreachable from Start; rendering it
/// here made it reachable by hand, in a monospaced font that invites exactly
/// that. The files are what `ProcessCompose.RunCommandPlan` meant the user to be able to see.
///
/// A free function, so the property that matters — no output of this is ever a
/// runnable process-compose command — can be tested without a view.
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
    let runStarted: Bool
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
    /// `StartContextResolver` will resolve, so Start's enabled state and the
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
    /// states that reach this were all silent: a config that vanished, a
    /// binary the search paths do not cover, and an `execute` namespace nothing
    /// declares.
    let startUnavailableReason: String?
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
                // a process-compose binary that stopped resolving mid-run took
                // the Stop button away from a live stack, leaving Ctrl+C in the
                // surface as the only way out. Only Rerun needs to know a run
                // can be started.
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
                // beside it: ⌘⇧⏎ goes through `StartContextResolver`, which
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
                        // Three clicks, no typing, and `dispose`
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
                Text("No dev command found. Add an execution.process-compose.yaml to this project's directory, or set a command below.")
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
            devCommand?.sourceDescription ?? "execution.process-compose.yaml"
        }
        return Text(text)
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
            .foregroundStyle(.tertiary)
    }

    /// Shown whenever Start cannot run. Two shapes, one surface: with no
    /// `reason` it names the two things that would make Start work — an
    /// `execution.process-compose.yaml` in the project directory, or a
    /// per-workstream override — and with one it says what is actually in the way.
    ///
    /// **That default naming is the whole migration story**, so it has to be
    /// specific. `Config.locate` used to search four places, two of them inside
    /// the worktree; a project whose config still sits in one of those simply
    /// stops being found, and this sentence is what tells the user where the file
    /// goes now.
    ///
    /// Deliberately not a new pane. Every state that lands here was previously
    /// silent, and the review that found them was specific that they belong in
    /// the surface that already renders for "nothing to run".
    /// Why there is nothing to start, as the platform's own empty state.
    ///
    /// **The twin of `VerificationTabView.unavailableView`, and deliberately
    /// built the same way.** Both panes answer the same question — a config file
    /// in the project directory is missing, unreadable, or declares nothing — so
    /// they use one glyph, one type scale and one layout. Change one and change
    /// the other; a reader who sees them disagree will read the difference as
    /// meaning something.
    ///
    /// **`reason` reaches the screen verbatim, and the fallback is not a
    /// paraphrase of it.** `Text(_:)` over a `String` binds the `StringProtocol`
    /// overload rather than the `LocalizedStringKey` one, so
    /// `ProcessCompose.RunCommandPlan.unavailableReason`'s wording is *shown*
    /// rather than looked up a second time under itself as a key. Nothing here
    /// reformats it or appends to it — and note that those three strings are
    /// pinned from the other side: `RunCommandPlanTests` asserts one of them
    /// `contains("no execute processes")`, so this view may be restyled freely
    /// but that copy may not be reworded here or there.
    ///
    /// **A nil `reason` is the ordinary case, not a missing explanation.**
    /// `unavailableReason` returns nil when `devCommand` is nil — no override
    /// typed and no config located — precisely because this default already says
    /// the thing, and it names the same file. The `??` is the whole of that
    /// contract.
    ///
    /// **The `label:`/`description:` builder form, to keep the app's type
    /// scale.** `ContentUnavailableView`'s convenience initializer sizes itself
    /// for a full window — a ~28pt title — and this is a tab pane in an app
    /// whose body text is 11–13pt. The builder form keeps the component's
    /// layout, centring and accessibility while holding the 28/13/11 scale this
    /// pane already had. The explicit `.frame(maxWidth: 380)` that used to cap
    /// the description is gone because the component caps it itself, at close to
    /// the same width and without the pane's own width having to be guessed.
    private func scriptInstructions(reason: String?) -> some View {
        ContentUnavailableView {
            Label {
                Text("Nothing to start")
                    .font(.system(size: 13))
            } icon: {
                Image(systemName: "doc.text")
                    .font(.system(size: 28))
            }
        } description: {
            Text(reason ?? NSLocalizedString(
                "Add an execution.process-compose.yaml to this project's directory, or set a command with Customize above.",
                comment: ""
            ))
            .font(.system(size: 11))
        }
    }

    /// Whether Rerun may be pressed.
    ///
    /// The selection half is defensive rather than a case anyone can reach
    /// today, and it is worth knowing which: the checklist is hidden during a
    /// run, and the one path that sets `runStarted` without a Start press —
    /// `ProcessCompose.RunSession.restore` — is only reached with a
    /// `StartContext` the view could build, which is already impossible for an
    /// empty selection. So a run cannot currently be live over one.
    ///
    /// It is gated anyway because `restartRun` guards on `runStartContext`,
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
