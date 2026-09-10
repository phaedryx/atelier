// ABOUTME: Builds shell command strings with proper escaping.
// ABOUTME: Replaces ad-hoc string concatenation for claude/tmux commands.

import Foundation

struct CommandBuilder {
    private var parts: [String] = []

    init(_ executable: String) {
        parts.append(executable)
    }

    mutating func arg(_ value: String) {
        parts.append(value)
    }

    mutating func flag(_ name: String) {
        parts.append(name)
    }

    mutating func option(_ name: String, _ value: String) {
        parts.append(name)
        parts.append(Self.shellQuote(value))
    }

    var command: String {
        parts.joined(separator: " ")
    }

    /// Wrap two commands in a fallback using the user's login shell for proper PATH.
    /// Uses two layers: the login shell loads profiles, then exec's sh for POSIX syntax.
    /// This is shell-agnostic (works with zsh, bash, fish) because only sh sees POSIX operators.
    static func withFallback(_ primary: String, _ fallback: String, message: String? = nil, shell: String = userShell) -> String {
        let fallbackCmd: String
        if let message {
            let escapedMessage = shellQuote(message)
            fallbackCmd = "(echo \(escapedMessage); \(fallback))"
        } else {
            fallbackCmd = fallback
        }
        return inLoginShell("\(primary) || \(fallbackCmd)", shell: shell)
    }

    /// Run one command through the user's login shell, so it sees the PATH their
    /// profile builds.
    ///
    /// Two layers, and both are load-bearing: the login shell loads profiles,
    /// then `exec sh` gives POSIX syntax regardless of whether that shell is
    /// zsh, bash or fish. Factored out of `withFallback`, which is the same
    /// wrapping around a `||` pair — a single command needs the wrapping without
    /// needing a fallback to invent.
    static func inLoginShell(_ command: String, shell: String = userShell) -> String {
        let shArgQuote = isFish(shell) ? fishQuote(command) : shellQuote(command)
        let shCmd = "exec sh -c \(shArgQuote)"
        // Quoted for the same reason `RunLauncher.runScriptCommand` quotes it:
        // $SHELL can sit under a path with a space.
        //
        // POSIX quoting, *not* `forShell:`, and that is the whole point: this
        // outermost token is never parsed by the user's shell. Ghostty runs a
        // surface command through `/usr/bin/login -flp <user> /bin/bash
        // --noprofile --norc -c "exec -l <command>"` on macOS
        // (`ghostty/src/termio/Exec.zig`), so bash reads this string and only
        // then execs the login shell. Fish-quoting it wrapped the payload in
        // double quotes that bash happily performed command substitution
        // inside: every backtick in `--append-system-prompt` ran as a command
        // and vanished from the prompt.
        return "\(shellQuote(shell)) -lic \(shellQuote(shCmd))"
    }

    static var userShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    static func shellQuote(_ s: String) -> String {
        let simple = !s.isEmpty && s.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/" || $0 == ":" || $0 == "~" || $0 == "@" || $0 == "+" || $0 == "="
        }
        if simple {
            return s
        }
        return "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Quote a string for the given shell, for the one argument that shell
    /// itself parses.
    ///
    /// Fish's single quotes are not POSIX — `\'` and `\\` are escapes *inside*
    /// them — so one level of `'\''` survives by coincidence and two levels do
    /// not, which is what "Fish 4.0 can't parse POSIX `'\''`" (#309) actually
    /// was. Hence double quotes when the parser is fish.
    ///
    /// **Never for the outermost token of a command string.** That one is read
    /// by ghostty's `/bin/bash --noprofile --norc -c` wrapper, not by the user's
    /// shell, and double quotes leave backticks and `$(…)` live for bash to
    /// substitute. Outermost tokens use the POSIX `shellQuote` above. One
    /// production caller is left — `TmuxSession.wrapCommand`, for the `sh -c`
    /// argument fish reads; `inLoginShell` reaches `fishQuote` directly for the
    /// same argument.
    static func shellQuote(_ s: String, forShell shell: String) -> String {
        let simple = !s.isEmpty && s.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/" || $0 == ":" || $0 == "~" || $0 == "@" || $0 == "+" || $0 == "="
        }
        if simple {
            return s
        }
        if isFish(shell) {
            return fishQuote(s)
        }
        return shellQuote(s)
    }

    static func isFish(_ shell: String) -> Bool {
        shell.hasSuffix("/fish") || shell == "fish"
    }

    /// Inside fish double quotes only `\\`, `$` and `"` are special — everything else,
    /// including `(`, `)` and backticks, is already literal. Escaping those anyway does
    /// not "extra-protect" them: fish leaves the backslash in place, so a payload handed
    /// on to `sh -c` arrives as `\\(echo ...` and sh reads the paren as literal, which
    /// destroys subshell grouping (`sh: (echo: command not found`). Escape the three that
    /// are actually special and nothing more.
    private static func fishQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
        return "\"\(escaped)\""
    }
}
