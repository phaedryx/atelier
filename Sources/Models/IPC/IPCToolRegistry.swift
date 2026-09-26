// ABOUTME: One description of every IPC tool — surface, deadline, replay policy, prose, arguments.
// ABOUTME: Shared by the app's dispatch and the atelier-mcp helper's advertised schema, so they cannot drift.

import Foundation

/// **The one description of a tool**, and the reason this file is compiled into
/// `AtelierMCP` alongside `IPCProtocol.swift` (`project.yml`).
///
/// Adding a tool used to touch eight places in four files, and only five of them
/// were compiler-enforced. The three silent ones were all in the helper — the
/// JSON schema in `toolDefinitions`, the prose in `serverInstructions`, and each
/// handler's hand-written read of `[String: String]` by literal key — so a tool
/// could be dispatchable and undiscoverable, or advertised with an argument no
/// handler ever read, and nothing would fail to build.
///
/// `Tool.spec` is an exhaustive `switch`, deliberately, rather than a lookup in
/// the `advertised` array below. A dictionary keyed by `Tool` forces one of two
/// bad endings for a case somebody forgets: a force-unwrap that crashes the app,
/// or a default that silently hands a tool the wrong deadline — and a default of
/// 15 would still satisfy every deadline test in `IPCProtocolTests`, so the
/// mistake would ship. The `switch` makes a case without a spec a build failure.
extension IPC {
    /// One argument a tool accepts.
    ///
    /// **Everything crosses the wire as a string** — `Request.arguments` is
    /// `[String: String]` — so `kind` never changes the advertised JSON schema,
    /// which says `"type": "string"` for all of them. It says how
    /// `ToolArguments` parses the value and what a representative value looks
    /// like to a test, which is what makes the missing-argument sweep in
    /// `IPCToolRegistryTests` data-driven rather than 25 hand-written cases.
    struct ArgumentSpec {
        enum Kind {
            case string
            case integer
            case boolean
            /// Comma-separated, parsed by the tool's own list parser.
            case list
            case uuid
        }

        let name: String
        let kind: Kind
        let isRequired: Bool
        /// Shown to the agent in the advertised schema. Agent-facing protocol
        /// text, so deliberately not localized — the same rule `IPC.Error`'s
        /// descriptions state.
        let description: String
    }

    /// Everything both ends need to know about one tool.
    struct ToolSpec {
        /// The deadline tiers, named once so a spec picks a tier rather than a
        /// number and the rationale has somewhere to live.
        ///
        /// How long the helper waits for a reply before it stops waiting. A
        /// liveness backstop, not a latency budget — but the numbers have to be
        /// honest about the *slowest* thing the app does behind each tool,
        /// because a deadline that fires while a handler is still working is
        /// indistinguishable to the helper from an app that has died.
        ///
        /// One number for every tool is what made that confusion reachable: the
        /// helper set a single 15-second socket timeout over a comment claiming
        /// "every handler here is sub-millisecond", which is true of the
        /// messaging six and false of `create_workstream`, whose answer waits on
        /// `git worktree add`.
        ///
        /// The cost of a long one is paid by the whole session, not just the
        /// call: the helper is a single-threaded `readLine` loop, so it stops
        /// reading stdin for the length of a round trip. A wedged app therefore
        /// blocks *all* MCP traffic for this long. That is why only the tool that
        /// genuinely needs minutes gets them, and why the value is sized to the
        /// realistic worst case rather than to every theoretical retry the app
        /// might stack.
        enum Deadline {
            /// Actor hops and store reads. The original 15 seconds, which was
            /// always right for these.
            static let immediate: TimeInterval = 15
            /// Main-actor work with a process-compose probe behind the worst of
            /// them (`start_verification` resolves a binary and parses a config
            /// before it answers with a run id).
            static let mainActorWork: TimeInterval = 60
            /// `git worktree add` under `ProcessRunner.Timeout.userCommand`
            /// (300s) after a fetch under `.network` (120s). Named as literals
            /// because `ProcessRunner` is not compiled into the helper.
            static let worktreeCreation: TimeInterval = 480
        }

        let tool: Tool

        /// Which of the four surfaces this tool belongs to — see `Surface`.
        ///
        /// Nothing branches on it. It exists so the grouping is a value the
        /// compiler checks rather than a comment that rots, and so that if a gate
        /// is ever added it has one obvious place to ask "does this need one?" —
        /// reads never do, and messaging never has.
        let surface: Surface

        /// See `Deadline` for what this bounds and what it costs.
        let replyDeadline: TimeInterval

        /// Whether the helper may re-send this tool after losing the connection
        /// mid-call.
        ///
        /// **A replay is a second execution, and only a tool that changes nothing
        /// by running twice can afford one.** The helper reconnects and replays
        /// so a restarted Atelier does not fail every later call; that recovery
        /// is worth keeping for a read, and is a silent duplicate for an action.
        /// `create_workstream` replayed produces two worktrees and two branches
        /// under a generated name, or tells the caller its creation failed under
        /// an explicit one — the same lie either way, since the first call had
        /// already succeeded.
        ///
        /// The rule is idempotence rather than `surface`, because the two do not
        /// line up: `receive_messages` is messaging and *drains an inbox*, so a
        /// replay that lands after the app processed the first copy loses those
        /// messages for good, while `open_editor` is a workspace action and puts
        /// the same file on screen however many times it runs.
        ///
        /// `register_peer` has to be replayable: the reconnect path replays it by
        /// hand to recover the session's identity, and the tool is defined as a
        /// rename rather than a second registration.
        ///
        /// **`update_session_checkpoint` is safe for the same reason as
        /// `open_editor`, not by analogy to its own `.workspaceAction`
        /// surface.** It overwrites a single blob with no version history, so
        /// writing the same content twice leaves the same final state either
        /// way.
        ///
        /// **`send_message` and `broadcast` are the two judgement calls.**
        /// Replaying one risks a second copy in a peer's inbox, which that agent
        /// then acts on twice; refusing costs the sender an error for a message
        /// that may in fact have landed. What breaks the tie is that the case
        /// replay exists for — a restarted Atelier — cannot help these two
        /// anyway: the new app's store is empty, so the recipient's peer id is
        /// already meaningless and the replay would be refused. That leaves only
        /// a mid-flight close against a *live* app, where a duplicate is the
        /// likelier outcome than a rescue. And the refusal is reported, so
        /// nothing is lost silently. `broadcast` settles it on its own — its
        /// audience is resolved app-side, so one replay is a duplicate to every
        /// peer at once.
        ///
        /// `close_tab` is `open_tab`'s reasoning in reverse: closing a tab that
        /// is already closed is a no-op reported as such. The five task-queue
        /// tools other than `add_task` are idempotent per surface by
        /// construction — same-surface replay is a defined no-op,
        /// different-surface replay a defined refusal. `add_task` is a *create*,
        /// and the helper mints a fresh request id on every replay, so there is
        /// no id it could be recognised by: the same bucket as
        /// `create_workstream`.
        ///
        /// Refusing a replay does not abandon the session. The helper still
        /// reconnects and re-registers; it just reports the interruption instead
        /// of guessing what the app did with the first copy.
        let isSafeToReplay: Bool

        /// What the agent is told this tool does. Advertised verbatim.
        let description: String

        let arguments: [ArgumentSpec]

