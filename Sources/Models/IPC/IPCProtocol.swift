// ABOUTME: Wire types shared by the app's IPC server and the atelier-mcp helper.
// ABOUTME: Newline-delimited JSON over loopback TCP — deliberately not HTTP.

import Foundation

/// Agent-to-agent messaging: the wire protocol, its transport, and the
/// settings that gate it.
///
/// Declared here rather than in a file of its own because `AtelierMCP`
/// compiles only this file and `IPCToolRegistry.swift` out of `Models/IPC/`
/// (`project.yml`); a namespace declared anywhere else in this directory would
/// not exist for the `atelier-mcp` binary.
enum IPC {}

extension IPC {
    /// Where the app's IPC listener is, and the token that admits a caller.
    ///
    /// Written to `~/Library/Caches/atelier/ipc.json` at mode 0600 when the server
    /// starts, and read by every `atelier-mcp` helper at startup. Keeping the token
    /// here rather than in the MCP config means it never lands in `LaunchLogger`'s
    /// verbatim record of the launch command.
    ///
    /// Every process involved runs as the user, so the token is not a security
    /// boundary against the agent. It stops another app colliding on the port and
    /// stops a stray `fetch` from a page in the embedded browser. That is the whole
    /// claim.
    struct Endpoint: Codable {
        let port: UInt16
        let token: String

        static var fileURL: URL {
            AppConstants.cacheDirectory.appendingPathComponent("ipc.json")
        }

