// ABOUTME: The project's `verification.yaml` — the checks the Verification tab offers.
// ABOUTME: Project directory only, so it can never arrive with the repository.

import Foundation

extension Verification {
    /// A project's declared checks, in the order the file declares them.
    ///
    /// **This file lives in the project directory and nowhere else**, and that is a
    /// trust decision rather than a convenience. `Project.directory` is the
    /// repository's *home* — the `.bare` container in that layout — so a file there
    /// sits outside every work tree and cannot have arrived with the repository.
    /// CLAUDE.md's rule for process-compose configs applies unchanged: approval is
    /// gated by a config's location, not its content, and a config in the project
    /// directory "was placed there by hand, outside git, and is never asked about".
    /// So there is no `ScriptTrust` fingerprint here and no `PhasePolicy` gate, and
    /// adding one would be answering a question that cannot arise.
    ///
    /// Two consequences follow and both are wanted. One set of checks serves every
    /// worktree of the project, so a check is edited in one place. And an agent
    /// working in a worktree — confined there by the "Restrict to worktree" system
    /// prompt — cannot edit the file that decides whether its own work passes. A
    /// worktree-local override would hand it exactly that, which is why there is no
    /// tier-one worktree lookup mirroring `ProcessCompose.Config.locate`'s.
    ///
    /// **The known hole, stated rather than papered over:** for an ordinary clone
    /// `Project.directory` *is* the checkout (`Project.swift:70-79`), so the file
    /// sits inside the work tree and can be committed. That hole already exists for
    /// process-compose's project-directory tier and the rule is applied here
    /// unchanged rather than half-tightened. Sniffing whether the file is git-tracked
    /// would make the gate depend on a second fact the user cannot see.
    struct Config: Equatable {
        /// The file this was read from.
        let path: String
        /// Every declared check, in file order.
        let checks: [Check]

        /// One check: a name, a command, and the shell to run it in.
        struct Check: Equatable {
            let name: String
            /// The command, as written. Run by `shell`, not parsed here.
            let command: String
            /// The shell named for this check, or nil to use the user's `$SHELL`.
            ///
            /// Kept `Optional` rather than resolved at parse time so the resolution
            /// stays with the spawn: `$SHELL` is read from the environment the app
            /// launched with, and a parsed config outliving a settings change should
            /// not pin a shell the user has since replaced.
            let shell: String?
        }

        /// The names, in file order. What the tab draws a row per.
        var checkNames: [String] {
            checks.map(\.name)
        }

        func check(named name: String) -> Check? {
            checks.first { $0.name == name }
        }
    }
}

extension Verification.Config {
    /// What a load attempt found.
    ///
    /// Three cases, not two, for the reason `ProcessCompose.Config.declaredProcesses`
    /// returns nil rather than `[]` on a parse failure: a file Atelier cannot read
    /// must never render as "this project declares no checks", which is the same
    /// sentence a project with genuinely no checks gets and the only diagnostic
    /// either one has.
    ///
    /// The three cases and `config` are `Project.ConfigLoad`'s, shared with
    /// `Initialization.Config.Load` — the mechanism is one file's, the *wording*
    /// below is this file's.
    typealias Load = Project.ConfigLoad<Verification.Config>
}

extension Project.ConfigLoad where Contents == Verification.Config {
    /// The checks to draw a row for. Empty whenever `unavailableReason` is
    /// set, so the two cannot describe different states.
    var checkNames: [String] {
        config?.checkNames ?? []
    }

    /// Present-tense wording for why nothing can run yet, or nil when
    /// something can.
    ///
    /// **This is the availability decision, not a mirror of one.** The gate the
    /// process-compose phases have — `PhasePolicy.plan`, hand-mirrored by a
    /// second copy that nothing made agree with it — has no counterpart here:
    /// there is no binary to resolve and no approval to check, so "can a check
    /// run" is exactly "did this file parse and does it declare anything". The
    /// runner asks the same `load` and throws on the same three cases, rendering
    /// *this* wording rather than a second set of its own, which is what keeps
    /// the tab's empty state and `start`'s refusal in step.
    var unavailableReason: String? {
        switch self {
        case .missing:
            NSLocalizedString(
                "Add a verification.yaml to this project's directory to declare checks.",
                comment: "Verification tab: no config"
            )
        case let .invalid(reason):
            String(
                format: NSLocalizedString(
                    "This project's verification.yaml could not be read: %@",
                    comment: "Verification tab: the config is present and broken"
                ),
                reason
            )
        case let .loaded(config):
            config.checks.isEmpty
                ? NSLocalizedString(
                    "This project's verification.yaml declares no checks.",
                    comment: "Verification tab: the config parsed and is empty"
                )
                : nil
        }
    }
}