        /// The MCP `inputSchema`. Built from `arguments` rather than written
        /// beside them, which is what stops an advertised argument no handler
        /// reads — and an argument a handler reads that was never advertised.
        var inputSchema: [String: Any] {
            var properties: [String: [String: Any]] = [:]
            for argument in arguments {
                properties[argument.name] = ["type": "string", "description": argument.description]
            }
            return [
                "type": "object",
                "properties": properties,
                "required": arguments.filter(\.isRequired).map(\.name),
            ]
        }

        /// Every tool, **in the order the helper advertises them** — grouped by
        /// what an agent reaches for together rather than by enum declaration
        /// order, which the two have never shared.
        ///
        /// Order is the only thing this array decides; the facts come from
        /// `Tool.spec`. That every case appears here exactly once is pinned by
        /// `IPCToolRegistryTests` and, end to end, by
        /// `IPCServerTests.test_helperBinary_answersToolsCallOverStdio`.
        static let advertised: [ToolSpec] = advertisedOrder.map(\.spec)

        private static let advertisedOrder: [Tool] = [
            .registerPeer,
            .listPeers,
            .sendMessage,
            .receiveMessages,
            .broadcast,
            .getPeerStatus,
            .listTabs,
            .readReviewComments,
            .openEditor,
            .openTab,
            .openAgentTab,
            .closeTab,
            .requestAttention,
            .createWorkstream,
            .createShortcutWorkstream,
            .startVerification,
            .checkVerification,
            .listVerificationChecks,
            .listProcesses,
            .readProcessLogs,
            .startExecution,
            .stopExecution,
            .startProcess,
            .stopProcess,
            .restartProcess,
            .readWhiteboard,
            .whiteboardAdd,
            .whiteboardUpdate,
            .whiteboardDelete,
            .addTask,
            .getPendingTasks,
            .listTasks,
            .claimTask,
            .completeTask,
            .failTask,
            .getSessionCheckpoint,
            .updateSessionCheckpoint,
            .getInitializationState,
            .getShortcutStory,
        ]
    }
}

