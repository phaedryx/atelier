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

    /// Whether this config can be shown, with confidence, to assign zero
    /// processes to `namespace` — across both the base file and the override,
    /// when one exists. False whenever that confidence isn't there: the
    /// namespace actually appears on some process, or either file could not be
    /// read or parsed. `PhaseRunner.startCommand` uses this to decide whether
    /// chaining a phase would just hang process-compose on an empty
    /// namespace — and a parse failure must fail open into "not empty" rather
    /// than into silently skipping a phase the user actually declared.
    func namespaceIsConfidentlyEmpty(_ namespace: String) -> Bool {
        for file in [path, overridePath].compactMap({ $0 }) {
            guard let namespaces = Self.declaredNamespaces(at: file) else { return false }
            if namespaces.contains(namespace) { return false }
        }
        return true
    }
}
