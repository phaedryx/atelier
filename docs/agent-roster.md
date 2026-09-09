# Agent Roster — Architecture

The sidebar shows live agent status per workstream: under each row's name a
status line carries the main agent's state, current activity, and context
meter — and while subagents are running, a compact roster of two-line mini
cards under the row shows who is doing what right now. The main agent is not
listed in the roster; everything it does is visible on the row itself.

## How it works

Claude Code fires **hooks** at lifecycle events (tool use, session stop,
subagent spawn). A shell script bundled in the app forwards these events to a
local HTTP listener in the Swift app, which routes them to the workstream's
roster in `Workstream.AgentStateTracker`.

```
Claude Code hooks (settings.json)
  → atelier-hook (shell script, reads stdin JSON + CLAUDE_PROJECT_DIR env var)
  → curl POST http://127.0.0.1:{port}/hook
  → HookEventReceiver (NWListener, Swift)
  → AtelierApp.onEvent → HookEventRouter (fan-out) + Workstream.AgentStateTracker.handle
  → Sidebar: status line on the workstream row + WorkstreamAgentRosterView cards
```

## Hook registration

On app launch, `HookInstaller` writes entries into `~/.claude/settings.json`
for these events:

| Hook Event | What it means | AgentEvent | Sidebar effect |
|---|---|---|---|
| `PreToolUse` | Agent is about to use a tool | `agentToolStart` (+ activity) | Run's activity text updates |
| `PostToolUse` | Tool execution finished | `agentToolDone` | Activity cleared |
| `Stop` | Main agent finished its turn | `agentIdle` | Main run ends: activity line and context meter leave the row; blue "finished" ring if unselected |
| `UserPromptSubmit` | User sent a message | `agentWaiting` | Main run starts (working ring on the row) |
| `SubagentStart` | Subagent spawned | `agentCreated` | New roster card for the subagent |
| `SubagentStop` | Subagent finished | `agentRemoved` | That roster card removed |
| `Notification` | Permission prompt / idle nudge | `agentStatus` | Orange permission ring + badge |

Each hook entry uses `type: "command"` pointing to the bundled `atelier-hook` script.