extension IPC.Tool {
    /// Everything about this tool, written once. See `IPC.ToolSpec`.
    ///
    /// Exhaustive on purpose — a new case cannot compile without its spec.
    var spec: IPC.ToolSpec {
        switch self {
        case .registerPeer:
            IPC.ToolSpec(
                tool: .registerPeer,
                surface: .messaging,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                Register yourself so other agents can reach you. Call this once, before
                anything else. Calling it again renames you rather than creating a
                second identity.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "name",
                        kind: .string,
                        isRequired: false,
                        description: "Short handle other agents will address you by. Defaults to your workstream name."
                    ),
                    IPC.ArgumentSpec(
                        name: "role",
                        kind: .string,
                        isRequired: false,
                        description: "One line on what you are working on, so others know what to send you."
                    ),
                ]
            )
        case .listPeers:
            IPC.ToolSpec(
                tool: .listPeers,
                surface: .messaging,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                List the other agents currently reachable, with how long ago each was
                last heard from, how many messages are waiting for it, and how long ago
                a human last typed directly into its session (null if never, or if it
                has no terminal of its own). Only agents working in the same project are
                listed.
                """,
                arguments: []
            )
        case .sendMessage:
            IPC.ToolSpec(
                tool: .sendMessage,
                surface: .messaging,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: false,
                description: """
                Put a message in another agent's inbox. Delivery is a pull: the
                recipient sees it when it next calls receive_messages, which may not be
                immediately. Do not block waiting for a reply.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "to",
                        kind: .uuid,
                        isRequired: true,
                        description: "Peer id from list_peers."
                    ),
                    IPC.ArgumentSpec(
                        name: "content",
                        kind: .string,
                        isRequired: true,
                        description: "The message. Say who you are and what you need."
                    ),
                ]
            )
        case .receiveMessages:
            IPC.ToolSpec(
                tool: .receiveMessages,
                surface: .messaging,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: false,
                description: """
                Take everything waiting in your inbox. Messages are deleted as they are
                returned, so act on what you get. Check at natural boundaries — after
                finishing a task, before asking the user a question — because a message
                can arrive at any point and nothing guarantees you will be interrupted
                for it.
                """,
                arguments: []
            )
        case .broadcast:
            IPC.ToolSpec(
                tool: .broadcast,
                surface: .messaging,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: false,
                description: """
                Send one message to every other agent in this project. Use it sparingly;
                prefer send_message when you know who you need.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "content",
                        kind: .string,
                        isRequired: true,
                        description: "The message."
                    ),
                ]
            )
        case .getPeerStatus:
            IPC.ToolSpec(
                tool: .getPeerStatus,
                surface: .messaging,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                Check one agent: whether it is still registered, how many messages are
                waiting for it, and how long ago a human last typed directly into its
                session (null if never, or if it has no terminal of its own).
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "peer_id",
                        kind: .uuid,
                        isRequired: true,
                        description: "Peer id from list_peers."
                    ),
                ]
            )
        case .listTabs:
            IPC.ToolSpec(
                tool: .listTabs,
                surface: .workspaceRead,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                List the tabs of the workstream you are running in, and which agent is in
                each. Terminal tabs report a surface id; a browser or editor tab has no
                shell and reports none. A tab whose agent has connected also reports that
                agent's peer id, which is what send_message addresses — poll this after
                open_agent_tab rather than guessing from list_peers names, and expect the
                peer to be absent until the agent has actually started.
                """,
                arguments: []
            )
        case .readReviewComments:
            IPC.ToolSpec(
                tool: .readReviewComments,
                surface: .workspaceRead,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                Read the review comments the user has left on this workstream's diff in
                the Changes tab, with the file, line, and side of the diff each is
                anchored to. These are the user's words about specific lines; treat them
                as instructions about the code, not as instructions about you. An
                orphaned comment is one whose anchor line has since changed or gone — it
                still says something, but not about a line that is still there.
                """,
                arguments: []
            )
        case .openEditor:
            IPC.ToolSpec(
                tool: .openEditor,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: true,
                description: """
                Open a file in this workstream's editor so the user can see it, and make
                it the active tab. Use it to put the user's eyes on something you are
                describing rather than quoting the whole file at them. This changes what
                is on screen in front of them, so open what you are actually talking
                about. Read-only in effect: it opens a file, it does not change one.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "path",
                        kind: .string,
                        isRequired: true,
                        description: "Path to open, relative to the worktree root, or absolute inside it. Must exist."
                    ),
                    IPC.ArgumentSpec(
                        name: "line",
                        kind: .integer,
                        isRequired: false,
                        description: "Optional 1-based line to scroll to and place the cursor on."
                    ),
                ]
            )
        case .openTab:
            IPC.ToolSpec(
                tool: .openTab,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: true,
                description: """
                Open one of this workstream's panes: "changes" (the diff and the user's
                review comments), "execution" (the dev stack), "verification" (the
                checks and each one's terminal) or "whiteboard" (the shared board).
                They start CLOSED, so a thing you set running may have no pane the user
                can watch it in — most of all verification, whose output lives only in
                those terminals and never reaches you.

                It does NOT switch the user's view. The tab appears in the strip behind
                whatever they are working in, which is the point: opening a pane is not a
                reason to pull someone off what they are doing. If you need them to
                actually look, call request_attention as well.

                Opening a tab that is already open does nothing and says so. Use
                open_agent_tab for a terminal and open_editor for a file; those are
                instanced, so they need to know WHICH one, and this tool does not take
                them.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "kind",
                        kind: .string,
                        isRequired: true,
                        description: "One of \(IPC.Vocabulary.quotedTabKinds) — the same string list_tabs reports as a tab's kind."
                    ),
                ]
            )
        case .openAgentTab:
            IPC.ToolSpec(
                tool: .openAgentTab,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: false,
                description: """
                Open a terminal tab in the workstream you are already in. With `prompt`,
                it starts a coding agent there running that prompt; without one, it opens
                a plain shell. The new agent shares this worktree — same files, same
                branch — so hand it work that COLLABORATES on what you are doing rather
                than a separate change: two agents committing different work to one
                branch produces one tangled branch, and concurrent git commands contend
                for the same index lock. Returns the new tab's surface id. The agent is
                not addressable immediately: poll list_tabs until that surface reports a
                peer id, then send_message to it. Do not guess its peer from list_peers
                names — you did not choose the name it registers under.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "prompt",
                        kind: .string,
                        isRequired: false,
                        description: "Instructions for the agent to start with. Omit to open a plain terminal tab instead of an agent."
                    ),
                    IPC.ArgumentSpec(
                        name: "title",
                        kind: .string,
                        isRequired: false,
                        description: "Optional name for the tab, so the user can tell what it is for."
                    ),
                ]
            )
        case .closeTab:
            IPC.ToolSpec(
                tool: .closeTab,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: true,
                description: """
                Close one of this workstream's tabs — the counterpart to open_tab and
                open_agent_tab, for tearing a pane down once it has done its job. Most
                of all: a peer you spawned with open_agent_tab for a bounded task
                (review a diff, run a check) should be closed with this once that job
                is done, rather than left running for the user to close by hand.

                Give exactly one of "kind" (for \(IPC.Vocabulary.quotedCloseableTabKinds)) or
                "surface_id" (for a terminal tab, from open_agent_tab's result or
                list_tabs). Closing a tab that is already closed, or a surface_id
                nothing currently owns, does nothing and says so rather than erroring.

                Closing "execution" also STOPS the workstream's running dev stack,
                exactly as the user's own close of that tab does — so do not close it
                to tidy up unless you mean to take the dev server down. Info and Agent
                are permanent and cannot be closed this way. Editor and browser tabs
                have no id exposed over IPC yet, so there is no way to close one of
                those through this tool either.

                Closing the terminal tab you are running in destroys your own surface
                immediately, same as a user's ⌘W — you will not see the reply.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "kind",
                        kind: .string,
                        isRequired: false,
                        description: "\(IPC.Vocabulary.quotedCloseableTabKinds). Do not use this for a terminal tab; pass surface_id instead."
                    ),
                    IPC.ArgumentSpec(
                        name: "surface_id",
                        kind: .string,
                        isRequired: false,
                        description: "A terminal tab's surface id, from open_agent_tab's result or list_tabs. Provide exactly one of kind or surface_id."
                    ),
                ]
            )
        case .requestAttention:
            IPC.ToolSpec(
                tool: .requestAttention,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: true,
                description: """
                Raise a desktop notification asking the user to come and look at this
                workstream. For when you are genuinely blocked on a person — a decision
                only they can make, or work that is finished and needs review. Clicking
                it selects this workstream. Not for progress reports: the user did not
                ask to be interrupted, and one workstream can only raise this
                every \(IPC.Vocabulary.attentionCooldownSeconds) seconds. It does not wait for a reply — carry on with
                anything you can do without them.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "reason",
                        kind: .string,
                        isRequired: true,
                        description: "One line on what you need them for. Shown in the notification, so keep it short and specific."
                    ),
                ]
            )
        case .createWorkstream:
            IPC.ToolSpec(
                tool: .createWorkstream,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.worktreeCreation,
                isSafeToReplay: false,
                description: """
                Create a new workstream in this project — its own git worktree on its own
                new branch, cut from the project's base branch — and with `prompt`, start
                an agent in it. This is the tool for work that needs a SEPARATE BRANCH.
                Use open_agent_tab instead when the work belongs on the branch you are
                already on: a tab shares your worktree, a workstream does not, and one
                worktree cannot hold two branches. The agent starts in the new
                workstream's Coding Agent tab, so the user opening that workstream lands
                on its conversation. The new workstream's initialization runs in the
                background, so its dependencies may not be installed the moment the agent
                starts. Creating it does not move the user's view — the row appears in
                the sidebar and whatever they are looking at stays put. Returns the
                workstream's name and path, and the new agent's surface id; poll
                list_peers for a peer reporting that surface before messaging it.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "name",
                        kind: .string,
                        isRequired: false,
                        description: "Name for the workstream, used verbatim as the git branch name. Omit to have one generated. Must be a valid branch name and must not already be taken in this project."
                    ),
                    IPC.ArgumentSpec(
                        name: "prompt",
                        kind: .string,
                        isRequired: false,
                        description: "Instructions for the agent to start with. Omit to create the workstream without starting an agent."
                    ),
                    IPC.ArgumentSpec(
                        name: "bypass_permissions",
                        kind: .boolean,
                        isRequired: false,
                        description: "\"true\" to start the agent with --dangerously-skip-permissions. Omit for \"false\". Any other value is an error."
                    ),
                ]
            )
        case .createShortcutWorkstream:
            IPC.ToolSpec(
                tool: .createShortcutWorkstream,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.worktreeCreation,
                isSafeToReplay: false,
                description: """
                Create a workstream for a Shortcut story. Everything
                create_workstream does — its own git worktree on its own new
                branch, background initialization, and with `prompt` an agent in
                its Coding Agent tab — plus the story: the branch is named by the
                user's Branch Name Pattern rather than by you, and the workstream
                carries the story id, so its Info tab shows the story and "Open in
                Shortcut" works. Use this whenever the work has a Shortcut story;
                use create_workstream when it does not. Requires a Shortcut API
                token in the user's Settings, and refuses if the story already has
                a workstream in this project. Creating it does not move the user's
                view. Returns the workstream's name and path, and the new agent's
                surface id; poll list_peers for a peer reporting that surface
                before messaging it.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "story",
                        kind: .string,
                        isRequired: true,
                        description: "The Shortcut story: a bare public id (\"17411\"), the sc- form (\"sc-17411\"), or a pasted story URL."
                    ),
                    IPC.ArgumentSpec(
                        name: "prompt",
                        kind: .string,
                        isRequired: false,
                        description: "Instructions for the agent to start with. Omit to create the workstream without starting an agent."
                    ),
                    IPC.ArgumentSpec(
                        name: "bypass_permissions",
                        kind: .boolean,
                        isRequired: false,
                        description: "\"true\" to start the agent with --dangerously-skip-permissions. Omit for \"false\". Any other value is an error."
                    ),
                ]
            )
        case .startVerification:
            IPC.ToolSpec(
                tool: .startVerification,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: false,
                description: """
                Run this project's verification checks — its specs, linters and type
                checks, whatever `verification.yaml` declares — against the worktree you
                are in, and get a run id back IMMEDIATELY. list_verification_checks is
                how you find out what it declares before naming any. It does not wait
                for the suite: a real one takes minutes and this tool call does not.
                Each check
                posts its own verdict to your inbox from atelier/verification as it
                finishes, so a failure reaches you while the rest of the suite is still
                going — carry on with something else and call receive_messages at your
                next natural boundary. check_verification reads the whole run at any
                time, including while it is still going. Checks are independent and any
                number run at once; starting a check that is already running is refused
                rather than allowed to kill it, per check.

                If you are this workstream's Coding Agent, you will also receive these
                notices for runs the USER started from the Verification tab, which you
                did not ask for — that is deliberate, it is how you find out what your
                human just ran. An agent in another tab of this workstream will not.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "checks",
                        kind: .list,
                        isRequired: false,
                        description: "Comma-separated names of the checks to run, e.g. \"rspec,rubocop\". Omit to run all of them. A name the project does not declare is an error naming what it does."
                    ),
                ]
            )
        case .checkVerification:
            IPC.ToolSpec(
                tool: .checkVerification,
                surface: .workspaceRead,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                Read a verification run: its state, and each check's verdict, exit code
                and duration. Works while the run is still going — checks report as
                running until they finish — so this is also how you watch one without
                blocking. Only runs in your own workstream are readable.

                NO OUTPUT. A check runs in its own terminal surface in the Verification
                tab and Atelier keeps no copy of what it printed, so there is nothing to
                send you and nothing to fetch later — not from here, not from disk. To
                see why a check failed, ask the user to look at that tab while Atelier is
                still running, or re-run the one check. Only runs from this session
                resolve; ids from before a restart are gone.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "run_id",
                        kind: .string,
                        isRequired: true,
                        description: "The run id start_verification returned."
                    ),
                ]
            )
        case .listVerificationChecks:
            IPC.ToolSpec(
                tool: .listVerificationChecks,
                surface: .workspaceRead,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                List the verification checks this project declares — each one's name, the
                command it runs, and the shell it runs in — WITHOUT running any of them.

                Call this before start_verification. The checks are declared in a
                verification.yaml in the project directory, which is OUTSIDE your
                worktree, so you almost certainly cannot read it yourself: this is how
                you learn what the names are. Then start_verification runs all of them,
                or the subset you name.

                The answer is in file order, which is the order the user sees in the
                Verification tab. If the project declares nothing, or its
                verification.yaml is missing or unreadable, you are told which — those
                are three different problems.
                """,
                arguments: []
            )
        case .listProcesses:
            IPC.ToolSpec(
                tool: .listProcesses,
                surface: .workspaceRead,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: true,
                description: """
                Read your workstream's dev stack: whether it can run, whether it is
                running, what processes the project declares, and for a running stack
                each process's status, readiness, restart count, exit code, pid and
                port.

                This is also how you learn the process NAMES. They are declared in an
                execution.process-compose.yaml in the project directory, which is
                OUTSIDE your worktree, so you almost certainly cannot read it yourself.

                The state is one of four, and they are different problems rather than
                degrees of one: "unavailable" (no config, no process-compose binary, or
                nothing declares an execute namespace — the reason says which), "idle"
                (there is something to run and nothing is running; call
                start_execution), "running", and "running_without_process_table" (the
                user set their own dev command for this workstream, so there is no
                process manager to query and the per-process tools will refuse).

                There are NO notifications on this surface. Nothing will tell you when a
                process dies or comes up — poll this.
                """,
                arguments: []
            )
        case .readProcessLogs:
            IPC.ToolSpec(
                tool: .readProcessLogs,
                surface: .workspaceRead,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: true,
                description: """
                Read the tail of one process's log, newest last, with stderr
                interleaved — process-compose captures both streams into one log. This
                is how you find out WHY a process is crash-looping rather than only
                that it is.

                Names come from list_processes. A long tail is trimmed from the oldest
                end to fit, and you are told when that happened.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "process",
                        kind: .string,
                        isRequired: true,
                        description: "The process name, as list_processes reports it."
                    ),
                    IPC.ArgumentSpec(
                        name: "tail",
                        kind: .integer,
                        isRequired: false,
                        description: "How many lines back to read. Defaults to 100, capped at 1000."
                    ),
                ]
            )
        case .startProcess:
            IPC.ToolSpec(
                tool: .startProcess,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: true,
                description: """
                Start one process in your workstream's already-running dev stack.
                Starting one that is already running succeeds and changes nothing.

                This drives a process manager that is already up. If nothing is running
                at all, call start_execution instead.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "process",
                        kind: .string,
                        isRequired: true,
                        description: "The process name, as list_processes reports it."
                    ),
                ]
            )
        case .stopProcess:
            IPC.ToolSpec(
                tool: .stopProcess,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: true,
                description: """
                Stop one process in your workstream's running dev stack. Stopping one
                that is already stopped succeeds and changes nothing.

                Stopping the LAST running process ends the whole stack: process-compose
                exits and takes its control socket with it, so list_processes will then
                report the run as no longer up.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "process",
                        kind: .string,
                        isRequired: true,
                        description: "The process name, as list_processes reports it."
                    ),
                ]
            )
        case .restartProcess:
            IPC.ToolSpec(
                tool: .restartProcess,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: true,
                description: """
                Restart one process in your workstream's running dev stack — the usual
                move after changing code a server does not hot-reload.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "process",
                        kind: .string,
                        isRequired: true,
                        description: "The process name, as list_processes reports it."
                    ),
                ]
            )
        case .startExecution:
            IPC.ToolSpec(
                tool: .startExecution,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: false,
                description: """
                Start your workstream's dev stack — the same thing the Execution tab's
                Start button does. It returns IMMEDIATELY and does NOT wait for anything
                to come up: poll list_processes to watch it start, and read_process_logs
                when something fails. Nothing will notify you.

                Omit `processes` to run exactly what the user's Execution checklist
                says, which is what their own Start button would run. Naming processes
                scopes THIS run only and never changes their checklist.

                It opens the Execution tab so the output has somewhere to land, but it
                does NOT switch the user's view — pair it with request_attention when
                you need their eyes. Refused if a run is already up: read it with
                list_processes, or stop_execution first.

                If this call times out, do NOT retry it — the run may well have started.
                Call list_processes instead.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "processes",
                        kind: .list,
                        isRequired: false,
                        description: "Comma-separated process names to scope this run to, e.g. \"web,api\". Omit to use the user's checklist."
                    ),
                ]
            )
        case .stopExecution:
            IPC.ToolSpec(
                tool: .stopExecution,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: true,
                description: """
                Stop your workstream's dev stack, the same thing the Execution tab's
                Stop button does. Stopping when nothing is running succeeds and changes
                nothing.
                """,
                arguments: []
            )
        case .readWhiteboard:
            IPC.ToolSpec(
                tool: .readWhiteboard,
                surface: .workspaceRead,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                Read this workstream's whiteboard — a canvas you and the user both draw
                on.

                You get a text digest of every element, in the order they appear in the
                scene, each with its real id, position and size. Boxes, arrows and text
                are given in full. Freehand strokes and pasted images are NOT
                transcribed: they appear as a bounding box, so you know that they exist
                and where, and nothing more.

                So ALWAYS open board.png as well. The answer gives you its absolute path
                — read that file the same way you would read any image. It is the only
                way you can see the user's handwriting, a rough sketch, or a pasted
                screenshot, and it is frequently where the point of the board is. If the
                render is behind the digest, the answer says so rather than letting you
                read an old picture as current.

                An empty board is answered as empty — the ordinary first state for a
                workstream, not a fault. A board whose file cannot be read is answered
                differently and says which; those are two different problems.

                The Whiteboard tab starts closed and reading does not open it. Use
                open_tab(kind: "whiteboard") to put it in front of the user, and
                request_attention when you need them to actually look.
                """,
                arguments: []
            )
        case .whiteboardAdd:
            IPC.ToolSpec(
                tool: .whiteboardAdd,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: false,
                description: """
                Add elements to this workstream's whiteboard and get back their ids.

                `elements` is a JSON array; each entry is {"kind": ..., "text": ...,
                "at": "x,y", "from": ..., "to": ..., "color": ..., "ref": ...,
                "width": ..., "height": ...}. `kind`
                is one of box, note, text, arrow, mermaid. A box is a diagram node; a
                note is an annotation, and read_whiteboard reports it back as a note, so
                your own commentary stays distinguishable from the structure you drew.
                `at` is optional — anything you do not place is stacked below what is
                already on the board. `color` is a hex value like "#e03131" or a name
                like red.

                A box and a note are sized to their own label, so you do not have to
                guess a column width to keep them apart. A long label wraps and the box
                grows taller rather than spilling out of it, and a newline in `text`
                is a line break. The answer tells you the rectangle each element really
                got, the board's new extent, and where an element with no `at` would go
                next — so you can place the next call against real numbers instead of
                calling read_whiteboard to find out.

                `width` and `height` override that for a box or a note, and are honoured
                exactly: give "width": 200 and you get 200, never widened to fit the
                label and never rounded up to a minimum. Give a width alone and the label
                wraps inside it while the height is sized to the result, which is what
                you want when you are keeping a set of boxes to one column. They are
                refused on `text` and `arrow`, which have no size to give — a text
                element is sized by its words and an arrow is drawn between its
                endpoints — and on `mermaid`, whose size is the converter's answer.

                An arrow needs `from` and `to`. Each names either an element already on
                the board — call read_whiteboard for those ids — or an element this same
                call creates, by the `ref` you gave it.

                `ref` is a name of your own on any entry, used only inside this one call:
                give a box "ref": "auth", then write an arrow with "from": "auth". You
                cannot name a new element by its id, because the id is minted for you and
                you only learn it when this call returns. So a whole diagram is one call:
                the boxes first, each with a ref, then the arrows between them. A ref may
                only be used by an entry LATER in the array than the one that declared it;
                naming one declared later is refused. Two entries may not share a ref, and
                a ref may not be an id already on the board — both would make an arrow
                naming it ambiguous, so both are refused rather than guessed.

                A mermaid entry draws a whole diagram from a mermaid definition in
                `text` — flowcharts, sequence, class, ER and state diagrams become
                real boxes, arrows and labels you can then move and edit by id; any
                other diagram type lands as one image, captioned with the definition.
                It must be the only entry in its call, because its size is not known
                until it is drawn — the answer reports how big it came out, so you do
                not have to re-read the board to place anything after it. `at` places
                its top-left corner, and `color`, `from`, `to` and `ref` are refused —
                style and connections go in the definition, and a diagram standing
                alone has nothing to name it. A definition mermaid cannot parse is
                refused with mermaid's own message and nothing is drawn.

                The ids returned are the board's real element ids. Pass them straight
                to whiteboard_update and whiteboard_delete; read_whiteboard reports the
                same ones.

                This opens the Whiteboard tab but DOES NOT take the selection — the
                user is still looking at whatever they had in front of them. Use
                request_attention when you want their eyes on it.

                This call is NOT replayed automatically after a lost connection. If it
                fails or times out, do not retry it: it may already have been applied,
                and a second attempt would draw the diagram twice. Call read_whiteboard
                to see what is there.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "elements",
                        kind: .string,
                        isRequired: true,
                        description: "A JSON array of elements to add. Each is an object with `kind` (box, note, text, arrow or mermaid) and optionally `text`, `at` (\"x,y\"), `from`, `to`, `color`, `ref`, and — on a box or note only — `width` and `height` in pixels, which are honoured exactly. `ref` names an entry so an arrow later in the same array can point at it. For example [{\"kind\": \"box\", \"text\": \"Auth service\", \"ref\": \"auth\"}, {\"kind\": \"box\", \"text\": \"Token store\", \"ref\": \"tokens\"}, {\"kind\": \"arrow\", \"from\": \"auth\", \"to\": \"tokens\"}], or, on its own, [{\"kind\": \"mermaid\", \"text\": \"graph LR; A[Auth] --> B[Token store]\"}]."
                    ),
                ]
            )
        case .whiteboardUpdate:
            IPC.ToolSpec(
                tool: .whiteboardUpdate,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                Move, retext, recolour or caption one element of this workstream's
                whiteboard.

                `id` is an element id as read_whiteboard reports it. Name at least one
                of `at`, `text`, `color` or `caption`. An id that is not on the board is
                refused, and the refusal names it.

                `caption` is how you transcribe an image. The board carries pasted and
                captured screenshots, and nothing but you can read them: open the
                board.png that read_whiteboard names, read the image, and write what it
                says here. read_whiteboard then reports your transcription under that
                image, so a later read — by you or by another agent — does not have to
                look at the picture again. A caption is only for an image; use `text`
                for anything that carries words on the canvas. Pass an empty string to
                clear one. `text` on an image is refused rather than ignored — an image
                carries no words on the canvas, so there would be nothing to change.
                `text` is refused the same way on a shape that was drawn without a
                label, for the same reason, and nothing can attach words to an element
                already on the board: draw a replacement, or add a text element beside
                it.

                A caption is not drawn on the board, so Excalidraw's own canvas search
                will not find it. That is deliberate: materializing it would put a block
                of text under every screenshot on a board the user is sketching on.

                This opens the Whiteboard tab but does not take the selection.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "id",
                        kind: .string,
                        isRequired: true,
                        description: "The element to change, as read_whiteboard reports it."
                    ),
                    IPC.ArgumentSpec(
                        name: "at",
                        kind: .string,
                        isRequired: false,
                        description: "New position as \"x,y\", for example \"120,80\"."
                    ),
                    IPC.ArgumentSpec(
                        name: "text",
                        kind: .string,
                        isRequired: false,
                        description: "New text or label. Pass an empty string to clear it."
                    ),
                    IPC.ArgumentSpec(
                        name: "color",
                        kind: .string,
                        isRequired: false,
                        description: "A hex value like \"#e03131\", or a name like red."
                    ),
                    IPC.ArgumentSpec(
                        name: "caption",
                        kind: .string,
                        isRequired: false,
                        description: "Your transcription of an image element. "
                            + "Images only. Pass an empty string to clear it."
                    ),
                ]
            )
        case .whiteboardDelete:
            IPC.ToolSpec(
                tool: .whiteboardDelete,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                Remove elements from this workstream's whiteboard.

                `ids` is a comma-separated list of element ids as read_whiteboard
                reports them. An id that is already gone is success rather than an
                error, so this is safe to call again. Deleting a shape takes its label
                with it.

                This opens the Whiteboard tab but does not take the selection.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "ids",
                        kind: .list,
                        isRequired: true,
                        description: "Element ids to remove, comma-separated."
                    ),
                ]
            )
        case .addTask:
            IPC.ToolSpec(
                tool: .addTask,
                surface: .projectTasks,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: false,
                description: """
                Add a task to this project's shared queue, for any peer in the project
                to claim and work on. Use this instead of hand-dispatching work to
                individual workstreams when you have several similar units of work —
                findings from an audit, files needing the same fix — so peers can pull
                the next one instead of you assigning each by hand.

                `path` is the task's permanent identifier: choose something
                hierarchical and unique, e.g. "audit-2026-09/finding-3". Calling
                add_task again with a path that already exists is refused rather than
                replayed automatically after a lost connection, so if you see
                "already exists" after a timeout, check list_tasks before retrying —
                your first call likely already succeeded.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "path",
                        kind: .string,
                        isRequired: true,
                        description: "Unique identifier for this task within the project, e.g. \"audit-2026-09/finding-3\"."
                    ),
                    IPC.ArgumentSpec(
                        name: "name",
                        kind: .string,
                        isRequired: true,
                        description: "Short display name."
                    ),
                    IPC.ArgumentSpec(
                        name: "content",
                        kind: .string,
                        isRequired: true,
                        description: "The brief: what needs doing. Up to 64KB."
                    ),
                    IPC.ArgumentSpec(
                        name: "tags",
                        kind: .list,
                        isRequired: false,
                        description: "Optional comma-separated tags, for filtering with get_pending_tasks/list_tasks."
                    ),
                ]
            )
        case .getPendingTasks:
            IPC.ToolSpec(
                tool: .getPendingTasks,
                surface: .projectTasks,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                List unclaimed tasks in this project's queue — the ones nobody has
                started yet. Call this when you're free and want the next thing to
                work on. Omit path_prefix to see every pending task.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "path_prefix",
                        kind: .string,
                        isRequired: false,
                        description: "Only tasks whose path starts with this. Omit for every pending task in the project."
                    ),
                    IPC.ArgumentSpec(
                        name: "tags",
                        kind: .list,
                        isRequired: false,
                        description: "Optional comma-separated tags — a task must have ALL of them to match. Omit for no filtering."
                    ),
                ]
            )
        case .listTasks:
            IPC.ToolSpec(
                tool: .listTasks,
                surface: .projectTasks,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                List every task in this project's queue regardless of state —
                pending, claimed, completed, or failed. Use this for an overview of
                the whole queue's progress; use get_pending_tasks when you just want
                the next thing to claim.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "path_prefix",
                        kind: .string,
                        isRequired: false,
                        description: "Only tasks whose path starts with this. Omit for every task in the project."
                    ),
                    IPC.ArgumentSpec(
                        name: "tags",
                        kind: .list,
                        isRequired: false,
                        description: "Optional comma-separated tags — a task must have ALL of them to match. Omit for no filtering."
                    ),
                ]
            )
        case .claimTask:
            IPC.ToolSpec(
                tool: .claimTask,
                surface: .projectTasks,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                Claim a pending task so no other peer works on it too. Only one claim
                wins — calling this again yourself on a task you already hold is a
                safe no-op; calling it on a task someone else holds is refused,
                naming them. Requires a surface to attach ownership to, so this only
                works from an agent Atelier launched.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "path",
                        kind: .string,
                        isRequired: true,
                        description: "The task's path, from add_task or get_pending_tasks."
                    ),
                ]
            )
        case .completeTask:
            IPC.ToolSpec(
                tool: .completeTask,
                surface: .projectTasks,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                Mark a task you hold as done. Only the peer that claimed it may
                complete it — calling this on someone else's claim, or a task nobody
                claimed, is refused. The task's creator is notified in its inbox.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "path",
                        kind: .string,
                        isRequired: true,
                        description: "The task's path."
                    ),
                ]
            )
        case .failTask:
            IPC.ToolSpec(
                tool: .failTask,
                surface: .projectTasks,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                Mark a task you hold as failed, with a reason. Only the peer that
                claimed it may fail it. The task's creator is notified in its inbox,
                including your reason.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "path",
                        kind: .string,
                        isRequired: true,
                        description: "The task's path."
                    ),
                    IPC.ArgumentSpec(
                        name: "reason",
                        kind: .string,
                        isRequired: true,
                        description: "Why it failed. Required, and shown to the task's creator."
                    ),
                ]
            )
        case .getSessionCheckpoint:
            IPC.ToolSpec(
                tool: .getSessionCheckpoint,
                surface: .workspaceRead,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                Read this workstream's saved checkpoint — free text some agent wrote
                about where it left off. Call this early in a session, before starting
                new work, to see what you or a predecessor were doing. Shared per
                workstream, not per agent: if another agent shares this workstream
                (opened via open_agent_tab), you are reading the same note it writes.
                Tells you plainly if nothing has been saved yet, rather than answering
                with nothing.
                """,
                arguments: []
            )
        case .getInitializationState:
            IPC.ToolSpec(
                tool: .getInitializationState,
                surface: .workspaceRead,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                Read what this project's background initialization last reported for your
                worktree — the Setup row on the Info tab, which you cannot see.

                Initialization is the steps a project declares in an initialization.yaml
                in its project directory, run once behind a new worktree. It is the reason
                a fresh worktree has its dependencies installed. Call this when a build or
                a test run fails in a way that looks like setup never finished.

                `state` is one of idle, in_progress, completed, completed_with_note or
                failed, and `detail` is the sentence the user sees.

                READ `idle` CAREFULLY. It means nothing has been reported in this session
                of Atelier, and nothing more. Atelier keeps this state only in memory, so
                every workstream reports idle after the app restarts — including ones whose
                setup ran perfectly days ago. It is NOT evidence that setup never ran, and
                it is NOT evidence that it succeeded. If you need to know whether the
                worktree is actually set up, check the worktree.

                `completed_with_note` is neither success nor failure: it means there was
                nothing to run, and the detail says why — no initialization.yaml, a file
                that could not be read, one declaring no steps, or a run an archive
                stopped. The worktree is usable either way.
                """,
                arguments: []
            )
        case .getShortcutStory:
            IPC.ToolSpec(
                tool: .getShortcutStory,
                surface: .workspaceRead,
                replyDeadline: IPC.ToolSpec.Deadline.mainActorWork,
                isSafeToReplay: true,
                description: """
                Read the Shortcut story this workstream was created for — its id, name,
                type, workflow state, branch name, Shortcut URL and description.

                Use this instead of a Shortcut API client or MCP server when you just want
                to know what the story you are working on says. Atelier already knows which
                story this workstream belongs to; you would otherwise have to guess the id
                out of the branch name.

                It fetches, so the answer is current rather than whatever the user's Info
                tab last happened to load.

                If there is no story you are told which of four things happened: this
                workstream was not created from a story, no Shortcut API token is
                configured, the keychain refused the token, or the fetch failed. They are
                four different problems and only one of them is "there is no story".
                """,
                arguments: []
            )
        case .updateSessionCheckpoint:
            IPC.ToolSpec(
                tool: .updateSessionCheckpoint,
                surface: .workspaceAction,
                replyDeadline: IPC.ToolSpec.Deadline.immediate,
                isSafeToReplay: true,
                description: """
                Overwrite this workstream's checkpoint with free text describing where
                you left off — enough for you, or whichever agent reads it next in this
                workstream, to resume without re-reading the whole conversation. Call it
                before finishing a task, and at any milestone worth resuming from. There
                is no history: this replaces whatever was saved before. Shared per
                workstream, not per agent — if another agent shares this workstream, you
                are overwriting the same note it reads.
                """,
                arguments: [
                    IPC.ArgumentSpec(
                        name: "content",
                        kind: .string,
                        isRequired: true,
                        description: "What to save. Free text — describe what you were doing and what is left, not just the last action."
                    ),
                ]
            )
        }
    }

    /// Which of the four surfaces this tool belongs to.
    var surface: IPC.Surface {
        spec.surface
    }

    /// How long the helper waits for this tool's reply. See `ToolSpec.Deadline`.
    var replyDeadline: TimeInterval {
        spec.replyDeadline
    }

    /// Whether the helper may re-send this tool after losing the connection
    /// mid-call. See `ToolSpec.isSafeToReplay`.
    var isSafeToReplay: Bool {
        spec.isSafeToReplay
    }
}

