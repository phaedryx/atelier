// ABOUTME: Tests for the pure halves of the IPC workspace tools — resolution, path safety, attention limits.
// ABOUTME: Everything here takes its inputs, so none of it needs a live app, workspace, or notification centre.

@testable import Atelier
import XCTest

final class WorkspaceActionsResolveTests: XCTestCase {
    private func project(name: String, directory: String, workstreams: [Workstream]) -> Project {
        var project = Project(name: name, directory: directory)
        project.workstreams = workstreams
        return project
    }

    func testResolvesTheProjectHoldingTheWorkstream() {
        let wanted = Workstream(name: "wanted")
        let other = Workstream(name: "other")
        let projects = [
            project(name: "a", directory: "/repos/a", workstreams: [other]),
            project(name: "b", directory: "/repos/b", workstreams: [wanted]),
        ]

        let found = WorkspaceActions.resolve(workstreamID: wanted.id, in: projects)

        XCTAssertEqual(found?.project.name, "b")
        XCTAssertEqual(found?.workstream.id, wanted.id)
    }

    func testUnknownWorkstreamResolvesToNil() {
        let projects = [project(name: "a", directory: "/repos/a", workstreams: [Workstream(name: "x")])]

        XCTAssertNil(WorkspaceActions.resolve(workstreamID: UUID(), in: projects))
    }

    /// The reason resolution is keyed on the workstream id and not on the
    /// caller's `ATELIER_PROJECT_DIR`: in the bare-repo layout one project's
    /// checkout is a path inside its own container, and matching on paths makes
    /// two projects ambiguous in a way a workstream id never is.
    func testTwoProjectsWithOverlappingPathsStayDistinct() {
        let inContainer = Workstream(name: "in-container", worktreePath: "/repos/app/feature")
        let projects = [
            project(name: "app", directory: "/repos/app", workstreams: [inContainer]),
            project(name: "main-checkout", directory: "/repos/app/main", workstreams: [Workstream(name: "other")]),
        ]

        let found = WorkspaceActions.resolve(workstreamID: inContainer.id, in: projects)

        XCTAssertEqual(found?.project.name, "app")
    }
}

/// `open_tab`'s pure half: which kinds it will open, and how it refuses the rest.
///
/// The opening itself is `WorkspaceModel.ensureSingleton`, already pinned in
/// `WorkspaceModelTests` — including that it leaves `activeTab` alone, which is
/// the whole behavioural claim this tool makes.
@MainActor
final class WorkspaceActionsOpenTabTests: XCTestCase {
    /// The four on-demand singletons, and nothing else.
    ///
    /// Whiteboard joined with the read path. It was held out of PR 1 because
    /// that PR's rule was "no agent involvement whatsoever"; an agent that can
    /// read the board has to be able to put it in front of the user.
    func testOpensExactlyTheSingletonTabs() {
        XCTAssertEqual(
            WorkspaceActions.openableTabs,
            [
                "changes": .changes,
                "execution": .execution,
                "verification": .verification,
                "whiteboard": .whiteboard,
            ]
        )
    }

    /// The keys must be `WorkspaceTabKind.id`, because `list_tabs` reports that
    /// string as a tab's `kind` — so the name an agent reads off a tab is the
    /// name it passes back to open one. A second vocabulary here would be one
    /// nothing keeps in step.
    func testTheKeysAreTheKindIDsListTabsReports() {
        for (key, tab) in WorkspaceActions.openableTabs {
            XCTAssertEqual(key, tab.kind.id, "\(key) is not the id list_tabs would report for that tab")
        }
    }

    /// Two different reasons, both ending in "not here". Info and Agent are
    /// permanent, so opening them can neither fail nor do anything; terminal,
    /// browser and editor are instanced, so "the" tab is meaningless and two of
    /// them have their own tool.
    func testPermanentAndInstancedKindsAreNotOpenable() {
        for kind in [WorkspaceTabKind.info, .agent, .terminal, .browser, .editor] {
            XCTAssertNil(WorkspaceActions.openableTabs[kind.id], "\(kind.id) must not be openable by name")
        }
    }

