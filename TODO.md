# TODO

## Pre-release

- [x] App screenshots on website (agent, environment, info, terminal, browser, project)

## Post-release

- [ ] Auto-update mechanism (Sparkle): in-app update for direct DMG users

## Bugs

- [x] Branch name doesn't appear in sidebar after workstream creation until the 15s refresh timer fires. Fixed: call `refreshPathValidity` immediately in the `.workstreamWorktreeReady` handler.

## UI improvements

- [x] Sidebar workstream rows: removed repetitive terminal icons, kept warning icon only for invalid paths
- [x] Sidebar workstream subtext: show PR title (#number) when available, fall back to branch name only when it differs from the workstream name

## Future

- [ ] Agent roster avatars for more agent types: drop 64x64 `avatar_<type>_<k>.png` files in `Resources/AgentSprites/` (claude/plan have 1 sprite each; explore/generalpurpose have 4 each — sets cycle automatically; see docs/agent-roster.md)
- [ ] External Chrome integration: launch with --remote-debugging-port for WebMCP/CDP
- [ ] PR management: create and manage PRs from workstreams (currently view-only)
- [ ] Horizontal terminal splits within a tab (ghostty C API supports splits)
- [ ] System notifications when agent needs attention (bell/urgency from Ghostty)

## Done

- [x] Embedded Ghostty terminals (Metal GPU-rendered via libghostty)
- [x] Project and workstream management with sidebar tree
- [x] Git worktrees for workstreams (branch off default branch)
- [x] .env/.env.local symlinks in worktrees (guarded by setting)
- [x] Tmux mode for Coding Agent session persistence
- [x] Claude session resume via --session-id/--resume
- [x] Auto-respawn agent on process exit (tmux pane-died hook)
- [x] Auto-rename branch via --append-system-prompt
- [x] Per-workstream permission mode (bypass prompts, context menu on +)
- [x] Agent Teams setting (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS)
- [x] Deterministic port allocation per workstream (ATELIER_PORT env var, DJB2 hash)
- [x] Dynamic workspace tabs (Info + Agent + Environment, Terminal/Browser on demand)
- [x] Terminal tabs auto-close on shell exit, agent respawns
- [x] Multi-terminal support with proper Ghostty focus management
- [x] Embedded WKWebView browser with nav bar, loading indicator
- [x] Cmd+L address bar focus, auto-focus on new browser
- [x] PR badge in workspace toolbar (links to GitHub PR)
- [x] Info tab with README.md, CLAUDE.md, AGENTS.md (cmark-gfm WKWebView, skip files < 20 bytes)
- [x] Doc tabs in project overview (shared DocFile/DocTabButton)
- [x] GitHub integration: repo info, open PRs, branch PR status (via gh CLI)
- [x] Keyboard shortcuts: all documented in HelpView, README, AGENTS.md, and website
- [x] Help view with app icon, skyline, shortcuts, credits, sponsor/bug/feature links
- [x] Settings: environment, CLI install (auto-hidden), tmux, bypass, teams, auto-rename, appearance, language, base dir, branch prefix, external apps, bleeding edge, danger zone
- [x] Project overview with editable name, git info, GitHub info, worktree list with prune, doc tabs
- [x] Workstream info with project icon, branch copy, directory, PR status, scripts, docs
- [x] Drag-and-drop directories to sidebar
- [x] atelier:// URL scheme for single-instance behavior
- [x] CLI launcher (ff) installed via Homebrew cask binary directive
- [x] Auto-generated workstream names (operation-adjective-component)
- [x] Workstream name syncs from branch rename (every 15s)
- [x] Sidebar state persisted across restarts (JSON files in ~/.config/atelier/)
- [x] Async git repo info, path validity, branch names (parallelized via TaskGroup)
- [x] Auto-remove projects with missing directories (with user notification)
- [x] Worktree path validation with visual feedback
- [x] Archive warning for uncommitted changes
- [x] Workstream sorting in project view (recent / A-Z)
- [x] Localization: en only (other locales dropped; strings still go through `Localizable.strings`)
- [x] Script config: .atelier.json
- [x] Environment tab: setup (auto) / run (on-demand) with Rebuild and Start/Rerun shortcuts
- [x] Port detection: atelier-run launcher with libproc process tree scanning and auto browser retarget
- [x] Tmux session restore for run scripts on app relaunch
- [x] Preload agent and setup terminals in background
- [x] Occlude non-visible terminal surfaces (ghostty_surface_set_occlusion)
- [x] Update notification: versions.json check + sidebar badge + /get page
- [x] App icon with Poblenou skyline
- [x] Project icon detection (icon.svg, icon.png, logo.svg, logo.png)
- [x] Ghostty submodule pinned to v1.3.1, weekly CI compatibility test
- [x] Code signing, notarization, tag-driven release CI pipeline (security hardened)
- [x] Homebrew tap (phaedryx/homebrew-tap) with cask and CLI binary
- [x] Website: Hugo + Tailwind, i18n (4 langs), sponsor page, privacy, SEO, OG image, /get page
- [x] Distribution: docs/distribution.md with automated versions.json in release workflow
- [x] Onboarding view with prerequisites, getting started, key concepts
- [x] Sentry crash reporting (EU, no PII, environment/version tags)
- [x] Swift 6 strict concurrency migration
- [x] Security: WKWebView JS disabled, shell-escape tmux, surface destroy, git flag injection, .env symlink validation
- [x] Accessibility: labels, focus rings, keyboard-reachable hover actions
- [x] Code quality: dedup, parallelized git, cached state, consolidated timers, error propagation
- [x] Error feedback: worktree creation, non-git dir, ghostty init, project removal, Claude not found
- [x] Fix: terminal mouse selection coordinates, env script lifecycle, proc_listchildpids count
- [x] Restore full app state on launch, right-click sidebar menus, drag-and-drop tab reorder

## Multi-harness support (Claude Code + OpenCode)

- [x] CodingHarness enum with per-workstream harness selection and backward-compatible decoding
- [x] OpenCode plugin auto-installer (status events, session tracking, instructions injection)
- [x] Per-harness agent command building (resume/--session, --auto bypass, tmux wrapping)
- [x] Harness picker in new-workstream sheet, global default setting, sidebar badges
- [x] Switch-harness context menu with surface teardown + tmux kill
- [x] OpenCode GitHub quick actions (opencode run -c --fork)
- [x] OpenCode subagent roster: child-session name map + `agent_info` events (agent type, model attribute on roster lines), `session.status`, subtask spawn signal, sprite aliases for build/general/ask
- [x] OpenCode quick-action output parsed from `--format json` stream into a summary + PR link; raw JSONL collapsed behind disclosure
- [x] Fixed: quick-action forks hijacked `.atelier-state/opencode-session` (sentinel file makes the plugin ignore quick-action subprocesses)
- [ ] Future harnesses (e.g., Codex): add enum case + command builder branch + event mapper

## Agent IPC follow-ups

- **opencode support.** v1 wires Claude Code only, via `--mcp-config` in
  `buildClaudeCommand()`. opencode reads MCP config from a file; the precedent
  for writing one is `OpencodePluginInstaller` and `Resources/Scripts/atelier-opencode.js`.
- **The nudge is unexercised.** `AgentNudge.shouldNudge` is tested; the injection
  path (`sendText` + two-stage synthetic Return) needs a live surface and has
  only been reasoned about. Watch the first real delivery.
- **Cross-project messaging.** Peers are scoped to the caller's project with no
  way to opt out. If that ever becomes a real need, it wants its own louder
  switch, not a widening of `atelier.agentIPC`.
- **The helper does not reconnect.** If Atelier restarts while an agent is
  running, its `atelier-mcp` keeps the dead socket and every tool call returns
  "Atelier closed the IPC connection" until the agent restarts. The error is
  honest, but a single reconnect attempt in `IPCBridge.call` would fix it.
- **Peer contexts are pruned only by `list_peers`.** A peer that expires while
  nobody lists gets its `IPCService` context held until the next call. Harmless
  today — the store's own liveness check still rejects the peer — but it is a
  slow leak in a long session.
