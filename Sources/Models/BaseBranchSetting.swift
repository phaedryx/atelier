// ABOUTME: Which branch new worktrees are cut from, as an app-wide setting.
// ABOUTME: Replaces .atelier.json's base_branch, which went with the .atelier.json reader.

import Foundation

enum BaseBranchSetting: String, CaseIterable, Identifiable {
    case main
    case master
    case trunk
    case develop
    /// Ask git what the repository's default branch is.
    case repositoryDefault

    var id: String {
        rawValue
    }

    static let storageKey = "atelier.baseBranch"

    var label: String {
        self == .repositoryDefault ? NSLocalizedString("Repository default", comment: "") : rawValue
    }

    static var current: BaseBranchSetting {
        get {
            UserDefaults.standard.string(forKey: storageKey)
                .flatMap(BaseBranchSetting.init(rawValue:)) ?? .main
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    /// The branch name to use for a project. A named branch is used verbatim;
    /// `repositoryDefault` asks git via `GitOperations.defaultBranch`, which
    /// never returns an empty string (worst case `"HEAD"`) — an empty branch
    /// name would fail a worktree creation with an obscure git error.
    static func resolve(for projectDirectory: String) -> String {
        let setting = current
        guard setting == .repositoryDefault else { return setting.rawValue }
        // GitOperations.defaultBranch returns a non-optional String and already
        // falls back on its own, so there is nothing to coalesce here.
        return GitOperations.defaultBranch(at: projectDirectory)
    }
}
