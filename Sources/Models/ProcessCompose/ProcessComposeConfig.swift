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
    /// A worktree-level override to load alongside a base config that lives in
    /// the project directory. Nil when the base config is itself in the
    /// worktree — then the override is its sibling, and `loadedFiles` resolves
    /// it from the base's own directory rather than recording it here.
    ///
    /// Only ever set for a project-directory base, so it is also the one loaded
    /// file that can be repository content while `isRepositoryProvided` is
    /// false; see `repositoryProvidedFiles`.
    let overridePath: String?

    /// process-compose also discovers `compose.yaml` and `compose.yml`, but that
    /// name belongs to docker compose far more often, and running the wrong tool
    /// is worse than offering nothing.
    ///
    /// Because Atelier now names every file with `-f` (see `loadedFiles`),
    /// leaving those names out of this list means process-compose never loads
    /// them either. That is the point: while discovery was left on, a repository
    /// could ship a benign `process-compose.yaml` for Atelier to display and
    /// approve, and a `compose.yaml` for process-compose to actually run —
    /// verified against v1.122.0, where `compose.yaml` wins outright and
    /// `process-compose.yaml` is never read.
    static let fileNames = ["process-compose.yaml", "process-compose.yml"]

    /// Override names, **in the order process-compose itself prefers them**.
    /// Verified against v1.122.0: with both extensions present, discovery loads
    /// `.yml` and ignores `.yaml`. The order is load-bearing — `firstPresent`
    /// resolves the override with it, so reversing it would silently change
    /// which file wins.
    static let overrideFileNames = ["process-compose.override.yml", "process-compose.override.yaml"]

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
    /// This list is the whole contract. `PhaseRunner.command` names each entry
    /// with `-f`, which turns process-compose's own discovery off, so the files
    /// that execute are exactly the files listed here — and `ScriptTrust`
    /// fingerprints and `ConfigApprovalView` displays the repository-provided
    /// subset of the same list. Approved set, displayed set, and executed set
    /// are equal by construction rather than by Atelier mirroring discovery's
    /// rules correctly.
    ///
    /// That mirror is what had to go. While a worktree config was left unnamed
    /// so discovery could pick up its sibling override, the gate could only ever
    /// be as correct as the mirror — and it was not: discovery also loads
    /// `compose.yaml`, which Atelier deliberately does not detect, so a
    /// repository could have one file approved and a different one run.
    ///
    /// Exactly one override, never both extensions. Naming both would load a
    /// file discovery would have ignored, which is a change to which file wins;
    /// `overrideFileNames` is ordered to match process-compose's own preference,
    /// so `firstPresent` resolves the same one discovery would have.
    var loadedFiles: [String] {
        guard isRepositoryProvided else {
            return [path] + [overridePath].compactMap { $0 }
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let override = Self.firstPresent(Self.overrideFileNames, in: directory)
            .map { directory.appendingPathComponent($0).path }
        return [path] + [override].compactMap { $0 }
    }

    /// The loaded files that arrived with the repository, and therefore have to
    /// be approved before an unattended phase runs them.
    ///
    /// Not the same as "`path` when `isRepositoryProvided`". Two cases make the
    /// difference load-bearing:
    ///
    /// - A repository-provided base config has a sibling
    ///   `process-compose.override.yml` beside it that `locate` never recorded
    ///   but `loadedFiles` names. That override is repository content that
    ///   executes, so approving only `path` would show the user a benign file
    ///   while an unseen sibling ran.
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
}
