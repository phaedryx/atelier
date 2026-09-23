# Agent status, hooks and the context meter

Everything Atelier infers about a running Coding Agent, and the channel it infers
it from. Silence is the only raw material, so most of this is about what silence
is allowed to mean.

### Agent status: silence, and what it is allowed to mean

Every signal Atelier has about an agent comes from a Claude Code hook, and no hook fires
*during* anything. `PreToolUse` fires when a tool starts and nothing else arrives until
`PostToolUse`; between two tool calls the model can generate for a minute with no hook at all.
So **silence is the app's only raw material, and silence is ambiguous** — a build, a long
response, a slow MCP call and a wedged agent are indistinguishable from the outside.

`Workstream.AgentStateTracker.sweepForStalls` therefore reads silence in two stages, and the
distinction is the whole point:

| | `silenceThreshold` (45s) | `wedgeThreshold` (300s) |
|---|---|---|
| Renders | **nothing** — the row stays Working | `.stalled`, the yellow dot |
| Does | asks `HookChannelProbe` whether events are still arriving | reports a wedge |

The 45-second mark used to set the yellow dot directly. That was wrong far more often than
right, because everything in the first sentence of this section passes 45 seconds routinely.
The question 45 seconds of silence actually raises is *whether the app is still listening*, and
no amount of further silence answers it — only the probe can.

Three exemptions keep the 300s tier honest, and each has a bound:

- **A tool in flight** (`AgentRun.isRunningTool`, set between `PreToolUse` and `PostToolUse`).
  This is the one the original complaint was about. Tracked separately from `activity` because
  `activity` is display text and may be nil for a tool the mapper had no phrase for; the sweep
  needs the fact.
- **Compaction** (`isCompacting`), which emits nothing between `PreCompact` and `PostCompact`.
- **A permission prompt**, which is waiting on the user, not stalling.

The first two are bounded by `longWorkGrace` (1800s), which must stay larger than
`wedgeThreshold` or it never binds. The bound exists because the event that would *lift* the
exemption may never arrive — the agent died mid-tool, or the POST carrying it was dropped — and
a missing end-event must not suppress the sweep for the rest of the session.

**`HookEventReceiver.isMetaTool` is consulted by both `PreToolUse` and `PostToolUse`, and that
is not an accident.** The two hooks bracket a running tool, and a bracket that opens without
closing — or closes without opening — is worse than no bracket. `mcp__*` was once filtered on
the `PreToolUse` side only, so an MCP call reported nothing going in and a stray `toolDone`
coming out; the sweep saw a silent agent with no tool in flight and had nothing to exempt,
which is why a slow MCP server read as a wedge. MCP calls are ordinary tool calls, frequently
the slowest, and belong inside a bracket. Only `Skill` and `ToolSearch` are filtered, on both
sides.

### The hook channel is checked, not assumed

`HookChannelProbe` answers the one question absence cannot: **are hook events arriving at all?**

`Resources/Scripts/atelier-hook` posts with `curl -s --max-time 1 -o /dev/null 2>/dev/null` and
exits 0 when the port file is missing. **Every channel failure is therefore silent by
construction** — an app that relaunched on a new port, a removed port file, hook entries another
Atelier install rewrote, or a POST that simply took longer than a second under load. All of them
render identically to a busy agent.

So the probe does not reason about silence. It writes a real payload to the real script's stdin
(`{"hook_event_name": "AtelierPing", "nonce": …}`, which the script wraps as `event_input` like
any hook event) and waits for that nonce to come back out of `HookEventReceiver.onPing`. A nonce
that returns has proved the whole path end to end: port file, curl, its timeout, the listener,
the parser. Calling the listener directly would prove only that the app can reach itself.

Facts worth keeping:

- **The ping produces no `AgentEvent`.** It is answered before `mapHookEvent`. An envelope that
  touched a roster would reset the very stall clock the probe was sent to explain, making the
  probe's own traffic the reason the channel looked healthy.
- **Real traffic is better evidence than a ping, and free.** Any delivered hook event calls
  `noteTraffic`, which verifies the channel, cancels a check in flight, and clears `.down` the
  moment events resume rather than at the end of the debounce. It runs on *every* event, so
  `State` deliberately carries no timestamps and `markVerified` publishes only on a transition —
  a date in the published state would invalidate the sidebar on every tool call. The timestamps
  live beside it, unpublished.
- **Two attempts, not one.** `curl --max-time 1` drops a slow POST, so a single unanswered ping
  is expected and must not repaint anything.
