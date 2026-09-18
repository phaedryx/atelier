// ABOUTME: The project's `initialization.yaml` — the steps run once when a worktree is created.
// ABOUTME: Project directory only, so it can never arrive with the repository.

import Foundation

/// A project's worktree setup: named steps, run in order, once, at creation.
///
/// This replaced the `bootstrap` namespace of `process-compose.yaml`. Setup is
/// a short ordered list of commands, which is not what a process supervisor is
/// for: the namespace had to carry `depends_on` graphs to express "then", and
/// `process-compose up -n bootstrap` against a namespace nobody declared idles
/// forever with no output rather than failing. A file whose whole schema is
/// "name, command, shell" says the same thing without either.
enum Initialization {}

extension Initialization {
    /// A project's declared setup steps, in the order the file declares them.
    ///
    /// **This file lives in the project directory and nowhere else**, and that is
    /// a trust decision rather than a convenience — the same one
    /// `Verification.Config` makes, for the same reasons. `Project.directory` is
    /// the repository's *home* (the `.bare` container in that layout), so a file
    /// there sits outside every work tree and cannot have arrived with the
    /// repository. CLAUDE.md's rule therefore settles it: approval is gated by a
    /// config's location, not its content, and a config in the project directory
    /// "was placed there by hand, outside git, and is never asked about". So
    /// there is no `ScriptTrust` fingerprint here and no `PhasePolicy` gate, and
    /// adding one would be answering a question that cannot arise.
    ///
    /// Two consequences follow and both are wanted. One set of steps serves every
    /// worktree of the project, so setup is edited in one place. And an agent
    /// working in a worktree — confined there by the "Restrict to worktree"
    /// system prompt — cannot edit the file that decides what runs when the next
    /// worktree is made. A worktree-local override would hand it exactly that,
    /// which is why there is no tier-one worktree lookup mirroring
    /// `ProcessCompose.Config.locate`'s.
    ///
    /// **The known hole, stated rather than papered over:** for an ordinary clone
    /// `Project.directory` *is* the checkout, so the file sits inside the work
    /// tree and can be committed. That hole already exists for process-compose's
    /// project-directory tier and for `verification.yaml`, and the rule is applied
    /// here unchanged rather than half-tightened.
    struct Config: Equatable {
        /// The file this was read from.
        let path: String
        /// Every declared step, in file order — which is run order.
        let steps: [Step]

        /// One step: a name, a command, and the shell to run it in.
        struct Step: Equatable {
            let name: String
            /// The command, as written. Run by `shell`, not parsed here.
            let command: String
            /// The shell named for this step, or nil to use the user's `$SHELL`.
            ///
            /// Kept `Optional` rather than resolved at parse time so the
            /// resolution stays with the spawn: `$SHELL` is read from the
            /// environment the app launched with, and a parsed config outliving a
            /// settings change should not pin a shell the user has since replaced.
            let shell: String?
        }

        /// The names, in run order.
        var stepNames: [String] {
            steps.map(\.name)
        }

        func step(named name: String) -> Step? {
            steps.first { $0.name == name }
        }
    }
}

extension Initialization.Config {
    /// What a load attempt found.
    ///
    /// Three cases, not two, for the reason `ProcessCompose.Config.declaredProcesses`
    /// returns nil rather than `[]` on a parse failure: a file Atelier cannot read
    /// must never render as "this project declares no setup", which is the same
    /// sentence a project with genuinely no steps gets and the only diagnostic
    /// either one has — a single line on the Info tab.
    ///
    /// The three cases and `config` are `Project.ConfigLoad`'s, shared with
    /// `Verification.Config.Load` — the mechanism is one file's, the *wording*
    /// below is this file's.
    typealias Load = Project.ConfigLoad<Initialization.Config>
}

extension Project.ConfigLoad where Contents == Initialization.Config {
    /// The steps that will run, in order. Empty whenever `unavailableReason`
    /// is set, so the two cannot describe different states.
    var steps: [Initialization.Config.Step] {
        config?.steps ?? []
    }

    var stepNames: [String] {
        config?.stepNames ?? []
    }

