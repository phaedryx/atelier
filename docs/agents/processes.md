# Child processes, AppleScript and paths

`ProcessRunner` and its deadline tiers, `AppleScriptRunner`, port detection, and
where Atelier writes on disk.

### Port detection
Run scripts are wrapped in the `atelier-run` launcher binary (bundled at `Contents/Helpers/atelier-run`).
The launcher monitors the child process tree for listening TCP ports using `libproc` and writes
state to `~/Library/Caches/<AppConstants.appID>/run-state/<workstream-id>.json` — see the
**Paths** section below for what `appID` resolves to per build variant, and do not re-spell the
three here, which is how this line came to name only the release one. The app watches these files
via FSEvents and retargets the embedded browser when a port is detected.

### Child processes
Everything that spawns a child goes through `ProcessRunner`, which enforces a
deadline and drains stdout and stderr concurrently. Both halves matter:
`readDataToEndOfFile()` followed by `waitUntilExit()` never returns if the child
hangs, and draining one stream while the other fills deadlocks any child whose
output passes the ~64 KB pipe buffer — reachable for `git fetch` on a
many-branch repository, or any package-manager install.

**Concurrently, and without a single auxiliary thread** — `ProcessRunner.PipePump`
moves stdin, stdout and stderr together in one `poll(2)` loop on the **calling**
thread. The concurrency is not optional: reading stdout to EOF while stderr fills
deadlocks any child whose output passes the buffer, and a stdin payload past that
same buffer blocks the writer until the child reads. What is deliberate is that
none of it costs a thread, and two earlier shapes that bought it with threads
each starved a pool:

- `readDataToEndOfFile()` on two dispatch threads parked both for good whenever a
  grandchild held the write end open — EOF is not the child's to give, and `sh -c
  'server &'` is ordinary in a project's own command. Two per call against
  libdispatch's ~64-thread global pool, and a few dozen calls starved it.
- Replacing those with `DispatchSource` read sources fixed the *leak* and kept the
  *dependency*: the waiter still blocked a thread while the source's event handler
  needed one of its own to deliver EOF. When the callers are Swift `Task`s that
  pool is the cooperative one, `hw.ncpu` wide rather than 64, so the waiters
  consumed the very threads that would have completed them. Measured in 0.2.1: 14
  of 14 cooperative threads parked in `capture`, every child killed at its
  deadline — `tmux -V` blowing a 120s bound, which is the tell, since nothing
  about that child is slow. The user-visible symptom was a workstream stuck on
  "Preparing Coding Agent..." and git operations that had already succeeded on
  disk being reported as failures.

So the invariant is now **a capture pumps its pipes on exactly one thread, the
caller's, consulting no pool** — immunity by construction rather than by having
enough threads, and what `Tests/ProcessRunnerTests.swift`'s two
`ConcurrentCaptures…` tests pin. Do not reintroduce a queue, a source or a
detached drain here, however tidy it looks; the corollary for callers is that the
thread is blocked for the child's whole life, so `capture` belongs off the main
actor and off any pool narrow enough to matter.

State that invariant about the *pump* and not about the whole call, because one
off-thread dependency is left: `exited.wait` is signalled from
`process.terminationHandler`, which Foundation delivers on machinery
`ProcessRunner` does not own. The concurrency test is evidence it is not the
cooperative pool — fourteen captures parked at the exit wait with none to spare
would wedge identically — but that is one width measured, not a proof. The
practical consequence is diagnostic: a capture starved there parks at the *exit
wait*, which is a different stack from the pump and a different bug.

One behaviour change came with it: **writing stdin is part of finishing.** A
payload still unwritten at the deadline now fails the capture, where the abandoned
writer thread it replaced reported success and parked forever. That needs a
payload past the ~64 KB pipe buffer handed to a child that will not drain it, and
`HookChannelProbe` is the only `standardInput:` caller in the app, at a few
hundred bytes — so no caller today can reach it. `PipePump` never closes a
descriptor it did not open — the `Pipe`s own them — with one exception, the stdin
write end, whose close is what gives the child EOF.

**The deadline kills the process group, not just the child.** When the child
exits immediately and leaves a grandchild behind, Foundation has already reaped
the child by the time the deadline fires — `terminate()` has nothing to signal,
and the survivor goes on running. `Process` spawns each child as its own group
leader (`pgid == pid`, measured) and a backgrounded grandchild inherits that
group, so the group is the only handle left on it. Two facts make that safe, and
both were measured rather than reasoned about, because the cost of being wrong
is signalling a stranger:

- **A pid live as a group id is never reissued.** A group was orphaned, then
  ~98,000 forks drove the pid counter a full lap past it (`kern.maxproc` is
  12,000) and the number was never allocated. So `kill(-pid)` after the leader
  is reaped can only reach the group Atelier created; an empty group answers
  ESRCH and nothing happens. `ProcessRunner.kill` also guards `pid > 1`, because
  `kill` reads 0 as "my own group" and -1 as "everything" — and a `Process` that
  never launched reports 0.
- **A daemon is out of reach, which is the wanted behaviour.** Anything calling
  `setsid` leaves the group by definition. The tmux server is exactly that: it
  lands in its own group and survives this (verified), which it must, since it
  is meant to outlive the client command that started it.

Pick a deadline from `ProcessRunner.Timeout` rather than inlining a number:
`local` for reads and ref-level writes, `network` for anything reaching a remote,
`userCommand` for work whose size the user controls, `install` for package
managers, `suite` for a project's own test or lint suite. `suite` is 1800s, the
same bound as `install`, because `userCommand`'s
300s is too short for a real suite — the bound exists to break a wedge rather
than to enforce a pace, and Stop is the real escape for a run that is merely
slow. The distinction that matters is not local-versus-remote but whether the
repository's size sets the duration: `git status` is `local`, while `git worktree
add` checks out a whole tree and goes through `Git.Operations.runOnWholeTree`. Git spawns also set `GIT_TERMINAL_PROMPT=0` and `GIT_ASKPASS`, because
a GUI app has no terminal on which to answer a credential prompt, so the prompt
is itself a hang.

**Three** sites are exempt and say so where they spawn: `BareRepoClone.run`,
`QuickAction.Runner.runShellCommand` and `Whiteboard.Capture.run`. All three run
work with no honest deadline and all three give the user a cancel instead. If you
add a fourth, it needs the same two properties and the same comment.

The third is the one whose cancel is **in band**, and it is worth reading before
concluding that any long-running child qualifies. `screencapture -i` blocks until
the user drags a selection or presses Escape, which is unbounded human time — but
the capture overlay owns the screen while it is up, so there is no Atelier button
left to press. Escape, in the system's own UI, *is* the cancel, and it is the
child's own rather than one this app had to provide. What makes the exemption
cheap rather than a concession is that there is nothing to drain: `screencapture`
writes to a file and prints nothing, so `ProcessRunner`'s pipe pump would buy none
of its value while costing a blocked thread for the length of a human gesture —
exactly the corollary stated above for callers. `terminationHandler` blocks
nothing. A tier would have been defensible (`userCommand`, as a wedge-breaker)
and was rejected for paying that thread to bound something no wedge can reach.

### AppleScript

Everything that runs AppleScript goes through `AppleScriptRunner`, which is to
`NSAppleScript` what `ProcessRunner` is to `Process`: **the source is a constant
and every value travels as an `NSAppleEventDescriptor` parameter to a named
handler**. There are two call sites — `ExternalTerminal.run`, which opens a file
in an editor in Apple Terminal, and `SettingsView`'s CLI install, which runs
`do shell script … with administrator privileges`.

Interpolating into the source is what this replaced, and it is two nested
languages deep: a Swift value lands inside an AppleScript string literal, which
lands inside a shell command. Escaping for one layer looks exactly like escaping
for both, and only the shell layer was ever escaped. A file named
`z" & (do shell script "touch atelier-pwned") & "` closed the AppleScript literal and the
rest **compiled** — verified, along with the everyday half of the same bug: an
ordinary name like `say"hi.txt` produced a script that did not compile at all and
the row silently did nothing. Atelier runs coding agents against cloned
repositories, so every name in a work tree is untrusted input.