- **One rendezvous, and only its named owner may delete it.** `~/Library/Caches/atelier/hook-port`
  is deliberately outside `AppConstants.cacheDirectory` (`HookEventReceiver.writePortFile`), so
  debug and release share it and the last launch wins. Taking it is unconditional; giving it up is
  not. `stop()` used to unlink the file on quit whatever it held, so quitting a worktree's debug
  build deleted the *running* release app's port — and because `atelier-hook` exits 0 when the
  file is missing, that silenced hooks for every Claude Code session on the machine. The surviving
  app's probe reported "No Signal" and was right, with nothing able to say why. `removePortFile`
  now removes the file only when it still names that instance's own port
  (`HookEventReceiver.ownsPortFile`, pinned in `Tests/HookEventReceiverTests.swift`). The
  comparison is exact on the trimmed contents; a prefix match would read `607980` as `60798`.
  Overwriting on launch is untouched and still starves every other instance of events — that is
  the one-rendezvous decision, not this bug.
- **Checked at launch and on suspicion, never on a timer.** Launch (forced, past the debounce)
  is where a botched install or stale port file is most likely and most fixable; after that only
  when the sweep reports prolonged silence, debounced to `minimumInterval`. A healthy app spawns
  nothing. The sweep calls through `AgentStateTracker.onProlongedSilence` rather than the
  singleton, so the sweep stays testable and the tracker keeps knowing nothing about how the
  channel gets checked.
- **A listener that ends rebuilds itself, because nothing else would.** `AtelierApp` calls
  `HookEventReceiver.start()` exactly once, at launch, and `setupListener` guards on
  `listener == nil` to stay idempotent — so when `.failed` cancelled the listener and left that
  property pointing at the dead object, every later `start()` was a no-op and hook delivery was
  over for the session. The probe reported "No Signal" correctly and nothing could act on it.
  `listenerEnded` clears the property on both terminal states and re-listens, bounded at five
  attempts backing off 1s→16s and reset on every `.ready`: a listener that cannot bind loopback
  will not start working because it was asked a hundredth time, and an unbounded timer is worse
  than the honest "No Signal". Three things hold it together — it is **identity-guarded**, since
  `stop()` clears the property itself and a `start()` may already have installed a replacement
  by the time the old listener's `.cancelled` lands; it releases the port file **before**
  clearing `currentPort`, the order `stop()` takes, because `removePortFile` only removes a file
  still naming this instance's port; and `wantsListener` separates a deliberate `stop()` from a
  listener ending on its own, so a retry scheduled just before a quit cannot take the rendezvous
  from an instance that is still running.

**Two surfaces, not one, and the second is not redundant.** `HookChannelBanner` sits in the
sidebar's bottom bar, gated on the probe's verdict and *nothing else*. A row only draws a status
line once `hasLiveSession` is true, and `liveSessionIDs` is only populated from `handle` — so a
channel that was already broken when the app launched leaves every row silent and would have had
nothing to speak through. `ensureSweepTimer` is called from `handle` too, so in that same case
the sweep never runs and `onProlongedSilence` never fires either: the forced launch check is the
only one that happens, and the banner is the only thing that can show it. Dropping the banner as
"redundant with the row word" is the mistake to avoid — it removes the surface for exactly the
case the probe exists to catch.

