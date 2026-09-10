// ABOUTME: Tests for CommandBuilder shell command composition and quoting.
// ABOUTME: Validates escaping of special characters, spaces, quotes, and nested commands.

@testable import Atelier
import XCTest

final class CommandBuilderTests: XCTestCase {
    // MARK: - Basic command building

    func testSimpleCommand() {
        var cmd = CommandBuilder("/usr/bin/claude")
        cmd.flag("--verbose")
        cmd.arg("run")
        XCTAssertEqual(cmd.command, "/usr/bin/claude --verbose run")
    }

    func testOptionWithSimpleValue() {
        var cmd = CommandBuilder("claude")
        cmd.option("--name", "my-workstream")
        XCTAssertEqual(cmd.command, "claude --name my-workstream")
    }

    func testOptionWithSpaces() {
        var cmd = CommandBuilder("claude")
        cmd.option("--name", "my workstream")
        XCTAssertEqual(cmd.command, "claude --name 'my workstream'")
    }

    // MARK: - shellQuote edge cases

    func testQuoteEmpty() {
        XCTAssertEqual(CommandBuilder.shellQuote(""), "''")
    }

    func testQuoteSimplePath() {
        XCTAssertEqual(CommandBuilder.shellQuote("/usr/local/bin/claude"), "/usr/local/bin/claude")
    }

    func testQuoteHomePath() {
        XCTAssertEqual(CommandBuilder.shellQuote("~/repos/my-app"), "~/repos/my-app")
    }

    func testQuotePathWithSpaces() {
        XCTAssertEqual(CommandBuilder.shellQuote("/Users/test/my app"), "'/Users/test/my app'")
    }

    func testQuoteSingleQuotes() {
        XCTAssertEqual(CommandBuilder.shellQuote("it's"), "'it'\\''s'")
    }

    func testQuoteDoubleQuotes() {
        XCTAssertEqual(CommandBuilder.shellQuote("say \"hello\""), "'say \"hello\"'")
    }

    func testQuoteBackticks() {
        XCTAssertEqual(CommandBuilder.shellQuote("run `cmd`"), "'run `cmd`'")
    }

    func testQuoteDollarSign() {
        XCTAssertEqual(CommandBuilder.shellQuote("$HOME/bin"), "'$HOME/bin'")
    }

    func testQuoteParentheses() {
        XCTAssertEqual(CommandBuilder.shellQuote("(echo hi)"), "'(echo hi)'")
    }

    func testQuoteSemicolon() {
        XCTAssertEqual(CommandBuilder.shellQuote("cmd1; cmd2"), "'cmd1; cmd2'")
    }

    func testQuotePipe() {
        XCTAssertEqual(CommandBuilder.shellQuote("cmd | grep"), "'cmd | grep'")
    }

    func testQuoteAtSign() {
        XCTAssertEqual(CommandBuilder.shellQuote("user@host"), "user@host")
    }

    func testQuotePlusSign() {
        XCTAssertEqual(CommandBuilder.shellQuote("c++"), "c++")
    }

    func testQuoteEquals() {
        XCTAssertEqual(CommandBuilder.shellQuote("FOO=bar"), "FOO=bar")
    }

