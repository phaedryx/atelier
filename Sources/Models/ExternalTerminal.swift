// ABOUTME: Runs a command on a file in Apple Terminal.
// ABOUTME: One hardened path, so no view assembles AppleScript or shell text itself.

import AppKit
import Foundation

/// The one place Atelier hands a *command* to a terminal application.
///
/// Opening a *directory* is an `NSWorkspace` call with no injection risk, and
/// lives in `ExternalApp` beside the editors, which open the same way.
///
/// Opening a *file in an editor* has to name a command, because that is what
/// Terminal's `do script` takes. It goes through `AppleScriptRunner`, so the
/// paths are event parameters rather than text spliced into a script, and the
/// shell quoting is done by AppleScript's own `quoted form of` inside the
/// script. Neither layer is escaped in Swift because neither layer is
/// assembled in Swift.
enum ExternalTerminal {
    /// Runs `<executablePath> <filePath>` in a new Apple Terminal window.
    ///
    /// Both paths arrive as AppleScript event parameters and are quoted by the
    /// script itself, so a file name containing `"`, `\`, `'` or a newline is
    /// an argument and can never become AppleScript or shell syntax. Apple
    /// Terminal specifically, because `do script` is its vocabulary and no
    /// other terminal is guaranteed to answer it.
    static func run(executablePath: String, on filePath: String) {
        AppleScriptRunner.runLoggingFailure(
            source: runScript,
            handler: runHandler,
            arguments: [executablePath, filePath]
        )
    }

    /// The handler `run` invokes.
    static let runHandler = "atelierruninterminal"

    /// The handler that assembles the shell command, called by `runHandler` and
    /// exercised directly by `Tests/ExternalTerminalTests.swift`. Splitting it
    /// out is what lets the tests assert the **production** quoting rather than
    /// a copy of it that could drift away from what actually runs.
    static let commandHandler = "atelierterminalcommand"

    /// Constant source: it declares two handlers and holds no caller data.
    /// Every value reaches it as an event parameter.
    static let runScript = """
    on \(commandHandler)(executablePath, filePath)
        return (quoted form of executablePath) & " " & (quoted form of filePath)
    end \(commandHandler)

    on \(runHandler)(executablePath, filePath)
        -- Resolved before the tell block on purpose: inside one, an unqualified
        -- call is dispatched to Terminal rather than to this script, and Terminal
        -- answers "Can't continue" for a handler it has never heard of.
        set theCommand to \(commandHandler)(executablePath, filePath)
        tell application "Terminal"
            activate
            do script theCommand
        end tell
    end \(runHandler)
    """
}
