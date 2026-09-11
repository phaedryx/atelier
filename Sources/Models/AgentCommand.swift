// ABOUTME: Builds the command that launches a coding agent, for the Coding Agent tab and for spawned tabs.
// ABOUTME: Extracted from TerminalContainerView so a non-view caller — the IPC tools — can build one too.

import Foundation

extension Workstream {
    /// How a coding agent is invoked in a terminal surface.
    ///
    /// This exists because there are now two callers. `TerminalContainerView`
    /// builds the Coding Agent tab's command, with its resume-then-fresh
    /// fallback; `open_agent_tab` builds a fresh one for a surface it is about
    /// to create, from `IPC.Service`, which is an actor with no view and no
    /// `@AppStorage`. What the two must agree on is the *system prompt*, and
    /// that agreement is the whole reason this type is not just a second copy of
    /// the flags — see `systemPrompt`.
    enum AgentCommand {
        /// The single `--append-system-prompt` value, or nil when no prompt applies.
        ///
        /// **One string, never several flags.** Claude Code accepts one
        /// `--append-system-prompt` per invocation and the last one wins, so
        /// active prompts are joined here rather than passed separately.
        ///
        /// **`mcpConfigWritten`, not "is IPC enabled".** The IPC prompt tells the
        /// agent it has peers and how to reach them, and it is gated on the MCP
        /// config having actually been written — the same condition that adds
        /// `--mcp-config`. An agent told it has peers but handed no server would
        /// call tools that do not exist, so the prompt and the config appear and
        /// disappear together. Any new gate belongs on the written config, not on
        /// the setting.
        static func systemPrompt(
            allowOutsideWorktree: Bool,
            autoRenameBranch: Bool,
            worktreePath: String,
            workstreamName: String,
            mcpConfigWritten: Bool
        ) -> String? {
            var parts: [String] = []
            if !allowOutsideWorktree {
                parts.append(SystemPrompts.restrictToWorktreePrompt(worktreePath: worktreePath))
            }
            if autoRenameBranch {
                parts.append(SystemPrompts.autoRenameBranchPrompt)
            }
            if mcpConfigWritten {
                parts.append(SystemPrompts.agentIPCPrompt(workstreamName: workstreamName))
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }

        /// A fresh agent invocation for a surface that has never held one.
        ///
        /// No resume half, deliberately: `--resume` names a session that must
        /// already exist, and a surface being created now has none. The Coding
        /// Agent tab's resume-then-fresh fallback stays where it is, because it
        /// is about recovering *that* tab's session across a relaunch.
        ///
        /// `sessionID` must not be the workstream id. That id is the Coding Agent
        /// tab's own session, and handing it to a second agent in the same
        /// workstream makes two processes fight over one transcript. Callers pass
        /// the new surface's id, which is unique per tab by construction.
        static func fresh(
            claudePath: String,
            sessionID: String,
            sessionName: String?,
            bypassPermissions: Bool,
            systemPrompt: String?,
            mcpConfigPath: String?,
            settingsPath: String?,
            initialPrompt: String?
        ) -> String {
            var builder = CommandBuilder(claudePath)
            builder.option("--session-id", sessionID)
            if let sessionName, !sessionName.isEmpty {
                builder.option("--name", sessionName)
            }
            if bypassPermissions {
                builder.flag("--dangerously-skip-permissions")
            }
            if let systemPrompt {
                builder.option("--append-system-prompt", systemPrompt)
            }
            if let mcpConfigPath {
                builder.option("--mcp-config", mcpConfigPath)
            }
            if let settingsPath {
                builder.option("--settings", settingsPath)
            }
            if let initialPrompt, !initialPrompt.isEmpty {
                // `--` ends option parsing: `--mcp-config <configs...>` is
                // variadic in the CLI, so without it a prompt following that
                // option is consumed as a second config path — a ~2KB
                // "filename" the CLI dies opening (ENAMETOOLONG), before any
                // session exists, losing the prompt. Emitted with the prompt
                // rather than after the config so an option added between
                // them cannot reopen the hole.
                builder.flag("--")
                // Positional, and quoted here because `arg` deliberately does not
                // quote — every other value on this command goes through
                // `option`, which does.
                builder.arg(CommandBuilder.shellQuote(initialPrompt))
            }
            // Through the login shell for the same reason the Coding Agent's
            // command is: the agent shells out, and a PATH assembled without the
            // user's profile is missing most of what it will reach for.
            return CommandBuilder.inLoginShell(builder.command)
        }

        /// Wraps an agent invocation in the workstream's tmux session, or returns
        /// it unchanged when there is no tmux to wrap it in.
        ///
        /// `tmuxPath` is nil both when tmux mode is off and when tmux is not
        /// installed, which is the same answer — the caller resolves that, this
        /// owns what the wrapping *is*. Shared because the Coding Agent tab and
        /// `create_workstream`'s seeded launch must land in the *same* session:
        /// a second copy deriving the name differently would leave
        /// `Workstream.Archiver` killing a session nothing is running in.
        static func tmuxWrapped(
            _ command: String,
            tmuxPath: String?,
            projectName: String,
            workstreamName: String,
            environmentVars: [String: String]
        ) -> String {
            guard let tmuxPath else { return command }
            return TmuxSession.wrapCommand(
                tmuxPath: tmuxPath,
                sessionName: TmuxSession.sessionName(
                    project: projectName,
                    workstream: workstreamName,
                    role: "agent"
                ),
                command: command,
                environmentVars: environmentVars,
                respawnOnExit: true
            )
        }
    }
}
