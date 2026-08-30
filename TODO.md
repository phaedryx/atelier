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

- [ ] External Chrome integration: launch with --remote-debugging-port for WebMCP/CDP
- [ ] PR management: create and manage PRs from workstreams (currently view-only)
- [ ] Horizontal terminal splits within a tab (ghostty C API supports splits)
- [ ] System notifications when agent needs attention (bell/urgency from Ghostty)
- [ ] WorkspaceModel retains both Monaco WebViews (editor + diff bridges, ~17 MB each) for every
  visited workstream until it is archived — Changes is a fixed tab, so most visited workstreams pin
  one. Deliberate (it is what makes unsaved editor content survive navigation), but unbounded: add an
  eviction policy (e.g. drop bridges for non-active workstreams after a while and recreate lazily).

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
- [x] Settings: environment, CLI install (auto-hidden), tmux, bypass, teams, auto-rename, appearance, language, base dir, branch prefix, external apps, danger zone
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

## Coding agent

- [x] Claude Code command building (resume, bypass, tmux wrapping)
- [x] Removed OpenCode support and the `CodingHarness` abstraction with it.
      Claude Code is assumed everywhere; a workstream no longer stores which
      agent it runs, and blobs that still carry the retired `harness` key load
      fine because the key is simply ignored.
- [ ] A second coding agent (e.g., Codex) means reintroducing the type, not
      adding a case: a per-workstream selection, its own command builder, its
      own event mapper in `HookEventReceiver`, and the selection UI (picker in
      the new-workstream sheet, a default setting, a switch menu).

## Agent IPC follow-ups

- **Other harnesses.** v1 wires Claude Code only, via `--mcp-config` in
  `buildClaudeCommand()`. A second harness needs its own way of receiving the
  MCP config, plus a `source` branch in `HookEventReceiver`.
- **`IPCStore.isAlive` is O(peers x messages) for expired peers.** The TTL check
  returns first, so the inbox scan only runs for peers already past their TTL —
  unreachable at this scale. If IPC is ever reused for something busier, keep a
  set of peers pinned by in-flight messages instead of scanning inboxes.
- **The helper's socket timeout is not covered by a test.** `SO_RCVTIMEO` needs a
  listener that accepts and never answers, and asserting it costs the full
  timeout in suite time. Verified by reasoning and by the unparseable-frame path
  that shares the recovery code.
- **Cross-project messaging.** Peers are scoped to the caller's project with no
  way to opt out. If that ever becomes a real need, it wants its own louder
  switch, not a widening of `atelier.agentIPC`.
- **Peer contexts are pruned only by `list_peers`.** A peer that expires while
  nobody lists gets its `IPCService` context held until the next call. Harmless
  today — the store's own liveness check still rejects the peer — but it is a
  slow leak in a long session.

## Changes review comments

- **Submit Review Comments silently no-ops unless Changes tab is mounted.** The palette command "Submit Review Comments" is gated only on an active workstream; it should check whether the Changes tab is mounted. Proper fix: add a changesActive field to PaletteContext (threaded from the palette presenter), or auto-switch to the Changes tab before submitting.
- **Deletion block at file start can't be clicked to comment.** A deletion block with modifiedStartLineNumber == 0 can't be clicked to open the comment input because the view-zone afterLineNumber clamps to 1 and never matches.
- **Gutter line-number DRAG opens comment instead of range-selecting.** Click a line number should range-select; currently DRAG opens the comment input on mousedown instead. The intended range gesture is text-drag (or select) then click a line number inside the selection.
- **A background refresh (setComments) discards an in-progress comment input, losing typed text.**
- **A refresh starting during a submit's git hop still sends pre-refresh anchors.** `submitReview()` guards on `isRefreshing` up front, but the post-hop checkpoint re-checks only liveness and turn state, so a refresh that begins inside that window sends line numbers the re-anchor is rewriting.
- **Comments are removed when a submit is initiated, not when it lands.** If the agent pane dies inside the ~1s window before the two Returns, `typeAndSubmit`'s liveness check correctly refuses, but the comments are already deleted and the payload was never submitted. Closing this needs a completion signal from `typeAndSubmit` so the delete can wait for it.
- **No automated coverage for the submit path.** `submitReview()` is a private View method with `DispatchQueue` hops, so the guards (busy/liveness re-check, delete-only-what-was-sent) are verified by reading and manual testing. Extracting a `ReviewSubmitter` seam would make them testable.
