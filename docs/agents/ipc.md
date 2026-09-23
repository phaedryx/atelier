# Agent IPC tools

The `atelier-ipc` MCP surface: the tool registry, the four tool groups, and the
trust argument each group rests on.

### Agent workspace tools (IPC)

`IPC.Tool` is four groups, not one, and `Tool.surface` makes the grouping a value the compiler
checks rather than a comment:

| Group | Tools | Trust story |
|---|---|---|
| Messaging | `register_peer`, `list_peers`, `send_message`, `receive_messages`, `broadcast`, `get_peer_status` | none needed — text between agents, nothing a user can see |
| Workspace reads | `list_tabs`, `read_review_comments`, `check_verification`, `list_verification_checks`, `list_processes`, `read_process_logs`, `read_whiteboard`, `get_session_checkpoint`, `get_initialization_state`, `get_shortcut_story` | none needed — answers about the caller's own workstream |
| Workspace actions | `open_agent_tab`, `open_editor`, `open_tab`, `close_tab`, `request_attention`, `create_workstream`, `create_shortcut_workstream`, `start_verification`, `start_execution`, `stop_execution`, `start_process`, `stop_process`, `restart_process`, `whiteboard_add`, `whiteboard_update`, `whiteboard_delete`, `update_session_checkpoint` | see below |
| Project tasks | `add_task`, `get_pending_tasks`, `list_tasks`, `claim_task`, `complete_task`, `fail_task` | see "The project task queue" below — project-scoped, and ungated for a third reason distinct from the two above |

The messaging six were once the whole enum. Calix's IPC core is the same six, and everything it
grew on top — pane/tab control, LSP, shell integration — arrived as separate tool surfaces with
separate gates. This is where Atelier takes that step.

**No approval gate, and that is a decision rather than an omission.** Calix gates its
`pane_run` because it can target any pane in any window, including one the caller does not own.
Every workspace tool here acts on the caller's *own* workstream and no other, which is the same
attended-ness argument that leaves `execute` ungated — the project task queue is the one group
that is project-scoped rather than workstream-scoped, and it earns its own ungated argument
rather than inheriting this one; see "The project task queue" below. `atelier.agentIPC` already
defaults off and already gates whether an agent knows any of these tools exist. Do not add an
approval inbox here without a reason that survives that comparison; `PermissionApprovalStore` in
particular is the wrong type to reuse — its expiry resolves to "no decision, let Claude Code ask
in the terminal", a fallback an MCP tool call does not have.

**A tool is described once, in `IPC.ToolSpec` (`Sources/Models/IPC/IPCToolRegistry.swift`).**
That file is the second one `AtelierMCP` compiles out of `Models/IPC/` — `project.yml` lists
`IPCProtocol.swift` and `IPCToolRegistry.swift`, and nothing else from the app — so the app's
dispatch and the helper's advertised schema read one description rather than two lists that
agreed by convention. A spec carries the tool's `surface`, `replyDeadline`, `isSafeToReplay`,
the prose an agent reads, and its `[ArgumentSpec]`, from which `inputSchema` is **generated**.

`Tool.spec` is an **exhaustive `switch`**, deliberately, and not a lookup in the ordered
`ToolSpec.advertised` array. A dictionary keyed by `Tool` forces one of two bad endings for a
case somebody forgets — a force-unwrap that crashes, or a default that silently hands a tool the
wrong deadline, and a default of 15 would still satisfy every deadline assertion in
`IPCProtocolTests`. The `switch` makes a case without a spec a build failure. `advertised`
decides **order only**; it is not enum order and never has been, which is why it is written out
rather than derived from `allCases`.

Adding a tool is therefore **three compiler-enforced edit sites**: the `Tool` case, its `spec`,
and the handler plus its `Service.handle` arm. It used to be eight across four files, three of
them silent. There is a fourth, and it is the one exception: `advertisedOrder` is a plain
`[Tool]`, so a case left out of it **compiles** and is caught only by `IPCToolRegistryTests`,
which pins that the advertised list and `allCases` are the same set. That is the price of
writing the order out; do not read "three edit sites" as meaning the array maintains itself.

This retires a paragraph that said the opposite — that a case with no entry in the helper's
`toolDefinitions` table was "dispatchable but undiscoverable", justified as room for a tool to
land ahead of its handler, and citing an `IPC.Service.notImplemented` that has never existed.
That hole is now closed by construction: there is no table to leave a case out of.
`IPCServerTests.test_helperBinary_answersToolsCallOverStdio` still pins the advertised list end
to end (its `undefined == []` assertion is now tautological, and kept as the wire-level check
that the helper really advertises what the registry says).

**Arguments are typed at the boundary, by `IPC.ToolArguments`.** Handlers no longer read
`request.arguments["line"]` by literal key and parse it inline; they ask for `required`,
`nonEmpty`, `integer`, `boolean`, `list` or `uuid` and get an `IPC.ToolError` naming the
argument. That collapsed three ad-hoc list/bool parsers applied unevenly —
`Workstream.Launcher.parseBool` (deleted, along with the now-unreachable
`Launcher.Failure.invalidArgument`), `VerificationSummary.checks(from:)` and
`TaskSummary.tags(from:)` (both now delegating to `ToolArguments.parseList`).

**Every argument is declared a string, and models send real JSON anyway — so the helper
coerces rather than renders, in `ToolArguments.strings(fromJSON:)`.** That is a shared
function rather than a literal in `main.swift` for the reason `IPC.Vocabulary` is one: it
lives in `IPCToolRegistry.swift`, which is one of the two files from `Models/IPC/` compiled
into `AtelierMCP`,
so the helper calls it and the app's tests assert it. The rule is that each JSON type gets
the spelling this surface's own readers already parse — a boolean becomes `"true"`/`"false"`,
an array becomes the comma-separated form `parseList` takes (elements by the same rules), an
object becomes compact JSON, and **null is dropped**, because "absent" is what a null
argument means and every optional read here treats absent and empty alike. It replaced
`value as? String ?? String(describing: value)`, whose comment claimed a non-string was
"rendered rather than rejected"; only numbers survived that. `JSONSerialization` returns
`__NSCFBoolean` for a JSON boolean and `String(describing:)` renders it **"1"**, which
`boolean(_:)` then refused as `received "1"` for an argument the agent spelled `true`; an
`NSArray` rendered with parentheses, which `parseList` does not split on, so
`start_verification(checks: ["rspec"])` reached the runner as `["(", "rspec", ")"]` and was
refused for an undeclared check named `(`; `NSNull` became the literal `"<null>"`. The
boolean test is `CFGetTypeID(… as CFTypeRef) == CFBooleanGetTypeID()` and not `is Bool`,
which answers true for `NSNumber(1)` and would spell a genuine `tail: 1` as `"true"`.

**And `IPC.Service` is a reentrant actor, so `list_peers` prunes only what it observed.**
`pruneContexts` takes the `contexts` keys snapshotted *before* the `store.listPeers()` await
and drops only ids in that snapshot the store no longer reports. Pruning to the store's
answer alone deleted a context written by a `register_peer` that completed inside the hop:
the new peer's reply carried its id, so its helper believed itself registered, while
`registeredPeerID` answered nil for the rest of the session — `send_message`,
`receive_messages` and `broadcast` all told it to register first, and `peersBySurface` missed
it so verification and task notices addressed to it were dropped. `touch` cannot repair that,
because its own guard needs a context to exist. It is reachable from the coordinator workflow
this document recommends, verbatim: polling `list_peers` for a spawned peer's surface id *is*
a read running while that peer registers.

