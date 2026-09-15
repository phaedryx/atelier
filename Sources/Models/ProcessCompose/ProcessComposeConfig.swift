// ABOUTME: Locates a project's execution.process-compose.yaml — one name, one place.
// ABOUTME: The project directory, outside every work tree, so it cannot arrive with a clone.

import Foundation
import os
import Yams

private let logger = Logger(subsystem: "atelier", category: "processcompose.config")

/// The process-compose subsystem: its config schema, the client that drives
/// the daemon, and the phased execution model built on top.
enum ProcessCompose {}

extension ProcessCompose {
    struct Config: Equatable {
        /// Absolute path of the config that will run.
        let path: String

        /// The names looked for, in order. The first that exists is the one read.
        ///
        /// **One name, one place, no tiers.** This replaced a four-tier search —
        /// `atelier.process-compose.y*ml` then `process-compose.y*ml`, each in the
        /// worktree and then in the project directory — whose precedence a reader
        /// had to hold in their head to predict what would run. The `execution.`
        /// prefix is what makes a single name safe to demand: a repository may run
        /// process-compose for its own reasons, and a generic `process-compose.yaml`
        /// is indistinguishable from an Atelier config, so nothing generic is read
        /// at all now.
        ///
        /// Two names process-compose itself would discover are deliberately absent:
        /// `compose.yaml`, which belongs to docker compose far more often than not,
        /// and the `process-compose.y*ml` pair this replaced. Because
        /// `ProcessCompose.PhaseRunner.command` names the located file with `-f`,
        /// process-compose's own discovery is off, so a name missing from this list
        /// is a name that never executes — verified against v1.122.0, where
        /// `compose.yaml` wins discovery outright and `process-compose.yaml` is
        /// never read.
        static let fileNames = ["execution.process-compose.yaml", "execution.process-compose.yml"]

        /// Find the project's config.
        ///
        /// **The project directory and nowhere else**, and that is a trust decision
        /// rather than a convenience — the rule `Verification.Config` already
        /// states, applied unchanged. `Project.directory` is the repository's *home*,
        /// the `.bare` container in that layout, so a file there sits outside every
        /// work tree and cannot have arrived with a clone. It was placed by hand,
        /// which is why there is no `ScriptTrust` fingerprint, no approval sheet and
        /// no approval precondition in `WorktreeSetup.PhasePolicy` any more: those
        /// gated a worktree tier that no longer exists.
        ///
        /// Two consequences, both wanted. One config serves every worktree of the
        /// project, so a stack is edited in one place. And an agent confined to its
        /// worktree by the "Restrict to worktree" system prompt cannot edit the file
        /// whose commands Atelier runs unattended at worktree creation and archive.
        /// There is deliberately no worktree tier, for exactly that reason.
        ///
        /// **The known hole, stated rather than papered over:** for an ordinary
        /// clone `Project.directory` *is* the checkout, so the file sits inside the
        /// work tree and can be committed. `Verification.Config` accepts the same
        /// hole, and the rule is applied here unchanged rather than half-tightened:
        /// sniffing whether the file is git-tracked would make the gate depend on a
        /// second fact the user cannot see.
        ///
        /// `projectDirectory` must be `Project.directory` and never
        /// `Project.checkout`. In the container layout those differ, and passing the
        /// checkout looks inside `main/` — a work tree, both the wrong place and the
        /// one location this lookup exists to avoid — where the config is simply
        /// never found.
        static func locate(projectDirectory: String) -> ProcessCompose.Config? {
            let directory = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            guard let name = firstPresent(fileNames, in: directory) else { return nil }
            return ProcessCompose.Config(path: directory.appendingPathComponent(name).path)
        }

