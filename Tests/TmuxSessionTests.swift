// ABOUTME: Tests for tmux session configuration and command composition.
// ABOUTME: Verifies respawn behavior is scoped to agent sessions, not global.

@testable import Atelier
import XCTest

final class TmuxSessionTests: XCTestCase {
    func testConfigKeepsNativeMouseSelectionEnabled() {
        XCTAssertTrue(TmuxSession.configContents.contains("set -g mouse off"))
        XCTAssertFalse(TmuxSession.configContents.contains("set -g mouse on"))
    }

    func testConfigDoesNotGloballyRespawnDeadPanes() {
        XCTAssertFalse(TmuxSession.configContents.contains("pane-died"))
        XCTAssertTrue(TmuxSession.configContents.contains("set -g remain-on-exit on"))
        XCTAssertTrue(TmuxSession.configContents.contains("set -g remain-on-exit-format \"\""))
    }

    func testRespawnOnExitAddsSessionLevelHook() {
        let command = TmuxSession.wrapCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            sessionName: "proj/ws/agent",
            command: "claude",
            respawnOnExit: true,
            shell: "/bin/zsh"
        )
        XCTAssertTrue(command.contains("set-hook pane-died"))
    }

    func testDefaultDoesNotRespawn() {
        let command = TmuxSession.wrapCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            sessionName: "proj/ws/setup",
            command: "setup.sh",
            shell: "/bin/zsh"
        )
        XCTAssertFalse(command.contains("pane-died"))
    }

    func testWrapCommandQuotesEnvVarValuesWithSpaces() {
        let command = TmuxSession.wrapCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            sessionName: "proj/ws/agent",
            command: "echo hello",
            environmentVars: ["ATELIER_PROJECT": "My Project"],
            shell: "/bin/zsh"
        )

        // The value must be double-quoted so the shell keeps it as one token
        XCTAssertTrue(command.contains("-e \"ATELIER_PROJECT=My Project\""))
    }

    /// Inverse of the POSIX single-quote escaping both wrapping layers apply
    /// (`'` -> `'\''`). Unwrapping is what makes an exact assertion possible: a
    /// `contains` check on a fragment holds for any nesting that happens to include
    /// the substring, including one that mangled the layering.
    private func posixUnquoted(_ quoted: String) -> String? {
        guard quoted.count >= 2, quoted.hasPrefix("'"), quoted.hasSuffix("'") else { return nil }
        return quoted.dropFirst().dropLast().replacingOccurrences(of: "'\\''", with: "'")
    }

    func testWrapCommandQuotesEnvVarValuesWithSpecialChars() throws {
        let command = TmuxSession.wrapCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            sessionName: "proj/ws/agent",
            command: "echo hello",
            environmentVars: ["ATELIER_PROJECT": "client's \"best\" $project"],
            shell: "/bin/zsh"
        )

        // Four `contains` checks — for "ATELIER_PROJECT", "client", "best" and
        // "\$project" — passed for any command that merely mentioned those pieces,
        // which a broken double layer still does. Peel the two POSIX quote layers the
        // wrapper applies (login shell -> `sh -c`) and assert the exact flag tmux is
        // handed. This is the same nested-quoting territory as the fish bug in
        // `CommandBuilder.withFallback`, where `fish -n` validated the outer shell and
        // said nothing about the inner payload.
        let outerPrefix = "/bin/zsh -lic "
        XCTAssertTrue(command.hasPrefix(outerPrefix), command)
        let shCmd = try XCTUnwrap(posixUnquoted(String(command.dropFirst(outerPrefix.count))), command)

        let innerPrefix = "exec sh -c "
        XCTAssertTrue(shCmd.hasPrefix(innerPrefix), shCmd)
        let innerCmd = try XCTUnwrap(posixUnquoted(String(shCmd.dropFirst(innerPrefix.count))), shCmd)

        XCTAssertTrue(
            innerCmd.contains(#"-e "ATELIER_PROJECT=client's \"best\" \$project""#),
            "the flag tmux receives must carry the value double-quote-escaped exactly once: \(innerCmd)"
        )
    }

    /// Fish quoting belongs on the `sh -c` argument and nowhere else.
    ///
    /// Both halves of this used to be asserted the other way round — the outer
    /// argument had to *start* with a double quote and had to *not* contain
    /// `'\''`. That is a claim about quote style rather than about what the
    /// child receives, and it held while bash — which is what actually parses
    /// this token, via ghostty's `/bin/bash --noprofile --norc -c "exec -l …"`
    /// — performed command substitution on every backtick in the payload.
    func testWrapCommandFishQuotesOnlyTheArgumentFishParses() {
        let command = TmuxSession.wrapCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            sessionName: "proj/ws/agent",
            command: "claude",
            respawnOnExit: true,
            shell: "/opt/homebrew/bin/fish"
        )
        XCTAssertTrue(
            command.hasPrefix("/opt/homebrew/bin/fish -lic '"),
            "The outermost argument is parsed by bash, so it must be POSIX-quoted: \(command)"
        )
        XCTAssertTrue(command.contains("exec sh -c \""), "The argument fish parses stays fish-quoted: \(command)")
        XCTAssertTrue(command.contains("new-session -A -s"))
        XCTAssertTrue(command.contains("claude"))
    }

    /// The end-to-end version: a payload full of characters a shell might act
    /// on, driven through bash -> the login shell -> `sh -c` -> tmux's argv, with
    /// a stub standing in for tmux so nothing starts a server.
    private func assertTmuxPayloadSurvives(shell: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let stub = try makeArgvEchoStub()
        let command = TmuxSession.wrapCommand(
            tmuxPath: stub,
            sessionName: "atelier/proj/ws/agent",
            command: ShellWrapper.printfCommand(),
            environmentVars: ["ATELIER_PROJECT": "My Project"],
            shell: shell
        )
        // The stub prints tmux's argv, so the payload arrives as the text of the
        // command tmux was told to run rather than as printf's output.
        try ShellWrapper.assertPayloadSurvives(command, payload: ShellWrapper.hostilePayload, file: file, line: line)
    }

    func testTmuxPayloadSurvivesUnderFish() throws {
        try assertTmuxPayloadSurvives(shell: ShellWrapper.requireFish())
    }

    func testTmuxPayloadSurvivesUnderZsh() throws {
        try assertTmuxPayloadSurvives(shell: "/bin/zsh")
    }

    /// Stands in for the tmux binary: prints its arguments and exits, so
    /// `start-server`, `source-file` and `new-session` all no-op.
    private func makeArgvEchoStub() throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atelier-tmux-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("tmux")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub.path
    }

    // MARK: - Shell syntax validation (integration tests)

    // Invoke real shell binaries to verify generated tmux commands parse
    // correctly. Syntax only, and `/bin/sh` is a stand-in for the outer parser
    // rather than a claim about it — ghostty's real macOS wrapper is
    // `/bin/bash --noprofile --norc -c "exec -l …"` (see `ShellWrapper`). A
    // command can parse cleanly here and still deliver a mangled payload.

    private func assertShellCanParse(_ command: String, file: StaticString = #filePath, line: UInt = #line) throws {
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

    private func realisticTmuxCommand(shell: String) -> String {
        TmuxSession.wrapCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            sessionName: "atelier/my-project/deploy-auth-fix/agent",
            command: "/opt/homebrew/bin/claude --resume a1b2c3d4 --name 'deploy auth fix'",
            environmentVars: [
                "ATELIER_PROJECT": "My Project",
                "ATELIER_WORKSTREAM": "deploy-auth-fix",
                "ATELIER_DIR": "/Users/test/repos/my project's dir",
            ],
            respawnOnExit: true,
            shell: shell
        )
    }

    func testTmuxCommandParsesInFish() throws {
        let fishPath = "/opt/homebrew/bin/fish"
        guard FileManager.default.fileExists(atPath: fishPath) else {
            throw XCTSkip("Fish not installed at \(fishPath)")
        }
        let command = realisticTmuxCommand(shell: fishPath)
        try assertShellCanParse(command)
    }

    func testTmuxCommandParsesInZsh() throws {
        let command = realisticTmuxCommand(shell: "/bin/zsh")
        try assertShellCanParse(command)
    }

    func testTmuxCommandParsesInBash() throws {
        let command = realisticTmuxCommand(shell: "/bin/bash")
        try assertShellCanParse(command)
    }

    func testWrapCommandUsesLoginShellAndStartsServer() {
        let command = TmuxSession.wrapCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            sessionName: "project/workstream/setup",
            command: "bun run build",
            shell: "/bin/zsh"
        )

        XCTAssertTrue(command.hasPrefix("/bin/zsh -lic "), "Should use interactive login shell for PATH")
        XCTAssertTrue(command.contains("exec sh -c"), "Should use sh for POSIX syntax")
        XCTAssertTrue(command.contains("start-server"))
        XCTAssertTrue(command.contains("source-file"))
        XCTAssertTrue(command.contains("new-session -A -s"))
        XCTAssertTrue(command.contains("bun run build"))
    }
}
