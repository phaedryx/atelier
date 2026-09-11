// ABOUTME: Locates a worktree's process-compose config and records who wrote it.
// ABOUTME: Explicitly-named files outrank generic ones; location decides authorship.

import Foundation
import Yams

/// The process-compose subsystem: its config schema, the client that drives
/// the daemon, and the phased execution model built on top.
enum ProcessCompose {}

extension ProcessCompose {
    struct Config: Equatable {
        /// Absolute path of the config that will run.
        let path: String
        /// Whether the config arrived with the repository. A config in the project
        /// directory sits outside every worktree and was placed there by hand, so it
        /// is the user's; one inside the worktree came with a clone. This decides
        /// whether the unattended phases ask for approval.
        let isRepositoryProvided: Bool

        /// process-compose also discovers `compose.yaml` and `compose.yml`, but that
        /// name belongs to docker compose far more often, and running the wrong tool
        /// is worse than offering nothing.
        ///
        /// Because Atelier names every file with `-f` (see `loadedFiles`), leaving
        /// those names out of this list means process-compose never loads them
        /// either. That is the point: while discovery was left on, a repository
        /// could ship a benign `process-compose.yaml` for Atelier to display and
        /// approve, and a `compose.yaml` for process-compose to actually run —
        /// verified against v1.122.0, where `compose.yaml` wins outright and
        /// `process-compose.yaml` is never read.
        static let fileNames = ["process-compose.yaml", "process-compose.yml"]

        /// The same file, named so that it can only be meant for Atelier.
        ///
        /// A repository may run process-compose for its own reasons — a `sfim`-style
        /// instance manager, a docker-free dev stack — and that file declares the
        /// project's own namespaces, not Atelier's five. Before this name existed,
        /// such a file was indistinguishable from an Atelier config and won the
        /// lookup outright, shadowing the user's real config in the project
        /// directory: `bootstrap` and `prepare` silently did nothing, Verification
        /// reported no checks, and Start ran `up -n execute` against a namespace
        /// nobody had declared — which does not fail, it idles forever with no
        /// output (measured against v1.122.0).
        ///
        /// The prefix is what a project uses to say which of its process-compose
        /// files is Atelier's. Nothing requires it: a project with only one
        /// process-compose file needs no disambiguation and the generic name still
        /// works.
        static let atelierFileNames = ["atelier.process-compose.yaml", "atelier.process-compose.yml"]

        /// The two places a config may sit, and what each one implies about who
        /// wrote it.
        private enum Location {
            /// Came with the repository, so its commands need approving before an
            /// unattended phase runs them.
            case worktree
            /// Placed by hand, outside git, by the user.
            case projectDirectory
        }

        private struct SearchTier {
            let names: [String]
            let location: Location
        }

        /// **Precedence follows explicitness, not location.**
        ///
        /// An `atelier.`-prefixed file is a project stating which of its
        /// process-compose files is Atelier's, so it outranks an unprefixed file
        /// wherever either one sits. Within a prefix, the worktree still outranks
        /// the project directory, because a worktree carrying its own config is
        /// being deliberate about *this* branch.
        ///
        /// The third tier beating the fourth is what it has always been, and is
        /// kept so that a project with a single unprefixed config — the common
        /// case, and every project that predates the prefix — is unaffected by any
        /// of this. The consequence is worth stating plainly: a repository that
        /// checks in a generic `process-compose.yaml` of its own still shadows an
        /// unprefixed project-directory config, and the fix is to name the
        /// project-directory file `atelier.process-compose.yaml` so it moves to
        /// tier two.
        private static let searchOrder: [SearchTier] = [
            SearchTier(names: atelierFileNames, location: .worktree),
            SearchTier(names: atelierFileNames, location: .projectDirectory),
            SearchTier(names: fileNames, location: .worktree),
            SearchTier(names: fileNames, location: .projectDirectory),
        ]

        static func locate(worktree: String, projectDirectory: String) -> ProcessCompose.Config? {
            let worktreeURL = URL(fileURLWithPath: worktree)
            let projectURL = URL(fileURLWithPath: projectDirectory)
            // A plain checkout opened directly is its own project directory. The
            // project-directory tiers are skipped there rather than deduplicated:
            // a file in that one directory arrived with the repository, so it has
            // to keep `isRepositoryProvided: true` and the approval gate that
            // comes with it.
            let projectIsDistinct = projectURL.standardizedFileURL != worktreeURL.standardizedFileURL

            for tier in searchOrder {
                let directory: URL
                switch tier.location {
                case .worktree:
                    directory = worktreeURL
                case .projectDirectory:
                    guard projectIsDistinct else { continue }
                    directory = projectURL
                }
                guard let name = firstPresent(tier.names, in: directory) else { continue }
                return ProcessCompose.Config(
                    path: directory.appendingPathComponent(name).path,
                    isRepositoryProvided: tier.location == .worktree
                )
            }
            return nil
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
        /// that execute are exactly the files listed here — and `ScriptTrust`
        /// fingerprints and `ConfigApprovalView` displays the repository-provided
        /// subset of the same list. Approved set, displayed set, and executed set
        /// are equal by construction rather than by Atelier mirroring discovery's
        /// rules correctly.
        ///
        /// That mirror is what had to go. While a worktree config was left unnamed
        /// so discovery could pick up a sibling file, the gate could only ever be as
        /// correct as the mirror — and it was not: discovery also loads
        /// `compose.yaml`, which Atelier deliberately does not detect, so a
        /// repository could have one file approved and a different one run.
        ///
        /// One config, one file. An earlier design also loaded a
        /// `process-compose.override.yml` from the worktree, so that a single
        /// project-directory config could be adjusted per worktree. That is what
        /// tier one of `searchOrder` is for now: a worktree that wants its own
        /// arrangement names its own `atelier.process-compose.yaml` and says so
        /// outright, rather than having two files merged by rules the user has to
        /// hold in their head to predict what runs.
        var loadedFiles: [String] {
            [path]
        }

        /// The loaded files that arrived with the repository, and therefore have to
        /// be approved before an unattended phase runs them.
        ///
        /// The user's own project-directory config is deliberately absent: it was
        /// placed by hand outside git, and re-asking every time they edit it is
        /// friction with no risk behind it.
        var repositoryProvidedFiles: [String] {
            isRepositoryProvided ? loadedFiles : []
        }

        /// Whether anything process-compose will load here came with the repository.
        /// The gate for `bootstrap` and `dispose`; `execute` is never gated.
        var requiresApproval: Bool {
            !repositoryProvidedFiles.isEmpty
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