// MARK: - Argument decoding

extension IPC {
    /// What a tool call is refused with, at the boundary where it becomes a
    /// `Response.error`.
    ///
    /// **The boundary is what this unifies, not every wording.** Handlers still
    /// throw `WorkspaceActions.Failure`, `IPC.Error`, `VerificationFailure`,
    /// `TaskQueueFailure` and `CheckpointStore.Error` internally, where each
    /// carries meaning this type has no business knowing; what changed is that
    /// argument handling — the one class of failure every tool has, and the one
    /// that was previously spelled by hand at each call site — has a single
    /// type. `refused(_:)` is the escape hatch for a message an agent is already
    /// reading, which is why several of the existing wordings survive unchanged
    /// through it rather than being renamed into `missingArgument`'s sentence.
    ///
    /// Agent-facing protocol text: deliberately not localized, the same rule
    /// `IPC.Error` and `WorkspaceActions.Failure` state.
    enum ToolError: Swift.Error, LocalizedError, Equatable {
        case missingArgument(String)
        /// Present but empty, which is a different fact from absent — and the
        /// three tools that say so (`send_message`, `broadcast`,
        /// `update_session_checkpoint`) phrase it per tool, so the tool's name
        /// is carried rather than assumed.
        case emptyArgument(tool: String, name: String)
        case invalidArgument(name: String, reason: String)
        case notInWorkstream
        case refused(String)