    /// The kind is validated *before* the workstream is resolved, so an agent
    /// with a typo is told what the legal values are rather than being handed
    /// whatever the app's readiness happens to be. This test relies on that
    /// ordering: `WorkspaceActions.shared` has no `projectList` here, so a guard
    /// in the other order would answer `appNotReady`.
    func testAnUnknownKindIsRefusedByNamingTheLegalOnes() {
        XCTAssertThrowsError(try WorkspaceActions.shared.openTab(workstreamID: UUID(), kind: "logs")) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("logs"), message)
            XCTAssertTrue(message.contains("changes, execution, verification"), message)
        }
    }

    /// `open_agent_tab` and `open_editor` are the tools for the instanced kinds,
    /// and this one must not look like a third way to reach them.
    func testAskingForATerminalIsRefusedRatherThanGuessingWhichOne() {
        XCTAssertThrowsError(try WorkspaceActions.shared.openTab(workstreamID: UUID(), kind: "terminal"))
    }
}

final class WorkspaceActionsPathTests: XCTestCase {
    private let worktree = "/repos/app/feature"

    private func resolve(_ path: String, exists: Bool = true) throws -> String {
        try WorkspaceActions.resolvePath(path, inWorktree: worktree, fileExists: { _ in exists })
    }

    /// The answer is worktree-relative because that is `editorFilePaths`' unit:
    /// every other producer (the file tree, the Cmd+P finder) stores paths
    /// relative to the worktree root, and `EditorView.loadFile` resolves them
    /// against `workingDirectory`. An absolute path stored there gets appended
    /// to the worktree a second time and reads back as "no such file".
    func testRelativePathResolvesToAWorktreeRelativePath() throws {
        XCTAssertEqual(try resolve("Sources/App.swift"), "Sources/App.swift")
    }

    func testAbsolutePathInsideTheWorktreeIsRelativized() throws {
        XCTAssertEqual(try resolve("/repos/app/feature/Sources/App.swift"), "Sources/App.swift")
    }

    func testAbsolutePathOutsideTheWorktreeIsRejected() {
        XCTAssertThrowsError(try resolve("/etc/hosts"))
    }

    /// `..` has to be resolved before the containment test, or a relative path
    /// walks straight out of the worktree while still looking relative.
    func testTraversalOutOfTheWorktreeIsRejected() {
        XCTAssertThrowsError(try resolve("../../../etc/hosts"))
    }

    func testTraversalThatStaysInsideIsAccepted() throws {
        XCTAssertEqual(try resolve("Sources/../Tests/AppTests.swift"), "Tests/AppTests.swift")
    }

    /// The relativization must use the same standardized components the
    /// containment test used — a worktree path spelled with a `.` or a
    /// trailing slash would otherwise leave its debris in the prefix strip.
    func testAnUnstandardizedWorktreePathStillYieldsACleanRelativePath() throws {
        XCTAssertEqual(
            try WorkspaceActions.resolvePath(
                "Sources/App.swift",
                inWorktree: "/repos/app/feature/./",
                fileExists: { _ in true }
            ),
            "Sources/App.swift"
        )
    }

    /// A sibling worktree whose name merely starts with this one's is outside
    /// it. A string-prefix containment test says otherwise, which is why the
    /// real one compares path components.
    func testSiblingWithACommonPrefixIsRejected() {
        XCTAssertThrowsError(try resolve("/repos/app/feature-2/Sources/App.swift"))
    }

    /// The worktree root itself is not a file to open, and admitting it would
    /// mean `pathComponents.count > rootParts.count` had been relaxed.
    func testTheWorktreeRootItselfIsRejected() {
        XCTAssertThrowsError(try resolve(worktree))
    }

    func testMissingFileIsRejected() {
        XCTAssertThrowsError(try resolve("Sources/Gone.swift", exists: false))
    }

    func testEmptyPathIsRejected() {
        XCTAssertThrowsError(try resolve("   "))
    }
}

final class AttentionNotifierPolicyTests: XCTestCase {
    func testFirstRequestIsAllowed() {
        XCTAssertTrue(Workstream.AttentionNotifier.shouldNotify(lastRequest: nil))
    }

    func testSecondRequestInsideTheCooldownIsRefused() {
        let now = Date()
        XCTAssertFalse(
            Workstream.AttentionNotifier.shouldNotify(lastRequest: now.addingTimeInterval(-5), now: now)
        )
    }

    func testRequestAfterTheCooldownIsAllowed() {
        let now = Date()
        let earlier = now.addingTimeInterval(-Workstream.AttentionNotifier.cooldown - 1)
        XCTAssertTrue(Workstream.AttentionNotifier.shouldNotify(lastRequest: earlier, now: now))
    }

