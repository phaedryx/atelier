// ABOUTME: Wire types shared by the app's IPC server and the atelier-mcp helper.
// ABOUTME: Newline-delimited JSON over loopback TCP — deliberately not HTTP.

import Foundation

/// Agent-to-agent messaging: the wire protocol, its transport, and the
/// settings that gate it.
///
/// Declared here rather than in a file of its own because `AtelierMCP`
/// compiles only this file out of `Models/IPC/` (`project.yml:198-200`); a
/// namespace declared anywhere else in this directory would not exist for
/// the `atelier-mcp` binary.
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
    /// **Three surfaces, and the split is the point** — see `Tool.surface`.
    /// *Messaging* moves text between agents and changes nothing a user can see.
    /// *Workspace reads* answer questions about the workstream the caller is
    /// already in. *Workspace actions* create or change something in front of
    /// the user. Sort a new case into the right group, and give a workspace
    /// action its own trust story rather than inheriting messaging's, which is
    /// "none needed".
    ///
    /// The messaging six were once the whole enum, with a comment saying so:
    /// Calix's IPC core is the same six, and everything it grew on top —
    /// pane/tab control, LSP, shell integration — arrived as separate tool
    /// surfaces with separate gates (`MCPCockpitBridge`, `MCPLSPBridge`,
    /// `MCPCommandLogBridge`). That prediction held; this enum is where Atelier
    /// takes the same step, so the groups are named rather than merged.
    ///
    /// **A case here is not a tool an agent can see.** What is advertised over
    /// MCP is `toolDefinitions` in `Sources/MCPHelper/main.swift`; a case with no
    /// entry there is dispatchable but undiscoverable. That is deliberate — it
    /// lets the shared enum and the exhaustive `IPC.Service.handle` switch land
    /// ahead of the handlers, so agents implementing a tool each do not collide
    /// on this file. An unimplemented case must fail loudly (see
    /// `Service.notImplemented`), never succeed silently.
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

        /// Workspace actions.
        /// Opens a terminal tab in the caller's own workstream, optionally
        /// starting an agent in it.
        case openAgentTab = "open_agent_tab"
        /// Opens a file in the workstream's editor, optionally at a line.
        case openEditor = "open_editor"
        /// Raises a notification asking the user to come and look.
        case requestAttention = "request_attention"
        /// Creates a new workstream — worktree, branch, `bootstrap` — and
        /// optionally starts an agent there.
        case createWorkstream = "create_workstream"
        /// Starts a verification run — the `verify` namespace — in the caller's
        /// own workstream, and answers with a run id rather than the result.
        case startVerification = "start_verification"

        /// Which of the three surfaces above this tool belongs to.
        ///
        /// Nothing branches on it yet. It exists so the grouping is a value the
        /// compiler checks rather than a comment that rots, and so that if a
        /// gate is ever added it has one obvious place to ask "does this need
        /// one?" — reads never do, and messaging never has.
        var surface: Surface {
            switch self {
            case .registerPeer, .listPeers, .sendMessage, .receiveMessages, .broadcast, .getPeerStatus:
                .messaging
            case .listTabs, .readReviewComments, .checkVerification:
                .workspaceRead
            case .openAgentTab, .openEditor, .requestAttention, .createWorkstream, .startVerification:
                .workspaceAction
            }
        }

        /// How long the helper waits for this tool's reply before it stops
        /// waiting. A liveness backstop, not a latency budget — but the numbers
        /// have to be honest about the *slowest* thing the app does behind each
        /// tool, because a deadline that fires while a handler is still working
        /// is indistinguishable to the helper from an app that has died.
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
        /// blocks *all* MCP traffic for this long. That is why only the tool
        /// that genuinely needs minutes gets them, and why the value is sized to
        /// the realistic worst case rather than to every theoretical retry the
        /// app might stack.
        var replyDeadline: TimeInterval {
            switch self {
            // Actor hops and store reads. The original 15 seconds, which was
            // always right for these.
            case .registerPeer, .listPeers, .sendMessage, .receiveMessages, .broadcast, .getPeerStatus,
                 .listTabs, .readReviewComments, .checkVerification:
                15
            // Main-actor work with a process-compose probe behind the worst of
            // them (`start_verification` resolves a binary and parses a config
            // before it answers with a run id).
            case .openAgentTab, .openEditor, .requestAttention, .startVerification:
                60
            // `git worktree add` under `ProcessRunner.Timeout.userCommand` (300s)
            // after a fetch under `.network` (120s). Named as literals because
            // `ProcessRunner` is not compiled into the helper — `AtelierMCP`
            // takes this file and nothing else out of `Models/IPC/`
            // (`project.yml:198-200`).
            case .createWorkstream:
                480
            }
        }

        /// Whether the helper may re-send this tool after losing the connection
        /// mid-call.
        ///
        /// **A replay is a second execution, and only a tool that changes
        /// nothing by running twice can afford one.** The helper reconnects and
        /// replays so a restarted Atelier does not fail every later call; that
        /// recovery is worth keeping for a read, and is a silent duplicate for
        /// an action. `create_workstream` replayed produces two worktrees and
        /// two branches under a generated name, or tells the caller its
        /// creation failed under an explicit one — the same lie either way,
        /// since the first call had already succeeded.
        ///
        /// The rule is idempotence rather than `surface`, because the two do not
        /// line up: `receive_messages` is messaging and *drains an inbox*, so a
        /// replay that lands after the app processed the first copy loses those
        /// messages for good, while `open_editor` is a workspace action and puts
        /// the same file on screen however many times it runs.
        ///
        /// `register_peer` has to be here: the reconnect path replays it by hand
        /// to recover the session's identity, and the tool is defined as a
        /// rename rather than a second registration.
        ///
        /// **`send_message` and `broadcast` are the two judgement calls**, and
        /// the choice is not an analogy to the rest. Replaying one risks a
        /// second copy in a peer's inbox, which that agent then acts on twice;
        /// refusing costs the sender an error for a message that may in fact
        /// have landed. What breaks the tie is that the case replay exists for —
        /// a restarted Atelier — cannot help these two anyway: the new app's
        /// store is empty, so the recipient's peer id is already meaningless and
        /// the replay would be refused. That leaves only a mid-flight close
        /// against a *live* app, where a duplicate is the likelier outcome than
        /// a rescue. And the refusal is reported, so nothing is lost silently:
        /// the sender is told, and can re-send deliberately. `broadcast` settles
        /// it on its own — its audience is resolved app-side, so one replay is a
        /// duplicate to every peer at once.
        ///
        /// Refusing a replay does not abandon the session. The helper still
        /// reconnects and re-registers; it just reports the interruption instead
        /// of guessing what the app did with the first copy.
        var isSafeToReplay: Bool {
            switch self {
            case .registerPeer, .listPeers, .getPeerStatus,
                 .listTabs, .readReviewComments, .checkVerification,
                 .openEditor, .requestAttention:
                true
            case .sendMessage, .receiveMessages, .broadcast,
                 .openAgentTab, .createWorkstream, .startVerification:
                false
            }
        }
    }

    /// The three groups of `Tool` — see that type's doc comment.
    enum Surface: String, Codable, CaseIterable {
        case messaging
        case workspaceRead
        case workspaceAction
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

    /// A verification run as reported to an agent.
    ///
    /// A **projection** of the runner's `Verification.Run`, not that type: the
    /// same relationship `PeerInfo` has to the store's `Peer`, and
    /// `TabInfo`/`ReviewCommentInfo` to what `WorkspaceActions` reads. Every
    /// model that crosses this boundary gets one, and this one has to differ —
    /// seconds-ago rather than a `Date` that would need a shared encoding
    /// strategy on both ends, a bounded output tail rather than a whole suite's
    /// log, and `isStale` rather than the stamp it is computed from.
    ///
    /// Declared here rather than beside the seam because `renderText` in
    /// `Sources/MCPHelper/main.swift` renders it, and `AtelierMCP` compiles
    /// exactly one file out of `Models/IPC/` — this one (`project.yml:198-200`).
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
        /// Why the **run itself** produced no per-check answer, when that is
        /// what happened.
        ///
        /// Distinct from a check failing, and deliberately not set for one: a
        /// suite where `rspec` failed is explained by that check's own state and
        /// output. This is for a spawn that never got far enough to report on
        /// anything, which otherwise reaches an agent as a list of checks that
        /// all say "not run" and no reason anywhere. It is the only place that
        /// reason exists.
        let failureDetail: String?
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
    struct VerificationCheckInfo: Codable {
        let name: String
        let state: VerificationCheckState
        /// The process's exit code. Only meaningful for `.failed`, and nil
        /// otherwise — a `Pending` check and a passing one both report 0 from
        /// process-compose, so an exit code alone cannot tell them apart.
        let exitCode: Int?
        let durationSeconds: Double?
        /// The tail of this check's output as captured while the run was live,
        /// bounded again before it is sent. Nil when there is none to show — a
        /// passing check usually has none stored.
        let outputTail: String?
        /// Whether there was more output than this **at capture time**.
        ///
        /// Not a promise that more can be fetched. The log lives in
        /// process-compose's control server, which the runner shuts down once
        /// the run is sealed, so the tail captured in that window is the only
        /// copy that exists afterwards — in the Verification tab, here, or on
        /// disk. An agent that reads "truncated" as "retrievable" goes looking
        /// for a fuller log that is not anywhere, which is why every string this
        /// flag drives says so.
        let outputTruncated: Bool
    }

    /// A check's state, as an agent sees it.
    ///
    /// Mapped from `Verification.CheckResult.State` **by the runner**, which is
    /// where the two measured traps live: a `Pending` check reads as a pass if
    /// you look at `exitCode` alone, and a `Skipped` one carries exit 1 and so
    /// renders as a failure it never had.
    enum VerificationCheckState: String, Codable, CaseIterable {
        case notRun = "not_run"
        case pending
        case running
        case passed
        case failed
        /// A dependency failed, so this check never ran.
        case skipped
        /// The run was stopped while this check was running.
        case stopped
    }

    /// Seconds as an agent should read them.
    ///
    /// Minutes appear because a real suite runs for tens of them and `1503.2s`
    /// is arithmetic homework. Declared here rather than beside the rest of the
    /// verification formatting because `renderText` in the helper needs it, and
    /// `AtelierMCP` compiles this file alone out of `Models/IPC/`.
    static func durationText(_ seconds: Double) -> String {
        guard seconds >= 60 else { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        return "\(minutes)m " + String(format: "%.1fs", seconds - Double(minutes * 60))
    }

    /// The result of a successful call.
    enum Payload: Codable {
        case peers([PeerInfo])
        case peer(PeerInfo)
        case messages([MessageInfo])
        case tabs([TabInfo])
        case reviewComments([ReviewCommentInfo])
        case verificationRun(VerificationRunInfo)
        case text(String)
    }

    /// One reply from the app to a helper.
    struct Response: Codable {
        let id: String
        let payload: Payload?
        let error: String?

        static func success(id: String, _ payload: Payload) -> Response {
            Response(id: id, payload: payload, error: nil)
        }

        static func failure(id: String, _ message: String) -> Response {
            Response(id: id, payload: nil, error: message)
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