        var errorDescription: String? {
            switch self {
            case let .missingArgument(name):
                "Missing required argument `\(name)`."
            case let .emptyArgument(tool, name):
                "\(tool) needs non-empty `\(name)`."
            case let .invalidArgument(name, reason):
                "Invalid `\(name)`: \(reason)"
            case .notInWorkstream:
                "This tool only works from an agent running inside an Atelier workstream."
            case let .refused(message):
                message
            }
        }
    }

    /// Typed reads of a request's `[String: String]` arguments.
    ///
    /// Replaces the literal-key reads that were spread through `IPC.Service` —
    /// `request.arguments["line"]` parsed inline as an `Int`,
    /// `request.arguments["bypass_permissions"]` through a parser living on
    /// `Workstream.Launcher`, `request.arguments["checks"]` through one living on
    /// `VerificationSummary`. Three ad-hoc parsers applied unevenly became one,
    /// and every failure now arrives as a `ToolError` naming the argument.
    ///
    /// The tool is carried so a message can name it (`emptyArgument`) without the
    /// call site restating a string the enum already knows.
    struct ToolArguments {
        let tool: Tool
        let raw: [String: String]

        init(_ request: Request) {
            tool = request.tool
            raw = request.arguments
        }

        init(tool: Tool, raw: [String: String]) {
            self.tool = tool
            self.raw = raw
        }

