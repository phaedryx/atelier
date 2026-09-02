// ABOUTME: Resolves the command that starts a workstream's local dev server.
// ABOUTME: Precedence: user override, then the selected detected runner.

import Foundation

/// The command that starts a workstream's dev server, and where it came from.
struct DevCommand: Equatable {
    enum Source: String, Equatable, Codable {
        /// Per-workstream command saved by the user in the Environment pane.
        case override
        /// Auto-detected process-compose config in the worktree.
        case processCompose
        /// Auto-detected dev script from the repository's package.json.
        case packageJSON
    }

    let command: String
    let source: Source
    let sourceDescription: String?
}

enum DevCommandResolver {
    private static let overrideKeyPrefix = "atelier.devCommand."
    private static let runnerKeyPrefix = "atelier.devRunner."

    /// Config file names that mean "this worktree is driven by process-compose",
    /// and the override names that go with them.
    ///
    /// Aliases, not copies. These were second definitions of the same two lists,
    /// and the override one had drifted: it still listed `.yaml` before `.yml`
    /// after `ProcessComposeConfig` was corrected to process-compose's own
    /// preference (`.yml` wins, verified against v1.122.0). Two copies of a
    /// discovery rule is exactly how that class of bug recurs, so there is one
    /// definition of each and it lives with the type that owns the contract.
    static let processComposeFileNames = ProcessComposeConfig.fileNames
    static let processComposeOverrideFileNames = ProcessComposeConfig.overrideFileNames

    // MARK: - Per-workstream override

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

    // MARK: - Runner selection

    /// Which detected runner the project prefers, when more than one was found.
    /// Stored per project, because the choice is about the repository's shape
    /// rather than about one workstream.
    static func runnerKey(for projectDirectory: String) -> String {
        runnerKeyPrefix + projectDirectory
    }

    static func selectedRunner(for projectDirectory: String) -> DevCommand.Source? {
        guard let raw = UserDefaults.standard.string(forKey: runnerKey(for: projectDirectory)) else { return nil }
        return DevCommand.Source(rawValue: raw)
    }

    static func selectRunner(_ source: DevCommand.Source?, for projectDirectory: String) {
        guard let source else {
            UserDefaults.standard.removeObject(forKey: runnerKey(for: projectDirectory))
            return
        }
        UserDefaults.standard.set(source.rawValue, forKey: runnerKey(for: projectDirectory))
    }

    // MARK: - Resolution

    /// Every runner detected for a worktree, best first.
    ///
    /// process-compose leads because a repository only grows one of these files
    /// deliberately, while a `dev` script is near-universal and usually starts a
    /// subset of the stack.
    static func candidates(in directory: String, projectDirectory: String) -> [DevCommand] {
        [
            detectProcessCompose(in: directory, projectDirectory: projectDirectory),
            detectPackageScript(in: directory),
        ].compactMap { $0 }
    }

    /// The detected runner to use: the project's choice if it is still present,
    /// otherwise the best candidate.
    static func detected(in directory: String, projectDirectory: String) -> DevCommand? {
        let found = candidates(in: directory, projectDirectory: projectDirectory)
        if let selected = selectedRunner(for: projectDirectory),
           let match = found.first(where: { $0.source == selected })
        {
            return match
        }
        return found.first
    }

    /// Resolution order: user override, then the selected detected runner.
    /// `override` is the per-workstream override already loaded by the caller.
    static func resolve(
        workingDirectory: String,
        projectDirectory: String,
        override: String?
    ) -> DevCommand? {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return DevCommand(command: override, source: .override, sourceDescription: nil)
        }
        return detected(in: workingDirectory, projectDirectory: projectDirectory)
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
    /// Resolved through `ProcessComposeConfig`, so this fallback names the same
    /// files the gated builders do.
    ///
    /// It used to leave a worktree config unnamed and let process-compose's own
    /// discovery find the override. That is not an approval bypass — Start is
    /// ungated by an explicit decision, and this command is displayed before it
    /// runs — but it meant Start resolved its files by discovery while bootstrap
    /// and dispose named theirs, so the two could run *different files for the
    /// same project*: discovery loads `compose.yaml`, which Atelier does not
    /// detect. One resolver, one answer.
    static func detectProcessCompose(in directory: String, projectDirectory: String) -> DevCommand? {
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

    private static func configName(in directory: URL) -> String? {
        processComposeFileNames.first {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    private static func overrideName(in directory: URL) -> String? {
        processComposeOverrideFileNames.first {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    // MARK: - package.json detection

    /// The dev command from the repository's package.json, if it has a dev script.
    static func detectPackageScript(in directory: String) -> DevCommand? {
        guard let script = devScript(in: directory) else { return nil }
        let manager = packageManager(in: directory)
        return DevCommand(
            command: "\(manager) run \(script)",
            source: .packageJSON,
            sourceDescription: "package.json"
        )
    }

    /// The package manager to use, inferred from lockfiles. Defaults to npm.
    static func packageManager(in directory: String) -> String {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: directory)
        if fm.fileExists(atPath: url.appendingPathComponent("bun.lock").path)
            || fm.fileExists(atPath: url.appendingPathComponent("bun.lockb").path)
        {
            return "bun"
        }
        if fm.fileExists(atPath: url.appendingPathComponent("pnpm-lock.yaml").path) {
            return "pnpm"
        }
        if fm.fileExists(atPath: url.appendingPathComponent("yarn.lock").path) {
            return "yarn"
        }
        return "npm"
    }

    /// The name of the `dev` script in package.json, if any.
    static func devScript(in directory: String) -> String? {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data),
              let dict = json as? [String: Any],
              let scripts = dict["scripts"] as? [String: Any],
              let dev = scripts["dev"] as? String,
              !dev.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return "dev"
    }
}
