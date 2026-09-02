// ABOUTME: Locates a worktree's process-compose config and records who wrote it.
// ABOUTME: Worktree first, then the project directory; location decides authorship.

import Foundation
import Yams

struct ProcessComposeConfig: Equatable {
    /// Absolute path of the config that will run.
    let path: String
    /// Whether the config arrived with the repository. A config in the project
    /// directory sits outside every worktree and was placed there by hand, so it
    /// is the user's; one inside the worktree came with a clone. This decides
    /// whether the unattended phases ask for approval.
    let isRepositoryProvided: Bool
    /// A worktree-level override that must be named explicitly, because naming
    /// the base config with `-f` turns off process-compose's own discovery.
    /// Nil when the base config is in the worktree, where discovery finds it.
    let overridePath: String?

    /// process-compose also discovers `compose.yaml` and `compose.yml`, but that
    /// name belongs to docker compose far more often, and running the wrong tool
    /// is worse than offering nothing.
    static let fileNames = ["process-compose.yaml", "process-compose.yml"]
    static let overrideFileNames = ["process-compose.override.yaml", "process-compose.override.yml"]

    static func locate(worktree: String, projectDirectory: String) -> ProcessComposeConfig? {
        let worktreeURL = URL(fileURLWithPath: worktree)
        if let name = firstPresent(fileNames, in: worktreeURL) {
            return ProcessComposeConfig(
                path: worktreeURL.appendingPathComponent(name).path,
                isRepositoryProvided: true,
                overridePath: nil
            )
        }

        let projectURL = URL(fileURLWithPath: projectDirectory)
        guard projectURL.standardizedFileURL != worktreeURL.standardizedFileURL,
              let name = firstPresent(fileNames, in: projectURL)
        else { return nil }

        return ProcessComposeConfig(
            path: projectURL.appendingPathComponent(name).path,
            isRepositoryProvided: false,
            overridePath: firstPresent(overrideFileNames, in: worktreeURL)
                .map { worktreeURL.appendingPathComponent($0).path }
        )
    }

    private static func firstPresent(_ names: [String], in directory: URL) -> String? {
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

    /// Every file process-compose will actually load, which is not the same as
    /// the ones `locate` recorded.
    ///
    /// `overridePath` is only ever set for a config in the project directory,
    /// because that one is named with `-f` and naming it turns process-compose's
    /// own discovery off, so a worktree override has to be named too. A config
    /// *in* the worktree is left unnamed precisely so discovery runs — and
    /// discovery picks up a sibling `process-compose.override.yaml` that
    /// `locate` never recorded. Reading only `path` there would miss a
    /// namespace the override declares and report `.empty`, silently skipping
    /// work the user really asked for.
    var loadedFiles: [String] {
        guard isRepositoryProvided else {
            return [path] + [overridePath].compactMap { $0 }
        }
        // Every present override, not just the first. process-compose loads
        // exactly one, and — verified against v1.122.0 — when both extensions
        // exist it takes `.yml`, the opposite of the order `overrideFileNames`
        // lists them in. Rather than encode a precedence that could change,
        // consider both: an override that turns out not to be loaded can only
        // move the answer from `.empty` to `.present` or `.unknown`, and both
        // of those fail towards running the phase. Guessing wrong in the other
        // direction is a silent skip, which is the failure this whole probe
        // exists to prevent.
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        return [path] + Self.overrideFileNames
            .map { directory.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// The loaded files that arrived with the repository, and therefore have to
    /// be approved before an unattended phase runs them.
    ///
    /// Not the same as "`path` when `isRepositoryProvided`". Two cases make the
    /// difference load-bearing:
    ///
    /// - A repository-provided base config is left unnamed so process-compose's
    ///   own discovery runs, and discovery picks up a sibling
    ///   `process-compose.override.yaml` that `locate` never recorded. That
    ///   override is repository content that executes, so approving only `path`
    ///   would show the user a benign file while an unseen sibling ran.
    /// - A config the *user* placed in the project directory is their own, but
    ///   `overridePath` beside it points into the **worktree**, which is
    ///   repository content and is named with `-f` explicitly. The base file
    ///   needs no approval; the override does.
    ///
    /// The user's own project-directory config is deliberately absent from this
    /// list: it was placed by hand outside git, and re-asking every time they
    /// edit it is friction with no risk behind it.
    var repositoryProvidedFiles: [String] {
        guard isRepositoryProvided else { return [overridePath].compactMap { $0 } }
        return loadedFiles
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
            if namespaces.contains(namespace) { return .present }
        }
        return unknown ? .unknown : .empty
    }

    /// Whether this config can be shown, with confidence, to assign zero
    /// processes to `namespace`. `PhaseRunner.startCommand` uses this to decide
    /// whether chaining a phase would just hang process-compose on an empty
    /// namespace — and it deliberately collapses `.unknown` into "not empty",
    /// because failing open is the safe direction when the only alternative is
    /// silently skipping a phase the user actually declared.
    func namespaceIsConfidentlyEmpty(_ namespace: String) -> Bool {
        namespacePresence(namespace) == .empty
    }
}
