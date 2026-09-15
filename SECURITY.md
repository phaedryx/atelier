# Security Policy

## Reporting a vulnerability

Report security issues privately by opening a
[private vulnerability report](https://github.com/phaedryx/atelier/security/advisories/new)
on GitHub.

Please do not open a public issue for a security problem.

Useful things to include, as far as you have them:

- What an attacker can do, and what they need in order to do it
- The steps you actually verified, and the version or commit you tested
- Anything that helps reproduce it: a config file, a sample repository, a recording

You can expect an acknowledgement within three working days and an assessment
within a week. We will tell you what we found, what we intend to change, and
when we expect to ship it. If we disagree that something is a vulnerability we
will explain why rather than going quiet.

## Disclosure

We ask that you hold the details until a fixed release is out. After that,
publish whatever you like; we publish an advisory ourselves.

Reporters are credited in the release notes and in the GitHub advisory, with
whatever attribution they prefer, or anonymously if they would rather. Tell us
which. If you want a CVE, say so and we will coordinate.

## Supported versions

Fixes go into the latest release. There are no long-term support branches.

## Scope notes

Atelier runs coding agents, terminals, and dev servers on your machine, so
some behaviour that looks alarming is intended:

- **A terminal runs the commands you type.** That is the product.
- **The Coding Agent can modify files and run commands.** Its own permission
  prompts are the boundary, and turning on "Bypass permission prompts" removes
  that boundary deliberately.
- **The commands Atelier runs for a project come from three files in the
  project directory, and nowhere else.** `execution.process-compose.yaml`
  declares the process-compose namespaces, `initialization.yaml` the steps run
  once behind a new worktree, and `verification.yaml` the checks the
  Verification tab runs. Each is looked for in the project directory — the
  repository's *home*, the `.bare` container in that layout — and nothing
  inside a work tree is read. There is no override file, no worktree tier, and
  no generic name: a plain `process-compose.yaml` is never read, because a
  repository may run process-compose for its own reasons.

  **That location rule is the whole trust decision, which is why there is no
  approval step.** A file outside every work tree cannot have arrived with a
  clone; it was placed there by hand, by you. Atelier does not fingerprint
  these files, does not show an approval sheet, and does not ask again when
  they change — the earlier releases that did were gating a worktree tier that
  no longer exists. The rule also means an agent confined to its worktree by
  the "Restrict to worktree" system prompt cannot edit what runs there.

  **The known hole, stated rather than papered over: the project directory is
  sometimes inside a work tree.** For an ordinary clone the project directory
  *is* the checkout, so all three files can be committed and can arrive with
  the repository. New Project seeds its templates into a directory it then runs
  `git init` on, which is the same case. The layout the README describes — a
  `.bare` directory with worktrees beside it — is the one where the rule holds
  as stated. Reports here are welcome, but a committed config in an ordinary
  clone is this hole and not a separate finding.

- **What runs attended, and what does not.** `prepare` and `execute` run on a
  deliberate press of Start, in a terminal surface in front of you, with Stop
  to hand — the same reasoning that covers the terminal above. A verification
  check is a deliberate press too, and its output lives only in that check's
  own terminal surface: Atelier never captures it, never persists it, destroys
  it when the check is re-run, and sends none of it to an agent. `dispose`,
  which runs when a workstream is *purged* — not when it is archived with
  Remove, which deletes nothing — and the `initialization.yaml` steps that run
  behind a new worktree are the unattended paths. Both are covered by the
  location rule above and by nothing else.

- **Location trust covers the config file, not everything its commands can
  reach.** These files hold shell commands, and a command runs with the
  worktree as its working directory. A `command:` that invokes a script from
  the repository, a path built from an environment variable, or a tool whose
  behaviour the repository controls all reach content the location rule says
  nothing about. Treat placing one of these files as trusting the repository it
  drives, not as auditing a single file. Narrowing that gap is wanted.

Anything that runs code from a repository without the user having put it there
is in scope, whatever the mechanism. Concretely: a path by which Atelier reads
or executes any of these three files from inside a work tree, or loads a config
file it did not locate in the project directory.