    func testQuoteUUID() {
        XCTAssertEqual(CommandBuilder.shellQuote("a1b2c3d4-e5f6-7890-abcd-ef1234567890"), "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    }

    func testQuoteMultipleSingleQuotes() {
        let input = "it's a 'test'"
        let result = CommandBuilder.shellQuote(input)
        XCTAssertEqual(result, "'it'\\''s a '\\''test'\\'''")
    }

    // MARK: - withFallback

    func testWithFallbackBasic() {
        let result = CommandBuilder.withFallback("cmd1", "cmd2", shell: "/bin/zsh")
        XCTAssertTrue(result.hasPrefix("/bin/zsh -lic "), "Should use interactive login shell")
        XCTAssertTrue(result.contains("exec sh -c"), "Should use sh for POSIX syntax")
        XCTAssertFalse(result.contains("2>"), "Stderr should not be redirected")
        XCTAssertTrue(result.contains("cmd1 || cmd2"), "Should have fallback with ||")
    }

    func testWithFallbackMessage() {
        let result = CommandBuilder.withFallback("cmd1", "cmd2", message: "Retrying...", shell: "/bin/zsh")
        XCTAssertTrue(result.contains("echo"), "Should contain echo for message")
        XCTAssertTrue(result.contains("Retrying..."), "Should contain user message")
        XCTAssertTrue(result.contains("cmd2"), "Should contain fallback command")
        XCTAssertTrue(result.contains("|| ("), "Should have fallback group with message")
    }

    func testWithFallbackMessageWithSpecialChars() {
        let result = CommandBuilder.withFallback("cmd1", "cmd2", message: "it's failing", shell: "/bin/zsh")
        XCTAssertTrue(result.contains("echo"), "Should contain echo")
        XCTAssertTrue(result.hasPrefix("/bin/zsh -lic "), "Should use interactive login shell")
        XCTAssertTrue(result.contains("exec sh -c"), "Should use sh for POSIX syntax")
    }

    func testWithFallbackNestedQuotes() {
        var cmd1 = CommandBuilder("claude")
        cmd1.option("--name", "my workstream")

        var cmd2 = CommandBuilder("claude")
        cmd2.option("--session-id", "abc-123")

        let result = CommandBuilder.withFallback(cmd1.command, cmd2.command, shell: "/bin/zsh")
        XCTAssertTrue(result.hasPrefix("/bin/zsh -lic '"))
        XCTAssertTrue(result.contains("exec sh -c"))
        XCTAssertTrue(result.contains("--name"))
        XCTAssertTrue(result.contains("--session-id"))
    }

    // MARK: - shellQuote forShell (Fish-safe quoting)

    func testShellQuoteForPosixShellUsesSingleQuotes() {
        let result = CommandBuilder.shellQuote("it's a test", forShell: "/bin/zsh")
        XCTAssertEqual(result, "'it'\\''s a test'")
    }

    func testShellQuoteForFishUsesDoubleQuotes() {
        let result = CommandBuilder.shellQuote("it's a test", forShell: "/opt/homebrew/bin/fish")
        XCTAssertTrue(result.hasPrefix("\""), "Fish quoting should use double quotes")
        XCTAssertTrue(result.hasSuffix("\""), "Fish quoting should use double quotes")
        XCTAssertTrue(result.contains("it's a test"), "Single quotes should pass through in double-quoted strings")
    }

    func testShellQuoteForFishEscapesDollarSign() {
        let result = CommandBuilder.shellQuote("echo $HOME", forShell: "/usr/local/bin/fish")
        XCTAssertTrue(result.contains("\\$HOME"), "Dollar signs must be escaped for Fish double quotes")
    }

    func testShellQuoteForFishEscapesBackslash() {
        let result = CommandBuilder.shellQuote("path\\to", forShell: "/opt/homebrew/bin/fish")
        XCTAssertTrue(result.contains("\\\\"), "Backslashes must be escaped for Fish double quotes")
    }

    func testShellQuoteForFishEscapesDoubleQuotes() {
        let result = CommandBuilder.shellQuote("say \"hello\"", forShell: "/opt/homebrew/bin/fish")
        XCTAssertTrue(result.contains("\\\"hello\\\""), "Double quotes must be escaped for Fish")
    }

    func testShellQuoteForFishLeavesBackticksAlone() {
        let result = CommandBuilder.shellQuote("run `cmd`", forShell: "/opt/homebrew/bin/fish")
        XCTAssertEqual(result, "\"run `cmd`\"", "Backticks are literal inside Fish double quotes; escaping them injects a stray backslash")
    }

    func testShellQuoteForFishLeavesParenthesesAlone() {
        let result = CommandBuilder.shellQuote("a || (b; c)", forShell: "/opt/homebrew/bin/fish")
        XCTAssertEqual(result, "\"a || (b; c)\"", "Parens are literal inside Fish double quotes; escaping them breaks the sh subshell that reads the payload")
    }

    func testShellQuoteForFishSimpleStringStaysUnquoted() {
        let result = CommandBuilder.shellQuote("/usr/bin/test", forShell: "/opt/homebrew/bin/fish")
        XCTAssertEqual(result, "/usr/bin/test", "Simple strings need no quoting even for Fish")
    }

    func testWithFallbackFish() {
        let result = CommandBuilder.withFallback("cmd1", "cmd2", shell: "/opt/homebrew/bin/fish")
        XCTAssertTrue(result.contains("exec sh -c"), "Should still use sh for POSIX syntax")
        XCTAssertTrue(result.contains("cmd1 || cmd2"))
    }

    /// Fish quoting stops at the argument fish parses, and the outermost token
    /// is POSIX-quoted for every shell — because that one is read by ghostty's
    /// `/bin/bash -c` wrapper, not by the login shell it names.
    ///
    /// This replaces a test that asserted the opposite (`hasPrefix("fish -lic
    /// \"")`). Double quotes there left backticks live for bash to substitute,
    /// which is how the IPC system prompt reached the agent with every tool
    /// name deleted from it and `bash: register_peer: command not found` on
    /// screen. The round-trip tests below are the real guard; this one names
    /// the mechanism so the two cannot be "simplified" back together.
    func testWithFallbackPosixQuotesTheOutermostArgumentEvenForFish() {
        let result = CommandBuilder.withFallback("cmd1", "cmd2", shell: "/opt/homebrew/bin/fish")
        XCTAssertTrue(
            result.hasPrefix("/opt/homebrew/bin/fish -lic '"),
            "The outermost argument is parsed by bash, so it must be POSIX-quoted: \(result)"
        )
        XCTAssertTrue(result.contains("exec sh -c \""), "The argument fish parses stays fish-quoted: \(result)")
    }

    // MARK: - Payload round trips (integration tests)

    // These invoke real shell binaries through `ShellWrapper`, which reproduces
    // ghostty's own macOS wrapper — `/bin/bash --noprofile --norc -c "exec -l
    // …"`, not the `/bin/sh -c` this comment used to claim. They assert what the
    // child process receives, which is the only thing that ever mattered.

    private func assertPayloadSurvivesFallback(shell: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let command = CommandBuilder.withFallback(
            ShellWrapper.printfCommand(), "/usr/bin/false",
            shell: shell
        )
        try ShellWrapper.assertPayloadSurvives(command, file: file, line: line)
    }

    func testFallbackPayloadSurvivesUnderFish() throws {
        try assertPayloadSurvivesFallback(shell: ShellWrapper.requireFish())
    }

    func testFallbackPayloadSurvivesUnderZsh() throws {
        try assertPayloadSurvivesFallback(shell: "/bin/zsh")
    }

    func testFallbackPayloadSurvivesUnderBash() throws {
        try assertPayloadSurvivesFallback(shell: "/bin/bash")
    }

    /// The failing case as the user met it: a `--append-system-prompt` whose
    /// value is the IPC prompt, backticked tool names and all.
    func testAgentSystemPromptSurvivesUnderFish() throws {
        let prompt = SystemPrompts.agentIPCPrompt(workstreamName: "start-messages")
        var resume = CommandBuilder("/usr/bin/printf")
        resume.option("%s", prompt)
        let command = try CommandBuilder.withFallback(
            resume.command, "/usr/bin/false",
            message: "Starting new session...",
            shell: ShellWrapper.requireFish()
        )
        try ShellWrapper.assertPayloadSurvives(command, payload: prompt)
    }

    /// The same path with the auto-rename prompt, and the destructive half of
    /// this bug rather than the lossy one.
    ///
    /// `agentIPCPrompt`'s backticks hold tool names, so substituting them
    /// deleted words. This prompt's hold `git branch -m <new-name>` and an
    /// `mkdir`/`echo` pair that writes `.atelier-state/description` — commands
    /// bash would have *run*, on every agent launch, before claude ever saw the
    /// prompt. Nothing about the fix is specific to which prompt is active, and
    /// this test is here so nobody concludes otherwise.
    func testAutoRenamePromptSurvivesUnderFish() throws {
        let prompt = SystemPrompts.autoRenameBranchPrompt
        var fresh = CommandBuilder("/usr/bin/printf")
        fresh.option("%s", prompt)
        let command = try CommandBuilder.withFallback(
            fresh.command, "/usr/bin/false",
            shell: ShellWrapper.requireFish()
        )
        try ShellWrapper.assertPayloadSurvives(command, payload: prompt)
    }

    // MARK: - Shell syntax validation (integration tests)

    // These tests invoke real shell binaries to verify generated commands parse
    // correctly. Syntax only — a command can parse cleanly in the outer shell
    // and still deliver a mangled payload, which is what the round trips above
    // are for.

    private func assertShellCanParse(_ command: String, file: StaticString = #filePath, line: UInt = #line) throws {
        // Replace -lic with -nc: keeps -c (command string) but adds -n (no-execute/syntax-only)
        let syntaxCheck = command.replacingOccurrences(of: " -lic ", with: " -nc ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", syntaxCheck]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "(no stderr)"
            XCTFail("Shell failed to parse command (exit \(process.terminationStatus)): \(errMsg)", file: file, line: line)
        }
    }

    private func fallbackCommand(shell: String) -> String {
        var cmd1 = CommandBuilder("claude")
        cmd1.option("--name", "my workstream")
        var cmd2 = CommandBuilder("claude")
        cmd2.option("--session-id", "abc-123")
        return CommandBuilder.withFallback(
            cmd1.command, cmd2.command,
            message: "it's retrying",
            shell: shell
        )
    }

    func testWithFallbackParsesInZsh() throws {
        try assertShellCanParse(fallbackCommand(shell: "/bin/zsh"))
    }

    func testWithFallbackParsesInBash() throws {
        try assertShellCanParse(fallbackCommand(shell: "/bin/bash"))
    }

    func testWithFallbackParsesInFish() throws {
        let fishPath = "/opt/homebrew/bin/fish"
        guard FileManager.default.fileExists(atPath: fishPath) else {
            throw XCTSkip("Fish not installed at \(fishPath)")
        }
        try assertShellCanParse(fallbackCommand(shell: fishPath))
    }

    /// `testWithFallbackParsesInFish` uses `fish -n`, which validates *fish* syntax and
    /// never looks inside the nested `sh -c` string — so it stayed green while the
    /// fallback branch was printing `sh: (echo: command not found`. This one runs the
    /// command and reads its output.
    func testWithFallbackActuallyRunsTheFallbackUnderFish() throws {
        let fishPath = "/opt/homebrew/bin/fish"
        guard FileManager.default.fileExists(atPath: fishPath) else {
            throw XCTSkip("Fish not installed at \(fishPath)")
        }

        let command = CommandBuilder.withFallback(
            "false", "echo FELL-BACK",
            message: "it's retrying",
            shell: fishPath
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(output.contains("it's retrying"), "Expected the fallback message, got: \(output)")
        XCTAssertTrue(output.contains("FELL-BACK"), "Expected the fallback command to run, got: \(output)")
        XCTAssertFalse(output.contains("command not found"), "Payload reached sh mangled: \(output)")
        XCTAssertFalse(output.contains("FELL-BACK)"), "Subshell grouping was destroyed: \(output)")
    }

    // MARK: - Real-world command patterns

    func testClaudeResumeCommand() {
        var cmd = CommandBuilder("/opt/homebrew/bin/claude")
        cmd.option("--resume", "a1b2c3d4")
        cmd.option("--name", "deploy-auth-fix")
        cmd.flag("--dangerously-skip-permissions")
        XCTAssertEqual(cmd.command, "/opt/homebrew/bin/claude --resume a1b2c3d4 --name deploy-auth-fix --dangerously-skip-permissions")
    }

    func testClaudeWithSystemPrompt() {
        var cmd = CommandBuilder("claude")
        cmd.option("--append-system-prompt", "Rename the branch using `git branch -m <name>`.")
        let result = cmd.command
        XCTAssertTrue(result.contains("--append-system-prompt"))
        // Backticks and angle brackets should be quoted
        XCTAssertTrue(result.contains("'"))
    }

    func testWithFallbackQuotesAShellPathContainingASpace() {
        let result = CommandBuilder.withFallback("cmd1", "cmd2", shell: "/Applications/My Shells/zsh")
        XCTAssertTrue(
            result.hasPrefix("'/Applications/My Shells/zsh' -lic "),
            "Expected a quoted shell path, got: \(result)"
        )
    }
}
