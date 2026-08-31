// ABOUTME: Configuration model for .atelier.json per-project config.
// ABOUTME: Extends Atelier with vibe-specific worktree setup options.

import Foundation

struct WorktreeSetupConfig: Codable, Sendable {
    /// Project-relative directory whose contents are rsync'd into every new
    /// worktree — the home for `.env` files and anything else deliberately kept
    /// out of git. Overridden per project with `"seed"` in `.atelier.json`.
    static let defaultSeedDirectory = ".atelier-seed"

    var baseBranch: String
    var packageManager: PackageManager?
    var seed: String
    var symlinks: [String]
    var postSetupCommands: [String]

    enum PackageManager: String, Codable, Sendable {
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
    func seedDirectory(in projectDirectory: String) -> String {
        let expanded = (seed as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return expanded }
        return URL(fileURLWithPath: projectDirectory)
            .appendingPathComponent(expanded)
            .path
    }
}

// Declared in an extension so the memberwise initializer survives. Every field
// is optional on the wire: a config that sets only `seed` must not fail to
// decode, because `load` swallows the error and silently reverts the whole
// config — including the seed — to the defaults.
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