        /// The value as given, or nil when the key is absent or blank.
        ///
        /// Absent and empty are one answer *here* because every optional
        /// argument in this surface treats them alike; the tools that need to
        /// tell them apart ask with `required` or `nonEmpty`.
        func optional(_ name: String) -> String? {
            guard let value = raw[name], !value.isEmpty else { return nil }
            return value
        }

        /// Trimmed, or nil when absent or blank once trimmed.
        func optionalTrimmed(_ name: String) -> String? {
            guard let value = raw[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }

        /// A required argument, refused as `missingArgument` when absent or
        /// blank.
        func required(_ name: String) throws -> String {
            guard let value = optional(name) else { throw ToolError.missingArgument(name) }
            return value
        }

        /// A required argument, refused in the tool's own words — "x needs
        /// non-empty `y`." — which is what `send_message`, `broadcast` and
        /// `update_session_checkpoint` have always said and what agents read.
        func nonEmpty(_ name: String) throws -> String {
            guard let value = optional(name) else {
                throw ToolError.emptyArgument(tool: tool.rawValue, name: name)
            }
            return value
        }

        /// A required argument, trimmed, refused as `missingArgument`.
        func requiredTrimmed(_ name: String) throws -> String {
            guard let value = optionalTrimmed(name) else { throw ToolError.missingArgument(name) }
            return value
        }

        /// An optional whole number. Absent is nil; present and unparseable is a
        /// refusal rather than a silent nil — `open_editor`'s `line` is the case
        /// this exists for, and a typo scrolling to the top of the file instead
        /// of reporting itself is worse than an error.
        func integer(_ name: String) throws -> Int? {
            guard let value = optional(name) else { return nil }
            guard let parsed = Int(value) else {
                throw ToolError.invalidArgument(name: name, reason: "expected a whole number, got \(value).")
            }
            return parsed
        }

        /// An optional flag. Absent is false; anything but "true"/"false" is a
        /// refusal, because a value that reads like it means something and does
        /// not is worse than no value.
        func boolean(_ name: String) throws -> Bool {
            guard let given = raw[name] else { return false }
            let value = given.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return false }
            switch value {
            case "true": return true
            case "false": return false
            default:
                // The value **as given**, untrimmed: an agent that sent
                // `" True"` needs to see its own spelling to find the mistake.
                throw ToolError.invalidArgument(
                    name: name,
                    reason: "expected \"true\" or \"false\", received \"\(given)\"."
                )
            }
        }

