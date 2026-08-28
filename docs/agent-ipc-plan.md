# Agent IPC — implementation plan (Atelier)

Companion to `../factoryfloor/notes/specs/agent-ipc-design.md`. That spec's
architecture stands; this file records where it is stale against the current
Atelier tree, and the concrete order of work.

## Naming

The spec was written pre-rename. `ff-mcp` → `atelier-mcp`, `FFMCP` → `AtelierMCP`,
`FF_WORKSTREAM_ID` → `ATELIER_WORKSTREAM_ID` (the `FF_*` aliases still exist in
`WorkstreamEnvironment`, but new code reads the `ATELIER_*` spelling).

## Deltas from the spec

### 1. The wakeup problem is largely solved (spec §"The wakeup problem")

The spec called this "the genuinely hard part" and argued against a nudge because
`WorkstreamActivityTracker` was a 5-second decay on terminal title changes. That
type no longer exists. `WorkstreamAgentStateTracker` replaces it and is driven by
real Claude Code lifecycle hooks (`UserPromptSubmit`/`Stop`, `PreToolUse`/
`PostToolUse`, `SubagentStart`/`SubagentStop`) delivered over the existing
`HookEventReceiver`. It exposes `state(for: workstreamID) -> AgentRunState`
(`.idle` / `.working` / `.stalled` / `.needsAttention`).

So "the agent's turn ended" is a real signal, not a guess. The nudge fires on
`.idle`, not on a quiet-window heuristic.

**What is still not solved:** hook events carry `project_dir`, so the tracker is
keyed per *workstream*, not per *surface*. A `claude` started by hand in a Cmd+T
tab is indistinguishable from the Agent tab at the tracker level, and nudging it
would inject into the wrong surface. Resolution: the Agent surface's environment
carries an extra `ATELIER_AGENT_SURFACE` var that plain terminal tabs do not get;
`register_peer` records it. Peers without it are **pull-only** — no nudge, ever.
That keeps the spec's honesty requirement without keeping its pessimism.

### 2. The "no HTTP surface" argument is already spent (spec §"Why not an in-app HTTP MCP server")

`HookEventReceiver` is already an `NWListener` on `127.0.0.1:<ephemeral>` speaking
HTTP, with its port in `~/Library/Caches/atelier/hook-port`. Loopback HTTP exists
in this app today.

The design does not change: a **separate** listener speaking newline-delimited
JSON. Live reasons, both still true:

- No second HTTP parser (Calix spends ~900 lines before its first tool).
- `HookEventReceiver` is deliberately untokened — a `/bin/sh` + `curl` script
  posts to it. Bolting a tokened `/mcp` route onto an untokened server is how a
  token gets accidentally bypassed.

### 3. `ScriptTrust` does not fit the trust gate (spec §"Trust gate")

The spec says to route the IPC enable through `ScriptTrust.isApproved` and reuse
`ScriptApprovalView`. Reading `Sources/Models/ScriptTrust.swift`: its whole API
takes a `ScriptConfig` and fingerprints `source + setup + run + teardown`. An IPC
enable has no command and no source file — using it would mean fabricating a
`ScriptConfig`.

`CLAUDE.md`'s invariant is specifically about *repository-provided commands*, and
an IPC enable is not one. So: a dedicated `atelier.agentIPC` setting (off by
default) with its own confirmation copy in Settings, and a separate
`atelier.agentIPCNudge` for the injection capability. The spec's substantive
point — messaging and injection are separately switchable, both off by default —
is kept; only the mechanism changes.

### 4. Harness scope: Claude Code only for v1

`CodingHarness` is `claudeCode | opencode`; there is no `cursor-agent`, so the
spec's "Minimum path" does not apply as written. v1 wires Claude Code via
`--mcp-config` in `buildClaudeCommand()` (`Sources/Views/TerminalContainerView.swift:542`,
already assembling flags through `CommandBuilder`). opencode is a follow-up;
precedent for its config lives in `OpencodePluginInstaller` and
`Resources/Scripts/atelier-opencode.js`.

### 5. Build wiring trap

The app target is `path: Sources, excludes: [Launcher]`. A new
`Sources/MCPHelper/main.swift` would be compiled **into the app** and collide with
its entry point. `MCPHelper` must be added to that `excludes` list, the way
`Launcher` is. The `AtelierMCP` tool target mirrors `AtelierRun`: explicit
`includes` of only the model files it needs, `PRODUCT_NAME: atelier-mcp`, a
`dependencies: - target: AtelierMCP` on the app, and copy+codesign lines into
`Contents/Helpers/` alongside `atelier-run`. `xcodegen generate` after.

## Status

All six steps are implemented on `feat/agent-ipc`, one commit each. Suite: 512
tests, 0 failures.

Verified against a running app, not just in tests: enabling `atelier.agentIPC`
brings up the listener and writes `ipc.json` at 0600; the bundled `atelier-mcp`
registers and lists peers through it; and a real headless
`claude --mcp-config … --strict-mcp-config` session loaded `atelier-ipc` and
called `register_peer` and `list_peers`.

**Not exercised end to end:** the terminal nudge itself. Its policy — who may be
interrupted and when — is a pure function with tests, but the injection needs a
live Ghostty surface with an agent sitting at a prompt, which no test can stand
up. Turn on **Nudge idle agents**, message a workstream whose agent has finished
its turn, and watch what lands.

## Order of work

1. **`IPCStore` + tests.** Port `Calix/Features/IPC/IPCStore.swift` (375 lines)
   and `CalixTests/IPC/IPCStoreTests.swift` (1367 lines) nearly as-is. Pure
   logic, no app, no transport.
2. **`IPCServer` + `atelier-mcp` helper, one tool (`list_peers`).** The whole
   transport risk; prove the round trip before adding a second tool.
3. **Config writing + `--mcp-config`.** Written to
   `~/Library/Caches/atelier/mcp/<workstream-id>.json` (file path, not inline
   JSON — `LaunchLogger` records `finalCommand` verbatim and the token must not
   land in a log). `--strict-mcp-config` stays off by default.
4. **Mailbox tools, pull-only.** `register_peer`, `send_message`,
   `receive_messages`, `broadcast`, `get_peer_status`. Working feature, no teeth.
5. **Settings + trust gate.** `atelier.agentIPC`, same-project by default.
6. **Terminal nudge**, gated on `WorkstreamAgentStateTracker.state(for:) == .idle`
   and on the peer being the Agent surface, behind `atelier.agentIPCNudge`. Uses
   the spec's two-stage deferred synthetic Return — a trailing `\n` in a paste is
   not reliably Return under bracketed paste. That Ghostty fact is unaffected by
   any of the deltas above.

Steps 1–4 give a working IPC whose worst failure mode is an unread message.
Step 6 is the only one that can inject text into another agent's session, and it
is correctly last.