**Only a `register_peer` reply binds a peer to a connection** (`IPC.Server.peerToClaim`).
The gate is the tool, never the payload's shape: `get_peer_status` answers `.peer` too, for a
peer that is somebody else's, and in the window between `forget` removing `peerOwners[P]` and
the *asynchronous* `retire` removing P from the store, P is ownerless and still readable — so
a read in that window claimed P, and the one-connection-speaks-for-one-peer branch retired
the caller's **own** live peer and bound its socket to P.

**`IPC.ToolError` unifies the *type* that crosses into a `Response`, not every wording.**
`missingArgument`/`invalidArgument`/`notInWorkstream` moved off `WorkspaceActions.Failure`,
which keeps only what the live app can know (`unknownWorkstream`, `appNotReady`,
`surfaceAlreadyRunning`); `IPC.Error`, `VerificationFailure`, `TaskQueueFailure` and
`CheckpointStore.Error` stay as they are, because each carries meaning the boundary has no
business knowing. `ToolError.refused(_:)` is the escape hatch for a sentence an agent is already
reading — `send_message`'s "needs a `to` peer id" and `get_peer_status`'s "needs a `peer_id`"
travel through it unchanged rather than being renamed into `missingArgument`'s sentence.
`emptyArgument(tool:name:)` reproduces the three "x needs non-empty `y`." refusals exactly.
**No agent-facing string changed in this refactor.**

**Four things both processes have to agree on now live in `IPC.Vocabulary`**, because the helper
compiles none of the app's *model* files beyond `AppConstants` and `FilePersistence`, and each
was previously a literal on both sides: the tab
kinds (`WorkspaceActions.openableTabs` is keyed by them, and `WorkspaceTabKindTests` pins each
still equals the matching `WorkspaceTabKind.id`), the two reserved senders
(`VerificationSummary.sender`, `TaskSummary.sender`) and the attention cooldown
(`Workstream.AttentionNotifier.cooldown` reads it; the tool's own description and the server
instructions interpolate it).

**And the helper no longer recognises a refusal by its sentence.** `IPC.Response` carries an
optional `code: ResponseCode?`, and the one case so far —
`peerOwnedByAnotherSession` — replaces `error.contains("belongs to another session")`, a
substring match across a process boundary against a string assembled in `IPC.Server`, where
rewording the message for a human would have silently disabled the re-registration it gates.
The field is optional on the wire, so a response carrying none decodes exactly as before. Add a
code only for a refusal the helper has to *act* on; an error an agent reads needs a sentence.

**`PeerInfo.lastUserPromptSecondsAgo` answers "has a human typed into this peer directly", and
Atelier deliberately has no notion of "since I dispatched it" to compare against.** It is
`nil` when no `UserPromptSubmit` hook event has been observed for that peer's surface this
session — which covers both "never happened yet" and "this peer has no surface at all"
(`surfaceID == nil`) — and otherwise the seconds since the most recent one, mirroring
`lastSeenSecondsAgo` rather than collapsing to a boolean: a boolean would force Atelier to
decide what "since dispatch" means, and dispatch is not a concept Atelier has. A coordinator
that just sent a peer a brief (via `send_message`, or an initial prompt through
`open_agent_tab`/`create_workstream`) knows its own dispatch time; comparing that against this
field is how it tells whether a human has since typed into that peer's own session — the
incident this field exists for: a coordinator saw a peer merge a PR, assumed it had gone off
brief, and broadcast that conclusion, when the user had in fact told the peer to do exactly
that in its own terminal. Tracked per **surface** (`Workstream.AgentStateTracker`'s
`surfaceLastUserPromptAt`, alongside `surfaceStates`), not per workstream, for the reason
`surfaceStates` already gives: two agents can share one workstream.

**The read is `nonisolated`, and that is not a style choice — a `MainActor.run` hop here
deadlocked a real socket round trip.** `IPC.Service` is an actor answering requests from
`IPC.Server`'s own dispatch queue, and `IPCServerTests` exercises it by blocking the *test's*
thread in a raw, untimed `recv()` waiting for the reply. `Workstream.AgentStateTracker` is
`@MainActor`, so producing that reply by hopping to the main actor works only if the main
thread is free to run the hop — and in that test it is the very thread parked in `recv()`.
Neither side can proceed: the reply can't be produced until the main thread goes idle, and the
main thread won't go idle until the reply arrives. `AgentStateTracker.lastUserPromptAt(forSurface:)`
is therefore `nonisolated`, backed by a lock-guarded box (`UserPromptClock`) rather than a plain
dictionary — the same reasoning as `Git.Operations.defaultBranch`'s cache living outside
`AppEnvironment`, for the same reason stated there: "half the callers structurally cannot reach
a `@MainActor` type." Writes still only ever happen from MainActor code, in `updateSurfaceState`.
Do not route this field back through a `MainActor.run` read to "simplify" it — that reintroduces
the deadlock, and `IPCServerTests` is what will hang to prove it.