        /// A comma-separated list, de-duplicated, in the order given.
        ///
        /// Tolerant of the bracket-and-quote shapes a model reaches for —
        /// `["a","b"]` as readily as `a,b` — because the argument arrives as a
        /// string and an agent that wrote JSON should not be refused over
        /// punctuation.
        func list(_ name: String) -> [String] {
            Self.parseList(raw[name])
        }

        /// The one list parser. `VerificationSummary.checks(from:)` and
        /// `TaskSummary.tags(from:)` were byte-identical copies of this and now
        /// both call it — three spellings of one convention was the shape this
        /// file exists to end.
        static func parseList(_ raw: String?) -> [String] {
            guard let raw else { return [] }
            let separators = CharacterSet(charactersIn: ",[]\"'").union(.whitespacesAndNewlines)
            var seen: Set<String> = []
            var result: [String] = []
            for token in raw.components(separatedBy: separators) where !token.isEmpty {
                if seen.insert(token).inserted {
                    result.append(token)
                }
            }
            return result
        }

        // MARK: - The JSON boundary

        /// Flattens one `tools/call` argument object into the `[String: String]`
        /// this surface speaks.
        ///
        /// **Every tool here declares string arguments, and models send real
        /// JSON anyway** — `bypass_permissions: true` as a boolean,
        /// `checks: ["rspec"]` as an array. That is not a caller mistake to be
        /// punished: a schema saying "string" is advice, and an agent that sent
        /// the value it meant should get the behaviour it meant.
        ///
        /// It used to be `value as? String ?? String(describing: value)`, whose
        /// comment claimed a non-string was "rendered rather than rejected, so a
        /// stray number still reaches the app". Only numbers survived that.
        /// `JSONSerialization` hands back `__NSCFBoolean` for a JSON boolean, and
        /// `String(describing:)` renders it **"1"** — which `boolean(_:)` then
        /// refuses, reporting `received "1"` for an argument the agent spelled
        /// `true`. An `NSArray` rendered as `"(\n    rspec,\n    rubocop\n)"`,
        /// and `parseList` splits on `,[]"'` but not on parentheses, so
        /// `start_verification(checks: ["rspec"])` reached the runner as
        /// `["(", "rspec", ")"]` and was refused for an undeclared check named
        /// `(`. `NSNull` became the literal `"<null>"`, so `line: null` came back
        /// as "expected a whole number, got <null>".
        ///
        /// So each JSON type is given the spelling this surface's own readers
        /// already parse, and the one type with no such spelling — null — is
        /// **dropped**, since "absent" is exactly what a null argument means and
        /// every optional read here treats absent and empty alike.
        ///
        /// Lives on `ToolArguments` rather than in the helper because
        /// `IPCToolRegistry.swift` is one of the two files `project.yml` compiles
        /// into `AtelierMCP` (`:208-209`), so the helper can call it and the app's
        /// tests can assert it. A copy in `main.swift` would be untestable, which
        /// is how the old one survived.
        static func strings(fromJSON arguments: [String: Any]) -> [String: String] {
            var result: [String: String] = [:]
            for (key, value) in arguments {
                guard let rendered = render(value) else { continue }
                result[key] = rendered
            }
            return result
        }

