// ABOUTME: Resolves the command that starts a workstream's local dev server.
// ABOUTME: Precedence: the per-workstream override, then the located process-compose config.

import Foundation

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
        UserDefaults.standard.set(command, forKey: overrideKey(for: workstreamID))
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
            return DevCommand(command: override, source: .override, sourceDescription: nil)
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
    /// **Nothing is detected while the integration is switched off, and that
    /// guard is a security boundary rather than a tidiness one.** This command
    /// carries no `-n`, so process-compose runs *every* namespace it finds —
    /// `bootstrap` and `dispose` included. Those two are the phases
    /// `PhasePolicy` exists to gate: they execute repository-authored processes
    /// unattended, and they run only once the user has approved every
    /// repository-provided file. But this command never goes through
    /// `PhasePolicy`, so without the guard below, pressing Start on a freshly
    /// cloned repository with the integration *disabled* would execute its
    /// bootstrap and dispose processes with no approval and no phase scoping —
    /// reachable precisely because `usesProcessCompose` is false when the
    /// setting is off, which sends `resolvedRunCommand` down this fallback.
    ///
    /// It became reachable when this function started naming files with `-f`:
    /// before that it was `process-compose up -U` relying on discovery, which
    /// mostly found nothing. Do not narrow this guard to the phase call sites —
    /// this *is* a call site, and it is the one that bypasses them.
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
