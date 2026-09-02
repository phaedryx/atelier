// ABOUTME: Resolves the command that starts a workstream's local dev server.
// ABOUTME: Precedence: the per-workstream override, then the located process-compose config.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "dev-command")

/// The command that starts a workstream's dev server, and where it came from.
struct DevCommand: Equatable {
    enum Source: String, Equatable, Codable {
        /// Per-workstream command saved by the user in the Environment pane.
        case override
        /// The process-compose config located for this worktree.
        case processCompose
    }

    let command: String
    let source: Source
    let sourceDescription: String?
}

enum DevCommandResolver {
    private static let overrideKeyPrefix = "atelier.devCommand."

    // MARK: - Per-workstream override

    /// The escape hatch. A project with no `process-compose.yaml` — or one whose
    /// config starts the wrong subset of the stack for a particular workstream —
    /// gets a command the user types here, and it outranks detection.
    static func overrideKey(for workstreamID: UUID) -> String {
        overrideKeyPrefix + workstreamID.uuidString.lowercased()
    }

    static func savedOverride(for workstreamID: UUID) -> String? {
        guard let value = UserDefaults.standard.string(forKey: overrideKey(for: workstreamID)),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    static func saveOverride(_ command: String?, for workstreamID: UUID) {
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            UserDefaults.standard.removeObject(forKey: overrideKey(for: workstreamID))
            return
        }
        guard !isUnscopedProcessComposeCommand(command) else {
            logger.warning("Refusing to save an un-'-n'd process-compose command as an override")
            UserDefaults.standard.removeObject(forKey: overrideKey(for: workstreamID))
            return
        }
        UserDefaults.standard.set(command, forKey: overrideKey(for: workstreamID))
    }

    /// Whether this text is a `process-compose up` with no `-n`.
    ///
    /// `.override` is the one unconstrained input in `RunCommandPlan`: it is
    /// the user's own text and runs literally. That is deliberate, and it is
    /// also the shape of the fifth bypass — the Environment pane used to seed
    /// its editable field from the un-`-n`'d display command, and Save turned
    /// it into exactly such an override. The seeding is gone, but a value
    /// saved before it was fixed would be rehydrated by `savedOverride` and
    /// run on every Start forever, because nothing scrubs UserDefaults.
    ///
    /// So the check lives on both sides: the writer refuses to store one, and
    /// `resolve` ignores one already stored. Both together, because either
    /// alone leaves a hole — the writer cannot reach values already on disk,
    /// and a reader-only check would keep re-reading a value it will not use.
    ///
    /// Matching is on shape, not on equality with the current generated
    /// string, because the generated string contains absolute paths that move:
    /// a stored value from another worktree, or from before a project moved,
    /// is the same hazard and would not compare equal. A command that names a
    /// namespace is left alone — that is a scoped command, whatever else it
    /// does — and so is anything not invoking process-compose.
    static func isUnscopedProcessComposeCommand(_ text: String) -> Bool {
        // Shell metacharacters separate words too. Splitting on whitespace and
        // quotes alone left `process-compose up; echo done` reading as the word
        // `up;`, which is not `up`, so it passed.
        let separators: Set<Character> = [" ", "\t", "\n", "'", "\"", ";", "&", "|", "(", ")", "<", ">"]
        let words = text.lowercased().split(whereSeparator: { separators.contains($0) }).map(String.init)
        guard let binary = words.firstIndex(where: { $0.contains("process-compose") }) else {
            return false
        }
        // A named namespace makes it scoped wherever it appears. `-nexecute`
        // and `-n=execute` are both valid pflag shorthand, so the prefix
        // rather than equality.
        if words.contains(where: { $0.hasPrefix("-n") || $0.hasPrefix("--namespace") }) {
            return false
        }
        // What follows the binary decides whether the project runs at all.
        //
        // Requiring the word `up` was wrong, and verified so against
        // process-compose 1.122.0: `process-compose -f x.yaml` with **no
        // subcommand** runs the project through the root command, and a
        // `bootstrap` process in that file executes. So a flag straight after
        // the binary — or nothing at all — is every bit as unscoped as `up`,
        // while a real subcommand like `down` is not.
        guard let next = words.dropFirst(binary + 1).first else { return true }
        return next == "up" || next.hasPrefix("-")
    }

    // MARK: - Resolution