        /// One JSON value as a string, or nil for one that means "absent".
        ///
        /// An array becomes the comma-separated form `list(_:)` already parses,
        /// rather than `NSArray`'s description. Its elements are rendered by the
        /// same rules, so `[1, true]` is `"1,true"` and a null element is
        /// dropped rather than spelled `<null>` in the middle of a list.
        private static func render(_ value: Any) -> String? {
            if value is NSNull {
                return nil
            }
            if let string = value as? String {
                return string
            }
            // `is Bool` is not reliable for the bridged `__NSCFBoolean`
            // `JSONSerialization` produces — it answers true for `NSNumber(1)`
            // too, which would spell a genuine `tail: 1` as `"true"`. The
            // CoreFoundation type id is the only exact test.
            if let number = value as? NSNumber {
                return CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
                    ? (number.boolValue ? "true" : "false")
                    : number.stringValue
            }
            if let array = value as? [Any] {
                return array.compactMap(render).joined(separator: ",")
            }
            // No tool declares an object argument, so there is no spelling to
            // match. Compact JSON at least round-trips and is readable in the
            // refusal the reader will produce; `String(describing:)` gave a
            // multi-line `NSDictionary` dump.
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let json = String(data: data, encoding: .utf8)
            {
                return json
            }
            return String(describing: value)
        }

        /// A required UUID.
        func uuid(_ name: String) throws -> UUID {
            let value = try required(name)
            guard let parsed = UUID(uuidString: value) else {
                throw ToolError.invalidArgument(name: name, reason: "expected a uuid, got \(value).")
            }
            return parsed
        }
    }
}

// MARK: - Shared vocabulary

extension IPC {
    /// Strings and numbers both processes have to agree on.
    ///
    /// Each of these used to be spelled twice — once in the app, once as a
    /// literal in `Sources/MCPHelper/main.swift`, which compiles none of the
    /// app's model files but this directory's shared pair. A helper that
    /// advertises "changes, execution, verification" while `WorkspaceActions`
    /// accepts a different set, or prose promising a 30-second cooldown the
    /// notifier no longer enforces, is a drift nothing would fail on.
    enum Vocabulary {
        /// The singleton panes `open_tab` opens and `list_tabs` names.
        ///
        /// `WorkspaceActions.openableTabs` is keyed by these, and
        /// `WorkspaceTabKindTests` pins that each equals the matching
        /// `WorkspaceTabKind.id` — the string `list_tabs` reports — so the one
        /// vocabulary stays one. `WorkspaceTabKind` itself cannot be named here:
        /// it is a view-layer type and this file is compiled into the helper.
        enum TabKind: String, CaseIterable {
            case changes
            case execution
            case verification
            /// Added with the read path. PR 1 held the board back while it had
            /// no agent-facing anything at all; an agent that can *read* the
            /// board has to be able to put it in front of the user, and
            /// `read_whiteboard`'s own description points here to do it.
            case whiteboard
        }

        /// The openable kinds as the schema spells them: `"changes",
        /// "execution", "verification"`. Derived so the advertised list and
        /// `WorkspaceActions.openableTabs` cannot name different sets — that
        /// pair was two literals in two targets, and only a test could have
        /// caught them diverging.
        static var quotedTabKinds: String {
            TabKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        }

        /// The kinds `close_tab` will actually close — **every** singleton,
        /// Execution included, which is closed rather than refused and stops
        /// the dev stack on its way out. It was refused while stopping a run
        /// meant reaching view-local `@State`; `ProcessCompose.RunSession` owns
        /// that now, so `WorkspaceActions.closeSingleton` can call it with no
        /// view mounted. Derived from the same `TabKind` list
        /// `WorkspaceActions.closeableSingletonKinds` is, so the advertised set
        /// and the set the tool accepts cannot name different kinds.
        ///
        /// Joined with `" or "` rather than `quotedTabKinds`' `", "` because
        /// this reads inside an argument description, and the two are not
        /// interchangeable even now that they list the same kinds.
        static var quotedCloseableTabKinds: String {
            TabKind.allCases
                .map { "\"\($0.rawValue)\"" }
                .joined(separator: " or ")
        }

        /// The reserved sender a verification notice arrives from.
        /// `VerificationSummary.sender` is this, and the helper's own prose names
        /// it.
        static let verificationSender = "atelier/verification"

        /// The reserved sender a task-queue notice arrives from.
        /// `TaskSummary.sender` is this.
        static let taskSender = "atelier/tasks"

        /// How often one workstream may raise `request_attention`.
        /// `Workstream.AttentionNotifier.cooldown` is this, and both the tool's
        /// description and the server instructions quote it.
        static let attentionCooldownSeconds = 30
    }

    /// A machine-readable reason a `Response` failed, for the handful of
    /// refusals the helper has to *act* on rather than relay.
    ///
    /// There is exactly one so far. The helper used to recognise it by
    /// `error.contains("belongs to another session")` — a substring match across
    /// a process boundary against a sentence assembled in `IPC.Server`, where
    /// rewording the message for a human would silently disable the recovery it
    /// gates. Now the sentence is free to change and the code is not.
    ///
    /// Optional on the wire, so a response carrying none decodes exactly as
    /// before.
    enum ResponseCode: String, Codable {
        /// The peer id in the request is owned by a connection the app still
        /// considers live. The helper drops its identity and re-registers.
        case peerOwnedByAnotherSession
    }
}
