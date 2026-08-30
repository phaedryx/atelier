// ABOUTME: Tests for UsageProbe's parsing of `claude -p /usage --output-format json`
// ABOUTME: output into session / weekly / model-week percentage windows.

@testable import Atelier
import XCTest

final class UsageProbeTests: XCTestCase {
    private let realOutput = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 100% used · resets Aug 30 at 1:10am (America/Denver)
    Current week (all models): 58% used · resets Aug 31 at 8pm (America/Denver)
    Current week (Fable): 29% used · resets Aug 31 at 8pm (America/Denver)

    What's contributing to your limits usage?
    Last 24h · 3028 requests · 22 sessions
      67% of your usage was at >150k context
    """

    // MARK: - parseText

    func testParsesAllThreeWindows() {
        let report = UsageProbe.parseText(realOutput)
        XCTAssertEqual(report?.session?.percentUsed, 100)
        XCTAssertEqual(report?.week?.percentUsed, 58)
        XCTAssertEqual(report?.modelWeek?.percentUsed, 29)
    }

    func testParsesResetTextWithoutTimezone() {
        let report = UsageProbe.parseText(realOutput)
        XCTAssertEqual(report?.session?.resetText, "Aug 30 at 1:10am")
        XCTAssertEqual(report?.week?.resetText, "Aug 31 at 8pm")
        XCTAssertEqual(report?.modelWeek?.resetText, "Aug 31 at 8pm")
    }

    func testParsesModelWeekForAnyModelName() {
        let report = UsageProbe.parseText(
            "Current week (Opus): 12% used · resets Sep 1 at 9am (UTC)"
        )
        XCTAssertEqual(report?.modelWeek?.percentUsed, 12)
        XCTAssertEqual(report?.modelName, "Opus")
        XCTAssertNil(report?.week)
    }

    func testCapturesModelNameFromRealOutput() {
        XCTAssertEqual(UsageProbe.parseText(realOutput)?.modelName, "Fable")
    }

    func testSessionOnlyOutputYieldsPartialReport() {
        let report = UsageProbe.parseText("Current session: 7% used")
        XCTAssertEqual(report?.session?.percentUsed, 7)
        XCTAssertNil(report?.session?.resetText)
        XCTAssertNil(report?.week)
        XCTAssertNil(report?.modelWeek)
    }

    func testUnrelatedPercentLinesAreIgnored() {
        // Breakdown lines like "67% of your usage was at >150k context" must not
        // be mistaken for usage windows.
        let report = UsageProbe.parseText("Last 24h\n  67% of your usage was at >150k context")
        XCTAssertNil(report)
    }

    func testGarbageYieldsNil() {
        XCTAssertNil(UsageProbe.parseText(""))
        XCTAssertNil(UsageProbe.parseText("API usage billing — no limits apply"))
    }

    // MARK: - parse (JSON envelope)

    func testParsesResultFromJSONEnvelope() {
        let json = """
        {"is_error":false,"result":"Current session: 42% used · resets Aug 30 at 1am (UTC)","type":"result"}
        """
        let report = UsageProbe.parse(Data(json.utf8))
        XCTAssertEqual(report?.session?.percentUsed, 42)
    }

    func testMalformedJSONYieldsNil() {
        XCTAssertNil(UsageProbe.parse(Data("not json".utf8)))
        XCTAssertNil(UsageProbe.parse(Data("{\"result\":123}".utf8)))
    }
}
