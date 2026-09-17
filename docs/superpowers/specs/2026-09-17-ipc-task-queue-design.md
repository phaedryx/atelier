# IPC task queue — design

> **Status: not started.** A design for something that does not exist yet.
> Nothing in Atelier implements this, and no code references it — read this as
> a proposal, not as a description of the app.
>
> This file lives inside a worktree (`feat-ipc-task-queue`) rather than at
> `<main-root>/notes/specs/`, the usual location for a worktree-authored spec:
> the session that wrote it was sandboxed to this worktree's directory and
> could not write to the main checkout. It should be treated as staged in the
> wrong place, not as an exception to that convention.

## Problem

Atelier's IPC layer (`Sources/Models/IPC/`, documented in `CLAUDE.md`'s "Agent
workspace tools (IPC)" section) supports manual 1:1 coordination: a
coordinating agent dispatches work to peer workstreams one at a time via
`create_workstream`/`open_agent_tab`, each with a hand-written prompt. There is
no shared work queue.

This showed up as a real incident: a coordinator dispatched seven separate
workstreams, one per audited finding, each with its own hand-typed brief. That
is brittle in three ways:

- **No atomicity.** Nothing stops two peers claiming the same finding.
- **No pull.** A peer that finishes early has no way to ask "what's next" — the
  coordinator has to notice and dispatch by hand.
- **No record.** If a peer dies mid-task, nothing says the finding it was
  working is unclaimed again.

Scenius (a separate MCP server this user has, for durable storage) has exactly
the missing primitive: `add_task`, `get_pending_tasks`, `claim_task`,
`complete_task`, `fail_task`. This design is an *equivalent* primitive for
Atelier's own IPC layer, scoped to a project rather than to a personal store —
not a clone of Scenius's semantics, which are shaped by durable storage this
feature deliberately does not use.

## Where task state lives

**In-memory**, in a new `IPC.TaskStore` actor — a peer to `IPC.Store`, not a
subsystem of it. This follows the precedent `IPC.Store` and
`Verification.Run` already set, for the same reason in both cases:

- `IPC.Store`'s own doc comment: "messages surviving a restart is a feature
  nobody asked for and a migration we would own forever."
- Verification run state is deliberately non-persistent because the thing that
  would make persisting it worthwhile — a check's output — lives in a terminal
  surface that doesn't survive a restart either, so persisting the record
  alone buys little.

The same logic applies here more directly than to either precedent: a task
queue coordinates **live agents in one Atelier session**. If the app restarts,
every workstream's Coding Agent process is gone too (barring tmux mode, which
is a different resilience story CLAUDE.md already scopes out of this feature).
There is no persistence story that survives a restart *and* is worth building
before anyone has asked for it. `IPC.TaskStore` is wiped exactly when
`IPC.Store` is: at `Server.stop()` (app quit, or the user toggling "Agent IPC"
off/on) via `Service.releaseAll()`, and nowhere else.

## Data model and scoping

```swift
extension IPC {
    struct ProjectTask: Codable {
        let path: String                    // caller-chosen, unique per project, e.g. "audit-2026-09/finding-3"
        let name: String
        let content: String                 // capped at 64KB — the same bound IPC.Store applies to messages
        let tags: [String]
        let createdAt: Date
        /// Nil when the creator has no ATELIER_SURFACE_ID (an agent Atelier
        /// didn't launch). Nil disables the completion notice; it does not
        /// block creation.
        let createdBySurfaceID: String?
        var state: TaskState
    }

    enum TaskState: Codable, Equatable {
        case pending
        case claimed(bySurfaceID: String, inWorkstreamID: String, at: Date)
        case completed(bySurfaceID: String, at: Date)
        case failed(bySurfaceID: String, at: Date, reason: String)
    }
}
```

