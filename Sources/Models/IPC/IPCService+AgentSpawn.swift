// ABOUTME: IPC.Service's three spawning tools — a tab with an agent in it, and two new workstreams.
// ABOUTME: Holds the launch pre-flight and the command and environment a spawned agent runs with.

import Foundation

extension IPC.Service {
    /// Opens a terminal tab in the caller's own workstream, optionally
    /// starting an agent in it.
    ///
    /// Three steps in two isolation domains, and the middle one is why this
    /// is not a single `MainActor.run`: building the environment asks git for
    /// the default branch and reads `ports.yaml`, and the main actor has no
    /// business waiting on either.
    ///
    /// **That middle step runs here, in the actor, and not in the closures
    /// `spawnTerminalTab` calls.** Those closures take the surface id, which
    /// `WorkspaceModel.addTerminal()` mints, so they are evaluated *inside*
    /// the main-actor hop — and for one round the whole of both ran there:
    /// `Git.Operations.defaultBranch` (up to six sequential git spawns on a
    /// cold cache), `ProcessCompose.PhaseEnvironment.variables` (a `ports.yaml`
    /// read plus a liveness probe per declared port), `IPC.Config.write` and
    /// `StatusLine.Config.write`, all on the main thread, for a tool call the
    /// user did not make. Nothing in that list depends on the surface: the id
    /// reaches the environment as one `ATELIER_SURFACE_ID` entry and the
    /// command as one `--session-id`. So both are built to completion out
    /// here, and the closures do a dictionary write and a string build.
    ///
    /// The tab and its surface stay in **one** hop, deliberately. Minting the
    /// id in a first hop and creating the surface in a second would leave a
    /// terminal tab on the strip with no surface behind it for the length of
    /// this work — and `SingleTerminalView` creates a surface on a miss, so a
    /// user looking at that workstream would get a plain shell where the
    /// agent was supposed to be.
    ///
    /// The agent is started by *creating the surface already running it*,
    /// never by typing into a shell. There is no paste, no synthetic Return,
    /// and no question of whether the pane was interruptible — the tab does
    /// not exist until it exists running the right thing.
    func openAgentTab(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        let arguments = ToolArguments(request)
        let title = Names.sanitized(arguments.optional("title") ?? "", limit: 40, fallback: "")
        // An empty `prompt` is not a request for an agent, and is now read as
        // absent. It used to arrive as `Optional("")`, which `startsAgent`
        // already treated as no agent while the `claude`-not-found guard
        // below treated it as one — so a caller sending `prompt: ""` on a
        // machine without `claude` was refused a plain terminal it would
        // otherwise have been given.
        let prompt = arguments.optionalTrimmed("prompt")

        do {
            let plan = try await MainActor.run {
                try WorkspaceActions.shared.agentTabPlan(workstreamID: workstreamID)
            }

            // An agent was asked for but there is no `claude` to start. Refuse
            // rather than opening a bare shell the caller would believe was an
            // agent — a tab that silently is not what was asked for is worse
            // than no tab.
            if prompt != nil, plan.claudePath == nil {
                return .failure(
                    id: request.id,
                    "Cannot start an agent: Atelier could not find the `claude` binary. Omit `prompt` to open a plain terminal tab instead."
                )
            }

            let startsAgent = prompt?.isEmpty == false
            // Both built before the hop — see this method's doc comment.
            let environmentBase = WorkspaceActions.environmentBase(for: plan)
            let agentCommand = agentCommand(plan: plan, prompt: prompt)
            let surfaceID = try await MainActor.run {
                try WorkspaceActions.shared.spawnTerminalTab(
                    workstreamID: workstreamID,
                    title: title.isEmpty ? nil : title,
                    command: { surfaceID in
                        agentCommand?.command(surfaceID: surfaceID)
                    },
                    environment: { surfaceID in
                        WorkspaceActions.environment(base: environmentBase, surfaceID: surfaceID)
                    }
                )
            }

            let answer = startsAgent
                ? "Started an agent in a new tab, surface \(surfaceID.uuidString). "
                + "It is not addressable yet: poll list_tabs until that surface reports a peer id, then send_message to it."
                : "Opened a terminal tab, surface \(surfaceID.uuidString)."
            return .success(id: request.id, .text(answer))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    /// Everything a spawned agent's command line needs except the surface it
    /// will run on.
    ///
    /// The split exists so the two config files are written and the system
    /// prompt assembled off the main actor; `openAgentTab`'s doc comment has
    /// the rest of that argument. What is left here is a `CommandBuilder`
    /// run, which is string work.
    private struct SpawnedAgent: Sendable {
        let claudePath: String
        let bypassPermissions: Bool
        let systemPrompt: String?
        let mcpConfigPath: String?
        let settingsPath: String?
        let initialPrompt: String

        /// **The session id is the surface's, never the workstream's.** The
        /// workstream id is the Coding Agent tab's own Claude session; a
        /// second agent handed it would fight that tab over one transcript.
        /// The surface id is unique per tab by construction, so it is the
        /// right session identity — which is why this one field, and only
        /// this one, is applied per surface.
        func command(surfaceID: UUID) -> String {
            Workstream.AgentCommand.fresh(
                claudePath: claudePath,
                sessionID: surfaceID.uuidString.lowercased(),
                sessionName: nil,
                bypassPermissions: bypassPermissions,
                systemPrompt: systemPrompt,
                mcpConfigPath: mcpConfigPath,
                settingsPath: settingsPath,
                initialPrompt: initialPrompt
            )
        }
    }

    /// What a spawned tab will run, or nil for a plain shell.
    ///
    /// The MCP config is the workstream's, shared deliberately: it names the
    /// helper binary and carries no identity, and the agent's identity comes
    /// from `ATELIER_SURFACE_ID` in its environment.
    private nonisolated func agentCommand(
        plan: WorkspaceActions.AgentTabPlan,
        prompt: String?
    ) -> SpawnedAgent? {
        guard let prompt, !prompt.isEmpty, let claudePath = plan.claudePath else { return nil }
        let mcpConfigPath = IPC.AgentSettings.isEnabled ? IPC.Config.write(for: plan.workstreamID) : nil
        let systemPrompt = Workstream.AgentCommand.systemPrompt(
            allowOutsideWorktree: UserDefaults.standard.bool(forKey: "atelier.allowOutsideWorktree"),
            autoRenameBranch: UserDefaults.standard.bool(forKey: "atelier.autoRenameBranch"),
            worktreePath: plan.workingDirectory,
            workstreamName: plan.workstreamName,
            mcpConfigWritten: mcpConfigPath != nil
        )
        // Resolved against the worktree, so a project that configures its
        // own status line in `.claude/settings.json` is honoured the same
        // way the Coding Agent tab honours it.
        let settingsPath = StatusLine.Config.write(
            for: plan.workstreamID,
            cwd: plan.workingDirectory
        )
        return SpawnedAgent(
            claudePath: claudePath,
            bypassPermissions: plan.bypassPermissions,
            systemPrompt: systemPrompt,
            mcpConfigPath: mcpConfigPath,
            settingsPath: settingsPath,
            initialPrompt: prompt
        )
    }

    /// Carries the agent-start result out of the launcher's `beforeReady`
    /// closure, which runs in a different isolation domain from the actor
    /// that needs the answer.
    ///
    /// `@unchecked Sendable` and unsynchronised because the access pattern
    /// makes it safe rather than because the checker was in the way: both
    /// fields are written inside one `MainActor.run`, and both are read only
    /// after `launch` has returned, which happens-after that write. Nothing
    /// else holds a reference.
    private final class AgentStartOutcome: @unchecked Sendable {
        var started = false
        var failure: String?
    }

    /// What starting a Coding Agent needs from the live app, gathered in one
    /// hop onto the main actor.
    ///
    /// Read *before* the worktree exists, so every reason an agent cannot
    /// start is a refusal the caller gets instead of a workstream. The
    /// `claude` lookup was already a pre-flight for that reason; the surface
    /// handle is here for the same one — without it the tool would report an
    /// agent started with nothing running it.
    private struct AgentLaunchInputs {
        let claudePath: String?
        let supportsSessionName: Bool
        /// Nil when tmux mode is off *and* when tmux is not installed. Those
        /// are one answer here — do not wrap — which is why the setting is
        /// resolved on this side rather than passed on.
        let tmuxPath: String?
        let canCreateSurfaces: Bool

        @MainActor
        static func read() -> AgentLaunchInputs {
            let environment = WorkspaceActions.shared.appEnvironment
            let tmuxMode = UserDefaults.standard.bool(forKey: "atelier.tmuxMode")
            return AgentLaunchInputs(
                claudePath: environment?.toolStatus.claude.path,
                supportsSessionName: environment?.toolStatus.claudeSupportsSessionName ?? false,
                tmuxPath: tmuxMode ? environment?.toolStatus.tmux.path : nil,
                canCreateSurfaces: WorkspaceActions.shared.canCreateSurfaces
            )
        }

        /// Why an agent cannot be started, or nil when one can. Both cases
        /// name `prompt` as the way to proceed anyway, because a workstream
        /// without an agent is still worth having.
        var refusal: String? {
            if claudePath == nil {
                return "Cannot start an agent: Atelier could not find the `claude` binary. "
                    + "Omit `prompt` to create the workstream without one."
            }
            if !canCreateSurfaces {
                return "Cannot start an agent: Atelier's terminal is not ready yet. "
                    + "Omit `prompt` to create the workstream without one, or try again in a moment."
            }
            return nil
        }
    }

    /// The environment the new workstream's Coding Agent runs in.
    ///
    /// `ProcessCompose.PhaseEnvironment.variables` is the assembler for a
    /// caller with no `ProcessCompose.PortPlan` to hand over — it resolves
    /// `ports.yaml` itself — which is exactly this caller.
    ///
    /// Deliberately **not** `WorkspaceActions.environment(for:surfaceID:)`,
    /// which blanks `TMUX`/`TMUX_PANE`. That is right for a terminal tab and
    /// wrong here: the Coding Agent is the surface tmux mode wraps, and the
    /// view's own `envVars` leaves those inherited. `ensureSurface` does not
    /// compare environments, so a divergence here would never be corrected —
    /// it would just be wrong for the life of the surface.
    private nonisolated func codingAgentEnvironment(
        target: Workstream.Launcher.Target,
        launched: Workstream.Launcher.Launched
    ) -> [String: String] {
        var vars = ProcessCompose.PhaseEnvironment.variables(
            workstreamID: launched.workstreamID,
            projectName: target.projectName,
            workstreamName: launched.name,
            projectDirectory: target.directory,
            worktreePath: launched.worktreePath,
            defaultBranch: Git.Operations.defaultBranch(at: target.directory)
        )
        // The Coding Agent's surface id is the workstream id, so it
        // addresses itself the way every other surface does.
        vars["ATELIER_SURFACE_ID"] = launched.workstreamID.uuidString
        return vars
    }

    /// The command the new workstream's Coding Agent runs.
    ///
    /// **The session id is the workstream's**, which is the opposite of
    /// `agentCommand`'s rule and for the same underlying reason: this *is*
    /// the Coding Agent, and `TerminalContainerView` will later resume that
    /// session on this same surface. `open_agent_tab` must take the surface's
    /// id instead precisely so a second agent does not end up here.
    ///
    /// Fresh rather than the view's resume-then-fresh pair: this workstream
    /// was created moments ago and has no session to resume. The pair is
    /// about recovering the session across a relaunch, a question that only
    /// arises after this one has run.
    private nonisolated func codingAgentCommand(
        target: Workstream.Launcher.Target,
        launched: Workstream.Launcher.Launched,
        prompt: String,
        claudePath: String,
        bypassPermissions: Bool,
        inputs: AgentLaunchInputs,
        environment: [String: String]
    ) -> String {
        let mcpConfigPath = IPC.AgentSettings.isEnabled
            ? IPC.Config.write(for: launched.workstreamID)
            : nil
        let systemPrompt = Workstream.AgentCommand.systemPrompt(
            allowOutsideWorktree: UserDefaults.standard.bool(forKey: "atelier.allowOutsideWorktree"),
            autoRenameBranch: UserDefaults.standard.bool(forKey: "atelier.autoRenameBranch"),
            worktreePath: launched.worktreePath,
            workstreamName: launched.name,
            mcpConfigWritten: mcpConfigPath != nil
        )
        let settingsPath = StatusLine.Config.write(
            for: launched.workstreamID,
            cwd: launched.worktreePath
        )
        let fresh = Workstream.AgentCommand.fresh(
            claudePath: claudePath,
            sessionID: launched.workstreamID.uuidString.lowercased(),
            sessionName: inputs.supportsSessionName ? launched.name : nil,
            bypassPermissions: bypassPermissions,
            systemPrompt: systemPrompt,
            mcpConfigPath: mcpConfigPath,
            settingsPath: settingsPath,
            initialPrompt: prompt
        )
        let command = Workstream.AgentCommand.tmuxWrapped(
            fresh,
            tmuxPath: inputs.tmuxPath,
            projectName: target.projectName,
            workstreamName: launched.name,
            environmentVars: environment
        )

        // The launch log is how an agent that starts and does nothing gets
        // diagnosed, and the Info tab reads it. This path would otherwise be
        // the one agent start that left no entry.
        LaunchLogger.log(LaunchLogEntry(
            workstreamID: launched.workstreamID,
            event: "agent-start",
            finalCommand: command,
            intermediateCommands: command == fresh ? [fresh] : [fresh, command],
            environmentVariables: environment,
            workingDirectory: launched.worktreePath,
            toolPaths: LaunchLogEntry.ToolPaths(
                claude: claudePath,
                tmux: inputs.tmuxPath,
                ffRun: RunLauncher.executableURL()?.path
            ),
            settings: LaunchLogEntry.Settings(
                tmuxMode: UserDefaults.standard.bool(forKey: "atelier.tmuxMode"),
                bypassPermissions: bypassPermissions,
                autoRenameBranch: UserDefaults.standard.bool(forKey: "atelier.autoRenameBranch"),
                allowOutsideWorktree: UserDefaults.standard.bool(forKey: "atelier.allowOutsideWorktree")
            ),
            shell: CommandBuilder.userShell
        ))

        return command
    }

    /// Creates a new workstream — worktree, branch, initialization — in the
    /// caller's project, and optionally starts an agent in it.
    ///
    /// **Initialization is inherited, not reimplemented.** The work happens
    /// by posting `.workstreamWorktreeReady`, which `ContentView` answers by
    /// calling `Initialization.Runner.run` — and that one path is also what
    /// gets path persistence, the HeadWatcher, the agent-state lookup and the
    /// Shortcut story id, none of which a second creation path would
    /// remember. So this handler must never call `Initialization.Runner.run`
    /// itself.
    ///
    /// **The agent goes in the workstream's Coding Agent tab**, on the
    /// surface whose id *is* the workstream id — so the user opening the
    /// workstream lands on the conversation rather than on an empty agent
    /// beside a terminal tab holding the real one.
    ///
    /// That surface has to exist before `TerminalContainerView` ever renders
    /// this workstream, because nobody is looking at it. The hazard is what
    /// happens when they finally do: `preloadSurfaces` calls `ensureSurface`
    /// with the command `buildClaudeCommand` builds, which carries no initial
    /// prompt, and `ensureSurface` destroys a surface whose stored command
    /// differs. `TerminalSurfaceCache.seedSurface` is what makes that safe —
    /// the view *adopts* the seeded surface once instead of reconciling it.
    /// The invariant lives there, at the consumer, rather than in an
    /// obligation on this handler to produce a byte-identical command.
    func createWorkstream(for request: Request) async -> Response {
        do {
            let plan = try await creationPlan(for: request)
            return await create(
                named: ToolArguments(request).optionalTrimmed("name"),
                forStory: nil,
                plan: plan,
                request: request
            )
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    /// `create_workstream` for a story: the name comes from the user's
    /// Branch Name Pattern rather than the caller, and the workstream carries
    /// the story id so the Info tab and "Open in Shortcut" have one.
    ///
    /// The sequence is the sidebar's, in the sidebar's order, and the two
    /// share `Shortcut.WorkstreamName.resolve` rather than each spelling the
    /// guards out — see that type for why only the *decision* is shared and
    /// the fetch, the staging and the launch stay here.
    func createShortcutWorkstream(for request: Request) async -> Response {
        do {
            let raw = try ToolArguments(request).requiredTrimmed("story")
            guard let storyID = Shortcut.StoryID.parse(raw) else {
                throw ToolError.invalidArgument(
                    name: "story",
                    reason: "\(raw) is not a Shortcut story. Pass a public id (17411), the sc- form (sc-17411), or a story URL."
                )
            }

            // Before the fetch, so a caller that could never have succeeded —
            // no project, no `claude` for the agent it asked for — spends no
            // round trip on Shortcut finding that out.
            let plan = try await creationPlan(for: request)
            let story = try await fetchStory(storyID)

            let name = try Shortcut.WorkstreamName.resolve(
                template: UserDefaults.standard.string(forKey: Shortcut.Settings.branchTemplateKey) ?? "",
                story: story,
                existing: plan.target.existingWorkstreams
            ).mapError { ToolError.refused($0.agentMessage) }.get()

            // Keep the copy just fetched: it carries the description, and the
            // worktree path it will be cached under does not exist yet. The
            // sidebar stages for the same reason, so the Info tab does not
            // round-trip again the moment it opens.
            //
            // Optional where the sidebar's is not, and a nil bridge costs
            // exactly that saved round trip: `AppEnvironment.refreshShortcutStory`
            // fetches on the tab's first appearance regardless, so staging is an
            // optimization rather than how the story reaches the workstream —
            // `shortcutStoryID`, passed to `launch` below, is that.
            await MainActor.run {
                WorkspaceActions.shared.appEnvironment?.stageShortcutStory(story)
            }

            return await create(named: name, forStory: story.id, plan: plan, request: request)
        } catch let error as Shortcut.Error {
            // Shortcut's own message is the only thing that says whether the
            // token is missing, revoked, or the story simply is not there.
            return .failure(id: request.id, error.message)
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    /// What both creation tools resolve before anything exists on disk.
    private struct CreationPlan {
        let target: Workstream.Launcher.Target
        let prompt: String?
        let bypass: Bool
        let inputs: AgentLaunchInputs
    }

    /// The preconditions both creation tools check, in the order that keeps
    /// their refusals true: the argument, then the project, then the agent.
    ///
    /// Every one of them happens before anything is created. The worktree is
    /// a directory on disk and a branch in the repository; refusing after it
    /// exists would leave the caller a workstream it was told it did not get.
    private func creationPlan(for request: Request) async throws -> CreationPlan {
        let arguments = ToolArguments(request)
        let prompt = arguments.optionalTrimmed("prompt")
        // Before the project is resolved, so a caller cannot get a worktree
        // out of a request that was malformed.
        let bypass = try arguments.boolean("bypass_permissions")

        let callerWorkstreamID = callerWorkstreamID(request)
        let target = try await MainActor.run {
            try Workstream.Launcher.shared.target(
                callerWorkstreamID: callerWorkstreamID,
                projectDirectory: request.client.projectDirectory
            )
        }

        let inputs = await MainActor.run { AgentLaunchInputs.read() }
        if prompt?.isEmpty == false, let refusal = inputs.refusal {
            throw ToolError.refused(refusal)
        }

        return CreationPlan(target: target, prompt: prompt, bypass: bypass, inputs: inputs)
    }

    /// The half of a creation that does not care why it was asked for:
    /// launch, seed the agent, answer.
    ///
    /// One copy, because the two tools differ in exactly the two values this
    /// takes — the name that was resolved and the story it carries. A sibling
    /// handler would have been sixty lines of seeding and answer strings that
    /// nothing keeps in step.
    private func create(
        named name: String?,
        forStory shortcutStoryID: Int?,
        plan: CreationPlan,
        request: Request
    ) async -> Response {
        do {
            // The agent starts inside `beforeReady`, which the launcher runs
            // after the worktree exists and *before* it posts
            // `.workstreamWorktreeReady`. That notification is what makes the
            // workstream renderable, and the first render creates the Coding
            // Agent's surface with the command the view builds — so seeding
            // after it would be a race against a user clicking the sidebar
            // row that has been sitting there since `.workstreamCreated`, and
            // losing that race would drop the prompt in silence.
            //
            // The outcome comes back in a box because this actor cannot
            // mutate a local from a closure the launcher runs. It is written
            // on the main actor and read only after `launch` has returned.
            let outcome = AgentStartOutcome()
            let launched = try await Workstream.Launcher.shared.launch(
                in: plan.target,
                requestedName: name,
                bypassPermissions: plan.bypass,
                shortcutStoryID: shortcutStoryID,
                beforeReady: { launched in
                    guard let prompt = plan.prompt, !prompt.isEmpty,
                          let claudePath = plan.inputs.claudePath else { return }
                    // Built from what the launcher hands over rather than by
                    // reading the workstream back out of `ProjectList`: the
                    // append happened on `.workstreamCreated`, but the
                    // notification that sets `worktreePath` has not been
                    // posted yet — that is the point of running here.
                    let environment = self.codingAgentEnvironment(target: plan.target, launched: launched)
                    let command = self.codingAgentCommand(
                        target: plan.target,
                        launched: launched,
                        prompt: prompt,
                        claudePath: claudePath,
                        bypassPermissions: plan.bypass,
                        inputs: plan.inputs,
                        environment: environment
                    )
                    await MainActor.run {
                        do {
                            try WorkspaceActions.shared.seedCodingAgent(
                                workstreamID: launched.workstreamID,
                                workingDirectory: launched.worktreePath,
                                command: command,
                                environment: environment
                            )
                            outcome.started = true
                        } catch {
                            outcome.failure = error.localizedDescription
                        }
                    }
                }
            )

            guard plan.prompt?.isEmpty == false else {
                return .success(id: request.id, .text(
                    "Created workstream \(launched.name) at \(launched.worktreePath). "
                        + "Its initialization is running in the background. No agent was started — pass `prompt` to start one."
                ))
            }

            // The worktree exists whatever became of the agent, so this is a
            // success carrying bad news rather than a failure — reporting it
            // as an error would tell the caller nothing was created.
            guard outcome.started else {
                return .success(id: request.id, .text(
                    "Created workstream \(launched.name) at \(launched.worktreePath), but no agent was started. "
                        + (outcome.failure ?? "Atelier gave no reason.")
                ))
            }

            return .success(id: request.id, .text(
                "Created workstream \(launched.name) at \(launched.worktreePath) and started an agent in its "
                    + "Coding Agent tab, surface \(launched.workstreamID.uuidString). Its initialization may still be "
                    + "running, so the worktree's dependencies may not be installed yet. The agent is not "
                    + "addressable until it registers: poll list_peers until a peer reports that surface id, then "
                    + "send_message to it."
            ))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }
}