    /// Resolution order: the user's per-workstream override, then the located
    /// process-compose config.
    ///
    /// There used to be a third source — a `dev` script in the repository's
    /// package.json — and a picker to choose between it and process-compose.
    /// Both are gone. A `dev` script is near-universal and almost always starts
    /// a subset of the stack, so it was a plausible-looking wrong answer that a
    /// project could not opt out of; the override covers the case it was there
    /// for, explicitly.
    static func resolve(
        workingDirectory: String,
        projectDirectory: String,
        override: String?
    ) -> DevCommand? {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A stored override from before the seeding bug was fixed. Falling
            // through to detection is the safe answer, not an error: the
            // project still has a config, and the phase-scoped plan is what it
            // should have been running all along.
            if isUnscopedProcessComposeCommand(override) {
                logger.warning("Ignoring a stored override that runs every namespace")
            } else {
                return DevCommand(command: override, source: .override, sourceDescription: nil)
            }
        }
        return detectProcessCompose(in: workingDirectory, projectDirectory: projectDirectory)
    }

    // MARK: - process-compose detection

    /// The process-compose command for a worktree.
    ///
    /// The config is looked for in the worktree first, then in the project
    /// directory. The project directory is the useful place to keep one: in the
    /// bare-repo layout it sits outside every worktree, so a single file serves
    /// all of them, git cannot see it, and it never needs a gitignore rule. A
    /// config in the worktree still wins, because a worktree that carries its
    /// own is saying something deliberate.
    ///
    /// Either way process-compose runs with the *worktree* as its working
    /// directory, and it resolves a relative `working_dir` against its own cwd
    /// rather than against the config's location — so `working_dir: apps/api`
    /// lands inside the worktree from either home.
    ///
    /// `-U` moves the control API onto a unix socket, so it does not add a
    /// listening TCP port for the port detector to confuse with the app's.
    ///
    /// Every file is named with `-f`, which turns process-compose's own
    /// discovery off. That is the point: the set of files Atelier shows, gates
    /// and runs is then exactly one set. Leaving the override to discovery
    /// meant Start could load `compose.yaml` — a name Atelier does not detect —
    /// while bootstrap and dispose ran something else for the same project.
    ///
    /// **The `command` built here carries no `-n`, so executing it would run
    /// *every* namespace the config declares — `bootstrap` and `dispose`
    /// included.** Those two are the phases `PhasePolicy` gates: they run
    /// repository-authored processes unattended, and only once the user has
    /// approved every repository-provided file. This string never goes through
    /// `PhasePolicy`, so it must never reach a shell.
    ///
    /// It no longer does. `RunCommandPlan` maps a `.processCompose` source to
    /// `.phaseScoped`, and the command Start actually runs is built by
    /// `PhaseRunner.startCommand`, which is `-n`-scoped. The string below
    /// survives only as the text the Environment pane displays.
    ///
    /// So the `isEnabled` guard is **not** the execution-side boundary any
    /// more, and previous versions of this comment saying it was were wrong.
    /// What it does now is decide whether a config is detected at all, which
    /// is what makes Start unavailable — with a reason — while the integration
    /// is off. That is worth keeping, but it is availability, not security.
    ///
    /// It was the boundary once, and the hole reopened five times: an unhashed
    /// override file, `compose.yaml` winning discovery, the toggle being off,
    /// the binary being unresolvable while it was on, and finally the
    /// Environment pane seeding its editable field from this very string,
    /// where Save turned it into a `.override` that *is* run literally.
    ///
    /// That last route is the one to keep in mind, because `.override` is an
    /// unconstrained passthrough by design: `RunCommandPlan` cannot tell a
    /// user's own text from this string. The invariant therefore rests on
    /// nothing ever seeding an override from a `.processCompose` command — see
    /// `EnvironmentTabView.devCommandDisplayText`, which is what the pane
    /// renders instead. Reintroducing a path that executes `command` for a
    /// `.processCompose` source, or that pre-fills the override field with it,
    /// reopens the hole for the sixth time.
    static func detectProcessCompose(in directory: String, projectDirectory: String) -> DevCommand? {
        guard ProcessComposeSettings.isEnabled else { return nil }
        guard let config = ProcessComposeConfig.locate(
            worktree: directory, projectDirectory: projectDirectory
        ) else { return nil }

        // `loadedFiles` existence-filters, so a missing `-f` target — which
        // process-compose treats as fatal — cannot be produced here.
        let flags = config.loadedFiles.flatMap { ["-f", CommandBuilder.shellQuote($0)] }
        return DevCommand(
            command: (["process-compose", "up", "-U"] + flags).joined(separator: " "),
            source: .processCompose,
            sourceDescription: (config.path as NSString).lastPathComponent
        )
    }
}