Every payload also carries the session's `transcript_path`; the tracker reads
context-window usage from its tail (see [Context window usage](#context-window-usage)).

## Port discovery

The HTTP listener binds to `127.0.0.1` on a dynamic port (OS-assigned via port
0). The actual port is written to `~/Library/Caches/atelier/hook-port`.
The `atelier-hook` script reads this file to know where to POST. If the file doesn't
exist (app not running), the script exits silently.

## Multi-workstream routing

There is a **single** HTTP listener shared across all workstreams.
`AtelierApp` feeds every event through two consumers:

1. `Workstream.AgentStateTracker.handle(projectDir:event:)` — resolves the
   payload's `project_dir` to a workstream UUID via `workstreamLookup`
   (rebuilt by `ContentView` whenever the project list changes) and updates
   that workstream's roster.
2. `HookEventRouter.route(projectDir:event:)` — fan-out for any additional
   registered handlers (none today; kept for future features).

Unknown `project_dir`s (Claude sessions outside tracked worktrees) are ignored.

Path normalization resolves symlinks and standardizes the path
(`Workstream.AgentStateTracker.normalize`) so hook payloads and stored
worktree paths match.

## Key files

| File | Role |
|---|---|
| `Resources/Scripts/atelier-hook` | Shell script invoked by Claude Code hooks. Reads stdin JSON, wraps with `CLAUDE_PROJECT_DIR`, POSTs to localhost. |
| `Sources/PixelAgents/HookEventReceiver.swift` | NWListener singleton. Parses HTTP POST, maps hook events to `AgentEvent`, derives activity strings from tool name + input, attaches `transcript_path`. |
| `Sources/PixelAgents/HookEventRouter.swift` | Singleton registry routing events by normalized path. |
| `Sources/PixelAgents/HookInstaller.swift` | Idempotent install/uninstall of hook entries in `~/.claude/settings.json`. |
| `Sources/PixelAgents/AgentEvent.swift` | Event model: `agentCreated`, `agentRemoved`, `agentStatus`, `agentToolStart`, `agentToolDone`, `agentIdle`, `agentWaiting`. |
| `Sources/PixelAgents/TranscriptContextReader.swift` | Extracts context-window usage from Claude Code transcript tails. |
| `Sources/PixelAgents/ContextLimits.swift` | Resolves the context-window limit (200k default, 1M extended) from the transcript model plus the harness model selection. |
| `Sources/PixelAgents/ClaudeCodeSettings.swift` | Reads Claude Code's `model` selection out of its settings files — the only place the `[1m]` marker survives. |
| `Sources/Models/WorkstreamAgentStateTracker.swift` | Per-workstream roster + row-level state machine + stall sweep + live-session tracking + context usage. |
| `Sources/Views/WorkstreamAgentRosterView.swift` | Subagent mini cards under each workstream row. |
| `Sources/Views/ContextMeter.swift` | Context-window meter (bar + percentage) shared by the row and roster cards. |

## Row-level states (`AgentRunState`)

Under the workstream name, a status line pairs a 5pt dot with the state
word (`WorkstreamRow.statusMeta`). One color drives both:

| State | Status line | Trigger |
|---|---|---|
| `.idle` (live session) | Secondary gray · "Idle" | No active turn, but ≥1 hook event seen since app launch |
| `.idle` (dormant) | Not rendered | No active turn and no agent activity this launch |
| `.working` | Blue · "Working" | `UserPromptSubmit`, tool activity after a permission grant |
| `.stalled` | Yellow · "Stalled" | No hook events for 45s mid-turn (swept every 15s) |
| `.needsAttention(.permission)` | Orange · "Waiting for approval" | Notification hook reports a permission prompt |
| `.needsAttention(.justFinished)` | Green · "Done" | `Stop` on an unselected workstream; cleared by `markSeen` when selected |

Whether an idle workstream counts as "live" comes from
`Workstream.AgentStateTracker.liveSessionIDs` — an in-memory set of
workstreams that saw any agent event this app launch. It is deliberately
not persisted: a workstream nobody touched today renders dormant regardless
of past sessions.

An invalid worktree path overrides all of the above: the name is struck
through and dimmed, and an orange warning triangle leads the row. That
marker is the row's only leading element — a healthy workstream reserves no
space for it.

## Roster lifecycle

- A run exists exactly from its create event (`UserPromptSubmit` /
  `SubagentStart`) to its stop event (`Stop` / `SubagentStop`) — no artificial
  collapse timers.
- The roster lists **subagents only**. The main agent's status dot, current
  activity line, and context meter render on the workstream row itself
  (`WorkstreamRow`), so no information is duplicated.
- Each live subagent renders as a two-line mini card: the agent name on the
  first line and its own status line on the second (blue while working,
  yellow when stalled, then the current activity and elapsed time).
- The trailing side of a card shows, in order of precedence: **"Stalled"**
  (orange label) → **context-window meter** (when the harness reports per-run
  usage) → **elapsed time** since the run started.
- At most 4 cards render inline; extras collapse into "+N more".
- Clicking a card selects the workstream and focuses its Coding Agent tab.
- Removing/archiving/purging a workstream calls `clear(workstreamID:)` so no
  stale state lingers.

## Context window usage

How full the agent's context window is, shown as a small meter.

Every Claude Code hook payload carries `transcript_path`. On main-agent
events the tracker re-reads the transcript through `TranscriptContextReader`.
Transcripts are append-only JSONL, so only the last 256KB is parsed; the
reader takes the *last* assistant entry carrying `message.usage` and sums
`input_tokens` + `cache_creation_input_tokens` + `cache_read_input_tokens`.
Reads are throttled to one per 5 seconds per workstream — except at turn end
(`Stop`), where the read is forced so the final totals always land. A failed
read keeps the previously known value.

Limits come from `ContextLimits`: 200k tokens by default, 1M for an
extended-context session. Deciding which takes **two** signals, because
neither is enough on its own:

- `message.model` in the transcript is the *resolved* model. Claude Code
  writes `claude-opus-5` whether or not the 1M beta is on — the `[1m]` marker
  appears in no transcript it has ever written — so this can confirm an
  extended window (a harness that does spell it out) but never rule one out.
- The `model` *selection*, which is where `[1m]` survives:
  `ClaudeCodeSettings.configuredModel(cwd:)` reads it from
  `<projectDir>/.claude/settings.local.json`, then
  `<projectDir>/.claude/settings.json`, then `~/.claude/settings.json`. That
  mirrors what Claude Code itself does — its window size is `/\[1m\]/i` tested
  against the selected model string. `projectDir` is the hook's
  `CLAUDE_PROJECT_DIR`, the same root Claude Code resolves project settings
  from, not the transcript's `cwd`, which follows the session around.

The selection is global, so it only widens the window when it names the same
*family* as the model the transcript recorded — otherwise one Haiku workstream
would inherit a 1M window from an Opus selection. Family rather than plain
containment because `opusplan` is Opus in plan mode while being a substring of
no resolved Opus ID; an unrecognised family falls back to containment either
way. A `--model` flag or `ANTHROPIC_MODEL` in the session's own environment is
invisible from outside the process; for those, usage past 200k is taken as
proof the window is the larger one.

The main session's meter shows on the workstream row itself (visible while
the main agent is working or stalled), reading the transcript-derived figure
(`Workstream.AgentStateTracker.mainContextUsage(for:)`). Subagent roster cards
carry no meter — Claude Code hooks report no per-run token figures. The meter
itself is a bar plus a "133k · 13%" label: gray below 60% of the window,
orange below 85%, red at 85% or more — and orange/red regardless of the
window past 200k/300k absolute tokens, where response quality decays even
on a roomy one (`ContextMeter`).

## Testing

Everything here is covered by XCTest: `HookInstallerTests` for the
`settings.json` merge (idempotency, foreign hooks, malformed input),
`HookEventReceiverTests` for the receiver, and
`WorkstreamAgentStateTrackerTests` for roster transitions. Run them with
`./scripts/dev.sh test`.

For an end-to-end check, run the app, open a workstream, and confirm roster
cards appear while subagents are live.

## Troubleshooting

**No roster appears:** Check that hooks are installed:
```bash
cat ~/.claude/settings.json | python3 -m json.tool | grep atelier-hook
```

**Port file missing:** The app writes `~/Library/Caches/atelier/hook-port`
on startup. If it's missing, the receiver failed to bind — check Console.app
for `atelier:hook-receiver` logs.

**Wrong workstream:** The hook's `CLAUDE_PROJECT_DIR` must match the stored
worktree path (e.g. `~/.atelier/worktrees/project/workstream-name`). Watch routing logs:
```bash
log stream --predicate 'subsystem == "atelier"' --info | grep -i hook
```
