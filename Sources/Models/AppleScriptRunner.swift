// ABOUTME: Runs AppleScript by calling a named handler with event parameters.
// ABOUTME: Keeps caller data out of the script source, so it cannot be parsed as code.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "applescript")

/// Runs AppleScript **without ever interpolating caller data into the source
/// text**, mirroring the role `ProcessRunner` plays for child processes.
///
/// Building a script by interpolation is two nested languages deep — the Swift
/// value lands inside an AppleScript string literal, which in turn usually
/// lands inside a shell command — and escaping for one of those layers looks
/// exactly like escaping for both. A file named `x"; do script "curl … | sh`
/// closes the AppleScript literal and the rest is compiled as AppleScript, so
/// a repository's own file names became code. Atelier runs coding agents
/// against cloned repositories, which makes every name in a work tree
/// untrusted input.
///
/// So the source a caller supplies is a **constant**: it declares handlers and
/// nothing else, and the values go in as `NSAppleEventDescriptor` parameters,
/// the same way arguments reach `execve` rather than a shell. There is no
/// escaping to get right because there is no layer left to escape for — the
/// injection is unrepresentable rather than defended against.
///
/// The shell layer, where a script has one, is closed the same way: AppleScript's
/// own `quoted form of` does the POSIX quoting inside the script, so no Swift
/// caller assembles a command line either.
enum AppleScriptRunner {
    enum Failure: Error, Equatable {
        /// The source did not compile. Sources here are constants, so this is a
        /// programming error rather than anything a caller's data can cause.
        case compileFailed
        /// AppleScript reported an error. Carries its message for the log.
        case executionFailed(String)
    }

    // AppleScript's own four-character codes. `kASAppleScriptSuite`,
    // `kASSubroutineEvent` and `keyASSubroutineName` are C constants that the
    // Swift overlay does not re-export, so they are spelled out here.
    private static let appleScriptSuite = AEEventClass(0x6173_6372) // 'ascr'
    private static let subroutineEvent = AEEventID(0x7073_6272) // 'psbr'
    private static let subroutineName = AEKeyword(0x736E_616D) // 'snam'

    /// Calls `handler` in `source`, passing `arguments` as event parameters.
    ///
    /// `handler` must be spelled in lower case, both here and in the source:
    /// the subroutine name travels as a string and is matched against the
    /// compiled script's handler table, which holds names lowercased.
    @discardableResult
    static func run(source: String, handler: String, arguments: [String]) throws -> String? {
        guard let script = NSAppleScript(source: source) else {
            throw Failure.compileFailed
        }
        var error: NSDictionary?
        // Compile up front. `NSAppleScript` would otherwise compile lazily on
        // execute and report a syntax error as an execution failure, which
        // hides the one failure mode that is always a bug in Atelier's own
        // constant source rather than a runtime condition.
        guard script.compileAndReturnError(&error) else {
            throw Failure.compileFailed
        }
        let result = script.executeAppleEvent(
            event(handler: handler, arguments: arguments),
            error: &error
        )
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String
                ?? String(describing: error)
            throw Failure.executionFailed(message)
        }
        return result.stringValue
    }

    /// The same call as `run`, with the failure logged rather than thrown.
    ///
    /// A failure here is Atelier's own plumbing — a mistyped handler name, a
    /// missing automation permission — and never something the user can act on
    /// from the surface that asked. It must still not be *silent*: swallowing
    /// the error dictionary is how the escaping bug this type replaces would
    /// have presented, as ordinary files quietly failing to open.
    @discardableResult
    static func runLoggingFailure(
        source: String,
        handler: String,
        arguments: [String]
    ) -> String? {
        do {
            return try run(source: source, handler: handler, arguments: arguments)
        } catch {
            logger.error("AppleScript handler \(handler, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The event a call marshals into. Separate so a test can inspect the
    /// descriptor a set of arguments produces without executing anything.
    static func event(handler: String, arguments: [String]) -> NSAppleEventDescriptor {
        let parameters = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            // AEDescList indices are 1-based.
            parameters.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        let event = NSAppleEventDescriptor(
            eventClass: appleScriptSuite,
            eventID: subroutineEvent,
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: subroutineName)
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))
        return event
    }
}
