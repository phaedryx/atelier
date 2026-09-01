// ABOUTME: Configuration model for .atelier.json per-project config.
// ABOUTME: Extends Atelier with vibe-specific worktree setup options.

import Foundation

struct WorktreeSetupConfig: Codable {
    /// Project-relative directory whose contents are rsync'd into every new
    /// worktree — the home for `.env` files and anything else deliberately kept
    /// out of git. Overridden per project with `"seed"` in `.atelier.json`.
    static let defaultSeedDirectory = "seed-files"

    /// What the default seed directory was called before it was renamed.
    /// Projects set up under the old name keep working: see `seedDirectory(in:)`.
    static let legacySeedDirectory = ".atelier-seed"

    var baseBranch: String
    var packageManager: PackageManager?
    var seed: String
    var symlinks: [String]
    var postSetupCommands: [String]

    enum PackageManager: String, Codable {
        case npm, yarn, pnpm, bun

        var installCommand: [String] {
            switch self {
            case .npm: return ["npm", "ci", "--prefer-offline"]
            case .yarn: return ["yarn", "install", "--immutable"]
            case .pnpm: return ["pnpm", "install", "--frozen-lockfile"]
            case .bun: return ["bun", "install", "--frozen-lockfile"]
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case baseBranch = "base_branch"
        case packageManager = "package_manager"
        case seed
        case symlinks
        case postSetupCommands = "post_setup_commands"
    }

    static let `default` = WorktreeSetupConfig(
        baseBranch: "development",
        packageManager: nil,
        seed: defaultSeedDirectory,
        symlinks: [
            "terraform.tfstate",
            "terraform.tfstate.backup",
            ".terraform",
            "volume",
        ],
        postSetupCommands: []
    )

    static func load(from projectDirectory: String) -> WorktreeSetupConfig {
        let url = URL(fileURLWithPath: projectDirectory)
            .appendingPathComponent(".atelier.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(WorktreeSetupConfig.self, from: data)
        else {
            return .default
        }
        return config
    }

    /// Absolute path of the seed directory for a project. A relative `seed`
    /// resolves against the project directory; an absolute or `~`-rooted one is
    /// taken as written, so a seed can live outside the repo entirely.
    ///
    /// A `seed` that resolves to the project directory itself, or that escapes it
    /// via `..`, falls back to the default — the sync copies a whole directory
    /// tree, and pointing it at the repo root would pour the repo (and `.git`)
    /// into every new worktree.
    /// A project seeded before the directory was renamed still has its files
    /// under the old name, and nothing in the repository records that. So when
    /// the default location is in play and it does not exist, the old name is
    /// used if it does — otherwise the rename would quietly stop seeding
    /// projects that were working, and the failure would surface as a worktree
    /// missing its `.env` rather than as anything about a rename.
    func seedDirectory(in projectDirectory: String) -> String {
        let fallback = Self.resolveSeed(Self.defaultSeedDirectory, in: projectDirectory)
            ?? (projectDirectory as NSString).appendingPathComponent(Self.defaultSeedDirectory)
        let resolved = Self.resolveSeed(seed, in: projectDirectory) ?? fallback

        guard resolved == fallback, !FileManager.default.fileExists(atPath: resolved) else {
            return resolved
        }
        guard let legacy = Self.resolveSeed(Self.legacySeedDirectory, in: projectDirectory),
              FileManager.default.fileExists(atPath: legacy)
        else { return resolved }
        return legacy
    }

    static func resolveSeed(_ seed: String, in projectDirectory: String) -> String? {
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let project = URL(fileURLWithPath: projectDirectory).standardizedFileURL.path

        if expanded.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: expanded).standardizedFileURL.path
            return absolute == project ? nil : absolute
        }

        let resolved = URL(fileURLWithPath: projectDirectory)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
        guard resolved != project, resolved.hasPrefix(project + "/") else { return nil }
        return resolved
    }
}

/// Declared in an extension so the memberwise initializer survives. Every field
/// is optional on the wire: a config that sets only `seed` must not fail to
/// decode, because `load` swallows the error and silently reverts the whole
/// config — including the seed — to the defaults.
extension WorktreeSetupConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        baseBranch = try container.decodeIfPresent(String.self, forKey: .baseBranch) ?? fallback.baseBranch
        packageManager = try container.decodeIfPresent(PackageManager.self, forKey: .packageManager)
        seed = try container.decodeIfPresent(String.self, forKey: .seed) ?? fallback.seed
        symlinks = try container.decodeIfPresent([String].self, forKey: .symlinks) ?? fallback.symlinks
        postSetupCommands = try container.decodeIfPresent([String].self, forKey: .postSetupCommands)
            ?? fallback.postSetupCommands
    }
}