        static func read(from url: URL = Endpoint.fileURL) -> Endpoint? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Endpoint.self, from: data)
        }
    }

    /// The tools the helper can forward to the app.
    ///
    /// **Four surfaces, and the split is the point** — see `Tool.surface`.
    /// *Messaging* moves text between agents and changes nothing a user can see.
    /// *Workspace reads* answer questions about the workstream the caller is
    /// already in. *Workspace actions* create or change something in front of
    /// the user. *Project tasks* — a claimable, project-scoped work queue; see
    /// `Surface.projectTasks` for the trust story. Sort a new case into the right
    /// group, and give a workspace action its own trust story rather than
    /// inheriting messaging's, which is "none needed".
    ///
    /// The messaging six were once the whole enum, with a comment saying so:
    /// Calix's IPC core is the same six, and everything it grew on top —
    /// pane/tab control, LSP, shell integration — arrived as separate tool
    /// surfaces with separate gates (`MCPCockpitBridge`, `MCPLSPBridge`,
    /// `MCPCommandLogBridge`). That prediction held; this enum is where Atelier
    /// takes the same step, so the groups are named rather than merged.
    ///
    /// **Everything else about a tool lives in `IPC.ToolSpec`** — its surface,
    /// its reply deadline, its replay policy, the prose an agent reads and the
    /// arguments it takes. `Tool.spec` is an exhaustive `switch`, so a case
    /// added here cannot compile without one, and the helper advertises what
    /// that spec says.
    ///
    /// That closes a hole this comment used to describe and excuse. A case was
    /// once dispatchable but undiscoverable — the advertised list was a
    /// hand-written table in `Sources/MCPHelper/main.swift` that nothing made
    /// agree with this enum — and the paragraph justified it as room for a tool
    /// to land ahead of its handler, citing a `Service.notImplemented` that has
    /// never existed. `IPCServerTests` has asserted the hidden set is empty for
    /// some time; now it is empty by construction, because there is no table to
    /// leave a case out of.
    enum Tool: String, Codable, CaseIterable {
        // Messaging.
        case registerPeer = "register_peer"
        case listPeers = "list_peers"
        case sendMessage = "send_message"
        case receiveMessages = "receive_messages"
        case broadcast
        case getPeerStatus = "get_peer_status"

        /// Workspace reads.
        /// The tabs of the caller's own workstream, and which agent sits in each.
        case listTabs = "list_tabs"
        /// The review comments the user has left on the Changes diff.
        case readReviewComments = "read_review_comments"
        /// A verification run's state and per-check results, by run id.
        case checkVerification = "check_verification"
        /// The checks this project declares — names, commands, shells — without
        /// running any of them.
        ///
        /// **An agent has no other way to learn them.** `verification.yaml` lives
        /// in the project directory, which is outside every work tree, and the
        /// "Restrict to worktree" system prompt is on by default — so a check's
        /// name could previously only be discovered by guessing one and reading
        /// `start_verification`'s refusal.
        case listVerificationChecks = "list_verification_checks"
        /// The caller's workstream's saved checkpoint — where an agent said it
        /// left off — or nothing if none has been saved.
        case getSessionCheckpoint = "get_session_checkpoint"
        /// Reads the caller's own workstream's whiteboard: a text digest of its
        /// elements, plus the absolute path to the rendered PNG.
        ///
        /// Both halves, deliberately. An LLM reads text precisely and pixels
        /// only impressionistically, so the digest is the part of the board that
        /// can be reasoned about exactly and the picture is the part that
        /// cannot — freehand and pasted screenshots reach an agent no other way.
        case readWhiteboard = "read_whiteboard"

        /// Workspace actions.
        /// Opens a terminal tab in the caller's own workstream, optionally
        /// starting an agent in it.
        case openAgentTab = "open_agent_tab"
        /// Opens a file in the workstream's editor, optionally at a line.
        case openEditor = "open_editor"
        /// Opens one of the workstream's singleton tabs — Changes, Execution or
        /// Verification — without taking the selection.
        ///
        /// Those three start *closed*: `startupWorkspaceTabState` seeds Info and
        /// Agent alone. So a tool an agent already has could produce something
        /// with no visible surface to read it in — `start_verification` spawns a
        /// terminal per check, and no output crosses IPC, so "look at the
        /// Verification tab" was the only pointer the agent had and the one thing
        /// it could not act on.
        case openTab = "open_tab"
        /// Raises a notification asking the user to come and look.
        case requestAttention = "request_attention"
        /// Creates a new workstream — worktree, branch, initialization — and
        /// optionally starts an agent there.
        case createWorkstream = "create_workstream"
        /// Starts a verification run — some or all of the checks
        /// `verification.yaml` declares — in the caller's own workstream, and
        /// answers with a run id rather than the result.
        case startVerification = "start_verification"
        /// Adds elements to the caller's own workstream's whiteboard, in the
        /// narrow vocabulary box / note / text / arrow, and answers with their
        /// real Excalidraw ids.
        ///
        /// A **list**, because a diagram is eight boxes and six arrows, and one
        /// call per element at this tier makes agent-produced visuals
        /// miserable. An arrow may name a box created earlier in the same call,
        /// so a whole diagram is one round trip.
        case whiteboardAdd = "whiteboard_add"
        /// Moves, retexts or recolours one element of the caller's board.
        case whiteboardUpdate = "whiteboard_update"
        /// Removes elements from the caller's board. An id that is already gone
        /// is success, which is what makes this safe to replay.
        case whiteboardDelete = "whiteboard_delete"
        /// The dev stack's state and live process table, in the caller's own
        /// workstream. Also how an agent learns the process names at all: they
        /// are declared in a config outside its worktree.
        case listProcesses = "list_processes"
        /// One process's log tail. Output crosses IPC here and deliberately not
        /// for verification — process-compose keeps logs and serves them, while
        /// a check's output exists only in a surface Atelier keeps no copy of.
        case readProcessLogs = "read_process_logs"
        case startProcess = "start_process"
        case stopProcess = "stop_process"
        case restartProcess = "restart_process"
        /// Starts the dev stack — the Execution tab's Start button — and answers
        /// immediately rather than waiting for anything to come up.
        case startExecution = "start_execution"
        /// Stops it.
        case stopExecution = "stop_execution"
        /// Overwrites the caller's workstream's checkpoint with free text.
        ///
        /// Shared per workstream, not per agent: two agents in one workstream
        /// (the Coding Agent and one spawned via `open_agent_tab`) read and
        /// write the same blob. There is no version history — this replaces the
        /// previous checkpoint outright, the same "call before finishing, or at
        /// any milestone worth resuming from" convention Scenius's own
        /// `update_last_session` states.
        case updateSessionCheckpoint = "update_session_checkpoint"
        /// Closes one of the workstream's tabs — a singleton pane by `kind`, or
        /// a terminal tab by `surface_id`. The counterpart to `open_tab` and
        /// `open_agent_tab`: the tool for tearing a pane down once it has done
        /// its job, most of all a peer `open_agent_tab` spawned for a bounded
        /// task.
        ///
        /// Closes every singleton, Execution included — and closing Execution
        /// **stops the running dev stack**, exactly as the user's own close of
        /// that tab does. Info and Agent are permanent and are not closeable.
        /// See `WorkspaceActions.closeTab` for why Execution stopped being
        /// refused.
        case closeTab = "close_tab"

        /// Project tasks — a claimable, project-scoped work queue. See
        /// `Surface.projectTasks`'s doc comment for why this is its own group.
        /// Adds a task to the queue for any peer in the project to claim.
        case addTask = "add_task"
        /// Lists unclaimed tasks in the project's queue.
        case getPendingTasks = "get_pending_tasks"
        /// Lists every task in the project's queue, regardless of state.
        case listTasks = "list_tasks"
        /// Claims a pending task. Ownership is keyed by the caller's surface
        /// id, never its peer id — see this file's `IPC.TaskStore` doc comment.
        case claimTask = "claim_task"
        /// Marks a claimed task done. Only its claimer may call this.
        case completeTask = "complete_task"
        /// Marks a claimed task failed, with a required reason. Only its
        /// claimer may call this.
        case failTask = "fail_task"
    }

    /// The four groups of `Tool` — see that type's doc comment.
    enum Surface: String, Codable, CaseIterable {
        case messaging
        case workspaceRead
        case workspaceAction
        /// A project-scoped, claimable task queue — `add_task`, `get_pending_tasks`,
        /// `list_tasks`, `claim_task`, `complete_task`, `fail_task`.
        ///
        /// Not `.messaging`: that group's trust story is "none needed — nothing a
        /// user can see," and a claim is durable state another agent's
        /// *correctness* depends on, not a private inbox message. Not
        /// `.workspaceRead`/`.workspaceAction` either: both are explicitly scoped
        /// to the caller's own workstream in their own doc comments, and this
        /// feature is project-wide by design — the same scope peers and messages
        /// already have.
        ///
        /// **No approval gate, for a third reason distinct from either existing
        /// ungated group.** Workspace actions go ungated because they're
        /// attended (a deliberate press, output in front of the user). Messaging
        /// goes ungated because nothing here is visible to the user at all.
        /// Project tasks go ungated because nothing in this surface executes
        /// code, spawns a process, or touches the user's files or git state —
        /// it's structured coordination data between peers already inside one
        /// trust boundary, gated by the same `atelier.agentIPC` setting that
        /// gates whether any IPC tool exists for this session at all.
        case projectTasks
    }

    /// One request from a helper to the app.
    ///
    /// `arguments` is `[String: String]` rather than arbitrary JSON because every
    /// tool in this surface takes only string arguments (peer ids, names, roles,
    /// message bodies). That keeps both ends free of a hand-rolled JSON value type.
    struct Request: Codable {
        /// Correlates the response; the helper matches replies by this.
        let id: String
        let token: String
        /// The tool being invoked.
        let tool: Tool
        let arguments: [String: String]
        /// Identity the helper inherited from its terminal's environment.
        let client: ClientIdentity

        init(id: String = UUID().uuidString, token: String, tool: Tool, arguments: [String: String] = [:], client: ClientIdentity) {
            self.id = id
            self.token = token
            self.tool = tool
            self.arguments = arguments
            self.client = client
        }
    }

    /// Who is calling, as far as the environment can say.
    ///
    /// The helper is a child of the terminal that launched the agent, so it reads
    /// all of this from its own environment — no config interpolation, no headers.
    struct ClientIdentity: Codable {
        /// `ATELIER_WORKSTREAM_ID`, when the helper was launched inside a workstream.
        let workstreamID: String?
        /// `ATELIER_WORKSTREAM`, for display.
        let workstreamName: String?
        /// `ATELIER_PROJECT_DIR`, used for same-project scoping.
        let projectDirectory: String?
        /// `ATELIER_SURFACE_ID`: the terminal surface this agent is running in.
        ///
        /// Every Atelier-launched terminal exports its own — the Coding Agent tab
        /// and each terminal tab alike — so a nudge can be typed into the pane the
        /// recipient actually occupies rather than assumed to be the Agent tab.
        /// Absent for anything Atelier didn't launch, which is then pull-only.
        let surfaceID: String?
        /// The peer this session registered, once it has one.
        let peerID: String?

        static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment, peerID: String? = nil) -> ClientIdentity {
            ClientIdentity(
                workstreamID: env["ATELIER_WORKSTREAM_ID"],
                workstreamName: env["ATELIER_WORKSTREAM"],
                projectDirectory: env["ATELIER_PROJECT_DIR"],
                surfaceID: env["ATELIER_SURFACE_ID"],
                peerID: peerID
            )
        }
    }

    /// A peer as reported to an agent. Distinct from the store's `Peer`: it carries
    /// the app-side context (workstream, inbox depth) the store deliberately
    /// doesn't know about, and no `Date` values that would need a shared encoding
    /// strategy on both ends.
    struct PeerInfo: Codable {
        let id: String
        let name: String
        let role: String
        let workstream: String?
        /// The terminal surface this peer's agent is running in, when Atelier
        /// launched it.
        ///
        /// Load-bearing, and the reason it is here: two agents in one workstream
        /// report the same `workstream`, so nothing else distinguishes them. A
        /// caller that has just created a tab holds its surface id and needs to
        /// turn that into an addressable peer; without this field it can only
        /// guess from names it does not choose. Nil for anything Atelier did not
        /// launch.
        let surfaceID: String?
        /// Seconds since this peer was last heard from.
        let lastSeenSecondsAgo: Int
        let pendingMessages: Int
        /// Seconds since this peer's surface last had a `UserPromptSubmit` hook
        /// event — a human typing into that pane, as opposed to the peer acting on
        /// its own or on another agent's instruction. Nil means no such event has
        /// been observed this session, which covers both "never happened yet" and
        /// "this peer has no surface to type into" (`surfaceID == nil`). A
        /// coordinator compares this against its own dispatch time to tell whether
        /// a peer has had direct human input since; Atelier has no notion of
        /// "dispatch" of its own to compare against.
        let lastUserPromptSecondsAgo: Int?
    }

    /// A delivered message as reported to an agent.
    struct MessageInfo: Codable {
        let id: String
        let from: String
        let fromName: String
        let content: String
        /// Seconds since the message was sent.
        let sentSecondsAgo: Int
    }

    /// One tab of a workstream's workspace, as reported to an agent.
    ///
    /// `surfaceID` is the address the rest of this surface speaks in: it is what
    /// `open_agent_tab` returns, what `ATELIER_SURFACE_ID` carries into a
    /// terminal, and what `PeerInfo.surfaceID` reports back — so a caller that
    /// spawns an agent can find the peer that appears in the tab it made. Only
    /// terminal tabs have one; a browser or editor tab has no shell and no
    /// agent, and reports nil rather than an id that addresses nothing.
    struct TabInfo: Codable {
        /// "agent", "terminal", "browser", "editor", "changes", "environment", "info".
        let kind: String
        let surfaceID: String?
        /// The tab's label, when it has one distinct from its kind.
        let title: String?
        /// Whether this is the workspace's active tab.
        let isActive: Bool
        /// Whether this is the tab the caller itself is running in.
        let isCaller: Bool
        /// The peer registered in this tab, when an agent has connected from it.
        /// Nil until one has — a tab whose agent is still starting reports the
        /// tab but no peer, which is the state a spawner polls through.
        let peerID: String?
        let peerName: String?
    }

    /// One of the user's review comments on the Changes diff.
    struct ReviewCommentInfo: Codable {
        /// Repo-relative, as `Git.DiffFile.relativePath` spells it.
        let filePath: String
        /// The diff scope it was written in: "branch" or "uncommitted".
        let mode: String
        /// Which side of the diff it anchors to: "old" or "new".
        let side: String
        let line: Int
        let endLine: Int?
        /// The anchor line's own text, so a comment can be located even if the
        /// line has since moved.
        let lineText: String
        let text: String
        /// Whether the line it was anchored to has since disappeared. An
        /// orphaned comment still says something; it just no longer says it
        /// about a line that exists.
        let isOrphaned: Bool
    }

    /// What a project declares in its `verification.yaml`, as an agent sees it.
    ///
    /// **Shaped like `Verification.Config.Load`, deliberately.** That type spends a
    /// paragraph on why `.missing`, `.invalid(reason:)` and a file declaring zero
    /// checks must stay three distinguishable answers rather than collapsing into
    /// one empty list — a file Atelier cannot read must never render as "this
    /// project declares no checks". So this carries the same pair the tab draws
    /// from: `checks`, and `unavailableReason`, which is non-nil exactly when
    /// `checks` is empty. The wording is `Load.unavailableReason`'s own, not a
    /// fourth copy of it.
    ///
    /// Declared here rather than beside the seam for the same reason
    /// `VerificationRunInfo` is: `renderText` in `Sources/MCPHelper/main.swift`
    /// renders it, and `AtelierMCP` compiles only this file and
    /// `IPCToolRegistry.swift` out of `Models/IPC/` (`project.yml`).
    struct VerificationChecksInfo: Codable, Equatable {
        /// Where the checks were read from, or nil when there is no file.
        let configPath: String?
        /// Every declared check, **in file order** — which is the order the
        /// Verification tab draws its rows in. Never routed through a dictionary,
        /// which would shuffle them between launches.
        let checks: [VerificationCheckDeclaration]
        /// Why nothing can run, or nil when something can. Empty `checks`
        /// whenever this is set, so the two cannot describe different states.
        let unavailableReason: String?
    }

    /// One declared check: what it is called, and what it runs.
    ///
    /// No verdict and no staleness. `check_verification` answers verdicts, and
    /// staleness costs four-plus git spawns — too much for a call an agent makes
    /// casually to find out what the names are.
    struct VerificationCheckDeclaration: Codable, Equatable {
        let name: String
        /// The command, as `verification.yaml` writes it.
        let command: String
        /// The shell named for this check, or nil for the user's `$SHELL`.
        /// Carried because it changes how the command runs.
        let shell: String?
    }

    /// A verification run as reported to an agent.
    ///
    /// A **projection** of the runner's `Verification.Run`, not that type: the
    /// same relationship `PeerInfo` has to the store's `Peer`, and
    /// `TabInfo`/`ReviewCommentInfo` to what `WorkspaceActions` reads. Every
    /// model that crosses this boundary gets one, and this one has to differ —
    /// seconds-ago rather than a `Date` that would need a shared encoding
    /// strategy on both ends, and `isStale` rather than the stamp it is computed
    /// from.
    ///
    /// **No output crosses this boundary, and that is a deliberate narrowing.**
    /// A check runs in its own terminal surface, so its output lives in that
    /// terminal and dies with it; Atelier never holds a copy to send. An agent
    /// gets verdicts, exit codes and durations, and the honest pointer for
    /// anything more is asking the user to look at the tab — or re-running the
    /// one check.
    ///
    /// Declared here rather than beside the seam because `renderText` in
    /// `Sources/MCPHelper/main.swift` renders it, and `AtelierMCP` compiles only
    /// this file and `IPCToolRegistry.swift` out of `Models/IPC/` (`project.yml`).
    struct VerificationRunInfo: Codable {
        let runID: String
        /// The workstream the run belongs to. Carried so a read can be scoped to
        /// the caller's own workstream: `check_verification` takes only a run id,
        /// and run ids are short and guessable.
        let workstreamID: String
        /// The workstream's display name, for the agent to read back.
        let workstreamName: String?
        let state: VerificationRunState
        let startedSecondsAgo: Int
        /// Wall-clock seconds the run took. Nil while it is still going.
        let durationSeconds: Double?
        let checks: [VerificationCheckInfo]
        /// Whether the worktree has changed since the run started, so a pass no
        /// longer describes the code on disk.
        let isStale: Bool
    }

    /// Whether a verification run is still going, finished on its own, or was
    /// stopped. There is no `failed` case: a run that finished with failing
    /// checks still *finished*, and which checks failed is per-check.
    enum VerificationRunState: String, Codable, CaseIterable {
        case running
        case finished
        case stopped
    }

    /// One check's result within a run.
    struct VerificationCheckInfo: Codable, Equatable {
        let name: String
        let state: VerificationCheckState
        /// The process's exit code. Only meaningful for `.failed`, and nil
        /// otherwise.
        let exitCode: Int?
        let durationSeconds: Double?
    }

    /// A check's state, as an agent sees it.
    ///
    /// Mapped from `Verification.CheckResult.State` by the bridge.
    ///
    /// `pending` and `skipped` have no producer: they described a
    /// process-compose dependency graph that checks no longer have. They stay in
    /// the wire enum so a helper built against an older Atelier still decodes,
    /// and so a queued check has a name waiting for it.
    enum VerificationCheckState: String, Codable, CaseIterable {
        case notRun = "not_run"
        case pending
        case running
        case passed
        case failed
        /// No producer; see the note above.
        case skipped
        /// Stopped by hand while it was running.
        case stopped
    }

    /// Whether a workstream's dev stack can run, is running, and whether there
    /// is a process table to read.
    ///
    /// **Four cases, not two, for the reason `Verification.Config.Load` has
    /// three.** `ProcessCompose.Client.ClientError.notRunning` collapses "no
    /// config", "not started", "started but there is no control socket" and
    /// "running" into one silence, and an agent told "nothing is running" is
    /// misled in three of them.
    enum ExecutionRunState: String, Codable, CaseIterable {
        /// No `execution.process-compose.yaml`, no process-compose binary, or
        /// nothing declares an `execute` namespace. `unavailableReason` says
        /// which, in `ProcessCompose.Resolution`'s own words.
        case unavailable
        /// A command exists and nothing is running. `start_execution` is the next
        /// move.
        case idle
        /// The run is up and `processes` is the live table.
        case running
        /// The run is the user's own per-workstream dev-command override, so
        /// there is no control socket and never will be. The socket-backed tools
        /// refuse rather than report an empty stack as a fact.
        case runningWithoutProcessTable = "running_without_process_table"
    }

    /// One process as an agent sees it.
    ///
    /// Named `ExecutionProcessInfo` and not `ProcessInfo`: `Foundation.ProcessInfo`
    /// is exactly the collision CLAUDE.md cites for keeping `ProcessRunner`
    /// top-level.
    struct ExecutionProcessInfo: Codable, Equatable {
        let name: String
        let namespace: String
        let status: String
        let isReady: String
        let hasReadyProbe: Bool
        let restarts: Int
        let exitCode: Int
        let pid: Int
        let isRunning: Bool
        /// The port this process owns, correlated by name through
        /// `ProcessCompose.TableModel.port(for:in:)`. Nil when nothing matches,
        /// which is cosmetic rather than wrong — process-compose reports pids and
        /// the port plan holds variable names, and nothing joins the two but the
        /// name.
        let port: String?
    }

    /// What `list_processes` answers.
    ///
    /// `declaredProcesses` rides along in **every** state, because this is also
    /// how an agent learns the names at all: `execution.process-compose.yaml`
    /// lives in the project directory, outside the worktree, and the "Restrict to
    /// worktree" system prompt is on by default. Already filtered through
    /// `PhaseRunner.runnableProcesses`, so it cannot offer a name the command
    /// would drop.
    struct ExecutionInfo: Codable, Equatable {
        let state: ExecutionRunState
        /// `ProcessCompose.Resolution.startUnavailableReason`, verbatim and never
        /// paraphrased, so an agent and `ExecutionTabView.scriptInstructions` say
        /// the same thing about the same file. Non-nil exactly when the state is
        /// `.unavailable`.
        let unavailableReason: String?
        let declaredProcesses: [String]
        let processes: [ExecutionProcessInfo]
        /// What will be loaded or run, for display only. For a process-compose
        /// source this is the config's files — never the un-`-n`'d
        /// `process-compose up` string, which must never reach anything that
        /// could execute it.
        let command: String?
    }

    /// A process's log tail.
    struct ExecutionLogs: Codable, Equatable {
        let process: String
        /// Newest last. stderr is interleaved, as process-compose captures both
        /// streams into one log.
        let lines: [String]
        /// Whether older lines were dropped to fit the budget. Reported rather
        /// than silent, the way `VerificationSummary` reports a cut list.
        let wasTrimmed: Bool

        /// Default byte budget for a tail.
        ///
        /// A tool response is **not** an `IPC.Store` message, so the store's 64KB
        /// cap does not bind here — but `IPC.Server.maxFrameBytes` (1MB) and the
        /// agent's own context both do, and one unbounded line is enough to reach
        /// either.
        static let defaultBudgetBytes = 65_536

        /// Trim a tail to a byte budget, dropping **oldest first** — a tail is
        /// about what happened most recently.
        ///
        /// The newest line is always kept, even when it alone exceeds the budget:
        /// an empty list would read as "this process printed nothing", which is a
        /// different and wrong answer.
        static func trimmed(
            lines: [String],
            budgetBytes: Int = defaultBudgetBytes
        ) -> (lines: [String], wasTrimmed: Bool) {
            guard !lines.isEmpty else { return ([], false) }
            var kept: [String] = []
            var used = 0
            for line in lines.reversed() {
                // +1 for the newline a reader will put back between them.
                let cost = line.utf8.count + 1
                if !kept.isEmpty, used + cost > budgetBytes {
                    break
                }
                kept.append(line)
                used += cost
            }
            kept.reverse()
            return (kept, kept.count != lines.count)
        }
    }

    /// What `start_execution` answers with.
    struct ExecutionStart: Codable, Equatable {
        /// The processes this run was scoped to. Empty means the whole `execute`
        /// namespace, which is what an unscoped run starts.
        let started: [String]
        /// Whether a socket reclaim is in flight, so the stack comes up a moment
        /// after this answer rather than immediately.
        let isReclaimingSocket: Bool
    }

    /// Seconds as an agent should read them.
    ///
    /// Minutes appear because a real suite runs for tens of them and `1503.2s`
    /// is arithmetic homework. Declared here rather than beside the rest of the
    /// verification formatting because `renderText` in the helper needs it, and
    /// `AtelierMCP` compiles only this file and `IPCToolRegistry.swift` out of
    /// `Models/IPC/`.
    static func durationText(_ seconds: Double) -> String {
        guard seconds >= 60 else { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        return "\(minutes)m " + String(format: "%.1fs", seconds - Double(minutes * 60))
    }

    /// A task's lifecycle, as an agent sees it.
    enum TaskWireState: String, Codable, CaseIterable {
        case pending
        case claimed
        case completed
        case failed
    }

    /// One task, projected for the wire — the relationship `PeerInfo` has to
    /// the store's `Peer`, and `VerificationRunInfo` to `Verification.Run`.
    ///
    /// `createdBy`/`claimedBy` are **peer ids**, not surface ids: ownership is
    /// keyed internally by surface id (see `IPC.TaskStore`'s doc comment), but
    /// an agent reading this has no use for another surface's raw id — a peer
    /// id is what `send_message` addresses. Both are resolved live from
    /// whichever peer currently occupies that surface, which can be a
    /// different peer than the one that originally created or claimed the
    /// task; nil when nobody is currently registered there.
    struct TaskInfo: Codable, Equatable {
        let path: String
        let name: String
        let content: String
        let tags: [String]
        let state: TaskWireState
        let createdSecondsAgo: Int
        let createdBy: String?
        let createdByName: String?
        let claimedBy: String?
        let claimedByName: String?
        let claimedSecondsAgo: Int?
        /// Set only when `state == .failed`.
        let failureReason: String?
    }

    /// The result of a successful call.
    enum Payload: Codable {
        case peers([PeerInfo])
        case peer(PeerInfo)
        case messages([MessageInfo])
        case tabs([TabInfo])
        case reviewComments([ReviewCommentInfo])
        case verificationRun(VerificationRunInfo)
        case verificationChecks(VerificationChecksInfo)
        case execution(ExecutionInfo)
        case executionLogs(ExecutionLogs)
        case task(TaskInfo)
        case tasks([TaskInfo])
        case text(String)
    }

    /// One reply from the app to a helper.
    struct Response: Codable {
        let id: String
        let payload: Payload?
        let error: String?
        /// Why it failed, for the refusals the helper has to *act* on rather
        /// than relay — see `IPC.ResponseCode`. Nil for everything else, which
        /// is almost everything: an error an agent reads needs a sentence, not
        /// a code.
        let code: ResponseCode?

        static func success(id: String, _ payload: Payload) -> Response {
            Response(id: id, payload: payload, error: nil, code: nil)
        }

        static func failure(id: String, _ message: String, code: ResponseCode? = nil) -> Response {
            Response(id: id, payload: nil, error: message, code: code)
        }
    }

    /// Encodes and decodes the newline-delimited framing both ends speak.
    ///
    /// `JSONEncoder` never emits a raw newline inside a value, so a single `\n`
    /// terminator is an unambiguous frame boundary.
    enum Framing {
        static let terminator: UInt8 = 0x0A

        static func encode(_ value: some Encodable) throws -> Data {
            var data = try JSONEncoder().encode(value)
            data.append(terminator)
            return data
        }

        /// Splits `buffer` into complete lines, returning them along with whatever
        /// partial line is left over.
        static func lines(from buffer: Data) -> (lines: [Data], remainder: Data) {
            var lines: [Data] = []
            var remainder = buffer
            while let index = remainder.firstIndex(of: terminator) {
                let line = remainder[remainder.startIndex ..< index]
                if !line.isEmpty {
                    lines.append(Data(line))
                }
                remainder = Data(remainder[remainder.index(after: index)...])
            }
            return (lines, remainder)
        }
    }
}