The shell layer is closed the same way rather than by a second escaper:
AppleScript's own `quoted form of` does the POSIX quoting **inside** the script,
so no Swift caller assembles a command line either. `CommandBuilder.shellQuote`
is deliberately not used here — it leaves a leading `~` unquoted on purpose,
which is right for the commands it serves and wrong for a file name.

Three things that are easy to undo:

- **A handler called inside a `tell application` block is dispatched to that
  application**, which answers "Can't continue" for a name it has never heard of.
  `ExternalTerminal.runScript` resolves the command *before* its `tell` block for
  exactly that reason. The unit tests do not catch this, because they call the
  command handler directly; only running it against Terminal does.
- **`AppleScriptRunner.run` compiles up front.** `NSAppleScript` otherwise
  compiles lazily on execute and reports a syntax error as an execution failure,
  hiding the one failure mode that is always a bug in Atelier's own constant
  source.
- **Failures are logged, never swallowed.** `runLoggingFailure` exists because
  discarding the error dictionary is precisely how the escaping bug presented —
  as ordinary files quietly failing to open.

`ExternalTerminal` also owns opening a *directory* in the user's terminal, which
is an `NSWorkspace` call carrying a `URL` and has no injection to speak of. It
lives there because the same eight lines had been copied into four views, and a
fifth copy is how the hardened path above eventually gets worked around.

### Paths
- Persistent data: UserDefaults (projects, sidebar state, workspace tabs)
- Cache: `~/Library/Caches/<AppConstants.appID>/` — `atelier` for a release
  build, `atelier-debug` for a debug one, `atelier-tests` under XCTest. Holds
  run-state, tmux.conf and the process-compose phase sockets. The split is
  load-bearing: both variants shared one directory, so quitting a debug build
  swept a release build's live phase servers.
- Worktrees: beside the repository when the project uses the README's bare-repo layout
  (a `.bare` directory with a `.git` file next to it), so a worktree for `/repos/app` is
  created at `/repos/app/<name>`. Any other layout — an ordinary clone, a plain
  `git clone --bare`, a submodule — falls back to `~/.atelier/worktrees/<project>/<name>`,
  because there the equivalent directory is the working tree or a git directory, and a
  worktree must not be created inside either. See `Git.Operations.worktreeDestination`.
- URL scheme: `atelier://`
- Bundle ID: `com.github.phaedryx.atelier`