Storage is `[projectDirectory: [path: ProjectTask]]` inside the actor —
the same scoping key `IPC.Service.isVisible` already applies to peers, so
tasks are visible to every peer of the project, the way `list_peers` and
`broadcast` already are, and invisible across projects for the same reason
cross-project messaging is a separate, louder opt-in.

**Display names are never stored.** `createdByName` and `claimedByName` are
resolved live from `IPC.Service.peersBySurface()` whenever a `TaskInfo` is
built for a response — the same pattern `MessageInfo.fromName` and the
verification notices already use, and for the same reason: a peer can rename
itself, or its surface's current occupant can be a *different* peer than the
one that originally created or claimed the task (see "Ownership key" below).
A surface with nobody currently registered on it reads as "unknown" rather
than as a stale name.

## The claim model

### Ownership key: surface id, not peer id

This is the load-bearing decision, and it corrects an assumption I started
with. CLAUDE.md documents the reconnect race directly: a helper whose old
socket has not closed yet "drops that identity, re-registers under a **new**
peer id carrying the **same** `ATELIER_SURFACE_ID`." If task ownership were
keyed by peer id, an ordinary reconnect would make `claim_task` see a
*different actor* attempting its own earlier claim — refusing its own replay —
and `complete_task` would return `wrong_claimer` for the rest of the session,
deadlocking the task by machinery rather than by any agent's mistake.