extension Verification.Config {
    /// The file, described once: its two spellings, its template, and how to
    /// turn its text into checks.
    ///
    /// `Project.ConfigFile` owns the mechanics every project-directory config
    /// shares — first spelling present wins, nothing inside a work tree is read,
    /// a template is seeded only when neither spelling exists — and the trust
    /// argument behind them. What stays here is what is this file's alone: the
    /// names, the template, and the schema.
    static let configFile = Project.ConfigFile<Verification.Config>(
        fileNames: ["verification.yaml", "verification.yml"],
        defaultContents: defaultContents,
        parse: { text, path in
            try Verification.Config(
                path: path,
                checks: Project.parseCommandEntries(text, messages: messages).map {
                    Check(name: $0.name, command: $0.command, shell: $0.shell)
                }
            )
        }
    )

    /// The names looked for, in order. The first that exists is the one read —
    /// a second is never merged, because two files whose precedence a reader has
    /// to hold in their head is the shape `ProcessCompose.Config` retired.
    static var fileNames: [String] {
        configFile.fileNames
    }

    /// How this file describes its own shape when it is wrong. Shared schema,
    /// its own nouns: a *check*, named after `verification.yaml`.
    private static let messages = Project.CommandEntryMessages(
        notValidYAML: NSLocalizedString(
            "The file is not valid YAML: %@",
            comment: "verification.yaml: Yams could not parse it"
        ),
        topLevelIsNotAMapping: NSLocalizedString(
            "The file must be a mapping of check names to their commands.",
            comment: "verification.yaml: the top level is a list or a scalar"
        ),
        entryHasNoName: NSLocalizedString(
            "Every check needs a name.",
            comment: "verification.yaml: a key that is not a non-empty string"
        ),
        entryIsNotAMapping: NSLocalizedString(
            "“%@” must be a mapping with a command:.",
            comment: "verification.yaml: a check given as a bare string or a list"
        ),
        entryHasNoCommand: NSLocalizedString(
            "“%@” needs a command: to run.",
            comment: "verification.yaml: a check with no command"
        ),
        entryHasAnUnusableShell: NSLocalizedString(
            "“%@” has a shell: that is not a shell name.",
            comment: "verification.yaml: shell given as a list or a mapping"
        )
    )

    /// Read the project's checks.
    ///
    /// `projectDirectory` must be `Project.directory` and never `Project.checkout`.
    /// In the container layout those differ, and passing the checkout would look
    /// inside `main/` — a work tree — which is both the wrong place and the one
    /// location this type exists to avoid.
    static func load(projectDirectory: String) -> Load {
        configFile.load(projectDirectory: projectDirectory)
    }

    /// The parse, separated from the file system so the schema can be tested
    /// without one.
    static func parse(_ text: String, path: String) -> Load {
        configFile.load(text: text, path: path)
    }
}

extension Verification.Config {
    /// The file a newly created project starts with.
    ///
    /// Deliberately **not** localized, for the reason `BareRepoClone` writes
    /// `"gitdir: ./.bare\n"` as a literal: this is file content the user edits,
    /// not UI, and the keys are part of the schema.
    ///
    /// The example check is left *uncommented* on purpose. A file of nothing but
    /// comments composes to nil, which `parse` reads as a config declaring no
    /// checks — so the Verification tab would swap the actionable "Add a
    /// verification.yaml…" for the dead-end "declares no checks", and writing the
    /// template would have made the empty state worse than not writing it.
    static let defaultContents = """
    # Verification checks for this project.
    #
    # Each entry is one check: its name, the command to run, and optionally the
    # shell to run it in (`$SHELL` by default). Commands run with the
    # workstream's worktree as the working directory, each in its own terminal
    # in the Verification tab.
    #
    #   rubocop:
    #     shell: fish
    #     command: bundle exec rubocop
    #
    #   rspec:
    #     command: bundle exec rspec
    #
    # Replace the example below with this project's real checks.

    example:
      command: echo "Edit verification.yaml to declare this project's checks."

    """

    /// Seed a newly created project with `defaultContents`.
    ///
    /// `Project.ConfigFile.writeDefault` is the whole of it: this delegates so
    /// callers and tests keep one name to reach for, and so the refusal rule —
    /// nothing is written when *either* spelling is present — has one
    /// implementation rather than four.
    @discardableResult
    static func writeDefault(projectDirectory: String) -> Bool {
        configFile.writeDefault(projectDirectory: projectDirectory)
    }
}
