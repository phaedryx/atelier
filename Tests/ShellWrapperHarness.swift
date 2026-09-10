// ABOUTME: Test harness that runs a generated surface command the way ghostty runs one.
// ABOUTME: Lets quoting tests assert what the child receives instead of which quote style was used.

@testable import Atelier
import Foundation
import XCTest

/// Runs a generated command string through the wrapper ghostty actually uses,
/// and reports what came back out.
///
/// **Ghostty does not hand a surface command to `/bin/sh -c` on macOS.** It
/// builds `/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c "exec -l
/// <command>"` (`ghostty/src/termio/Exec.zig`, `execCommand`). The `login`
/// layer supplies a login session and utmp bookkeeping and parses nothing, so
/// it is dropped here. The layer that matters is bash, because bash is what
/// reads the command string — including any backtick or `$(…)` the outermost
/// quoting layer left unprotected.
///
/// Believing the `/bin/sh -c` version is what let the wrong-layer fix in #324
/// through: it fish-quoted the *outermost* token, wrapping it in double quotes,
/// and bash then ran every backtick in `--append-system-prompt` as a command
/// and substituted the empty result. Three tests asserting "the outer argument
/// starts with a double quote" stayed green throughout, because the quote style
/// was exactly what they checked.
enum ShellWrapper {
    struct Output {
        let stdout: String
        let stderr: String
        var combined: String {
            stdout + stderr
        }
    }

    /// One of each character class a shell might act on rather than pass
    /// through, in a multi-line string — the shape of the real payload, which
    /// is a `--append-system-prompt` value full of backticked tool names.
    static let hostilePayload = """
    backticks `whoami` and $(id -un) and a bare $HOME
    apostrophe it's, quote "q", backslash \\, semicolon; pipe | paren (x)
    """

    static let fishPath = "/opt/homebrew/bin/fish"

    static func requireFish() throws -> String {
        guard FileManager.default.fileExists(atPath: fishPath) else {
            throw XCTSkip("Fish not installed at \(fishPath)")
        }
        return fishPath
    }

    static func run(_ command: String) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", "exec -l \(command)"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        // Read before waiting: an interactive login shell plus the payload can
        // pass the pipe buffer, and waiting first would deadlock.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Asserts the child process received `payload` intact.
    ///
    /// `contains` rather than an equality check on stdout, because these run the
    /// user's real interactive login shell and its rc files may print. What the
    /// check pins is that no layer expanded, substituted or dropped a character
    /// of the payload on the way down.
    static func assertPayloadSurvives(
        _ command: String,
        payload: String = hostilePayload,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let output = try run(command)
        XCTAssertTrue(
            output.combined.contains(payload),
            "Payload was mangled between the wrapper and the child.\n"
                + "stdout: \(output.stdout)\nstderr: \(output.stderr)",
            file: file,
            line: line
        )
        XCTAssertFalse(
            output.combined.contains("command not found"),
            "A layer performed command substitution on the payload: \(output.combined)",
            file: file,
            line: line
        )
    }

    /// A command that prints one argument verbatim, built through
    /// `CommandBuilder` so the quoting under test is the production quoting.
    static func printfCommand(_ payload: String = hostilePayload) -> String {
        var cmd = CommandBuilder("/usr/bin/printf")
        cmd.option("%s", payload)
        return cmd.command
    }
}