        static func firstPresent(_ names: [String], in directory: URL) -> String? {
            names.first { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        }

        // MARK: - Namespace declarations

        /// The wire shape needed to find declared namespaces: every other key in a
        /// process-compose.yaml (env, depends_on, command, ...) is irrelevant here.
        private struct NamespaceFile: Decodable {
            struct Process: Decodable {
                let namespace: String?
            }

            let processes: [String: Process]?
        }

        /// Namespace names declared by at least one process in one file, read
        /// directly rather than by asking process-compose (`namespace list` would
        /// mean spawning a process from a property that must stay cheap to call
        /// speculatively). A process with no `namespace:` key belongs to
        /// process-compose's own default namespace and contributes nothing here.
        ///
        /// Nil means the file could not be read, or did not parse as a
        /// process-compose config at all (no `processes:` key) — the two cases a
        /// caller must treat as "unknown", never as "no namespaces", so a parse
        /// bug can never masquerade as an empty namespace.
        private static func declaredNamespaces(at path: String) -> Set<String>? {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            guard let file = try? YAMLDecoder().decode(NamespaceFile.self, from: text),
                  let processes = file.processes
            else { return nil }
            return Set(processes.values.compactMap(\.namespace))
        }

        /// The processes this config declares in a namespace, or nil if a file
        /// could not be read or decoded.
        ///
        /// The selection UI needs these *before* anything is running, so it cannot
        /// read the live API: the whole point is choosing what `execute` will
        /// start. nil is "unknown" for the same reason `declaredNamespaces` uses
        /// it — a parse failure must never look like "this namespace is empty",
        /// which here would silently offer no choices at all.
        ///
        /// **A file with no `processes:` key is skipped, not a parse failure**, and
        /// that distinction is the whole difference between this and
        /// `declaredNamespaces`. A config that sets only `environment:` or
        /// `version:`, or that holds nothing but a comment, declares no processes;
        /// it is not a file Atelier failed to read. Reporting nil for that shape
        /// would tell the user "these files could not be parsed, so the verify
        /// checks are unknown" — a refusal, for a config process-compose runs —
        /// and would silently offer the Execution checklist no processes.
        ///
        /// The loop over `loadedFiles` is the contract rather than a convenience:
        /// later files win on name, matching process-compose's own semantics, so
        /// the answer stays right if the loaded set ever grows past one file again.
        func declaredProcesses(in namespace: String) -> [String]? {
            var namespaceByProcess: [String: String] = [:]
            for file in loadedFiles {
                guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
                guard let decoded = try? YAMLDecoder().decode(NamespaceFile.self, from: text) else {
                    // A file holding no YAML document at all — empty, or nothing
                    // but comments — makes Yams throw rather than decode to an
                    // absent `processes:`. That is the same placeholder case as the
                    // guard below and gets the same answer; anything else really
                    // did fail to decode. Re-parsed only here, on the failure path,
                    // because this function is called per render.
                    if case .some(.none) = try? Yams.load(yaml: text) {
                        continue
                    }
                    return nil
                }
                guard let processes = decoded.processes else { continue }
                for (name, process) in processes {
                    namespaceByProcess[name] = process.namespace ?? ""
                }
            }
            return namespaceByProcess
                .filter { $0.value == namespace }
                .keys
                .sorted()
        }

        /// What this config says about a namespace. Three answers, not two,
        /// because "we could not tell" has to be actionable: a file Yams cannot
        /// decode but process-compose accepts — a top-level `include`, a
        /// `namespace` given as a list — is neither present nor empty, and a
        /// caller that treats it as present will run a namespace that may not
        /// exist and wait out its whole deadline for an answer.
        enum NamespacePresence: Equatable {
            /// Every file parsed, and none of them put a process in the namespace.
            case empty
            /// Some process declares it.
            case present
            /// A file could not be read, or did not parse as a process-compose
            /// config at all. Never treat this as `empty`: a parse bug must not
            /// silently skip a phase the project really declared.
            case unknown
        }

        /// Every file process-compose will load, in the order it loads them.
        ///
        /// This list is the whole contract. `ProcessCompose.PhaseRunner.command` names each entry
        /// with `-f`, which turns process-compose's own discovery off, so the files
        /// that execute are exactly the files `locate` found. Located set and
        /// executed set are equal by construction rather than by Atelier mirroring
        /// discovery's rules correctly — and a mirror is what had to go: discovery
        /// also loads `compose.yaml`, a name Atelier deliberately does not read, so
        /// a repository could once have had one file displayed and a different one
        /// run.
        ///
        /// One config, one file. An earlier design merged a worktree
        /// `process-compose.override.yml` into a project-directory base, and a later
        /// one gave the worktree its own `atelier.process-compose.yaml`. Both are
        /// gone: nothing inside a work tree is read at all. The array stays an array
        /// because it, not `path`, is what `PhaseRunner.command` names with `-f`, and
        /// the answer stays right if the loaded set ever grows past one file again.
        var loadedFiles: [String] {
            [path]
        }

        /// Whether the files that will be loaded, taken together, declare
        /// `namespace`.
        func namespacePresence(_ namespace: String) -> NamespacePresence {
            var unknown = false
            for file in loadedFiles {
                guard let namespaces = Self.declaredNamespaces(at: file) else {
                    unknown = true
                    continue
                }
                if namespaces.contains(namespace) {
                    return .present
                }
            }
            return unknown ? .unknown : .empty
        }
    }
}

extension ProcessCompose.Config {
    /// The file a newly created project starts with.
    ///
    /// Deliberately **not** localized, for the reason `Verification.Config`'s
    /// template is not: this is file content the user edits, not UI, and the keys
    /// are part of process-compose's schema.
    ///
    /// **The example process is real and uncommented, and that is load-bearing
    /// rather than friendly.** A file of nothing but comments — or one whose
    /// `processes:` key is present but null — fails to decode, so
    /// `namespacePresence` answers `.unknown`; and `ProcessCompose.RunCommandPlan`
    /// gates `execute` on `.empty` and **only** `.empty`, deliberately failing open
    /// on `.unknown` so a parse bug cannot silently skip a namespace the project
    /// really declared. A commented-out template would therefore have shipped every
    /// new project with an enabled Start that runs `up -n execute` against a
    /// namespace nobody declared — which does not fail and does not exit, it idles
    /// forever with no output (measured against v1.122.0).
    /// `ProcessComposeConfigTests` pins that this template is not `.unknown`.
    static let defaultContents = """
    # The processes Atelier runs for this project.
    #
    # Four namespaces, each run at a different moment:
    #
    #   bootstrap  once, in the background, when a workstream's worktree is created
    #   prepare    to completion before each Start, ahead of execute
    #   execute    the long-lived dev stack the Execution tab's Start button runs
    #   dispose    once, when a workstream is purged
    #
    # A process with no `namespace:` belongs to none of them and is never run.
    #
    # Commands run with the workstream's worktree as the working directory, and
    # receive the ATELIER_* variables and every port named in ports.yaml.
    # process-compose puts a command body through envsubst before the shell sees
    # it, so a *shell* variable has to be written $$VAR rather than $VAR.
    #
    #   processes:
    #     install:
    #       namespace: bootstrap
    #       command: bun install
    #     web:
    #       namespace: execute
    #       command: bun run dev --port $WEB_PORT
    #
    # Replace the example below with this project's real processes.

    processes:
      example:
        namespace: execute
        command: echo "Edit execution.process-compose.yaml to declare this project's processes."

    """

    /// Seed a newly created project with `defaultContents`.
    ///
    /// Called only by the two paths that *create* the project directory — a new
    /// empty project and a fresh clone — and never by the paths that adopt a
    /// directory the user already had, which would drop an untracked file into a
    /// repository they merely registered. The same rule, and the same two call
    /// sites, as `Verification.Config.writeDefault`.
    ///
    /// Does nothing when either name in `fileNames` is already present, and
    /// reports rather than throws: a convenience template must not fail project
    /// creation, but a write that silently did not happen is worse than one that
    /// says so.
    @discardableResult
    static func writeDefault(projectDirectory: String) -> Bool {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        guard !fileNames.contains(where: {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) else { return false }

        let path = directory.appendingPathComponent(fileNames[0])
        do {
            try defaultContents.write(to: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            logger.warning(
                "[Atelier] could not write default execution.process-compose.yaml: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