`ATELIER_SURFACE_ID` is stable for the life of a terminal, independent of how
many times its IPC helper reconnects. So `claim_task`, `complete_task`, and
`fail_task` all key on `request.client.surfaceID`, and all three refuse
cleanly when it is absent ("this looks like an environment Atelier didn't
launch — task ownership needs a surface to attach to").

A useful side effect: this decouples claims entirely from `IPC.Store`'s peer
registration lifecycle (the 600s TTL, `pin`/`release`). A task stays claimed
even if the claimer's peer entry itself expires or is re-registered under
a new id — ownership was never routed through the peer store at all.

### Atomicity

Nothing new is needed here. `TaskStore` is an actor, and `claim`, `complete`,
and `fail` are each a single synchronous method body with no `await` between
the check and the write — the same shape `IPC.Store.sendMessage`'s
alive-check-then-append already has. Swift actor isolation is what makes "only
one caller sees `.pending` and transitions it" true by construction, the same
way it already is for `IPC.Store`'s peer registration.

Any display-name resolution (an `await` into `peersBySurface()`) happens
**after** the claim has already been decided and written — never between the
read and the write, which is the reentrancy hazard `deliveredNotices.insert(
_:).inserted` in `IPC.Service` is already careful about.

### Idempotence, per verb

- **`claim_task(path)`**: same-surface replay is a no-op success ("already
  claimed by you"); a different surface's claim on an already-`.claimed` task
  is a refusal (`wrongClaimer`, naming who holds it — display name only, not
  the surface id, since a caller has no use for another surface's raw id); a
  claim against a task already `.completed`/`.failed` is a **distinct**
  refusal (`alreadyFinished`), not `wrongClaimer` — the task has no current
  owner to name, and the honest answer is "this is done," not "someone else
  has it."
- **`complete_task(path)`**: same-surface replay of an already-`.completed`
  task is a no-op success. Every other case — claimed by a different surface,
  `.pending` (nobody has claimed it), or `.failed` — is `wrongClaimer`: none of
  those is "you, the current claimer, finishing your own claim," which is the
  only case this call succeeds for.
- **`fail_task(path, reason)`**: same shape as `complete_task`, with
  `.completed` added to the `wrongClaimer` set (a task cannot be un-passed by
  calling fail on it). A same-surface replay of an already-`.failed` task
  succeeds as a no-op against the **stored** reason, even if the replay's
  `reason` argument differs — the first call's reason wins, since a replay
  must never let a second execution overwrite what the first one recorded.

Two error cases, one shared: `unknownTask(path)` when no task exists at that
path at all, for every one of the three mutating tools.

### Replay safety, per tool

| Tool | `isSafeToReplay` | Why |
|---|---|---|
| `claim_task` | **true** | Same-surface replay is a defined no-op; different-surface replay is a defined refusal. Neither is a duplicate side effect. |
| `complete_task` | **true** | Same reasoning. |
| `fail_task` | **true** | Same reasoning. |
| `get_pending_tasks` | **true** | Pure read, like every other read in the surface. |
| `list_tasks` | **true** | Pure read. |
| `add_task` | **false** | See below. |

`add_task` is the one tool here that is a *create*, and it does not get to
inherit the others' idempotence. I checked whether the helper's replay could
be deduplicated by `Request.id` — it can't: `IPCBridge.attempt` builds a fresh
`IPC.Request` with a new random id on every call, including a replay
(`Sources/MCPHelper/main.swift:812`), so there is no id for `IPC.Service` to
recognize as "I already did this one." A duplicate-path create is refused
("already exists at this path"), which is at least an honest, non-silent
outcome — a caller that sees it after a reconnect can read it as confirmation
the original went through — but it is still a second execution of a create,
which is exactly the shape CLAUDE.md documents for `create_workstream`:
"a replay is a second execution, and only a tool that changes nothing by
running twice can afford one." `add_task` goes in the same
`isSafeToReplay = false` bucket, for the same reason, and its refusal message
follows `create_workstream`'s pattern: it must forbid a retry rather than
invite one, since the caller cannot tell a genuine collision from one its own
retry caused.

## The tool surface

### A fourth `Surface` case: `.projectTasks`

Not `.messaging`: that group's documented trust story is "none needed —
nothing a user can see," and these tools mutate durable, queryable state that
*other agents' correctness depends on* — a wrong claim isn't a stray chat
message, it's two agents doing the same audited finding. Not
`.workspaceRead`/`.workspaceAction` either: both are explicitly scoped in
their own doc comments to "the caller's own workstream," and this feature is
project-wide by design — the same scope peers and messages already have, and
for the same reason (a coordinator in one workstream has to reach peers in
others).

`.projectTasks` gets its own doc-comment paragraph stating its trust story,
the way `Tool.surface`'s comment asks every new case to: **no approval gate,
for a different reason than either existing ungated group.** Workspace actions
go ungated because they're attended (a deliberate press, output in front of
the user). Messaging goes ungated because nothing here is visible to the user
at all. Project tasks go ungated because nothing in this surface executes
code, spawns a process, or touches the user's files or git state — it's
structured coordination data exchanged between peers already inside one
trust boundary, gated by the same `atelier.agentIPC` setting that gates
whether any IPC tool exists for this session at all.

### Six tools, not five

Mirroring Scenius's five (`add_task`, `get_pending_tasks`, `claim_task`,
`complete_task`, `fail_task`) plus one Atelier-specific addition,
**`list_tasks`** — every task regardless of state, for a coordinator checking
overall progress without relying on completion notices arriving. `IPC.Tool`
gains six cases:

```swift
case addTask = "add_task"
case getPendingTasks = "get_pending_tasks"
case claimTask = "claim_task"
case completeTask = "complete_task"
case failTask = "fail_task"
case listTasks = "list_tasks"
```

All six are workspace-visible in `toolDefinitions` (`Sources/MCPHelper/main.swift`)
from the start — there is no "dispatchable but undiscoverable" staging period
needed here, since all six land in one PR rather than being built by separate
agents in sequence.

`replyDeadline`: all six are actor hops and in-memory dictionary operations, no
different from the messaging six or the existing workspace reads — **15s**,
the "original 15 seconds, which was always right for these" tier.

### Preconditions, per tool

Project-tasks tools don't require `callerWorkstreamID` the way every existing
workspace tool does — they're scoped to the *project*, not the workstream, so
the natural precondition is `request.client.projectDirectory` non-empty, the
same gate `isVisible` already applies to messaging:

- `get_pending_tasks`, `list_tasks`: require `projectDirectory` only.
- `add_task`: requires `projectDirectory`; `surfaceID` is optional — its
  absence only disables the completion notice, it does not block creation.
- `claim_task`, `complete_task`, `fail_task`: require **both**
  `projectDirectory` and `surfaceID` (see "Ownership key" above).

None of the six requires a registered peer (`IPC.Store` involvement at all).
Task identity is carried entirely by `(projectDirectory, surfaceID)`, which
every Atelier-launched terminal already has independent of whether
`register_peer` has ever been called.

### Arguments

- `add_task`: `path` (required, unique per project), `name` (required),
  `content` (required, ≤64KB), `tags` (optional, comma-separated — the same
  convention `startVerification`'s `checks` argument already uses).
- `get_pending_tasks` / `list_tasks`: `path_prefix` (optional — absent means
  every task in the project, the same "empty means all" convention
  `startVerification`'s `checks` argument uses in the other direction), `tags`
  (optional, comma-separated, **all** must be present on a task to match —
  stated explicitly in the tool description to avoid ambiguity).
- `claim_task`: `path` (required).
- `complete_task`: `path` (required).
- `fail_task`: `path` (required), `reason` (required — Scenius's own contract
  already requires this, and CLAUDE.md's `fail_task` line in the task
  description does too).

### Wire types (all in `IPCProtocol.swift`)

`AtelierMCP` compiles exactly one file out of `Models/IPC/` —
`IPCProtocol.swift` (`project.yml:198-200`) — so every wire type the helper
needs to encode, decode, or render must live there, the same rule
`VerificationChecksInfo`/`VerificationRunInfo` already follow.

```swift
enum TaskWireState: String, Codable, CaseIterable {
    case pending, claimed, completed, failed
}

struct TaskInfo: Codable, Equatable {
    let path: String
    let name: String
    let content: String
    let tags: [String]
    let state: TaskWireState
    let createdSecondsAgo: Int
    let createdBy: String?          // peer id, resolved live; nil if unresolvable
    let createdByName: String?
    let claimedBy: String?
    let claimedByName: String?
    let claimedSecondsAgo: Int?
    let failureReason: String?      // set only when state == .failed
}
```

New `Payload` cases: `.task(TaskInfo)` (add/claim/complete/fail responses),
`.tasks([TaskInfo])` (get_pending_tasks/list_tasks).

## Failure/cleanup semantics on disconnect

This is the one place the design diverges from a literal parallel to
`Service.release`/`forget`, and the surface-id ownership decision above is
why.

`Service.release(peerID:)` fires on an **ordinary reconnect race**, not just a
genuine departure: CLAUDE.md documents the old connection's close landing
*after* a new one has already taken over the same surface (`claim`'s
ownership-transfer logic in `IPCServer.swift`). Since surface id is exactly
the identity a reconnect is designed to preserve, hooking claim-release to
peer release would spuriously un-claim a task the same agent is still
actively working, moments into a legitimate reconnect — reintroducing, via a
different path, the exact race this design otherwise avoids.

The real "this claim can never be finished" signal is the **workstream being
torn down**, not the peer connection blinking: `Workstream.Archiver.remove`
and `.purge` both call `surfaceCache.removeWorkstreamSurfaces(for:)`, which is
the point every surface belonging to that workstream stops existing for good
— no respawn, no reconnect coming back to it. `TaskState.claimed` therefore
carries `inWorkstreamID` (recorded at claim time from
`request.client.workstreamID`) precisely so this comparison doesn't need to
resolve individual surfaces back to workstreams.

I'd add one fire-and-forget call at the same two sites `verificationRunner?
.forget(workstreamID:)` is already called from
(`Sources/Models/WorkstreamArchiver.swift:52` and its `purge` counterpart):

```swift
Task { await IPC.Service.shared.releaseTaskClaims(inWorkstream: workstreamID) }
```

reverting every task claimed in that workstream back to `.pending`, clearing
`claimedBySurfaceID`/`inWorkstreamID`.

**Deliberately not** following `verificationRunner`'s injected-optional-
parameter pattern into `Archiver.remove`/`.purge`'s own signatures. That
pattern exists because verification's cleanup is a heavyweight, ordered
operation — kill running processes, wait for them, with a bounded timeout that
the archive flow genuinely needs to await before proceeding to
`git worktree remove`. Reverting a handful of in-memory dictionary entries
back to `.pending` carries none of that weight, and threading a new parameter
through a signature two heavily-tested call sites (`ContentView`,
`ProjectSidebar`) already share is a cost this operation doesn't justify.
Calling the actor singleton directly, detached, is the same shape
`WorkstreamArchiver.remove`'s own top does for killing tmux sessions
(`Task.detached { TmuxSession.killWorkstreamSessions(...) }`) — best-effort
cleanup that must not block the synchronous archive path.

Neither `remove` nor `purge` needs any *new* precondition to call this safely:
a project with no tasks, or a workstream with no claims, makes it a genuine
no-op — same shape `Verification.Runner.forget` already has for a workstream
running no checks.

## Notify on completion

`complete_task` and `fail_task` post a system message to the task's
**creator**, resolved from `createdBySurfaceID` **at delivery time** — not at
task-creation time — exactly the rule `postVerificationNotice` and
`postCheckNotice` already state and for the identical reason: a surface's
current occupant can be a different peer than the one that created the task,
and resolving early would deliver to a peer id that has since gone stale.

- Sender: a new constant beside `VerificationSummary.sender`, e.g.
  `TaskSummary.sender = "atelier/tasks"` — a reserved `Sender.system(_:)`
  label, not a peer an agent could address back (same reasoning
  `IPC.Sender`'s doc comment already gives for why a verification notice isn't
  routed through a real peer).
- Content references the task's **path and name only, never its `content`
  field** — task content is agent-chosen up to 64KB, and CLAUDE.md's own
  language for why a notice must stay bounded applies verbatim: an oversized
  notice "is lost, silently, exactly when the agent is waiting for it."
  `VerificationSummary`'s 6KB message budget is the precedent to match, not a
  number to reinvent.
- Delivery is best-effort exactly like the verification notices: `nil` back
  from `createdBySurfaceID` (no surface recorded), or no peer currently
  resolvable from that surface, is an ordinary, silent no-op — "the agent that
  created this task may have finished its session; the result stays readable
  through `list_tasks`/`get_pending_tasks` either way."

This is also the reason `list_tasks` earns its place instead of being deferred
as unnecessary: a coordinator that's mid-task itself when a peer's completion
notice arrives can miss it in exactly the way any pull-based inbox can be
missed, and `list_tasks` (unlike `get_pending_tasks`) is how it recovers the
full picture — including a task the underlying peer already reported failure
on — without needing every notice to have landed.

## What this explicitly does not add

- **No persistence.** Restated from above: this is app-session state, and a
  migration nobody asked for is not worth pre-building.
- **No approval gate.** Restated from above: nothing here executes code,
  spawns a process, or touches the user's files or git state.
- **No claim TTL or heartbeat.** A claim lives until `complete_task`,
  `fail_task`, or the owning workstream is torn down. A time-based expiry
  would need a policy for "how long is too long" that nothing in the reported
  incident calls for, and would risk yanking a claim out from under a peer
  doing genuinely slow work. If this turns out to be needed, it is a
  narrowly-scoped follow-up, not a reason to hold this design.
- **No task deletion or editing.** `add_task` creates; nothing removes a
  completed or failed task from the store. A long session accumulating a few
  dozen coordination tasks is the expected scale (audit findings, review
  items) — not a production job queue needing pruning.