    /// Exactly at the boundary counts as elapsed — otherwise the advertised
    /// "try again in Ns" is off by one and an agent that waits the stated time
    /// is refused again.
    func testTheCooldownBoundaryIsInclusive() {
        let now = Date()
        let earlier = now.addingTimeInterval(-Workstream.AttentionNotifier.cooldown)
        XCTAssertTrue(Workstream.AttentionNotifier.shouldNotify(lastRequest: earlier, now: now))
    }

    func testTruncateFlattensNewlines() {
        XCTAssertEqual(
            Workstream.AttentionNotifier.truncate("first line\n\nsecond line"),
            "first line second line"
        )
    }

    func testTruncateTrimsToTheLimit() {
        let long = String(repeating: "x", count: 500)
        let truncated = Workstream.AttentionNotifier.truncate(long, limit: 10)
        XCTAssertEqual(truncated.count, 10)
        XCTAssertTrue(truncated.hasSuffix("…"))
    }

    func testShortReasonIsUnchanged() {
        XCTAssertEqual(Workstream.AttentionNotifier.truncate("needs a decision"), "needs a decision")
    }
}

final class WorkspaceActionsTabTests: XCTestCase {
    /// The Coding Agent's surface id *is* the workstream id — the identity
    /// `AgentNudge` already relies on. Reporting nil here would make the one tab
    /// a caller most wants to address unaddressable.
    func testAgentTabReportsTheWorkstreamID() {
        let workstreamID = UUID()
        XCTAssertEqual(
            WorkspaceActions.surfaceID(of: .agent, workstreamID: workstreamID),
            workstreamID
        )
    }

    func testTerminalTabReportsItsOwnSurface() {
        let surfaceID = UUID()
        XCTAssertEqual(
            WorkspaceActions.surfaceID(of: .terminal(surfaceID), workstreamID: UUID()),
            surfaceID
        )
    }

    /// A browser or editor tab has no shell, so it has no address a message or a
    /// spawned agent could ever arrive at. Reporting the workstream id for them
    /// would be worse than nil: it would point at the Coding Agent.
    func testTabsWithoutAShellReportNoSurface() {
        for tab in [WorkspaceTab.info, .changes, .execution, .browser(UUID()), .editor(UUID())] {
            XCTAssertNil(
                WorkspaceActions.surfaceID(of: tab, workstreamID: UUID()),
                "\(tab) should report no surface"
            )
        }
    }
}

final class AgentCommandTests: XCTestCase {
    private func systemPrompt(
        allowOutsideWorktree: Bool = false,
        autoRenameBranch: Bool = false,
        mcpConfigWritten: Bool = false
    ) -> String? {
        Workstream.AgentCommand.systemPrompt(
            allowOutsideWorktree: allowOutsideWorktree,
            autoRenameBranch: autoRenameBranch,
            worktreePath: "/repos/app/feature",
            workstreamName: "wry-amber-lexer",
            mcpConfigWritten: mcpConfigWritten
        )
    }

    func testNoPromptsYieldsNil() {
        XCTAssertNil(systemPrompt(allowOutsideWorktree: true))
    }