    /// Why nothing will run, or nil when something will.
    ///
    /// **This is the availability decision, not a mirror of one.** The gate
    /// the process-compose phases have — `PhasePolicy.plan` — has no
    /// counterpart here: there is no binary to resolve and no approval to
    /// check, so "will anything run" is exactly "did this file parse and does
    /// it declare anything". `Initialization.Runner` asks the same `load` and
    /// reports the same three cases, which is what keeps the Info row's note
    /// and the runner's refusal in step.
    ///
    /// Past tense, because the only place this is rendered is the Info row
    /// after setup has finished — the one difference from
    /// `Verification.Config.Load`'s otherwise identical set, and the reason the
    /// two are separate extensions on one shared enum rather than one copy.
    var unavailableReason: String? {
        switch self {
        case .missing:
            NSLocalizedString(
                "This project has no initialization.yaml, so no setup ran.",
                comment: "Info tab: no initialization config"
            )
        case let .invalid(reason):
            String(
                format: NSLocalizedString(
                    "This project's initialization.yaml could not be read, so no setup ran: %@",
                    comment: "Info tab: the config is present and broken"
                ),
                reason
            )
        case let .loaded(config):
            config.steps.isEmpty
                ? NSLocalizedString(
                    "This project's initialization.yaml declares no steps, so nothing ran.",
                    comment: "Info tab: the config parsed and is empty"
                )
                : nil
        }
    }
}

extension Initialization.Config {
    /// The file, described once: its two spellings, its template, and how to
    /// turn its text into steps.
    ///
    /// `Project.ConfigFile` owns the mechanics every project-directory config
    /// shares — first spelling present wins, nothing inside a work tree is read,
    /// a template is seeded only when neither spelling exists — and the trust
    /// argument behind them. What stays here is what is this file's alone: the
    /// names, the template, and the schema.
    static let configFile = Project.ConfigFile<Initialization.Config>(
        fileNames: ["initialization.yaml", "initialization.yml"],
        defaultContents: defaultContents,
        parse: { text, path in
            try Initialization.Config(
                path: path,
                steps: Project.parseCommandEntries(text, messages: messages).map {
                    Step(name: $0.name, command: $0.command, shell: $0.shell)
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
    /// its own nouns: a *step*, named after `initialization.yaml`.
    private static let messages = Project.CommandEntryMessages(
        notValidYAML: NSLocalizedString(
            "The file is not valid YAML: %@",
            comment: "initialization.yaml: Yams could not parse it"
        ),
        topLevelIsNotAMapping: NSLocalizedString(
            "The file must be a mapping of step names to their commands.",
            comment: "initialization.yaml: the top level is a list or a scalar"
        ),
        entryHasNoName: NSLocalizedString(
            "Every step needs a name.",
            comment: "initialization.yaml: a key that is not a non-empty string"
        ),
        entryIsNotAMapping: NSLocalizedString(
            "“%@” must be a mapping with a command:.",
            comment: "initialization.yaml: a step given as a bare string or a list"
        ),
        entryHasNoCommand: NSLocalizedString(
            "“%@” needs a command: to run.",
            comment: "initialization.yaml: a step with no command"
        ),
        entryHasAnUnusableShell: NSLocalizedString(
            "“%@” has a shell: that is not a shell name.",
            comment: "initialization.yaml: shell given as a list or a mapping"
        )
    )

    /// Read the project's setup steps.
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
    ///
    /// **File order is run order here**, which is why `Project.parseCommandEntries`
    /// walks `Yams.compose`'s nodes rather than decoding a dictionary — see its
    /// own doc comment.
    static func parse(_ text: String, path: String) -> Load {
        configFile.load(text: text, path: path)
    }
}

extension Initialization.Config {
    /// The file a newly created project starts with.
    ///
    /// Deliberately **not** localized, for the reason `Verification.Config`'s
    /// template is not: this is file content the user edits, not UI, and the
    /// keys are part of the schema.
    ///
    /// Every line is a comment, which is the opposite of that template's
    /// decision and deliberate for the opposite reason: a verification check
    /// runs only when somebody presses Run, but a step here runs unattended
    /// behind every new worktree — so an uncommented example would *execute*,
    /// per worktree, in every seeded project. A comment-only file loads as
    /// "declares no steps", which the Info tab reports as a note rather than
    /// a failure.
    static let defaultContents = """
    # Worktree setup for this project.
    #
    # Each entry is one step, run once when a new worktree is created, with the
    # worktree as the working directory. Steps run in this file's order and
    # setup halts on the first failure; progress and failures show on the
    # workstream's Info tab. `shell:` is optional and defaults to $SHELL.
    #
    # Steps run with Atelier's environment: every ATELIER_* variable and every
    # port declared in ports.yaml.
    #
    #   deps:
    #     command: bundle install
    #
    #   assets:
    #     shell: fish
    #     command: bun install && bun run build
    #
    # Uncomment and replace with this project's real setup steps. A file with
    # no steps means no setup runs.

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
