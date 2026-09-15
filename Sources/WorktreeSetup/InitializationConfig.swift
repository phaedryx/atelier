// ABOUTME: The project's `initialization.yaml` — the steps run once when a worktree is created.
// ABOUTME: Project directory only, so it can never arrive with the repository.

import Foundation
import Yams

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
    enum Load: Equatable {
        /// No `initialization.yaml` in the project directory.
        case missing
        /// A file is there and could not be read as one.
        case invalid(reason: String)
        /// Parsed. May legitimately declare zero steps.
        case loaded(Initialization.Config)

        var config: Initialization.Config? {
            if case let .loaded(config) = self {
                return config
            }
            return nil
        }

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
        /// after setup has finished.
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

    /// The names looked for, in order. The first that exists is the one read —
    /// a second is never merged, because two files whose precedence a reader has
    /// to hold in their head is the shape `ProcessCompose.Config` retired.
    static let fileNames = ["initialization.yaml", "initialization.yml"]

    /// Read the project's setup steps.
    ///
    /// `projectDirectory` must be `Project.directory` and never `Project.checkout`.
    /// In the container layout those differ, and passing the checkout would look
    /// inside `main/` — a work tree — which is both the wrong place and the one
    /// location this type exists to avoid.
    static func load(projectDirectory: String) -> Load {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        guard let path = fileNames
            .map({ directory.appendingPathComponent($0).path })
            .first(where: { fileManager.fileExists(atPath: $0) })
        else { return .missing }

        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .invalid(reason: NSLocalizedString(
                "The file could not be read.",
                comment: "initialization.yaml: present but unreadable"
            ))
        }
        return parse(text, path: path)
    }

    /// The parse, separated from the file system so the schema can be tested
    /// without one.
    ///
    /// **Ordered, which is why this walks `Yams.compose`'s nodes rather than
    /// decoding a `[String: Step]`.** A Swift dictionary has no order, and here
    /// order is not cosmetic the way it is for verification's rows: steps run in
    /// this sequence and each one may depend on the last, so a decoded config
    /// would run setup in an arbitrary order that changed between launches.
    static func parse(_ text: String, path: String) -> Load {
        let document: Yams.Node?
        do {
            document = try Yams.compose(yaml: text)
        } catch {
            return .invalid(reason: String(
                format: NSLocalizedString(
                    "The file is not valid YAML: %@",
                    comment: "initialization.yaml: Yams could not parse it"
                ),
                error.localizedDescription
            ))
        }

        // An empty file, or one holding nothing but comments, composes to nil.
        // That is a file declaring no steps rather than a broken one.
        guard let document else {
            return .loaded(Initialization.Config(path: path, steps: []))
        }
        guard let mapping = document.mapping else {
            return .invalid(reason: NSLocalizedString(
                "The file must be a mapping of step names to their commands.",
                comment: "initialization.yaml: the top level is a list or a scalar"
            ))
        }

        // No duplicate-name guard: **Yams refuses a duplicated key itself**, as a
        // parse error, so such a file lands in `.invalid` above and never reaches
        // this loop. Two steps of one name would be indistinguishable in every
        // report there is, so the refusal matters; it just is not this
        // function's to make.
        var steps: [Initialization.Config.Step] = []
        for (keyNode, valueNode) in mapping {
            guard let name = keyNode.string, !name.isEmpty else {
                return .invalid(reason: NSLocalizedString(
                    "Every step needs a name.",
                    comment: "initialization.yaml: a key that is not a non-empty string"
                ))
            }
            guard let entry = valueNode.mapping else {
                return .invalid(reason: String(
                    format: NSLocalizedString(
                        "“%@” must be a mapping with a command:.",
                        comment: "initialization.yaml: a step given as a bare string or a list"
                    ),
                    name
                ))
            }
            guard let command = entry["command"]?.string,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .invalid(reason: String(
                    format: NSLocalizedString(
                        "“%@” needs a command: to run.",
                        comment: "initialization.yaml: a step with no command"
                    ),
                    name
                ))
            }
            let shellNode = entry["shell"]
            if shellNode != nil, shellNode?.string == nil {
                return .invalid(reason: String(
                    format: NSLocalizedString(
                        "“%@” has a shell: that is not a shell name.",
                        comment: "initialization.yaml: shell given as a list or a mapping"
                    ),
                    name
                ))
            }
            let shell = shellNode?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            steps.append(Initialization.Config.Step(
                name: name,
                command: command,
                shell: (shell?.isEmpty ?? true) ? nil : shell
            ))
        }
        return .loaded(Initialization.Config(path: path, steps: steps))
    }
}