**`AgentStatusLabel` decides what a row may claim, and `channelDown` masks `.working` and
`.stalled` — nothing else.** Those two are held up by the *continued arrival* of events: "still
working" means no `Stop` has come in, and `.stalled` is inferred from absence outright. Neither
survives learning that the app has stopped hearing, so both become **No Signal** (grey, because
the fault is Atelier's own plumbing and nothing is asked of the user). The rest are positive
facts a delivered hook established, and losing the channel afterwards does not unmake them —
masking `.needsAttention(.permission)` would be the worst of it, since the agent is stopped
until someone answers. `AgentStatusLabel` also exists because the row and the roster cards had
already drifted: the row grew a permission state and a live-session-aware idle that the cards
never learned.

### System prompts

The Coding Agent receives additional system prompts via `--append-system-prompt` based on
user settings. Prompts are defined in `Sources/Models/SystemPrompts.swift` and assembled in
`Workstream.AgentCommand.systemPrompt` (`Sources/Models/AgentCommand.swift`), which
`TerminalContainerView.buildClaudeCommand()` calls for the Coding Agent tab and the
`open_agent_tab` tool calls for a tab it is about to spawn. It lives there rather than in the
view because there are now two callers and the *gating* is what they must agree on — a second
copy would drift on exactly the condition below.

**Important**: Claude Code only accepts a single `--append-system-prompt` flag per invocation.
Multiple flags do not stack; the last one wins. When multiple prompts are active, they must be
concatenated into a single string before passing to the CLI.

Active prompts (combined when multiple are enabled):
- **Restrict to worktree** (default: on, setting: `atelier.allowOutsideWorktree`): constrains file writes to the worktree directory.
- **Auto-rename branch** (setting: `atelier.autoRenameBranch`): renames the git branch to match the task on first request.
- **Agent IPC** (default: off, setting: `atelier.agentIPC`): tells the agent it has
  peers and how to reach them through the `atelier-ipc` MCP server. This one is
  **not** gated on the setting directly — it is gated on `IPC.Config.write`
  having returned a path, the same condition that adds `--mcp-config`. An agent
  told it has peers but handed no server would call tools that do not exist, so
  the prompt and the config must appear and disappear together. Keep any new
  gate on the written config, not on the setting.

There are three, and the list above is the whole of it. Two of them were once the
whole of it, which is why `SystemPrompts.swift` is worth reading before assuming.

### Where the context meter's numbers come from

The sidebar's context bar has two possible sources and they are not equal.

**The status line is the first choice.** Hook payloads carry no token or context
fields at all — `session_id`, `transcript_path`, `cwd`, `permission_mode`, the
event's own fields, and that is the whole documented set. Claude Code hands the
figures to exactly one interface, the status line command, which receives
`context_window.total_input_tokens` and `context_window.context_window_size`
already resolved, the second including whether the session is on a 1M window.
That single field is why this channel exists: `ContextLimits` can only *infer*
the window from a model string plus `ClaudeCodeSettings.configuredModel`, and it
is not consulted at all on this path.

**`statusLine` is a single command slot, so Atelier never writes it.** Unlike
`hooks`, which is a list Atelier merges an entry into, that key holds one
command — registering into it means taking it from whatever the user has.
Instead `StatusLine.Config.write` produces a settings file naming
`atelier-statusline`, and the agent is launched with `--settings <path>`
alongside the `--mcp-config` it already gets. That layer sits above user
settings, merges per key, lasts one session and writes to no file, so a Claude
session started anywhere else is untouched. The file carries `statusLine` and
nothing else, because a second key there would silently override the user's own
value for it.

Four consequences worth keeping:

1. **No configured status line means no registration**, and that session falls
   back to the transcript. Registering one anyway would give a user a status
   line they never asked for: Claude Code hides most of the footer's keyboard
   hints as soon as one is configured, and a script that prints nothing leaves
   the row blank. `ClaudeCodeSettings.statusLineCommand` is the gate, and it
   reads only `type: "command"` — an unrecognised shape has to mean "leave it
   alone", never "there is nothing there".
2. **The user's own status line is chained, and resolved at launch.**
   `atelier-statusline` POSTs the payload, then runs the command it was handed
   as `$1` with the same stdin and prints its output verbatim. The command is
   resolved in Swift when the agent starts rather than re-read on every render,
   because a `sh` script has no JSON parser — the same call `atelier-hook` makes
   by taking a flag instead of sniffing its own stdin. The cost, and it is real:
   a `/statusline` change reaches a running agent only when its surface
   respawns.
3. **Only the main session's reading is taken.** `open_agent_tab` registers
   the status line for the agent it spawns too, and two agents in one worktree
   report the same `project_dir` — so `handleStatusLine` drops a payload whose
   surface id is not the workstream's own, the same restriction the transcript
   path gets from `event.agentId == "main"`. The comparison is on `UUID` values,
   never on the strings: `ATELIER_SURFACE_ID` is exported uppercase and the
   workstream id is written lowercase, so comparing text would reject every real
   Coding Agent tab. A payload with no surface id at all is a session started by
   hand in the worktree and is taken.
4. **A status line reading does not mark a session live.**
   `AgentStateTracker.handleStatusLine` sets `contextUsage` and deliberately
   does not touch `liveSessionIDs`, the roster, or any stall clock. The status
   line renders on a timer as well as on a turn, so it is not evidence that an
   agent is alive in the sense the row's status word means — and `hasLiveSession`
   is what decides whether a row may speak at all, which `HookChannelBanner`
   depends on.

**The transcript is the fallback and stays one.** `TranscriptContextReader`
parses `message.usage` out of the JSONL tail, which works, but Claude Code's own
documentation says that entry format is internal and changes between versions.
`refreshContextUsage` returns early for a workstream whose source is already
`.statusLine` — before the throttle and before the read, since this is a channel
that has been superseded rather than an attempt to retry. It also logs a missing
or unreadable transcript on the *edge* only: the read is deliberately retried on
every hook event until it succeeds, so an unconditional line there would be one
per tool call for the whole life of the session it is meant to make
diagnosable.
