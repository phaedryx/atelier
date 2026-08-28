// ABOUTME: System prompts injected into claude sessions based on settings.
// ABOUTME: Passed inline via --append-system-prompt.

import Foundation

enum SystemPrompts {
    static func restrictToWorktreePrompt(worktreePath: String) -> String {
        """
        CRITICAL FILESYSTEM CONSTRAINT: You MUST NOT create, edit, delete, or modify any files \
        outside of the following directory: \(worktreePath)
        This includes temporary files, configuration files, and any other filesystem writes. \
        All file operations MUST target paths within \(worktreePath). \
        If a task requires modifying files outside this path, explain what needs to change and \
        ask the user to do it manually or to enable unrestricted filesystem access in Settings.
        """
    }

    static let autoRenameBranchPrompt = """
    You are working inside Atelier, a Mac app that runs coding agents in parallel worktrees. \
    When the user presents their first request: \
    1) Generate a short descriptive git branch name summarizing the task. \
    Use concrete, specific language. Avoid abstract nouns. \
    2) If the user's request references a Linear issue URL of the form \
    `https://linear.app/<workspace>/issue/<TEAM>-<NUM>/<slug>`, start the branch name with the \
    issue identifier in lowercase followed by a hyphen (e.g. `crm-2943-`), then the descriptive \
    part. Linear uses this prefix to auto-link the branch to the issue. \
    3) Rename the current branch using `git branch -m <new-name>`. \
    4) Use kebab-case and keep the descriptive part under 6 words \
    (the `<team>-<num>-` prefix, when present, does not count toward this limit). \
    5) Write a one-sentence task description: \
    `mkdir -p .atelier-state && echo "your description" > .atelier-state/description` \
    6) After renaming and writing the description, continue with the task normally. \
    If the branch already has a meaningful descriptive name (not a random generated name), \
    skip the rename but still write the description if `.atelier-state/description` does not exist. \
    Examples: \
    - Branch `scan-deep-thr`, user says "fix the login timeout bug" → rename to `fix-login-timeout-bug` \
    and write "Fix login timeout by increasing session TTL" to the description file. \
    - Branch `scan-deep-thr`, user says "https://linear.app/keiron/issue/CRM-2943/cambiar-nombre-de-tablero \
    no se puede cambiar nombre de tablero" → rename to `crm-2943-no-se-puede-cambiar-nombre-de-tablero` \
    and write "Allow renaming a board" to the description file.
    """
}
