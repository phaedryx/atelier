// ABOUTME: Tests for resolving absolute paths to app-launched command line tools.
// ABOUTME: Guards against debug and release builds using different command lookup behavior.

@testable import Atelier
import XCTest

final class CommandLineToolsTests: XCTestCase {
    func testPrefersLoginShellPath() {
        // The login shell PATH should take priority over known locations
        // so we find the same binary the user's terminal would.
        var knownLocationChecked = false
        let resolved = CommandLineTools.path(
            for: "claude",
            environment: ["SHELL": "/bin/zsh"],
            isExecutable: { path in
                if path == "/opt/homebrew/bin/claude" {
                    knownLocationChecked = true
                }
                return path == "/Users/me/.nvm/versions/node/v22/bin/claude"
            },
            resolveFromPath: { _, _ in nil },
            resolveFromShellPath: { shell in
                XCTAssertEqual(shell, "/bin/zsh")
                return "/Users/me/.nvm/versions/node/v22/bin:/opt/homebrew/bin:/usr/bin"
            }
        )

        XCTAssertEqual(resolved, "/Users/me/.nvm/versions/node/v22/bin/claude")
        XCTAssertFalse(knownLocationChecked, "Known locations should not be checked when shell PATH matches")
    }

    func testFallsBackToProcessPathWhenShellPathMisses() {
        let resolved = CommandLineTools.path(
            for: "mytool",
            environment: ["PATH": "/custom/bin", "SHELL": "/bin/zsh"],
            isExecutable: { $0 == "/custom/bin/mytool" },
            resolveFromPath: { name, env in
                let rawPath = env["PATH"] ?? ""
                for dir in rawPath.split(separator: ":") {
                    let candidate = "\(dir)/\(name)"
                    if candidate == "/custom/bin/mytool" {
                        return candidate
                    }
                }
                return nil
            },
            resolveFromShellPath: { _ in
                // Shell PATH doesn't contain the tool
                "/usr/bin:/bin"
            }
        )

        XCTAssertEqual(resolved, "/custom/bin/mytool")
    }

    func testFallsBackToKnownLocationsAsLastResort() {
        let resolved = CommandLineTools.path(
            for: "git",
            environment: ["PATH": "", "SHELL": "/bin/zsh"],
            isExecutable: { $0 == "/opt/homebrew/bin/git" },
            resolveFromPath: { _, _ in nil },
            resolveFromShellPath: { _ in
                // Shell PATH doesn't contain the tool either
                "/usr/bin:/bin"
            }
        )

        XCTAssertEqual(resolved, "/opt/homebrew/bin/git")
    }

    func testReturnsNilWhenNothingFound() {
        let resolved = CommandLineTools.path(
            for: "nonexistent",
            environment: ["PATH": "", "SHELL": "/bin/zsh"],
            isExecutable: { _ in false },
            resolveFromPath: { _, _ in nil },
            resolveFromShellPath: { _ in "/usr/bin:/bin" }
        )

        XCTAssertNil(resolved)
    }

    func testFallsBackToNixSystemLocation() {
        let resolved = CommandLineTools.path(
            for: "tmux",
            environment: ["PATH": "", "SHELL": "/bin/zsh"],
            isExecutable: { $0 == "/run/current-system/sw/bin/tmux" },
            resolveFromPath: { _, _ in nil },
            resolveFromShellPath: { _ in "/usr/bin:/bin" }
        )

        XCTAssertEqual(resolved, "/run/current-system/sw/bin/tmux")
    }

    func testFallsBackToNixProfileLocation() {
        let nixProfilePath = "\(NSHomeDirectory())/.nix-profile/bin/gh"
        let resolved = CommandLineTools.path(
            for: "gh",
            environment: ["PATH": "", "SHELL": "/bin/zsh"],
            isExecutable: { $0 == nixProfilePath },
            resolveFromPath: { _, _ in nil },
            resolveFromShellPath: { _ in "/usr/bin:/bin" }
        )

        XCTAssertEqual(resolved, nixProfilePath)
    }

    func testSkipsShellPathWhenShellNotSet() {
        // No SHELL in environment, should skip shell PATH and fall through
        let resolved = CommandLineTools.path(
            for: "git",
            environment: ["PATH": ""],
            isExecutable: { $0 == "/usr/local/bin/git" },
            resolveFromPath: { _, _ in nil },
            resolveFromShellPath: { _ in
                XCTFail("Shell PATH should not be queried when SHELL is not set")
                return nil
            }
        )

        XCTAssertEqual(resolved, "/usr/local/bin/git")
    }

    // MARK: - Login-shell PATH output

    func testTakesTheLastLineOfShellOutput() {
        // A .zshrc / config.fish that echoes a banner puts its text ahead of the
        // PATH. Trimming the whole buffer left the banner glued to the first entry.
        let parsed = CommandLineTools.parseShellPathOutput("""
        Welcome back!
        nvm: using v22
        /opt/homebrew/bin:/usr/bin
        """)

        XCTAssertEqual(parsed, "/opt/homebrew/bin:/usr/bin")
    }

    func testIgnoresTrailingBlankLines() {
        XCTAssertEqual(
            CommandLineTools.parseShellPathOutput("/usr/bin:/bin\n\n  \n"),
            "/usr/bin:/bin"
        )
    }

    func testEmptyShellOutputIsNoPath() {
        XCTAssertNil(CommandLineTools.parseShellPathOutput("  \n\n"))
    }

    // MARK: - Process PATH fallback

    func testProcessPathFallbackUsesTheInjectedExecutableCheck() {
        // The default `resolveFromPath` used to hardcode FileManager, so this
        // lookup reached the real filesystem in tests and in every caller that
        // passed an `isExecutable` of its own.
        var probed: [String] = []
        let resolved = CommandLineTools.path(
            for: "mytool",
            environment: ["PATH": "/custom/bin:/other/bin"],
            isExecutable: { path in
                probed.append(path)
                return path == "/other/bin/mytool"
            },
            resolveFromShellPath: { _ in nil }
        )

        XCTAssertEqual(resolved, "/other/bin/mytool")
        XCTAssertEqual(Array(probed.prefix(2)), ["/custom/bin/mytool", "/other/bin/mytool"])
    }
}