    func testRestrictToWorktreeAppliesWhenOutsideAccessIsNotAllowed() {
        let prompt = systemPrompt(allowOutsideWorktree: false)
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt?.contains("/repos/app/feature") ?? false)
    }

    /// Claude Code takes one `--append-system-prompt` and the last wins, so
    /// several active prompts have to arrive as one string.
    func testActivePromptsAreJoinedIntoOne() {
        let prompt = try? XCTUnwrap(
            systemPrompt(allowOutsideWorktree: false, autoRenameBranch: true, mcpConfigWritten: true)
        )
        XCTAssertTrue(prompt?.contains("\n\n") ?? false, "prompts should be joined, not replaced")
    }

    /// The IPC prompt is gated on the config having been *written*, not on the
    /// setting: an agent told it has peers but handed no MCP server would call
    /// tools that do not exist.
    func testIPCPromptIsAbsentWithoutAWrittenConfig() {
        let without = systemPrompt(allowOutsideWorktree: true, mcpConfigWritten: false)
        let with = systemPrompt(allowOutsideWorktree: true, mcpConfigWritten: true)
        XCTAssertNil(without)
        XCTAssertNotNil(with)
    }

    private func fresh(
        sessionID: String = "11111111-1111-1111-1111-111111111111",
        bypassPermissions: Bool = false,
        systemPrompt: String? = nil,
        mcpConfigPath: String? = nil,
        settingsPath: String? = nil,
        initialPrompt: String? = nil
    ) -> String {
        Workstream.AgentCommand.fresh(
            claudePath: "/usr/local/bin/claude",
            sessionID: sessionID,
            sessionName: nil,
            bypassPermissions: bypassPermissions,
            systemPrompt: systemPrompt,
            mcpConfigPath: mcpConfigPath,
            settingsPath: settingsPath,
            initialPrompt: initialPrompt
        )
    }

    func testFreshCarriesTheStatusLineSettingsWhenOneWasWritten() {
        XCTAssertFalse(fresh().contains("--settings"))
        let withSettings = fresh(settingsPath: "/tmp/statusline/ws.json")
        XCTAssertTrue(withSettings.contains("--settings"))
        XCTAssertTrue(withSettings.contains("/tmp/statusline/ws.json"))
    }

    func testFreshCarriesTheSessionID() {
        XCTAssertTrue(fresh().contains("--session-id"))
        XCTAssertTrue(fresh().contains("11111111-1111-1111-1111-111111111111"))
    }

    /// A fresh invocation must never try to resume: `--resume` names a session
    /// that has to already exist, and a surface being created now has none.
    func testFreshNeverResumes() {
        XCTAssertFalse(fresh().contains("--resume"))
    }

    func testOptionalFlagsAreAbsentWhenNotAskedFor() {
        let command = fresh()
        XCTAssertFalse(command.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(command.contains("--append-system-prompt"))
        XCTAssertFalse(command.contains("--mcp-config"))
    }

    func testMCPConfigIsPassedWhenPresent() {
        XCTAssertTrue(fresh(mcpConfigPath: "/cache/mcp/x.json").contains("--mcp-config"))
    }

    /// The prompt is positional and `CommandBuilder.arg` does not quote, so it
    /// has to be quoted at the call site. A prompt with a space that arrived
    /// unquoted would be parsed as several arguments.
    func testInitialPromptIsQuoted() {
        let command = fresh(initialPrompt: "review the diff and report back")
        XCTAssertTrue(
            command.contains("'review the diff and report back'"),
            "expected a quoted prompt in: \(command)"
        )
    }

    /// A prompt is untrusted text that ends up on a shell command line, so an
    /// apostrophe must never appear bare — that would close the quoted argument
    /// early and leave the rest as shell syntax.
    ///
    /// Asserted against `shellQuote`, which is where the escaping happens. The
    /// assembled command wraps this in one or two more shells, so matching the
    /// escaped form inside the finished string would be testing the wrapping
    /// rather than the escaping.
    func testInitialPromptWithQuotesIsEscaped() {
        XCTAssertEqual(
            CommandBuilder.shellQuote("it's broken; rm -rf /"),
            "'it'\\''s broken; rm -rf /'"
        )
    }

    /// `--mcp-config <configs...>` is variadic in the Claude Code CLI: it
    /// consumes every following argument until the next option, including a
    /// positional prompt. Without a `--` terminator ahead of the prompt, the
    /// prompt is read as a second config path — a ~2KB "filename" — and the
    /// agent dies at launch with ENAMETOOLONG before a session exists, losing
    /// the prompt. `--` must come with the prompt itself, not with the config,
    /// so a future option added between them cannot reopen the hole.
    func testInitialPromptIsSeparatedFromOptionsByDoubleDash() {
        let command = fresh(
            mcpConfigPath: "/cache/mcp/x.json",
            initialPrompt: "review the diff and report back"
        )
        // Matched as ranges rather than one literal, because the login-shell
        // wrapping re-escapes the prompt's quotes — the same reason
        // testInitialPromptWithQuotesIsEscaped asserts against `shellQuote`.
        let separator = command.range(of: " -- ")
        let prompt = command.range(of: "review the diff and report back")
        XCTAssertNotNil(separator, "expected -- before the positional prompt in: \(command)")
        XCTAssertNotNil(prompt, command)
        if let separator, let prompt {
            XCTAssertTrue(
                separator.upperBound <= prompt.lowerBound,
                "expected -- to precede the prompt in: \(command)"
            )
        }
    }

    /// The whole prompt has to survive as one argument, however many shells it
    /// is wrapped in on the way.
    func testInitialPromptSurvivesTheShellWrapping() {
        let command = fresh(initialPrompt: "review the diff; then report")
        XCTAssertTrue(command.contains("review the diff"), command)
        XCTAssertTrue(command.contains("then report"), command)
    }

    func testRunsThroughTheLoginShell() {
        XCTAssertTrue(fresh().contains("-lic"))
    }
}
