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
- **Repository-provided `bootstrap`, `dispose`, and `verify` processes
  require your approval before they run.** Atelier reads a
  `process-compose.yaml` and its override file, and runs five namespaces from
  it: `bootstrap` when a worktree is created, `prepare` and `execute` when you
  press Start, `verify` when you press Run in the Verification tab, and
  `dispose` when a workstream is archived. `bootstrap` and `dispose` run
  unattended, with nobody watching; `verify` is a deliberate press, but its
  output is captured rather than shown in a terminal, so the same requirement
  applies to it too. Those three are the ones behind approval. Atelier shows
  you the files that will load, runs nothing until you approve, and asks again
  when their contents change. A path that runs any of them without approval is
  a vulnerability; please report it.

  Approval keys off *location*, not content: a config inside the worktree is
  repository-provided and is gated, while one in the project directory beside
  `.bare` is yours and is not — git cannot see it, so a repository cannot put
  one there.

- **`prepare` and `execute` are not gated, deliberately.** They run only when
  you press Start, which is an attended action on a workstream you made, and
  the same reasoning covers the terminal above it. Report a path that runs
  either of them *without* a Start press.

- **What approval covers is the YAML Atelier hashes, not everything that YAML
  can reach.** The fingerprint is over the config files Atelier loads. A
  `command:` that invokes a script in the repository, a path built from an
  environment variable, or an `include:` of another YAML file all reach content
  outside that fingerprint, so a repository can leave the approved file
  untouched and change what it does. Treat approving a repository's config as
  trusting that repository, not as auditing one file. Narrowing this gap is
  wanted; a concrete divergence between what you approved and what ran is worth
  reporting.

Anything that runs code from a repository without the user agreeing to it is in
scope, whatever the mechanism.
