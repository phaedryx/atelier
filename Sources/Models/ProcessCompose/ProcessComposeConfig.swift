// ABOUTME: Locates a worktree's process-compose config and records who wrote it.
// ABOUTME: Worktree first, then the project directory; location decides authorship.

import Foundation

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
}
