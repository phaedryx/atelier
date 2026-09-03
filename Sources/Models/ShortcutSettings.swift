// ABOUTME: Settings keys and stored state for the Shortcut integration.
// ABOUTME: Key constants live here so non-view code can reference them without SettingsView.

import Foundation

extension Shortcut {
    enum Settings {
        /// Whether the Shortcut button appears on project rows. The button also requires a
        /// stored API token, so this is the user's way to keep a working key but hide the button.
        static let buttonEnabledKey = "atelier.shortcutButtonEnabled"

        /// Branch-name template, e.g. `tad@sc-${STORY_ID}-${SLUG}`. Empty means use the branch
        /// name Shortcut itself suggests. See `Shortcut.BranchName` for the variables.
        static let branchTemplateKey = "atelier.shortcutBranchTemplate"

        /// Posted after the token is written or cleared, so the sidebar can re-evaluate whether
        /// to show its button. Keychain presence is not observable, so this is the only signal.
        static let tokenChanged = Notification.Name("atelier.shortcutTokenChanged")

        /// Whether a project row shows the Shortcut button. All three conditions are required:
        /// a repo to make a worktree in, a token to call the API with, and the user's opt-in.
        static func shouldShowButton(isGitRepo: Bool, toggleEnabled: Bool, hasToken: Bool) -> Bool {
            isGitRepo && toggleEnabled && hasToken
        }
    }
}