**Not every synthetic keystroke should count, and the two Atelier already has disagree.**
`PromptInjector`'s stored prompts are a human's own decision — they choose, in the moment, which
saved prompt to send into which pane — so a `UserPromptSubmit` that follows one is genuinely
attributable to that human, however it was typed. `AgentNudge`'s unread-messages notice is the
opposite: fully autonomous text Atelier types on the recipient's behalf when nothing has been
read yet, and unrelated to the sender's own conduct. Left alone it would have made every
`send_message` to an idle peer look like a human just walked up to that peer's terminal, which is
the exact false positive this field exists to prevent, just self-inflicted rather than caused by
the coordinator's misreading — so `AgentNudge.nudge` calls
`Workstream.AgentStateTracker.shared.expectSyntheticPrompt(surfaceID:)` immediately before typing,
and `updateSurfaceState`'s `.agentWaiting` case consumes that marker instead of recording the
prompt, provided it arrives within `syntheticPromptWindow` (10s — generous headroom over
`typeAndSubmit`'s own ~1s of delay plus hook latency). Past the window an unconsumed marker is
discarded and the next prompt counts as human regardless: `typeAndSubmit`'s own safety check can
skip its Return keypress entirely if the pane stops looking idle mid-delivery, and a marker with
no expiry would then go on suppressing attribution for whatever genuinely human prompt eventually
arrived — silently, at an arbitrary point later in the session. Add a marker-and-consume pair like
this for any *other* future mechanism that submits synthetic text into a Coding Agent tab; do not
extend `PromptInjector`'s path the same way, since its submissions are the human input this field
is supposed to report.

**Known, accepted gap: the CLI-supplied initial prompt from `open_agent_tab`/`create_workstream`
may itself read as a human prompt.** If Claude Code's harness fires `UserPromptSubmit` for that
first turn the same way it does for one typed after the session starts, a peer's
`lastUserPromptSecondsAgo` will read as "just now" from the moment it is created by *another
agent's* dispatch, not a human's. This is deliberately not suppressed the way `AgentNudge`'s
notice is: the dispatching coordinator already knows exactly what it just sent and when, so its
own "since I dispatched" comparison naturally reads this as unremarkable rather than as evidence
of a human redirect. Suppressing it would also require assuming a fact about Claude Code's own
hook semantics for a CLI-argument-supplied first turn that has not been verified here.

**A tool call that is interrupted is never re-sent unless re-sending it changes nothing.**
`IPC.Tool` carries two properties the helper reads — `replyDeadline` and `isSafeToReplay` —
and both exist because one 15-second socket timeout with one reconnect-and-replay policy
covered a surface where neither is uniform. `create_workstream` does not answer until
`git worktree add` has, so the deadline fired while the app was still working, the helper read
that as a dead app, reconnected to the *same* app, re-registered under a new peer id and re-sent
the call. Silently: a generated name produced two worktrees and two branches, and an explicit
one produced a refusal — `nameInUse`, or `git worktree add failed … may already be checked out`,
depending on how far the first copy had got — reported to a caller whose workstream had in fact
been created.

Three things hold it shut, and each is easy to undo by accident:

1. **A timeout is not a disconnection.** `IPCTransport.roundTrip` returns `.timedOut` for
   `recv` = -1/`EAGAIN` and `.closed` for `recv` = 0 or a half-written frame. They were one case
   — a nil return — and merging them is the whole bug: a closed socket says the app hung up, a
   timeout says only that it has not answered *yet*, which is no evidence about whether it has
   already acted. A `.timedOut` is reported and never replayed, and the connection is deliberately
   left up, so the session keeps its peer id and a late reply is discarded by request id.
2. **`isSafeToReplay` is idempotence, not `Tool.surface`.** The two do not line up:
   `receive_messages` is messaging and *drains an inbox*, so a replay that lands after the app
   processed the first copy loses those messages for good; `open_editor` is a workspace action and
   puts the same file on screen however many times it runs. `register_peer` has to stay replayable
   because the reconnect path replays it by hand. Refusing a replay still reconnects and
   re-registers — only the call is abandoned, not the session.
3. **The deadlines are sized to the app-side work, and the cost is paid session-wide.** The helper
   is a single-threaded `readLine` loop, so it stops reading stdin for the length of a round trip:
   a wedged app blocks *all* MCP traffic for that long. Only the two creates get minutes —
   `create_workstream` and `create_shortcut_workstream`, both on `Deadline.worktreeCreation`
   (480s — `ProcessRunner.Timeout.userCommand` after a `.network` fetch, spelled as literals
   because `ProcessRunner` is not compiled into `AtelierMCP`). Nothing waits less than the 15
   seconds it replaced. That bound is on *total elapsed time since the call began*, not on the
   gap between chunks: `SO_RCVTIMEO` only ever bounds one `recv`, so `roundTrip` recomputes the
   remaining time before every `recv` rather than setting the timeout once — a reply (or a late
   frame for an abandoned request, still read and discarded per point 1) that trickles in under
   the per-chunk window would otherwise re-arm a fresh window on every chunk and run for
   chunks × timeout instead of `deadline`.
   `IPCServerTests.test_roundTrip_isBoundedByTheToolDeadline_evenWhenRepliesTrickleIn` pins it,
   against a stub that answers in gapped single-byte fragments and never completes the frame.

The timeout message has to **forbid** a retry rather than invite one, and that is the finding's
own conclusion rather than a style preference: the caller cannot tell a genuine `nameInUse` from
one its own second attempt caused, so "try again under another name" risks the duplicate this
rule exists to prevent. `IPCProtocolTests` pins the two tables and
`IPCServerTests.test_helper_doesNotReplayACreateWorkstreamAfterLosingTheConnection` pins that
`call()` consults them — against a listener that hangs up rather than a slow one, because both
reach the same branch and only one of them finishes in milliseconds.

**`open_tab` opens a singleton pane and deliberately does not take the selection.**
Changes, Execution, Verification and Whiteboard start *closed* — `startupWorkspaceTabState` seeds Info and
Agent alone — so a tool an agent already has could produce something with no visible surface to
read it in, worst of all `start_verification`, whose per-check output lives only in those
terminals and never crosses IPC. It goes through `WorkspaceModel.ensureSingleton`, never
`activateSingleton`: opening a pane is not a reason to pull someone off what they are working
in, the same call the run pane already makes when a browser tab starts the dev server. The
answer says so in as many words, because an agent that reads "opened" as "they are looking at
it" waits for a reaction nobody had; `request_attention` is the tool for their eyes and the two
are meant to be paired.

`WorkspaceActions.openableTabs` is the table, **keyed by `WorkspaceTabKind.id`** — the same
string `list_tabs` reports as a tab's `kind`, so the name an agent reads off a tab is the name
it passes back, and there is no second vocabulary for anything to keep in step. The two
exclusions are different refusals rather than one: Info and Agent are **permanent**, so opening
them can neither fail nor do anything, while terminal, browser and editor are **instanced** —
"the" tab is meaningless, and two of the three already have a tool that says which one. The
kind is validated *before* the workstream is resolved, so a typo is answered with the legal
values rather than with whatever the app's readiness happens to be.

**`open_agent_tab` spawns the surface already running the agent** —
`TerminalSurfaceCache.surface(for:…command:)`, not a paste into a shell. There is no synthetic
Return, no timing heuristic, and no question of whether the pane was interruptible. Two
consequences worth keeping:

- **The session id is the *surface's*, never the workstream's.** The workstream id is the Coding
  Agent tab's own Claude session; a second agent handed it fights that tab over one transcript.
- **Surfaces are created eagerly, outside any render pass** (the same construction
  `TerminalSurfaceCache.retrySurface` already does), so a tab can be spawned into a workstream
  the user is not looking at. What is view-bound is *rendering*, not surface creation.

**`close_tab` is `open_tab`/`open_agent_tab`'s counterpart, for the pane an agent's own job
created rather than one the user did.** A controller that spawns a peer into a new tab for a
bounded task — a reviewer, a test-writer — had no way to tear that pane down once the job was
done, so it (or the peer itself) leaves it running for the user to close by hand. `close_tab`
closes a singleton by `kind` (`"changes"`, `"execution"`, `"verification"` or `"whiteboard"`)
or a terminal by `surface_id`, the same two vocabularies `open_tab` and
`open_agent_tab`/`list_tabs` already speak — no third one for anything to keep in step. It
reuses `openableTabs` rather than a second table keyed the same way, so a fifth singleton kind
added there is closeable by default. **Do not hard-code that list of four**: both
`quotedTabKinds` and `quotedCloseableTabKinds` derive from `IPC.Vocabulary.TabKind.allCases`,
which is what stopped the advertised set and `openableTabs` naming different things. Whiteboard
was the fourth and arrived with `read_whiteboard`.

**Execution closes, and stops the run on its way out. It used to be refused by name, and what
changed is where the run lives.** `⌘W` on that tab also stops the running dev stack, and the
method that did it reached into view-local `@State` (`browserStartPending`) that
`WorkspaceActions` — a `MainActor` singleton with no view — could not reach; reimplementing it
there would have been the inlined second copy this document keeps warning about, so the refusal
stood until there was one copy to call. There is: `ProcessCompose.RunSession` owns the run and
`TerminalSurfaceCache` owns the session, so `stopIfTabOwnsRun` is the same call
`TerminalContainerView.forceCloseTab` makes and it works with nothing on screen. Both paths run
it *after* `removeTab`, and only when the tab was really open — `closingTabStopsRun` names
exactly one owner, so Changes and Verification reach it and it does nothing for them. A running
verification check in particular is unaffected either way, since its surface comes from
`Verification.Spawn` and only `Verification.Runner.forget` reaches it.

**Closing an already-closed tab, or a `surface_id` nothing currently owns, is success, not a
refusal.** `close_tab` is `isSafeToReplay`, the same as `open_tab`: a replay landing after the
first close already succeeded must answer the same way rather than erroring on a fact that is
merely no longer true. The unmatched-`surface_id` case reports no kind, deliberately — the id
may never have named a tab in this workstream at all, and asserting one it did not resolve
would be rendering a guess as a fact.

**The Agent tab is refused the same way Info would be, and for the same reason `open_tab`
already refuses them: they are permanent.** The Agent tab's surface id *is* the workstream id
(`WorkspaceActions.surfaceID(of:)`), so an agent naming its own main session's surface resolves
to `.agent`, and `removeTab`'s own `false` there would read identically to "not open" — the one
place this tool checks `WorkspaceTabKind.isCloseable` explicitly, because here the two answers
must not collide.

**Two gaps stay open, deliberately, rather than being half-closed.** Editor and browser tabs
have no id exposed over IPC — `surfaceID(of:)` returns nil for both, so `list_tabs` cannot
report one to close by — and giving them one is a `TabInfo` change, out of scope here. And
closing the terminal tab you are running in — the actual peer-teardown case — destroys your own
surface immediately, the same as a user's `⌘W`; you will not see the reply, because there is
nothing left to send it to.

**`create_shortcut_workstream` is `create_workstream` for work that has a Shortcut story**, and
the two share everything except two values. It parses `story` with `Shortcut.StoryID.parse` — the
same bare id / `sc-` / pasted-URL spellings the sheet takes, which is why the argument is a
**string** rather than an integer — fetches the story, resolves the name, stages the story so the
Info tab does not round-trip again, and hands off. It is `.workspaceAction`, on
`Deadline.worktreeCreation`, and **not replayable**: it is a create, and the duplicate-story guard
making a replay *look* idempotent is not a reason to flip that, since a caller cannot tell a
genuine collision from one its own retry caused.

Two things are shared rather than copied, and both are the second-copy trap this document keeps
naming:

- **The name/guard decision is `Shortcut.WorkstreamName.resolve`**, which `ProjectSidebar`'s sheet
  calls too. It renders the Branch Name Pattern, then refuses in a fixed order — an invalid branch
  name, the story already having a workstream, the rendered name being taken. The order is
  load-bearing for the reason the sidebar's comment always gave: checking the name first blamed the
  story when an unrelated workstream matched, and let one story through twice under a changed
  pattern. Only the *decision* is shared. The **wording is per consumer** —
  `Refusal.localizedMessage` for the sheet, `Refusal.agentMessage` for the tool — which is
  `Project.ConfigLoad`'s shape, and for the same reason: user copy and an instruction to an agent
  are different artifacts, and `Workstream.Launcher.Failure` already says IPC refusals are
  deliberately not localized. The rest of the sidebar's sequence deliberately stays in the view,
  because it is entangled with `shortcutFetching`, `shortcutErrorNeedsToken`, sheet dismissal and
  task cancellation, none of which belongs in a handler.
- **The handler's own tail is `IPC.Service.create(named:forStory:plan:request:)`**, with
  `creationPlan(for:)` in front of it. Everything from `AgentLaunchInputs.read()` down — the prompt
  pre-check, the `AgentStartOutcome` box, the `beforeReady` seeding closure and the three answer
  strings — is identical for both tools, and a sibling handler would have been sixty lines of it
  that nothing keeps in step. `creationPlan` is also what fixes the ordering: the argument, then
  the project, then the agent preconditions, **then** the fetch, so a caller that could never have
  succeeded spends no Shortcut round trip learning it.

**The story read is injected** (`Service.setStoryFetch`), for the reason `WorktreeCreator` is
injected on `launch`: this handler's whole job is the order it does things in, and none of that is
assertable if reaching the first guard costs a network round trip.
`Workstream.Launcher.Target` carries `existingWorkstreams` rather than a name set because the
story-collision guard asks *which* workstream already holds a story id — a question names cannot
answer, and one a second main-actor lookup would answer against a list that had moved on.
`existingWorkstreamNames` survives as a derived property.

**It is not gated on `atelier.shortcutButtonEnabled`.** That key is "the user's way to keep a
working key but hide the button" — chrome, not capability. The token is the real requirement, and
a missing or revoked one arrives as `Shortcut.Error`'s own message, which is the only thing that
says which of the two it is.

**`create_workstream` inherits `bootstrap`'s policy by not touching it.** Creating a
workstream runs the project's `bootstrap` namespace — the thing `PhasePolicy.plan` exists to
decide. The
handler never calls `AsyncSetupService.setupExistingWorktree`. It posts `.workstreamCreated`,
does the git work off the main thread, and posts `.workstreamWorktreeReady`; `ContentView`'s
handler for that notification is what calls `Initialization.Runner`. Those three notifications are
the seam, and going through them is also what gets path persistence, the HeadWatcher, the
agent-state lookup and the Shortcut story id, none of which a second creation path would remember.
Calling `Initialization.Runner.run` directly here is the inlined second copy that section forbids.

**There used to be three producers of that seam and now there is one.**
`ProjectSidebar.launchWorkstream` was a hand-rolled copy of the sequence on its own
`DispatchQueue`, with its own choice of git operation, its own rollback and its own alert, and
`ProjectOverviewView.adoptWorktree` was a third that posted `.workstreamCreated` alone and skipped
the ready notification because the path already existed — which skipped `attachWorktreePath`, the
half that persists the path, refreshes path validity, starts the HeadWatcher and promotes a staged
Shortcut story. Most of that is reached a second way, through `ContentView`'s `.onChange(of:
projectList.items)`, which is why nothing visibly broke; accidental redundancy of that kind is what
a third copy accumulates rather than a reason to keep it. Every producer now goes through
`Workstream.Launcher`: `launch` for the sidebar's three entry points and `create_workstream`,
`adopt` for the overview's Adopt button. The views keep what only a mounted view can do — sheets,
the expanded-project set, and the failure alert the launcher's `throw` raises. Do not add a fourth.

**Adoption posts the same pair as a creation, and differs by one key that states a fact rather
than a decision.** `Launcher.adopt` posts `.workstreamCreated` with a `nil` path and then
`.workstreamWorktreeReady`, so nothing downstream can tell an adopted workstream from a created
one — except for `worktreeIsPreexisting`, which says only that the tree was not made by this call.
`ContentView` is what decides what that means, the way `RunCommandPlan` keeps its invariant at the
consumer, and what it decides is **not** to run `initialization.yaml` in a directory the user
already had: adoption registers a worktree, it does not build one, and running a project's setup
commands unprompted in a tree that may hold work in progress is a side effect nobody asked for. It
renders as `.idle` on the Info tab — "Nothing reported this session.", benign, with Rerun enabled
beside it — so the steps stay one press away. Do not turn that key into a `runInitialization`
flag; the producer states what happened and the consumer states the policy.

**Which of the two git operations runs is a value, `Launcher.WorktreeSource`, not a closure a
caller assembles.** `ProjectSidebar` used to build the `createWorktreeTrackingRemote` call itself,
in a view no test mounts, so the rule in "Two ways to create a worktree, and they are not
interchangeable" had nothing pinning it. The sidebar now names `.existingRemoteBranch(branch)` or
`.newBranch` and `Launcher.gitWorktreeCreator` is the one place both operations are spelled — a
`switch` with no shared tail, so they still cannot be routed through each other. The branch travels
on the case rather than being read off the workstream name: they are equal in the only flow that
produces it, and that is that flow's choice rather than an invariant to inherit.
`Tests/WorkstreamLauncherTests.swift` pins the source reaching the creator in both directions.

Two further things about it that are not guesses:

- **It does not take the selection.** `.workstreamCreated` carries a `select` key that
  `Workstream.Launcher` always sets — true for the sidebar's entry points and for adoption, which
  are buttons the user just pressed, false for `create_workstream`. `ContentView`'s `?? true`
  survives as a defence, not as a description of a producer that omits it. An agent spinning up a
  workstream must not pull the user out of the pane they are working in, and the sidebar row
  appears optimistically either way.
- **Its agent goes in the Coding Agent tab**, on the surface whose id *is* the workstream id, so
  the user opening that workstream lands on the conversation. Nobody is looking at the workstream
  when it is created, so the surface has to exist before `TerminalContainerView` renders — and it
  runs a command carrying the initial prompt, which that view would never build.
  `TerminalContainerView.preloadSurfaces` then calls `ensureSurface` with `buildClaudeCommand`'s
  output, and `ensureSurface` destroys a surface whose stored command differs.
  **`TerminalSurfaceCache.seedSurface` is what makes that safe, and the mechanism is adoption,
  not agreement.** A seeded surface is marked once; the view's first `ensureSurface` for it
  records the view's command and clears the marker instead of comparing. From there it is an
  ordinary surface — a later settings change still respawns it, and a respawn after the agent
  exits uses the view's resume-first command rather than replaying the prompt. The rejected
  alternative was making the two commands *equal*, which would stake a running agent's life on
  byte-equality between two builders reading eight settings each; one divergence — an MCP config
  path resolving in one and not the other — is the same mid-turn kill, only harder to see. The
  invariant belongs at the consumer, the way `ProcessCompose.RunCommandPlan`'s does, rather than
  as an obligation on every future caller.
  **The seed runs before `.workstreamWorktreeReady`, and that ordering is load-bearing** — it is
  what `Launcher.launch`'s `beforeReady` hook exists for. That notification is what makes the
  workstream renderable; the optimistic sidebar row has been clickable since
  `.workstreamCreated`, seconds earlier, so a user who selects the new row is rendering it the
  instant the path lands. Seeding after the post is a race, and losing it means the view's
  surface wins and the prompt is dropped in silence. `seedSurface` returns whether it actually
  created the surface, and the handler reports "no agent was started" rather than the success it
  intended, because a lost prompt that reads as success is the worse half of the bug.
  Two things the handler must still get right on its own, because `ensureSurface` will not
  correct them: the **environment**, which is never compared, so a divergence is permanent —
  `WorkspaceActions.environment(for:surfaceID:)` is the wrong source here, because it blanks
  `TMUX`/`TMUX_PANE`, which is right for a terminal tab and wrong for the surface tmux mode
  wraps — and the **tmux session name**, which goes through
  `Workstream.AgentCommand.tmuxWrapped` so the seeded agent lands in the session
  `Workstream.Archiver` kills.

### The verification tools, and the first message Atelier sends itself

**`list_verification_checks` is how an agent learns a check's name at all**, and it is not a
convenience on top of `start_verification`. `verification.yaml` lives in the project directory,
outside every work tree, and the "Restrict to worktree" system prompt is on by default — so
before this tool a name could only be discovered by guessing one and reading the refusal. It
reads the same `Verification.Config.Load` the tab draws from and carries **both** halves of it:
the declarations in file order, and `Load.unavailableReason`, non-nil exactly when the list is
empty. That pairing is the point rather than tidiness — `.missing`, `.invalid` and a file
declaring nothing all yield no checks, and telling an agent "this project declares no checks"
for the middle one sends it looking for a file that is right there and broken. The wording is
`Load`'s own, never paraphrased, so an agent and its human are told the same thing about the
same file. It deliberately carries **no verdict and no staleness**: `check_verification` answers
verdicts, and a staleness read costs four-plus git spawns on a call an agent makes casually.

`start_verification` runs the project's `verification.yaml` checks against the caller's own
worktree and answers with a **run id**, never a result: a real suite outlives an MCP tool
call. The results reach the agent two ways — **one notice per check, posted as that check
finishes** — and `check_verification(run_id)`, which exists because delivery is a pull and
the nudge is best-effort, so an agent that never reads its inbox must still be able to find
out.

**The seam is declared on the IPC side and the runner conforms**:
`IPC.VerificationControlling` (`Sources/Models/IPC/VerificationControlling.swift`),
mirroring `ProcessCompose.Controlling`. It carries `IPC.VerificationRunInfo` rather
than the runner's `Verification.Run` — the projection `PeerInfo` is to the store's
`Peer`, and for the same reasons: seconds-ago instead of a `Date` needing a shared
encoding strategy on both ends, and `isStale` instead of the stamp. **No output crosses
this boundary at all** — a check's output lives in its terminal surface and Atelier keeps
no copy, so an agent gets verdicts, exit codes and durations, and every string points at
the Verification tab or at re-running the one check. Its doc comment carries the rest of
the contract, and two clauses there are load-bearing: a start must **refuse a check that
is already running**, per check rather than per workstream, since two *different* checks
at once is the design; and `onFinish` must fire on every terminal path, because a path
that does not is a completion notice that never arrives.

**Per check means a partial start, not a whole-call refusal**, and for one round the code
said otherwise — `Runner.start` threw `alreadyRunning` on the *first* clash while its own
doc comment and this section both said it should not. A call naming a live check and an
idle one starts the idle one and hands the refused name back on `Run.refused`; only a call
with nothing left to start throws, and that refusal names **every** one of them rather
than the first, so a caller does not retry into the second. The IPC path is where this bit
hardest: `start_verification` with no `checks` means *all* of them, so one running check
refused an agent's entire run. `Tests/VerificationRunnerTests.swift` pins the mixed call —
one running, one idle — which is the case that was untested and is how this shipped.

**The refused names are reported in `start_verification`'s answer and nowhere else.** They
are deliberately not on `VerificationRunInfo`: none of the seven `CheckResult.State` cases
honestly says "not part of this run", and a refused check's verdict is posted under the run
that *started* it — a different run id. So the answer has to say so in as many words, or an
agent waits for a notice that cannot arrive under the id it was handed, which is the same
silence the run-level notice exists to break. The two UI callers — the row's Run button and
the palette's per-check command — each name exactly one check, so they still throw exactly
as they did and their wording is unchanged.

**There is no approval gate to recheck.** `verification.yaml` lives in the project
directory, outside every work tree, so it cannot have arrived with the repository — the
same location rule that leaves the execution config unasked-about.
`Verification.Runner.start` is the only legal entrance to the runner and the handler passes
its refusals through verbatim; adding a check in `IPC.Service` is the inlined second copy
that section forbids.

**The bridge routes completions per run, because `Runner.onFinish` is one slot that fires
for every run the app performs** — including the ones the user pressed Run for.
`IPC.VerificationRunnerBridge` holds the callback `start_verification` was handed, keyed
by run id, so a run nobody asked about finishes silently. Two consequences: constructing
a second bridge silently unsubscribes the first, which is why `ContentView` builds exactly
one; and nothing may `await` between `Runner.start` returning and the callback being
registered, or a fast failure fires into a slot that is not there yet.

**A run's state is read from its own rows, never from `Runner.isLive`.** They answer
different questions: `isLive` means "is anything running in this workstream", which stays
true while a *sibling* check keeps going — so a state read from it would report this run as
still running in the very notice announcing it finished. `wasStopped` then `isFinished` is
the projection, and `isLive` is left to the thing it is for.

**`IPC.Message.from` is a `Sender` enum, and that is what an app-originated message
cost.** Every other message in the store has a peer on both ends; a run finishing has
no peer behind it. A reserved *peer* registered in the store would have to be filtered
out of `listPeers`, out of a `broadcast` audience and out of `peersBySurface`, each one
a place to forget; a sentinel UUID would let an agent try to `send_message` back to
something that cannot read. `Store.deliverSystemMessage` is the entry point, the label
an agent sees is `atelier/verification`, and the compiler walked every site that had
assumed a sender peer existed. The store's inbox scan is what keeps a queued notice
from being orphaned by its recipient's TTL — the same guarantee peer messages already
had.

**A run id resolves for the whole session and never past it.** Runs live in the runner's
memory and are not persisted: what they used to carry across a restart — a check's output —
now lives in a terminal surface that does not survive one either, and the verdicts are in
`CheckStore` regardless. So every run of this session resolves, rather than only the
newest. The scope check on a read is not a security boundary — every process in this feature runs as the user — it is there because a run
id is the tool's only argument and ids are short, so a stale one should be told it is
not this caller's run rather than handed somebody else's results.

**Notices are per check, and they are posted for every run — including the user's.**
`Runner.onCheckFinished` is the publication point, fired only by `recordCompletion`, and
`IPC.VerificationRunnerBridge` holds it. A run an agent started is addressed to the surface
that asked, because two agents in one worktree report the same workstream name and the
surface is the only discriminator; **a run nobody asked for is addressed to the Coding Agent
surface, whose id is the workstream id**. That fallback is what makes a run the user pressed
in the Verification tab reach the agent, where it used to finish silently. The peer is
resolved when the notice is posted, never when the run started — a helper whose old socket
has not closed yet re-registers under a *new* peer id, so an id captured when the run started
can be dead while its pane has an agent sitting in it. **A caller Atelier did not launch has
no surface of its own to fall back from**, so that same Coding Agent-surface fallback is a
different pane, not this caller's — which is why `startAnswer` still tells such a caller
"nothing will be posted to your inbox" rather than claiming a delivery that is not to it.

**One run-level notice survives, for a run that completed nothing and was not stopped.**
A press where every check failed to get a terminal leaves rows present and `.notRun`, so no
check reaches a terminal edge and there are no per-check notices — and "0 of 0 failed" is
both true and a green suite. The discriminator is exactly that: every check `.notRun`, which
is also exactly when `recordCompletion` wrote nothing. A run the user *stopped* before
anything started looks the same way and is excluded, because the notice exists to break a
silence rather than to report an action back to the person who took it.

**A check's output reaches no agent, ever.** It lives in that check's terminal surface and
Atelier keeps no copy at all, so there is nothing to send and nothing that could be fetched
later. Every string here says so: the tab, for as long as Atelier is running, and re-running
the one check are the two honest pointers.

**Two bounds that are not tuning.** `IPC.Store` refuses content over 64KB outright, so an
oversized notice is not trimmed on delivery — it is lost, silently, exactly when the agent is
waiting for it. With no output to carry, the two things that can still overshoot are the list
of verdicts (`VerificationSummary` assembles against a 6KB budget and says when it cut the
list) and a **check's name**, which is the user's and unbounded — a 200KB name in
`verification.yaml` is legal YAML. And a run that finished having run **nothing** must never
render as a pass, which is what the run-level notice above is for.

Two agents in one worktree is a supported shape, not a mistake — `/ping-pong`-style pairing
wants it. They are distinguishable because every Atelier-launched terminal exports its own
`ATELIER_SURFACE_ID`, which `IPC.Service.PeerContext` carries and `PeerInfo.surfaceID` reports.
That field is load-bearing: two agents in one workstream report the same workstream name, so it
is the only way a caller turns a tab it just created into a peer it can address. What one
worktree cannot hold is two *branches*, which is why work needing its own branch needs its own
workstream.

**Retiring a peer clears the tracker state for its surface — unless a live peer has already
taken that surface over.** Closing a helper's socket is how a peer is retired
(`IPC.Server.forget` → `retire` → `Service.release`), and the clear exists because a surface
left reporting its dead agent's last state — usually `.idle` — is a pane `AgentNudge` would
type into after the agent has gone. But the close is not ordered against the *next*
registration: the helper whose id is refused as belonging to another session drops that
identity, re-registers under a **new** peer id carrying the **same** `ATELIER_SURFACE_ID`, and
the old socket's close lands afterwards (`Sources/MCPHelper/main.swift`). `claim`'s
one-peer-per-connection rule is a second producer of exactly that shape. Retiring the older
peer must therefore reach past nobody: `release` consults `contexts` *after* removing the
departing peer's own entry, and skips the clear while any other context names that surface.

The two directions cost differently, which is why the guard errs towards "occupied".
Over-counting is one *missed* clear and is self-healing — `agentSessionEnded` clears the
surface, `Archiver` clears the workstream, and the successor's own release finds the
predecessor gone and clears it then. Under-counting is the bug: the nudge treats an unreported
surface as "do not interrupt", so a wiped state kills nudging for the rest of the session in
exactly the pane that is waiting on a message, and nothing restores it until a hook event that
the skipped nudge was meant to provoke. Contexts cannot outlive their peers for good in any
case — a connected helper's peer is pinned past the TTL, and the context goes with it in
`release`, in `touch`, or in `pruneContexts`. `releaseAll` clears unconditionally and stays
that way: at shutdown every context goes at once, so there is no successor to reach past.

### The execution tools, and the silence that is on purpose

Seven tools give an agent the Execution tab's capabilities, as the verification tools give it the
Verification tab's: `list_processes`, `read_process_logs`, `start_process`, `stop_process`,
`restart_process`, `start_execution`, `stop_execution`.

**No new `Surface` case, and that is a decision.** They act on the caller's own workstream and no
other, which is exactly what `.workspaceRead` and `.workspaceAction` already mean — `close_tab`
has stopped a run from `.workspaceAction` since it stopped being refused. A fifth surface needs a
trust argument distinct from the four that exist, and this has none; the reads sit in
`.workspaceRead` and the five mutators beside `start_verification` in `.workspaceAction`.

**No approval gate**, on the rule `verification.yaml` and `initialization.yaml` already state:
`execution.process-compose.yaml` lives in the project directory, outside every work tree, so it
cannot have arrived with a clone. The known hole is the one all three accept — for an ordinary
clone `Project.directory` *is* the checkout — and this does not reopen it.

**`list_processes` answers four states, not two.** `ProcessCompose.Client.ClientError.notRunning`
collapses "no config", "not started", "started but there is no control socket" and "running" into
one silence, and an agent told "nothing is running" is misled in three of them — the trap
`Verification.Config.Load`'s three cases exist to prevent. `IPC.ExecutionRunState` keeps them
apart, and `unavailableReason` is `Resolution.startUnavailableReason` **verbatim**, so an agent
and `ExecutionTabView.scriptInstructions` say the same thing about the same file.
`.runningWithoutProcessTable` is the user's own per-workstream dev-command override: there is no
control socket and never will be, so the five socket-backed tools refuse with that reason rather
than reporting an empty stack as a fact. `declaredProcesses` rides along in **every** state,
because this is also how an agent learns the names — the config is outside its worktree and the
"Restrict to worktree" prompt is on by default.

**There are no completion notices, and mirroring verification here is the mistake to avoid.**
Verification posts one per check because `Verification.Runner` already runs completions through
the app. The process table's polling (`TerminalContainerView.syncProcessPolling`) is view-owned by
design, so notices would mean a second per-workstream polling lifecycle *plus* a definition of
"finished" for a server that is meant to stay up. Agents poll `list_processes`, and
`start_execution`'s answer says so in as many words — an agent that waits for a notice waits for
the rest of the session.

**`IPC.ExecutionBridge` carries two guards `ProcessCompose.RunSession` does not, and they must not
move into it.** `RunSession.start` opens with `guard !isReclaimingSocket else { return }` and
returns *silently*, so a start reported as success would be a press that did nothing;
`RunSession.stop()` has no `runStarted` guard at all, because every caller today gates it
externally — the view's Stop button renders only when a run is up, and `close_tab` goes through
`stopIfTabOwnsRun`'s `closingTabStopsRun`. Called with nothing running it still sets
`runStoppedManually = true`, which **suppresses the tmux restore on the next launch**, and still
bumps `runGeneration`. Those two callers need `stop()` unconditional once their own question is
answered, so the guard belongs at the third caller.

**Every tool is on the `mainActorWork` (60s) tier, never `immediate`.**
`ProcessCompose.Client.requestTimeout` is 15 seconds, which is exactly what `immediate` is, so a
tool on that tier would have the helper abandon a call that was about to answer. The control
socket is behind all seven.

**`start_execution` is the one non-replayable tool here**, alongside `create_workstream` and
`add_task`. A replay during the socket reclaim runs a second `down` and a second `beginRun`, and
the later one bumps `runGeneration` and replaces the surface the first built —
`RunSession.isReclaimingSocket` documents that bug already. Its refusal **forbids** a retry rather
than inviting one, for the reason `create_workstream`'s timeout message does: the caller cannot
tell a genuine "already running" from one its own retry caused. The other six are replayable, and
that is load-bearing rather than incidental — stopping a run that is not up, and controlling a
process already in the asked-for state, are **success**, not refusals.

**`processes` scopes one run and never writes `atelier.processSelection.<id>`.** An agent
narrowing a run must not re-tick the user's checkboxes. Omitted, the stored selection is read
exactly as the Start button reads it, three-state encoding included.

**Output crosses IPC here and deliberately not for verification.** That is not an inconsistency:
a check's output exists only in a Ghostty surface Atelier keeps no copy of, so there is nothing to
send, while process-compose keeps its logs and serves them over the same control socket. The tail
is bounded twice — a line count (100 default, 1000 ceiling, clamped rather than refused) and a
64KB byte budget trimmed oldest-first, which says when it cut. The store's 64KB message cap is
**not** what binds: a tool response is not an inbox message. `IPC.Server.maxFrameBytes` and the
agent's own context are.

### The Info tab's two reads

`get_initialization_state` and `get_shortcut_story` are the Info tab over IPC. That tab was the
one pane with no IPC read at all, and of what it shows only two things are Atelier's alone: a
branch is `git`, dirtiness is `git`, a pull request is `gh`. **Setup state and the Shortcut story
are the facts an agent cannot get another way**, and they are all that was added — the tab's other
sections are deliberately not mirrored, because a tool that re-answers `git status` is a second
copy of a fact with no owner.

Both are `.workspaceRead`, both replayable, and neither gets a gate: they answer about the
caller's own workstream, which is what that surface already means.

**`.idle` is the case that decides whether `get_initialization_state` is honest.**
`Initialization.Runner.states` is in memory, so *every* workstream answers `.idle` after a
relaunch — including ones whose setup ran perfectly days ago. It is evidence of neither outcome,
and the tool's own description says so in as many words, because the sentence alone does not:
"Nothing reported this session." is true and still invites "so nothing needed doing". An agent
that reads `idle` as "setup never ran" and reruns it, or as "nothing to do" and debugs a missing
dependency for an hour, is the failure this ships with otherwise.

**The sentence is `Initialization.State.detail` and is written once.** It moved off
`initializationRow(for:)` when this became its second consumer: an agent and the user reading the
Setup row have to be told the same thing about the same run, which is the rule
`Verification.Runner.loadConfig` had to be corrected to after wording two of its three refusals
differently from the tab. The view keeps the icon and the tint, which are its own and which no
agent can read. `Initialization.State.key` is beside it and is the *other* half deliberately —
the key is a wire value that must stay stable, the sentence is copy that may be reworded, and
collapsing them would make either promise impossible to keep.

**`get_shortcut_story` fetches; it does not read the cache the Info tab fills.**
`shortcutStoryCache` is in memory and is only refilled when that tab appears, so a cache-only
read answers "no story" for any workstream whose Info tab has not been opened since launch —
a fact's availability depending on which pane the user happened to visit, which is exactly the
bug `hasGitHubRemote` was moved onto `refreshPathValidity`'s sweep to fix. It goes through
`AppEnvironment.refreshShortcutStory` rather than straight to `Shortcut.Client` so the tab and
the tool share one cache and one workflows lookup.

**The story id comes from `Workstream.shortcutStoryID`, not from `Worktree.Facts`.** That field
is persisted with the project list; the facts copy is written by `ContentView.syncShortcutStoryIDs`,
so reading it would make the answer depend on whether that sweep had run — and the wrong answer
would be "this workstream has no Shortcut story", which is unfalsifiable from the agent's side.
`refreshShortcutStory(for:storyID:)` exists for that, with the facts-reading version delegating
to it.

**Four ways to have no story, and they are four sentences.** No story linked; a story but no
API token; a story and a token the keychain would not release; a story, a token, and a fetch that
failed. The tab renders all four as an absent Shortcut section, which is fine for a section and
useless for a tool named `get_shortcut_story`. The third is not padding:
`KeychainTokenStore.ReadOutcome` already separates `.absent` from `.failed` precisely because
collapsing them told a user their token had vanished and sent them to re-paste one they still
had — flattening it back at the IPC boundary would undo that fix one layer up.
`refreshShortcutStory` logs and swallows its error, so an empty cache after a fetch is the only
evidence the fetch failed; that is what the fourth sentence is reading.
`WorkspaceActions.shortcutStoryInfo` is a pure static holding all of it, for the reason `resolve`
is one.

**A cached story is not a current one, and `isStale` is what keeps that from being a lie.**
`refreshShortcutStory`'s `catch` deliberately keeps any cached copy rather than blanking the tab,
and `registerShortcutStory` caches a story at *creation* — so every Shortcut-created workstream
has one before any pane is opened. Reading the cache after a failed fetch therefore hands an agent
an old copy under a tool description promising the answer is current, which is precisely the
failure a revoked token or a deleted story produces. So the refresh returns **whether the fetch
succeeded** — not whether it published anything, since an unchanged story is a successful fetch
that writes nothing — and a story returned over a failed fetch carries `isStale`, the same meaning
`VerificationRunInfo.isStale` has: this no longer describes reality. The tab ignores the return
value and goes on rendering the stale copy, which is right for a pane whose user can see it is not
moving.

Two lesser cases ride inside a successful answer. A story whose workflow **state name** is unknown,
because stories carry only a `workflow_state_id` and the workflow list is a second round trip that
fails on its own: `state` goes nil and `stateUnavailableReason` says why, rather than the field
simply being absent — `state` is one of the four things this tool exists to answer, and an absent
one with no reason reads as a story that has no state. And that reason names **which** of its two
causes actually happened — the list could not be fetched, or the list was fetched and does not
contain this story's state id. They are different facts, and asserting the likelier one is the
mistake `KeychainTokenStore.ReadOutcome` exists to prevent one layer down.

`description` rides along, clamped to 8KB with the cut reported the way `ExecutionLogs` reports a
trimmed tail — and trimmed from the **end**, the opposite of a log tail, because a story's first
paragraph is the one that says what the work is.

**Neither is tested through `IPCServerTests`' round-trip harness, and that is not laziness.**
That harness parks the test's own thread in an untimed `recv()` — the reason
`AgentStateTracker.lastUserPromptAt` is `nonisolated` — so a round trip through either handler's
`MainActor` hop would deadlock and read as a bug in the handler. The mappings are pure statics and
are asserted directly; `test_helperBinary_answersToolsCallOverStdio` still pins that both are
advertised on the wire.

### The project task queue

Six tools — `add_task`, `get_pending_tasks`, `list_tasks`, `claim_task`, `complete_task`,
`fail_task` (`IPC.Tool`, `Sources/Models/IPC/IPCProtocol.swift`) — give a project a
shared, claimable work queue: add several units of work once and let any peer in the project
pull the next one, instead of a coordinator hand-dispatching each with `create_workstream`. The
incident this answers: a coordinator once dispatched seven workstreams by hand, one per audited
finding, with no atomicity (two peers could claim the same finding), no pull (a peer finishing
early had to be noticed rather than ask), and no record (a dead peer's finding stayed silently
claimed). `list_tasks` is the one tool with no Scenius counterpart — a coordinator that's
mid-task when a completion notice arrives can miss it the way any pull-based inbox can be
missed, and this is how it recovers the whole picture without every notice having landed.

**A fourth `Surface` case, `.projectTasks`, and it is deliberately not `.messaging`.**
(`Surface`, `IPCProtocol.swift`.) Messaging's trust story is "none
needed — nothing a user can see"; these six mutate durable, queryable state that *another
agent's correctness depends on* — a wrong claim is two agents doing the same audited finding,
not a stray chat message. It isn't `.workspaceRead`/`.workspaceAction` either: both those groups
are scoped to the caller's own workstream in their own doc comments, and this queue is
project-wide by design, the same scope peers and messages already have (a coordinator in one
workstream has to reach peers in others). **The ungating is a third argument, not a copy of
either existing one**: workspace actions go ungated because they're attended, messaging because
nothing here is visible to the user at all; project tasks go ungated because nothing in this
surface executes code, spawns a process, or touches the user's files or git state — it's
structured coordination data between peers already inside the one trust boundary
`atelier.agentIPC` draws around the whole IPC surface. All six sit in the 15s `replyDeadline`
tier with the messaging six (`IPC.ToolSpec.Deadline.immediate`, `IPCToolRegistry.swift`): actor
hops over an in-memory dictionary, no shell, no process, no network. The workspace reads are
*not* uniform and must not be cited as if they were — `list_processes`, `read_process_logs` and
`get_shortcut_story` sit on the 60s `mainActorWork` tier.

**Ownership is keyed by surface id, never peer id, and that is the load-bearing decision.**
(`IPC.TaskStore`'s doc comment, `Sources/Models/IPC/IPCTaskStore.swift:93-107`; the actor at
`:108`.) CLAUDE.md already documents the reconnect race two sections up: a helper whose old
socket hasn't closed yet drops its identity and re-registers under a **new** peer id carrying
the **same** `ATELIER_SURFACE_ID`. Keying a claim on peer id would make that ordinary reconnect
look like a different actor attempting its own earlier claim — `claim_task` would refuse its own
replay, and `complete_task` would return `wrongClaimer` against its rightful claimer for the
rest of the session, deadlocking the task by machinery rather than by any agent's mistake.
`ATELIER_SURFACE_ID` is stable for the life of a terminal independent of how many times its
helper reconnects, so `claim_task`/`complete_task`/`fail_task` key on it via one shared guard,
`surfaceAndWorkstream(_:)` (`Sources/Models/IPC/IPCService+Tasks.swift`), and refuse cleanly
when it's absent — an agent Atelier didn't launch has no surface for ownership to attach to. A
useful side effect: a claim is fully decoupled from `IPC.Store`'s own peer lifecycle (the 600s
TTL, `pin`/`release`) — a task stays claimed even if the claimer's peer entry itself expires or
is re-registered under a new id, because ownership was never routed through the peer store at
all.

**The cleanup hook is workstream teardown, never `IPC.Service.release(peerID:)`.**
`Service.release(peerID:)` fires on the ordinary reconnect race above, not only on a genuine
departure — and since surface id is exactly the identity a reconnect is designed to preserve,
hooking claim-release to peer release would spuriously un-claim a task the same agent is still
actively working, reintroducing the same race the surface-id decision exists to avoid. The real
"this claim can never be finished" signal is a workstream ceasing to exist:
`TaskState.claimed` carries `inWorkstreamID`, recorded at claim time from
`request.client.workstreamID` (`IPCTaskStore.swift:29`), precisely so the sweep doesn't need
to resolve individual surfaces back to a workstream. `TaskStore.releaseClaims(inWorkstreamID:)`
(`IPCTaskStore.swift`) reverts every task claimed there back to `.pending`, and
`IPC.Service.releaseTaskClaims(inWorkstream:)` (`IPCService+Tasks.swift`) is called
fire-and-forget from both archive paths, `Workstream.Archiver.remove` and `.purge`
(`Sources/Models/WorkstreamArchiver.swift`) — reached through the shared
`detachWorkstream` tail, so it is one call site serving both paths rather than two, which is how
it differs from `verificationRunner?.forget(workstreamID:)`, written out separately in each. It deliberately does **not** follow that call's
injected-optional-parameter pattern (the `verificationRunner:` parameter on both entry points): that pattern exists
because verification teardown is heavyweight and ordered — killing running processes and
awaiting a bounded timeout the archive flow genuinely needs before `git worktree remove` — and
reverting a handful of in-memory dictionary entries to `.pending` carries none of that weight.
Calling the actor singleton from a plain, un-awaited `Task { ... }` is the same fire-and-forget
shape `Archiver.remove`'s own top already uses to kill tmux sessions, though that call is
`Task.detached` — the two share only "kicked off and not waited on," not the detached/
non-detached distinction itself; a plain `Task` is enough here because this has no captured
`@MainActor` state to escape the way the detached tmux kill does. A project with no tasks, or a
workstream with no claims, makes the call a genuine no-op, so neither archive path needs a new
precondition to add it safely.

**`add_task` is the one non-replayable tool in this group, alongside `create_workstream`.**
Every other tool here is `isSafeToReplay == true` (each tool's `ToolSpec` in `IPCToolRegistry.swift`): a same-surface
replay of `claim_task`/`complete_task`/`fail_task` is a defined no-op, a different-surface replay
is a defined refusal, and the two reads are pure. `add_task` is a *create*, and creates don't get
to inherit that idempotence — the helper mints a fresh request id on every replay
(`attempt(...)`, `Sources/MCPHelper/main.swift`), so there is no id `IPC.Service` could
use to recognize "I already did this one." A duplicate-path `add_task` is refused rather than
silently re-executed, and the refusal message is written to forbid a retry rather than invite
one, the same rule the timeout message states above for `create_workstream`: "add_task is not
replayed automatically after a lost connection, so this may mean your earlier call already
succeeded — check list_tasks rather than retrying under the same path"
(`TaskQueueFailure.alreadyExists`, `Sources/Models/IPC/IPCTaskStore.swift:70-72`). A caller
cannot tell a genuine path collision from one its own retry caused, so the honest answer is
"don't," not "try a different path."

**Do not reintroduce persistence, an approval gate, a claim TTL, or task editing.** All four
were considered and declined, not overlooked:

- **No persistence.** `TaskStore` is in-memory and wiped exactly when `IPC.Store` is — at
  `Server.stop()`, via `Service.releaseAll()` — because this coordinates live agents in one
  Atelier session; if the app restarts, every workstream's Coding Agent process is gone too, and
  there is no restart-survival story worth building before anyone has asked for one.
- **No approval gate.** Restated from above: nothing here executes code, spawns a process, or
  touches the user's files or git state. Adding one needs a reason that survives the comparison
  to the two existing ungated groups, not just "it's new."
- **No claim TTL or heartbeat.** A claim lives until `complete_task`, `fail_task`, or the owning
  workstream is torn down. A time-based expiry needs a policy for "how long is too long" that
  nothing in the reported incident calls for, and risks yanking a claim out from under a peer
  doing genuinely slow work.
- **No task deletion or editing.** `add_task` creates; nothing removes a completed or failed
  task from the store. A long session accumulating a few dozen coordination tasks — audit
  findings, review items — is the expected scale, not a production job queue needing pruning.
