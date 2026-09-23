# Execution and the project config files

process-compose, and the four files a project places in its project directory:
`execution.process-compose.yaml`, `initialization.yaml`, `verification.yaml`, `ports.yaml`.
They answer to one rule — a config's *location* is the trust decision — so they are
documented together.

### process-compose is a requirement, not an integration
Everything a project asks Atelier to run lives in one **`execution.process-compose.yaml`** in the
project directory, read by
[process-compose](https://f1bonacc1.github.io/process-compose/).
`ProcessCompose.Settings.resolveBinary()` finds the binary, and **there is no process-compose
setting of any kind** — no switch, no path. Two UserDefaults keys were removed, and neither
should come back or be read as meaning anything if a stale copy is found:

- `atelier.processCompose.enabled` defaulted off, which made "off" a supported state in which a
  worktree got no setup at all, nothing ran, and five surfaces each explained the silence a
  different way.
- `atelier.processCompose.binaryPath` named a binary explicitly, took precedence over the search,
  and deliberately *failed* rather than falling back to it — on the argument that silently running
  a different binary than the one named is worse than reporting the named one is gone. That
  argument was sound and the setting still went: the binary is auto-detected, first match on
  `searchPaths` wins.

process-compose now sits in Settings → Environment under **Detected Tools**, between `git` and
`tmux`, and on the onboarding screen as a required prerequisite with an install link. The only
interaction left is that pane's refresh button.

**The Detected Tools row is fed by `resolveBinary()`, never by `ToolStatus.findBinary`.** Those
two search different places — `resolveBinary` walks three fixed directories,
`CommandLineTools.path(for:)` walks the login PATH and six known locations — so a row fed by the
generic search reads green above a Start button reporting "process-compose was not found", the
button-versus-run disagreement `ProcessCompose.RunCommandPlan` exists to prevent, only spread
across two windows. Whatever `resolveBinary` searches, every surface must keep asking *it*. The
version probe is `version -s`: there is no `--version` flag, and bare `version` prints six lines
whose first is the product name.

**Detection is now an input to `runPlan`, and `TerminalContainerView` observes it.** The binary
path key was an `@AppStorage` there precisely so that Start became enabled when the user followed
the plan's own "go and fix this in Settings" advice; with the key gone,
`.onChange(of: appEnv.toolStatus.processCompose.path)` is what carries an install through to
Start, and the refresh button is what triggers detection. Removing that observer without putting
another trigger in its place leaves Start disabled after the user has done exactly what it asked.

`resolveBinary(searchPaths:)` takes the list as a defaulted parameter, injected only by tests.
`ProcessComposeSettingsTests` declined that seam while the search was merely the fallback behind
a configured path — "adding a search-paths injection point to production for one test" — and the
ruling flipped when the search became the only resolution path there is, because declining it
left the whole of resolution unassertable on any host. `WorkstreamArchiverDisposeTests` cannot
use the seam (it goes through `disposePlan`, which calls `resolveBinary()` with no arguments on
purpose) and `XCTSkipIf`s instead; that is safe only because `ci.yml` installs process-compose
and hard-fails if it is not on `searchPaths`, in the same job and immediately before the tests.

Removing the flag took out a guard in each of three places — `PhasePolicy.plan` (so no
unattended phase runs), the approval resolution (since removed outright) and
`DevCommand.Resolver.detectProcessCompose` (so Start has nothing to detect). Only the third was
ever near a security boundary, and it stopped being the boundary when
`ProcessCompose.RunCommandPlan` took the invariant to the consumer — see below.

**The un-`-n`'d command must never be executed, and is no longer displayed either.**
`DevCommand.Resolver.detectProcessCompose` builds `process-compose up -U -f <files>` as the
`.processCompose` source's `command`. It carries no `-n`, so running it would run **every**
namespace — `dispose` included — without passing through `PhasePolicy`. It is
not a runnable string, and the pane no longer renders it: for a
`.processCompose` source `devCommandDisplayText` shows the *files* that will be loaded, which
is what the user needed to see. Rendering the command was a copy-paste hazard on its own, and
Customize seeded its editable field from it — and Save turns that field into an `.override`,
which `ProcessCompose.RunCommandPlan` runs literally. Do not put a runnable process-compose command back into
`DevCommand.command`'s display path.

That invariant was defended four times by guarding *preconditions*, and reopened four times by
a different route each time: a worktree override process-compose discovered but Atelier never
showed; `compose.yaml` winning discovery outright; the process-compose switch — since removed —
being off; and — with that switch **on** — `resolveBinary()` returning nil, which is ordinary rather than exotic,
since process-compose is not in homebrew-core and `go install`, nix, mise and asdf shims all
sit on PATH but outside the three searched directories. That last one was additionally nasty
because `scriptCommand` wraps the fallback in `$SHELL -lic`, so PATH would resolve the very
binary `resolveBinary` had just failed to find, defeating that function's own promise that a
configured-but-missing path fails rather than letting a substitute run.

The fallback is reachable whenever *any* precondition of the gated path fails, so enumerating
preconditions can only ever be one behind. **So the invariant now lives at the consumer, keyed
on the dev command's source, in `ProcessCompose.RunCommandPlan.plan`**: a `.processCompose` source has exactly
one legal command — the phase-scoped one — and if that cannot be built the answer is `.nothing`.
There is no branch that returns the display string, so a precondition added tomorrow makes
Start inert rather than reopening the bypass. `Tests/RunCommandPlanTests.swift` pins it,
including a test that no combination of inputs yields the display string; three of those fail
if the fallback is put back. Do not replace this with another precondition check.

**One decision, and it is reported.** `ProcessCompose.RunCommandPlan.canRun` is what enables the Execution
pane's Start button, and `doStartRun` refuses on the same stored plan, so the two cannot
disagree — they did, for a round: the button was enabled on `devCommand?.command != nil` while
the run guarded the resolved command, and an unresolvable binary rendered an enabled Start that
did nothing in silence. `ProcessCompose.ResolutionModel` resolves the dev command, the plan, the
reason, the execute checklist and the declared verification checks together and publishes
them as **one `Resolution` value**, because *agreement* is the invariant here rather than
freshness — one struct assigned in one statement holds by construction what eight separate
`@State`s in `TerminalContainerView.refreshDevCommand` held by convention. That is also what
makes it safe for the resolution to run off the main actor, which it now does: a consumer reading
mid-flight reads the previous pass whole rather than a half-updated one. The **first** resolution
is synchronous, in the model's `init`, because a pane with nothing resolved is not neutral — a nil
verification reason reads as "everything is fine" and put an enabled Run over an empty check list. `refreshNow` exists for a caller that needs the result of a write it just made rather than the
world before it. `ProcessCompose.RunCommandPlan.unavailableReason` explains a `.nothing`, and
`ExecutionTabView.scriptInstructions` — the surface that already drew for "nothing to run" —
renders it, naming `execution.process-compose.yaml` where there is no config: a config that
cannot be located, a binary that is not where the search looks, an `execute` namespace nothing
declares. Initialization's own outcome, including `.completedWithNote`, is
rendered on the Info tab, which is permanent; nothing observed `.initializationStateChanged` before,
so those notes were written and discarded.

**The checklist's own gate is deliberately *not* in that plan**, and a reviewer will
pattern-match it to the second copy this document forbids, so say so in any commit that touches
it. **The rule is that the selection never enters `RunCommandPlan`** — not that it lives in any
particular file. `runnableExecuteSelection` reads the selection store per render in the view for
the Start button's `.disabled`, and `ProcessCompose.StartContextResolver` reads the same store for
the command itself, so the view and the IPC bridge share one assembler rather than two. (It used
to say "stays in the view", which was that rule's implementation while the view was the only
thing that could start a run; `start_execution` needed a second caller, and only the location of
the read changed.) It is the same one-decision rule
applied to the other half: the plan answers "is there a safe command for this source", and this
answers "is there anything selected to run it for". Folding the selection into
`RunCommandPlan.plan` was tried on paper and is worse in a way that is not obvious:
`Resolution.declaredExecuteProcesses` is derived by matching on `.phaseScoped`, so a plan that went
`.nothing` for an empty selection would take the **checklist** with it, hiding the checkboxes the user needs in order to
tick one again — and `canRun` removes the Start button rather than disabling it, so the pane would
answer "nothing to run" where the honest answer is "nothing selected". The two gates dim different
things on purpose.

**Three namespaces**, driven by `ProcessCompose.PhaseRunner` and `ProcessCompose.PhaseExecutor`.
There were five. `verify` went when verification stopped running through process-compose, and
`bootstrap` went when worktree setup did — see **verification.yaml** and **initialization.yaml**
below:

| Namespace | When | Interactive? |
|-----------|------|--------------|
| `prepare` | to completion before each Start, chained `&&` ahead of `execute` | no |
| `execute` | the long-lived stack, attached to a terminal surface and a process table | yes |
| `dispose` | once, at archive (`Workstream.Archiver.runDispose`) | no |

`prepare` is chained only when `namespacePresence` says `.present` — never on `.unknown`.
process-compose does not exit when told to run an empty namespace, it idles forever, so
chaining `up -n prepare` for a namespace that turns out not to exist hangs Start with no output.
`execute` is conditional on `.empty` and **only** `.empty`, and the gate lives in
`ProcessCompose.RunCommandPlan.plan` rather than in `PhaseRunner.startCommand`. It had to exist
because `up -n execute` against a namespace nobody declares does not fail and does not exit —
measured against v1.122.0, it idles indefinitely with no output — so Start opened a TUI with an
empty process list and Stop as the only way out. It had to go in `RunCommandPlan` because
`canRun` is what enables the Start button; deciding it in `startCommand` would leave the button
enabled over a run that does nothing, the exact disagreement that type exists to prevent.
`unavailableReason` carries the wording and `ExecutionTabView.scriptInstructions` renders it, so
the refusal is stated rather than silent — which is what makes this safe: the objection to
gating `execute` was that skipping it would make Start *silently* do nothing, and it is the
silence, not the skip, that was the problem. **Nothing but a test enforces that `plan` and
`unavailableReason` agree** — they hand-mirror each other in the same order, as
`verificationUnavailableReason` does; `Tests/RunCommandPlanTests.swift` pins both directions.

**`.unknown` fails closed here and open in `ProcessCompose.PhaseExecutor`, and that asymmetry is deliberate.**
A config Yams cannot decode still gets its `dispose` run, because refusing would
silently skip work the project may really have declared — and being wrong there costs a bounded
wait, `min(timeout, userCommand)` plus a grace period that ends in `.skipped`. Nothing bounds
the chained Start command: it runs in a terminal surface with no deadline, so failing open
there trades "a declared prepare was skipped" for "Start never returns". Do not make the two
consistent with each other; they are answering the same question under opposite costs.

Three facts about this are load-bearing and easy to lose:

1. **`$$`, not `$`, inside a `command:`.** process-compose runs the whole command body through
   envsubst before the shell sees it, and envsubst eats `${VAR}` *and* bare `$VAR`. A shell
   variable in a command body must be written `$$VAR`. A backslash does not escape it.
2. **Every file is named with `-f`, always** (`ProcessCompose.PhaseRunner.command`, `DevCommand.Resolver.detectProcessCompose`).
   That turns process-compose's own discovery *off*, which is the point: the set of files
   Atelier locates, displays and executes is then one set. Do not reintroduce discovery.
   Leaving a config unnamed so discovery could pick up a sibling file made the displayed set a
   *mirror* of discovery's rules, and a mirror can be stepped around — discovery also loads
   `compose.yaml`, a name Atelier deliberately does not detect, so a repository could ship a
   benign `process-compose.yaml` to be shown and a `compose.yaml` to be run. Verified against
   v1.122.0.
3. **The config's *location* is the trust decision, and there is no approval gate left.**
   `execute` was never gated, because it is **attended**: a deliberate press, output in a
   terminal surface in front of the user, Stop to hand. That, and not "the pane shows the
   command Start runs", is the reason — the pane shows the loaded *file*, and even before that
   it showed a display-only string rather than what Start runs. `dispose` *was* gated, because a
   config could arrive with a clone; now it cannot, so it is not. See below.

**`ProcessCompose.Config.locate` reads one name in one place**: `execution.process-compose.yaml`
in the **project directory**, then `execution.process-compose.yml`. Nothing inside a work tree is
read, and `Config` carries a `path` and nothing else — `isRepositoryProvided`,
`repositoryProvidedFiles` and `requiresApproval` are gone with the tiers that produced them.

**That is a trust decision, and it is the same one `Verification.Config` states.**
`Project.directory` is the repository's *home*, so a file there sits outside every work tree and
cannot have arrived with a clone: it was placed by hand. So `dispose` runs the project's
commands unattended with **no approval step at all** — no `ScriptTrust` fingerprint, no approval
sheet, no precondition in `PhasePolicy.plan`. That is the same rule `initialization.yaml` and
`verification.yaml` already state, so it is now three files answering to one rule rather than one
file with an exemption. Two consequences, both wanted: one config
serves every worktree, and an agent confined to its worktree by the "Restrict to worktree" prompt
cannot edit what runs there. The known hole, stated rather than papered over: for an ordinary
clone `Project.directory` *is* the checkout, so the file can be committed. `Verification.Config`
accepts the same hole and the rule is applied here unchanged rather than half-tightened —
sniffing whether the file is git-tracked would make the gate depend on a fact the user cannot
see. **Do not add a work-tree tier back**, and do not add an approval gate without adding one
first; each is the other's only justification.

**The `execution.` prefix is what makes a single name safe to demand.** A repository may run
process-compose for its own reasons — an instance manager, a docker-free dev stack — and that
file declares the project's own namespaces, not Atelier's three. Such a file was once
indistinguishable from an Atelier config and won the lookup outright: `prepare`
silently did nothing, and Start ran `up -n execute` against a namespace nobody had declared —
which does not fail, it **idles forever with no output** (measured against v1.122.0). No generic
name is read now, so that cannot recur.

**This replaced a four-tier search**, and the break is hard: `atelier.process-compose.y*ml` and
`process-compose.y*ml`, in the worktree and then the project directory, are all inert. A project
still carrying one gets `nil` from `locate`, and the wording is the whole migration story —
`RunCommandPlan.unavailableReason` and `ExecutionTabView.scriptInstructions` both name
`execution.process-compose.yaml` and the project directory. Do not reintroduce a deprecated
fallback tier; the precedence a reader has to hold in their head is what this removed.

**There is no override file.** An earlier design merged a worktree `process-compose.override.yml`
into a project-directory base, and a later one gave the worktree its own
`atelier.process-compose.yaml`. Both are gone. `loadedFiles` stays an array because it, not
`path`, is what `PhaseRunner.command` names with `-f`, so the located set and the executed set
are the same *set*. `Tests/ProcessComposeConfigTests.swift` pins that an override file beside the
config is never loaded, and that nothing in a work tree is.

**A newly created project starts with one.** `ProcessCompose.Config.writeDefault` drops a
commented template carrying one example process, called through `Project.seedDefaultConfigs`
(see **Seeded config templates** below) from the two paths that *create* the project
directory, and deliberately not from the two that adopt a directory the user already had.
Same rule, same entry point, as `Verification.Config.writeDefault`. **New Project seeds into a work tree** — that path runs
`git init` on the directory it made, so `Project.directory` is the checkout — and that is the
known hole above rather than a new one: a hand-written config in the same place is read
identically, and `verification.yaml`, whose checks are commands too, is seeded on the same terms.
Clone Repository is unaffected, because a committed config lands in the worktrees, where nothing
reads it. **The template's example process is real and uncommented, and
that is load-bearing**: a comments-only file — or one whose `processes:` key is null — fails to
decode, so `namespacePresence` answers `.unknown`, and `RunCommandPlan` gates `execute` on
`.empty` and *only* `.empty`. A commented-out template would ship every new project with an
enabled Start that idles forever.

**Which directory that is, is load-bearing.** `Project.directory` means the repository's
*home* — the `.bare` container, not the default checkout inside it — and every caller that
locates a config or reads `ports.yml` passes exactly that. `Project.checkout` is the other
half of the pair, and is for git work-tree reads only. They were one field until this was
fixed: `projectLocation` resolved a container forward to its checkout, so the lookups ran
against `<container>/main` and a config placed where the README says was never found. Passing
`checkout` to `Config.locate` or `PortsConfig.load` reintroduces exactly that bug.

Wherever the config lives, process-compose runs with the *worktree* as cwd and resolves a
relative `working_dir` against its own cwd, so `working_dir: apps/api` lands inside the
worktree.

`-u <path>` names the control socket explicitly. `-U` alone generates a path containing
process-compose's PID, which Atelier cannot predict and so cannot connect to. The headless
phases get namespace-suffixed paths, because a phase still running when the user presses Start
would otherwise rebind `execute`'s socket and strand the first server. `dispose` is the only
headless phase left and the suffix stays regardless — `prepare` is chained into `execute`'s own
command and shares its socket by design.

**The one gate.** `PhasePolicy.plan` answers the two preconditions — a config located and a
binary to run it with — for both unattended phases. There were four: the process-compose switch
went first, then approval of every repository-provided file went with the work-tree tiers.
`RunCommandPlan.unavailableReason` hand-mirrors the surviving two and does not fail to compile
when it disagrees, which is what `Tests/RunCommandPlanTests.swift` pins in both directions. It is
deliberately the *only* copy: a second, inlined set in
`Workstream.Archiver` could not be tested and would not follow a change made here. Any new
unattended execution path for repository-provided commands must go through it.
**Verification does not go through it**, and that is not an omission: a check's commands come
from `verification.yaml` in the *project directory*, which is outside every work tree, so the
location rule this gate implements already answers the question. See **verification.yaml** below.

### Seeded config templates
The two paths that *create* the project directory — "New Project" and Clone Repository,
both in `ProjectSidebar` — call **`Project.seedDefaultConfigs`**, which writes one
commented template per config file the app reads from the project directory:
`verification.yaml`, `initialization.yaml`, `ports.yaml` and
`execution.process-compose.yaml`. The two paths that *adopt* a
directory the user already had (the picker and the drag-and-drop) deliberately do not:
writing there would leave untracked files in a repository they merely registered.

Each file is **declared** on its config type as a `Project.ConfigFile` — its two
spellings, its template, and its parser — so only one place knows each filename, and
`Project.configFiles` is the list `seedDefaultConfigs` loops over. The **mechanism** is
`Project.ConfigFile`'s and is written once (`Sources/Models/ProjectConfigFile.swift`):
first spelling present wins, nothing inside a work tree is read, and a template is
written only when **neither** spelling is already present — seeding a `ports.yaml`
beside an existing `ports.yml` would win the lookup and hide the project's real
declarations. The refusals are per file, not all-or-nothing: a project that already
carries its own `ports.yml` still gains the templates it lacks. Each config type keeps
its own `locate`/`load`/`writeDefault` names and delegates, so nothing outside had to
move; `ProcessCompose.PortsConfig` keeps its `LoadError` and wraps rather than adopts
`ConfigLoad`, and `ProcessCompose.Config`'s declaration carries a trivial parser whose
`load` is never called — `namespacePresence` still answers `.unknown` for a file it
cannot decode, which is what `RunCommandPlan`'s `.empty`-and-only-`.empty` gate needs.

`Project.ConfigLoad` is the three-case `Load` shared by `Verification.Config` and
`Initialization.Config` (each a `typealias` onto it), with the *wording* —
`unavailableReason` — in a constrained extension per file, because verification's is
present tense for the tab and initialization's is past tense for the Info row. The node
walk both share is `Project.parseCommandEntries`.

**Whether a template's example is commented out is a per-file safety decision, not
style.** `verification.yaml`'s example check is uncommented (a check runs only on a
deliberate press, and an all-comments file would render the dead-end "declares no
checks" instead of the actionable empty state), and so is
`execution.process-compose.yaml`'s example process — there a comments-only file fails to
decode, `namespacePresence("execute")` answers `.unknown`, and Start runs a namespace
nobody declared, which idles forever (see the process-compose section).
`initialization.yaml`'s and
`ports.yaml`'s examples are commented out, because an uncommented step would *execute*
behind every new worktree and an uncommented port entry would claim a real port and
inject its variable into every terminal surface. The round-trip tests in
`InitializationConfigTests`, `PortsConfigTests` and `VerificationConfigTests` pin each
template to the loading behavior its choice depends on.

### initialization.yaml
Worktree setup does **not** go through process-compose. A project declares what a new
worktree needs in an `initialization.yaml`, and the steps run once, in the background,
the moment the worktree exists.

```yaml
deps:
  command: bundle install
assets:
  shell: fish
  command: bun install && bun run build
```

**The file lives in the project directory and nowhere else**, on exactly the trust
argument `verification.yaml` makes and for the same reasons: `Project.directory` is the
repository's *home*, so a file there sits outside every work tree and cannot have arrived
with the repository, and the existing rule therefore settles it — approval is gated by a
config's **location**, not its content. So there is **no `ScriptTrust` fingerprint and no
`PhasePolicy` gate** on this path. Two consequences, both wanted: one set of steps serves
every worktree, and an agent confined to its worktree by the "Restrict to worktree" prompt
cannot rewrite what runs when the next worktree is made. There is deliberately **no
worktree tier** mirroring `ProcessCompose.Config.locate`'s. The known hole is the same one
`verification.yaml` documents and is left unchanged rather than half-tightened: for an
ordinary clone `Project.directory` *is* the checkout.

**A newly created project starts with one**, all comments, via `Project.seedDefaultConfigs`
(see **Seeded config templates** above) — it loads as "declares no steps", the benign
Info-tab note, where an uncommented example would run behind every new worktree.

**Atelier's own project needs one, and it is not in this repository** — by design,
since the file lives in the project directory, outside every worktree, which is
what lets it run unattended. `docs/worktree-setup.md` carries the exact content to
place there and explains what happens without it: `ghostty/` stays empty and the
build fails with `error: Ghostty resources not found at ghostty/zig-out/share/`.

`Initialization.Config.load` returns **three** cases and never two — `.missing`,
`.invalid(reason:)`, `.loaded` — because a file Atelier cannot read must never render as
"this project declares no setup", which is the same sentence a project with genuinely none
gets and, here, the *only* diagnostic either one has: one line on the Info tab.
`Load.unavailableReason` **is** the availability decision rather than a mirror of one.
Parsed as YAML nodes rather than decoded as a dictionary, and here order is not cosmetic
the way it is for verification's rows — it is run order.

**Sequential, file order, halt on first failure.** This is the one deliberate difference
from `Verification.Runner`, whose checks are independent and run at once. Setup steps are
the opposite: `bundle install` before `rails db:prepare` is the ordinary case, and it is
what the `depends_on: process_completed_successfully` graphs in the old `bootstrap`
namespace existed to express. Running the rest after a failure works against a half-built
worktree and buries the error that mattered under the ones it caused.
`Initialization.Run.drive` is the pure loop; `Initialization.Runner` is the actor.

**Each step is `<shell> -lc '<command>'` through `ProcessRunner.capture`**, with the
worktree as cwd, `ProcessCompose.PhaseEnvironment`'s variables layered by
`childEnvironment`, and `Timeout.install` — the same deadline `bootstrap` had. **`-lc`,
not the `-lic` a verification check gets**, and the difference is the terminal: a check
runs in a Ghostty surface where `-i` is honest and is what makes a zsh user's `.zshrc`
PATH apply, while a step here has no tty and an interactive shell without one prints
job-control warnings to stderr — the stream a failure's message is read from. The PATH
`-i` was there for arrives another way, through `childEnvironment`'s injected login PATH.
There is no `sh -c` wrapper, no pid file and no status file: `capture` returns the exit
code, so the three layers `Verification.Spawn` needs have nothing to do here.
`CommandBuilder.resolveShell` is shared by both files, because both offer `shell:` and it
has to mean the same thing in each.

**There is no UI**, and that is the design rather than an omission. Setup is something that
happens to a worktree, not a pane anyone works in. The Info tab's **Setup** row is the only
surface — `initializationRow(for:)` and `canRerunInitialization(_:)` — fed by
`Initialization.State` over `.initializationStateChanged`, with a Rerun button and a
`Rerun Initialization` palette command. `.inProgress` names the running step and its
position; `.failed` names the step and carries the tail of its output; `.completedWithNote`
covers no file, an unreadable file, a file declaring no steps, and a cancelled run.

**Progress crosses back from the worker thread through an `AsyncStream`, not a `Task` per
report.** `Task { await updateState(...) }` per step has no ordering against the final
`updateState`, so a late one overwrote `.completed` and left the row stuck on "Running
“assets” (2 of 2)" for a run that had finished — and it reported to `Runner.shared` rather
than to the instance running, which is invisible in production and wrong under test. The
stream is ordered, and `finish()` plus awaiting the consumer is what makes "every progress
update has been applied" something the method can wait for.

**A purge cancels through `ProcessRunner.Cancellation`.** `Archiver.purge` calls
`Initialization.Runner.cancel`, which terminates the running step's process *group* —
`ProcessRunner`'s own kill, so a step that backgrounded a server goes with it — making
`capture` return and the loop finish as `.cancelled`. The poll watches for the
`Cancellation` it fired leaving `running`, which `run`'s `defer` clears, so it observes the
real end of the work rather than the signal, and it is bounded at 30s because a step wedged
past SIGKILL must not block an archive forever.

**The poll compares run *identity* (`running[id] === cancellation`), never slot presence.**
`run`'s `defer` frees the slot and a new run may claim it in the same breath — a manual
Rerun from the Info tab, or a late `.workstreamWorktreeReady` racing the purge — so a poll
that waited for the slot to be empty went on waiting on a run whose handle it had never
fired, burned the full 30s and answered `.timedOut` for a run that had already let go. The
archive then reached `git worktree remove --force` having been told the opposite of the
truth. A claimant is deliberately **not** cancelled in turn: `cancel` answers "the run you
asked me to stop has let go", and chasing claimants would put the exit condition back on
the slot being empty, where an arriving stream of them can still burn the bound. The
residual is stated rather than closed — a run that claims the slot during a purge is still
running in a tree about to be removed — and it is unchanged by this, which only stops
`cancel` from stalling and from misreporting. The `Cancellation` class was lifted out of `BareRepoClone`, which still
uses it: that type's exemption from `ProcessRunner` is about a clone having no honest
deadline, not about cancelling, so sharing the handle does not narrow it.

**`isCancelled` is consulted before each step and again when one fails, never after one
succeeds.** A cancel kills the running command, so it comes back as an ordinary non-zero
exit and the flag is the only discriminator; asking after a step that *succeeded* would
name it as the one stopped, when the step actually stopped is the one that never started. A
cancel arriving after the last step has already succeeded yields `.succeeded`, and that is
right rather than a gap — every step ran and the cancel was too late to stop anything.

**A project that still declares a `bootstrap` namespace is told so.** Setup would otherwise
stop happening in silence, since the namespace is simply never named on a command line
again. `Run.nothingToDoNote` keys on `namespacePresence("bootstrap") == .present` and
replaces only the "there is no file" reason — a file that is present and broken has its own,
and that is the one the user needs. `.unknown` deliberately gets the generic note: this one
makes a factual claim about the user's file, and `.unknown` is exactly where that claim is
unverified.

**The `bootstrap` namespace is gone** from `ProcessCompose.Phase`, and with it
`AsyncSetupService`, `AsyncSetupState`, `.asyncSetupStateChanged`, `cancelBootstrap` and its
socket-shutdown-and-poll, `runningBootstraps`, and `PhasePolicy.state(for:)` — which mapped
a `PhaseExecutor.Outcome` into `AsyncSetupState` and was bootstrap's alone. `PhasePolicy.plan`
survives with `dispose` as its **only** caller; the name stays phase-neutral rather than
becoming `DisposePolicy`, because naming a gate for its single caller is what invites the next
unattended phase to inline a second copy of it. Approving a repository's process-compose
config no longer reruns anything: `approveProcessConfig` used to call `rerunBootstrap`, and
worktree setup is not gated any more, so rerunning from there would run the project's setup a
second time for a reason that no longer exists.

### verification.yaml
Verification does **not** go through process-compose. A project declares its checks in a
`verification.yaml` and each one runs as a single command in its own Ghostty terminal surface.

```yaml
rubocop:
  shell: fish
  command: bundle exec rubocop
rspec:
  command: bundle exec rspec
```

**The file lives in the project directory and nowhere else** — beside `.bare`,
`execution.process-compose.yaml` and `ports.yml` — and that is a trust decision rather than a
convenience. `Project.directory` is the repository's *home*, so a file there sits outside every
work tree and cannot have arrived with the repository. It was placed there by hand, so there is
**no approval gate** on this path and adding one would be answering a question that cannot arise.
Two consequences, both wanted: one set of checks serves every worktree, and an agent confined to
its worktree by the "Restrict to worktree" prompt cannot edit the file that decides whether its
own work passes. There is deliberately **no worktree tier**, the same decision
`ProcessCompose.Config.locate` now makes — adding one would hand it exactly that. The known hole,
stated rather than papered over: for an ordinary clone `Project.directory` *is* the checkout, so
the file can be committed. Both configs accept that hole rather than half-tightening it.

This rule used to run the other way: process-compose *did* read the worktree, and a config found
there was gated by a `ScriptTrust` fingerprint the user approved in a sheet. Verification was
written to the project-directory-only rule first; the execution config then followed it, and the
gate went with the tiers it existed for.

**A newly created project starts with one**, seeded through `Project.seedDefaultConfigs`
(see **Seeded config templates** above). The template's example check is **uncommented on
purpose**: a file of nothing but comments composes to nil, which loads as "declares no
checks", so an all-comments template would have replaced the actionable empty state with a
dead-end one. Uncommented is safe *here* because a check runs only when somebody presses
Run — the templates that run unattended make the opposite choice.

`Verification.Config.load` returns **three** cases and never two: `.missing`, `.invalid(reason:)`
and `.loaded`. A file Atelier cannot read must never render as "this project declares no checks",
which is the same sentence a project with genuinely none gets and the only diagnostic either one
has — the same rule `ProcessCompose.Config.declaredProcesses` follows by returning nil rather
than `[]`. `Load.unavailableReason` **is** the availability decision rather than a mirror of one:
there is no binary to resolve and no approval to check, so "can a check run" is exactly "did this
file parse and does it declare anything", and `Runner.start` performs the same load and refuses on
the same three cases. That retires the hand-mirrored `verificationUnavailableReason` that nothing
made agree with `PhasePolicy.plan`.

**And `Verification.Runner.loadConfig` now *renders* `unavailableReason` rather than wording its
own refusal.** For two of the three cases it did not: `.missing` threw "This project has no
verification.yaml." where the tab says "Add a verification.yaml to this project's directory to
declare checks.", and `.invalid` threw the bare parse reason where the tab wraps it as "This
project's verification.yaml could not be read: …". An agent reading a refusal and a user reading
the tab were told different things about one file, under a doc comment claiming they could not be.
The empty-checks case deliberately stays worded at `start`'s own call site, because that site also
has to refuse an explicit empty `checks:` list and those are different sentences.

**Parsed as YAML nodes, not decoded as a dictionary**, so rows appear in **file order**. A Swift
dictionary has no order and rows would shuffle between launches. Yams refuses a duplicated key
itself, as a parse error — a hand-written duplicate guard was written here first and never fired.

**Each check runs `<shell> -lic '<command>'`** with the worktree as cwd and
`ProcessCompose.PhaseEnvironment`'s variables, so `ATELIER_*` and every `ports.yaml` name reach a
check exactly as they reach the other phases. `-lic` and not `-lc`: zsh users put PATH in
`.zshrc`, which only an interactive shell reads, and a check that cannot find `bundle` fails for
a reason nothing on the row could explain. `shell:` defaults to `$SHELL`; a bare name is resolved
against four common prefixes, because the wrapper inherits a GUI app's minimal PATH.

**The wrapper, and why it has three layers** (`Verification.Spawn.build`):

```sh
sh -c 'ps -o pgid= -p $$ | tr -d " " > <pid>; <shell> -lic "<command>"; echo $? > <status>'
```

1. **`sh -c` outside**, because the wrapper needs `$?` and redirection and the user's shell may be
   fish, where `$?` is `$status`.
2. **The process *group* id, recorded before anything runs.** Ghostty exposes no pid for a
   surface's child, so this is the only handle on a running check, and the group is what `stop`
   signals. **`ps -o pgid=`, never `$$`** — measured: a backgrounded `sh -c` reported `$$` as
   56980 while its real pgid was 56974, and `kill(-56980, 0)` answered ESRCH. Under `$$` both
   halves fail together and both fail *silently*: `stop` signals a group that does not exist so
   nothing dies, and `isAlive` reads the same ESRCH as "gone" so every check is recorded finished
   the moment the completion pass first looks. Production is the case where they most likely
   coincide, which is exactly what would make it pass in testing and break elsewhere.
3. **The exit code goes to a file**, not to Ghostty's `GHOSTTY_ACTION_SHOW_CHILD_EXITED`. That
   action does fire, but its code cannot be trusted here — Ghostty's own source says so where it
   builds the message: "On macOS, our exit code detection doesn't work, possibly because of our
   `login` wrapper" (`ghostty/src/Surface.zig:1209-1210`).

The outermost token is **POSIX-quoted, never fish-quoted**: Ghostty runs a surface command through
`/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c` on macOS, so bash reads it before any
shell of ours does — the same rule `CommandBuilder.inLoginShell` states at its own quoting.

**Checks are independent.** No control server, no socket, no suite. Any number run at once, each
with its own surface and its own stop, and starting or stopping one says nothing about any other.
So `Runner.isLive(workstreamID)` means "is *anything* running here" — what a purge waits on — and
`isRunning(_:check:)` is what gates a start. A `Run` survives only as the unit one press started,
which is what `start_verification` answers with.

**A check with no pid file yet is starting, never finished.** The completion pass reads the
wrapper's two files: a status file is a verdict, and a process group that is gone *with a pid file
present* is a check that died or was killed. Reading a **missing** pid as "gone" would record every
check as finished before it had run anything, silently. `stopRequested` is the only thing that
distinguishes a killed check from one that died on its own, because killing the group takes the
wrapper with it before it can write a status.

**And "starting" is bounded, by `startupGrace` (30s, injectable beside `killGrace`).** The rule
above is about what a *missing* pid means, not about how long it may go on meaning it, and nothing
used to bound it: `SurfaceHosting.startSurface` returning true is not the wrapper having run, so a
surface that failed to spawn its child — or was torn down before exec — left a check that never
wrote a pid and could not leave the starting state. The row showed Running for the rest of the
session, `stop` no-op'd because there was no group to signal and the grace's `SIGKILL` no-op'd
with it, and `stopAndWait` burned the whole of `ProcessRunner.Timeout.userCommand` before an
archive could proceed. Past the grace the pid file is not late, it is never coming, so the check
is recorded exactly as the process-is-gone branch records one — `.failed(-1)`, or `.stopped` if a
stop was asked for. **The bound is an upper limit on the window, never a change to what a missing
pid means inside it**: within the grace a check with no pid is still starting and must never be
read as finished, which `test_completionPass_leavesACheckThatHasNotWrittenItsPIDAlone` pins on the
production default. The number is a two-sided tradeoff and is chosen from the second side: the
real path is fork → `login` → bash → `sh` → `ps`, milliseconds, so thirty seconds is three orders
of magnitude of headroom — and because `stopAndWait` drives `completionPass`, it is also the
ceiling on how long an archive can pause for a check started a moment earlier. Do not shorten it
towards the measured path; the headroom is what keeps a loaded machine from having its checks
killed off for being slow.

**`stop`'s kill after the grace belongs to the *run*, not to the check.** `stop` sends `SIGTERM`
and schedules a `SIGKILL` `killGrace` (5s) later; the task fires only while the live check is
still the same **run id**. Guarding it on `isRunning(_:check:)` — "is *a* run of this check
going" — killed the *next* run when a stop and a re-run fell inside one grace, and capturing the
`Spawn` is no defence: `Verification.Spawn.fileStem` is the workstream id and a hash of the check's
name with no run id in it, so both runs share one pid file and the stale task reads the new group
out of it. The damage was silent and misattributed — the new `LiveCheck` has `stopRequested` false
and a killed wrapper writes no status, so the row recorded `.failed(-1)`, a check apparently
crashing, with nothing tying it to a Stop press two runs ago. `killGrace` is injectable through
`Runner.init` for the regression test alone; production takes `Runner.defaultKillGrace`.

**Output lives in the surface and nowhere else.** It is never captured, never persisted, and does
not survive the app — which is the whole bargain this design makes, and it retired
`outputTruncated`, the 200-line tail, the one-shot log window, and the "there is nothing more to
fetch" copy along with it. `Verification.CheckRecord` carries a verdict, a duration, a stamp and a
run id, and that is all that outlives a session. **No output crosses the IPC boundary either**:
`IPC.VerificationCheckInfo` has no `outputTail`, and every string an agent sees points at the
Verification tab or at re-running the one check. A re-run **destroys the previous surface**, so
the last run's output is gone the moment the next one starts.

**`Runner.forget` is called by both archive paths, not just `purge`.** A check's surface id comes
from `Verification.Spawn.surfaceID` — derived from the workstream id *and* the check's name, so it
cannot collide with the workstream's own id, which is the Coding Agent's surface — and
`TerminalSurfaceCache.removeWorkstreamSurfaces` sweeps only ids derived from `WorkspaceModel`'s
counters. So nothing else can reach a check's terminal: a workstream *removed* with rspec running
would otherwise leave that terminal and its process alive for the session.

**A purge stops checks through the runner and the wait is bounded.**
`Archiver.quiesceVerification` calls `Runner.stopAndWait`, because `stop` only *asks* — it signals
the group and returns. A purge that signalled and moved on would reach `git worktree remove
--force` with the command still running in that tree. The bound is
`ProcessRunner.Timeout.userCommand`, the same tier the next step uses; on expiry the purge logs and
proceeds, because a workstream stranded half-archived is worse than cleanup that did not happen.
`forget` runs **before** the destructive work, so a check outliving an expired wait finishes into
nothing rather than announcing a result for a worktree being deleted.

**The `verify` namespace is gone** from `ProcessCompose.Phase`, and with it the socket, the
control server, `liveClients`, `sealedRunIDs`, `tearingDown`, the `sawServer` guard, the
one-owner-of-`shutDown` rule, the `restart: exit_on_failure` trap that sealed watched failures as
`.notRun`, and the empty-namespace idle gate. `shutDownWhenDone: false` survives on
`PhaseExecutor.run` with **no production caller**: it is the only thing standing between
`--keep-project` and a report, and `Tests/PhaseExecutorTests.swift` keeps it covered for whoever
needs a server to outlive its namespace next.

**`CheckResult.State` keeps seven cases, two of which have no producer.** `.pending` and
`.skipped` described a process-compose dependency graph that checks no longer have. They stay
because the glyph table, the state words and the row's accessibility labels are a fixed set the UI
is specified against, and because a queued check is the obvious next thing this could grow.
Nothing may start *reading* them as reachable.

**The Verification tab is one row per declared check**, and the row is:

```
▸  ◯ rspec ▶                                        stale   12.4s
```

The **triangle is the only toggle** — clicking the glyph or the name does nothing, which is a
deliberate reversal of the shape this replaced, where the whole row was an invisible button and
there was no triangle at all. The **run button follows the name** rather than the trailing edge,
so it is unmistakably *this check's* button, and the column it forms is ragged by design; the
trailing edge belongs to the stale marker and the duration, which are what a user scans down.
Expanding shows that check's terminal at a fixed height, read-only and scrolling inside itself —
fixed rather than grown to fit, because a terminal has its own scrollback and the rows live in a
`ScrollView`.

**Three glyphs for three offers**, and `verificationRowAction` is the pure function that picks:
green `play.fill` for a check with no result, `arrow.clockwise` for one that produced a verdict,
`stop.fill` while it runs. **A stopped check offers Run, not Re-run** — a stop is the user
deciding this check should not have run, so the honest next offer is the one an untouched check
gets. Green is only ever for starting.

**There is no Run all and no top-bar Stop.** Every row has its own button, and the action row went
with them.

`VerificationSurfaceView` attaches an **existing** surface and never creates one — deliberately
not `SingleTerminalView`, which creates on a miss: a row for a check that has never run would
otherwise spawn a terminal running the wrapper the moment its group was opened. A missing surface
is an ordinary state the row draws a sentence for, and the runner is the only thing that starts
one. `TerminalView.isReadOnly` swallows `keyDown`, `insertText` and drops while leaving selection,
copy and scrollback working — it is a flag on the write paths rather than
`acceptsFirstResponder` returning false, because a surface that cannot be focused cannot be
selected from the keyboard either. It is set at creation *and* on every attach, since the runner
makes the surface and has no opinion about who renders it.

### ports.yaml
A **`ports.yaml`** in the project directory declares the port variables Atelier supplies, so
two worktrees of one project can run the same stack at once:

```yaml
ports:
  WEB_PORT: { assigned: true, browser: true }
  API_PORT: { assigned: true }
  OAUTH_PORT: { fixed: 4000 }
```

`ProcessCompose.PortsConfig` parses it and `ProcessCompose.PortPlan.resolve` turns it into numbers for one worktree. An
`assigned` port starts from `Port.Allocator.port(for:salt:)` — the same DJB2 hash that produces
`ATELIER_PORT`, salted with the variable's name — then walks forward past anything already
claimed in this pass or already bound. Deterministic-first matters: a port that changed every
run would break bookmarks, OAuth redirect URIs, and CORS allowlists. The probe only covers the
common case; nothing can close the window between checking a port and a child binding it. A
`fixed` port is that number everywhere, for values registered off the machine.

At most one entry may set `browser: true`; that port is what the embedded browser opens, and it
wins over detection — Atelier assigned it, so there is nothing to infer. Entries are sorted by
name before allocation, so an assigned port does not move because a YAML key was reordered.
`assigned: false` is an error rather than a no-op, because it reads like it means something.

**Two sets of names are refused, for different reasons, and neither is a reversal of the
merge-over rule below.** Six `ATELIER_*` names Atelier sets per *workstream*
(`ATELIER_WORKTREE_DIR` and friends) were the first; `ATELIER_SURFACE_ID`, `TMUX` and
`TMUX_PANE`, which Atelier sets per *surface*, are the second. `ATELIER_PORT` stays
declarable, which is the documented exception and the whole of it. What made the second set
worth refusing is that a declaration lands **inconsistently**: the surface paths assign all
three *after* the merge — `TerminalContainerView.envVars` and `terminalEnvVars`, and
`WorkspaceActions.environment(for:surfaceID:)` — so the line is silently inert there, while
`ProcessCompose.PhaseEnvironment.variables` returns the merged set unchanged, so the declared
value reaches every verification check, every `initialization.yaml` step and `dispose`
verbatim. One line meaning two different things depending on which surface reads it is worse
than either outcome alone. `ATELIER_SURFACE_ID` is the one that costs where it lands:
`IPC.TaskStore` keys **claim ownership** on it, so a wrong value is a task claim attributed to
the wrong agent. **`PATH`, `HOME`, `SHELL`, `TMPDIR`, `USER` and `LOGNAME` are deliberately
*not* reserved** — they fail loudly in the user's own terminal, and a footgun the user can see
is different from one they cannot; `PATH` is separately protected on the spawned-child path by
`PhaseEnvironment.childEnvironment`. Do not widen the list one name at a time: the better shape
is a general rule (a declared name can only ever hold a port), and
`testTheNamesDeliberatelyLeftUnreservedAreStillAccepted` pins the scope in that direction.

**A newly created project starts with one**, all comments, via `Project.seedDefaultConfigs`
(see **Seeded config templates** above) — it loads as "declares nothing", the ordinary state
for a project without ports, where an uncommented example would claim a real port.

Every declared name reaches **every** terminal surface via `Workstream.Environment.variables`,
not just the run pane — a port visible only to the run pane is invisible to a test run in a
terminal tab. Declarations merge *over* Atelier's own variables, so a project that wants
`ATELIER_PORT` to mean something specific may say so, and the legacy `FF_*` mirror is built
last so it never lags behind.

**And every declared name reaches all three namespaces, every initialization step and every
verification check.**
`prepare` and `execute` run in a Ghostty surface, which is handed those variables when it is
created; `dispose` spawns through `ProcessCompose.PhaseExecutor`, and until
`ProcessCompose.PhaseEnvironment` existed its children inherited only the app's own environment. One `execution.process-compose.yaml` therefore ran under two different
environments depending on which namespace was asked for: the documented replacement for the
seeding this integration removed, `rsync -rlpt --copy-links "$$ATELIER_PROJECT_DIR/seed-files/" .`,
rsynced from `/seed-files/`. `ProcessCompose.PhaseEnvironment.variables` assembles the same set for the
unattended phases, resolving `ports.yaml` itself because no call site has a plan to hand
over. `ProcessCompose.PhaseExecutor.run` takes it as a **required** parameter, and layers it over the inherited
environment with the login `PATH` applied last, so a declaration cannot displace `PATH`.
Allocation is deterministic per worktree and per name, so a plan resolved at worktree creation
lands on the same numbers Start does — modulo the liveness probe, which walks forward past a
port bound at the moment it looks, and which is why `fixed` exists for anything registered off
the machine.

### Dev command resolution
`DevCommand.Resolver` picks what the Execution tab's Start button runs, in order: the
**per-workstream override** the user typed (stored at `atelier.devCommand.<workstreamID>`),
then the located process-compose config. The override is the escape hatch for a project with no
config, and it is the only reason `DevCommand.Source` still has two cases.

There used to be a third source — a `dev` script in the repository's package.json — and a
picker to choose between it and process-compose. Both are gone. A `dev` script is
near-universal and almost always starts a subset of the stack, so it was a plausible-looking
wrong answer a project could not opt out of; the override covers the case it stood in for,
explicitly.

### The run lifecycle lives on a session, not on the view
**`ProcessCompose.RunSession` is the one place a workstream's dev-server run is started,
stopped, restarted or restored**, and it holds the state those decisions write.
`TerminalSurfaceCache.runSession(for:)` owns one per workstream, beside that workstream's
`WorkspaceModel` and for the same reason: `ContentView` keys `TerminalContainerView`
`.id(workstreamID)`, so the view is destroyed on navigation and anything the run needs to
outlive that cannot be the view's.

It was split across both. `runStarted`, `runStoppedManually`, `runGeneration` and
`runCommandString` lived on `WorkspaceModel` while every decision that set them —
`doStartRun`, `beginRun`, `stopRun`, `restartRun`, `restoreRunState` — was a private method on
the view, and four more pieces of run state never reached a model at all: `browserStartPending`,
`isReclaimingRunSocket`, the port plan and the port detector. That split has already produced
two shipped bugs of the same shape. `runGeneration` was view `@State` once, so navigating away
and back left the view believing a run was live with the generation reset to 0 and Stop removing
a surface nothing was using while a real server kept running; `browserStartPending` had exactly
that shape until this type existed. And `close_tab(kind: "execution")` was refused outright
because stopping a run meant reaching view-local `@State` — see **close_tab** in
`docs/agents/ipc.md`.

**The session consumes `ProcessCompose.RunCommandPlan`; it never re-decides one.** The resolved
command reaches it as a **non-optional** `StartContext.command`, assembled by
`TerminalContainerView.runStartContext` from the stored `Resolution`'s plan and the execute
checklist. That is what makes the one-decision rule structural here rather than a guard somebody
has to remember: `restart` cannot stop a run and then decline to start one, because there is no
optional left to decline on. **That command is assembled by
`ProcessCompose.StartContextResolver`, which the view and `IPC.ExecutionBridge` both call** — one
assembler, because a second one in the IPC layer is the drift this type exists to end. The
checklist's gate is still not in the plan; the process-compose section above explains why, and a
reviewer will pattern-match its absence from the session to the second copy this document
forbids.

**The tmux session a run is started in is recorded at `beginRun`, not read live at `stop`.**
That is what makes `stop()` self-contained enough for `WorkspaceActions` to call with no view
mounted, and it is strictly more correct than the live read it replaced: `killRunTmuxSession`
used to consult the *current* tmux mode and tool path, so a run started under tmux and stopped
after tmux mode was switched off killed nothing.

**The run surface's exit is the session's to observe, not the view's.** It subscribes to
`.terminalTabExited` in `init`, so a run whose last process dies while the user is looking at
another workstream is still recorded — it used to be an `.onReceive` on the container, which is
absent exactly then. The comparison is against the **current** `runID`, so the outgoing
generation's surface (which `beginRun` and `stop` both drop on their way past) cannot clear the
run that replaced it, and `runStoppedManually` is still deliberately left alone: the run died on
its own.

**What stayed in the view, and why.** `syncProcessPolling` reads `usesProcessCompose` off the
view-owned resolver and drives a `@StateObject` table, so it stays — rebound to
`.onChange(of: session.runStarted)`, which is still the right trigger because the tmux restore
sets that flag without going through start or stop. `Port.Detector` stays a view `@StateObject`
and writes `session.clearBrowserStartPending()` from its own `.onChange`; moving it would give
every visited workstream a permanent FSEvents source for no gain. Every remaining observer that
touches the run — the `.rerunScript` receiver, the `appEnv.isDetecting` change, `.onAppear` —
is on the always-mounted modifier chain, never inside a `@ViewBuilder` branch.

**Three seams are injected in `init` and defaulted**, the shape `Verification.Runner` uses for
`SurfaceHosting` and `killGrace`: creating and removing a surface and `ensureSingleton(.execution)`
(supplied by the cache, which owns both), the socket probe and reclaim, and the tmux
probe/kill. `TerminalSurfaceCache.terminalApp` exists for the same reason — it is the only place
in that type that needs `TerminalApp.shared`, and touching that initializes libghostty, which a
unit-test host cannot do. `Tests/RunSessionTests.swift` is what that buys.

**Nothing about a run is persisted.** `WorkspaceTabSnapshot` carries no run state at all now, and
never meaningfully did — it is a seed, not a store, and `WorkspaceStateStore` only ever wrote the
active tab. What made run state survive navigation was always that the cache owns the object
holding it. Across a *launch* no surface exists and a restored command string would be a lie, so
`restore`'s tmux probe is the only thing that carries a run over a relaunch.

**The editor tab answers the same question the same way, and it cost unsaved work to learn.**
`EditorView` is a `@ViewBuilder` branch of `TerminalContainerView`, so the rule above applies to
it unchanged: anything an editor tab needs to survive navigation belongs on `WorkspaceModel`,
which `TerminalSurfaceCache` owns, and not in view `@State`. `fileLoaded` was view `@State` — it
means "this tab's Monaco model already holds its file's contents" — so a fresh view read it as
`false`, `onAppear` read *that* as "never loaded", and reloaded the file from disk through
`openFile`, whose `model.setValue(text)` replaced whatever the user had been typing and reset the
model's clean version. Typing in a file and pressing ⌘⏎ lost the edits, the dirty dot and the ⌘W
save prompt together. It is now `WorkspaceModel.editorFileLoaded`, and `onAppear` calls
`switchModel` rather than reloading — which also keeps the undo stack, cursor and scroll position
across a switch on a clean tab. `currentFilePath` did **not** have to move: it is already durable
as `editorFilePaths[id]`, arrives as `initialFilePath`, and is kept current by `onFileChanged`.

Three things about it are load-bearing. The flag is **not** `@Published`, for the reason
`hasBeenPresented` and `editorInitialLines` give — nothing renders from it and it is written
inside a load the view is already performing. It is cleared in `removeTab` beside
`editorDirtyState`, and deliberately kept out of `WorkspaceTabSnapshot`, which carries no live
model state. And the attach branch is **gated on `initialFilePath` being present**: Save As to a
file outside the worktree removes that entry and detaches the editor, and there is nowhere
durable to record an absolute path, so that case keeps the do-nothing it has always had rather
than attaching the model underneath the opaque "Select a file to edit" placeholder. That gap is
known and open — a detached editor still loses its association across a navigation.
