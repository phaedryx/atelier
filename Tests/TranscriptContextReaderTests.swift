// ABOUTME: Tests for transcript context-usage parsing and context-window
// ABOUTME: resolution from the transcript plus Claude Code's model setting.

@testable import Atelier
import XCTest

final class TranscriptContextReaderTests: XCTestCase {
    private let userLine = #"{"type":"user","message":{"role":"user","content":"hello"}}"#
    private let sonnetLine =
        #"{"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":4,"cache_creation_input_tokens":123,"cache_read_input_tokens":45000,"output_tokens":99}}}"#
    private let opusOneMLine =
        #"{"type":"assistant","message":{"model":"claude-opus-4-1[1m]","usage":{"input_tokens":10,"cache_read_input_tokens":2000000}}}"#
    /// What Claude Code actually writes for a 1M session: the resolved model,
    /// with no marker anywhere on the line.
    private let opusLine =
        #"{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":5,"cache_read_input_tokens":133495}}}"#

    // MARK: - JSONL parsing

    func testSumsInputAndCacheFields() {
        let usage = TranscriptContextReader.usage(contents: sonnetLine)
        XCTAssertEqual(usage?.usedTokens, 4 + 123 + 45000)
        XCTAssertEqual(usage?.model, "claude-sonnet-4-5")
    }

    /// The transcript carries no marker for a 1M session — the whole reason
    /// `ContextLimits` needs a second signal.
    func testAOneMillionSessionIsIndistinguishableFromTheModelAlone() {
        let usage = TranscriptContextReader.usage(contents: opusLine)
        XCTAssertEqual(usage?.usedTokens, 5 + 133_495)
        XCTAssertEqual(usage?.model, "claude-opus-5")
    }

    func testLastAssistantEntryWins() {
        let contents = [userLine, sonnetLine, "not json at all", opusOneMLine].joined(separator: "\n")
        let usage = TranscriptContextReader.usage(contents: contents)
        XCTAssertEqual(usage?.usedTokens, 10 + 2_000_000)
        XCTAssertEqual(usage?.model, "claude-opus-4-1[1m]")
    }

    /// The case `testLastAssistantEntryWins` cannot reach: every assistant line there
    /// carries `usage`, so "last assistant line with usage" and "last assistant line,
    /// else nil" agree. A trailing assistant line *without* usage separates them, and
    /// it is the ordinary shape of a live transcript — the final turn is appended
    /// before its usage totals are.
    func testATrailingAssistantLineWithoutUsageDoesNotDiscardTheLastKnownUsage() {
        let noUsage = #"{"type":"assistant","message":{"model":"claude-opus-4-1[1m]"}}"#
        let contents = [userLine, sonnetLine, noUsage].joined(separator: "\n")

        let usage = TranscriptContextReader.usage(contents: contents)

        XCTAssertEqual(usage?.usedTokens, 4 + 123 + 45000, "the last line carrying usage is the sonnet one")
        XCTAssertEqual(usage?.model, "claude-sonnet-4-5", "the model must come from that same entry, not the later line")
    }

    func testMissingCacheFieldsDefaultToZero() {
        let line = #"{"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":42}}}"#
        let usage = TranscriptContextReader.usage(contents: line)
        XCTAssertEqual(usage?.usedTokens, 42)
    }

    func testSkipsMalformedAndUserLines() {
        let contents = [
            "{\"type\":\"assistant\",", // truncated
            userLine,
            "",
            sonnetLine,
        ].joined(separator: "\n")
        let usage = TranscriptContextReader.usage(contents: contents)
        XCTAssertEqual(usage?.usedTokens, 45127)
    }

    func testReturnsNilWithoutAssistantUsage() {
        XCTAssertNil(TranscriptContextReader.usage(contents: ""))
        XCTAssertNil(TranscriptContextReader.usage(contents: userLine))
        XCTAssertNil(TranscriptContextReader.usage(contents: "garbage\nmore garbage"))
        let noUsage = #"{"type":"assistant","message":{"model":"claude-sonnet-4-5"}}"#
        XCTAssertNil(TranscriptContextReader.usage(contents: noUsage))
    }

    // MARK: - File tail reading

    func testReadsUsageFromTempFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atelier-reader-tests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try [userLine, sonnetLine].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let usage = try XCTUnwrap(TranscriptContextReader.usage(transcriptPath: url.path))
        XCTAssertEqual(usage.usedTokens, 45127)
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(TranscriptContextReader.usage(transcriptPath: "/nonexistent/transcript.jsonl"))
    }

    /// The tail window starts at an arbitrary byte offset, which lands
    /// mid-codepoint whenever the transcript carries an emoji or a box-drawing
    /// character — i.e. most agent sessions. `String(data:encoding:.utf8)` then
    /// returns nil for the *whole* buffer, and the context meter showed nothing.
    func testReadsATailThatBeginsMidCodepoint() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        // Pad past the 256KB window with lines full of multi-byte characters, so
        // wherever the seek lands it is inside one.
        let padding = String(repeating: "🙂", count: 40)
        var lines: [String] = []
        var bytes = 0
        while bytes < 300 * 1024 {
            let line = #"{"type":"user","message":{"role":"user","content":"\#(padding)"}}"#
            lines.append(line)
            bytes += line.utf8.count + 1
        }
        lines.append(sonnetLine)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let usage = TranscriptContextReader.usage(transcriptPath: url.path)
        XCTAssertEqual(usage?.usedTokens, 4 + 123 + 45000)
    }

    func testReadsAShortFileWhole() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try "\(userLine)\n\(sonnetLine)\n".write(to: url, atomically: true, encoding: .utf8)

        let usage = TranscriptContextReader.usage(transcriptPath: url.path)
        XCTAssertEqual(usage?.usedTokens, 4 + 123 + 45000)
    }
}

final class ContextLimitsTests: XCTestCase {
    func testDefaultLimitWithoutAnyExtendedMarker() {
        XCTAssertEqual(ContextLimits.limitTokens(transcriptModel: nil, configuredModel: nil), 200_000)
        XCTAssertEqual(ContextLimits.limitTokens(transcriptModel: "", configuredModel: ""), 200_000)
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-sonnet-4-5", configuredModel: "sonnet"),
            200_000
        )
    }

    func testExtendedMarkerInTheTranscriptModelYieldsOneMillion() {
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-sonnet-4-5[1m]", configuredModel: nil),
            1_000_000
        )
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-sonnet-4-5-1m", configuredModel: nil),
            1_000_000
        )
    }

    func testMarkerMatchIsCaseInsensitive() {
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-sonnet-4-5[1M]", configuredModel: nil),
            1_000_000
        )
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "CLAUDE-SONNET-4-5-1M", configuredModel: nil),
            1_000_000
        )
    }

    /// The bug this all exists for: Claude Code writes the *resolved* model to
    /// the transcript, so a 1M Opus session is spelled "claude-opus-5" there
    /// and was measured against a 200k window — 133.5k read as 66% instead of
    /// 13%. The "[1m]" only survives in the model *selection*.
    func testTheSettingsSelectionSuppliesTheMarkerTheTranscriptDropped() {
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-opus-5", configuredModel: "opus[1m]"),
            1_000_000
        )
    }

    /// The settings value is global, so it must not widen a session running a
    /// different model — the whole reason the transcript model is still needed.
    func testASettingsSelectionForAnotherModelDoesNotWidenTheWindow() {
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-haiku-4-5-20251001", configuredModel: "opus[1m]"),
            200_000
        )
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-sonnet-5", configuredModel: "claude-fable-5[1m]"),
            200_000
        )
    }

    /// `opusplan` is Opus in plan mode and is not a substring of any resolved
    /// Opus ID, so comparing the alias by containment alone would leave the bug
    /// in place for anyone on that selection.
    func testTheOpusplanAliasCountsAsOpus() {
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-opus-5", configuredModel: "opusplan[1m]"),
            1_000_000
        )
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-sonnet-5", configuredModel: "opusplan[1m]"),
            200_000
        )
    }

    /// A family this build has never heard of still resolves by containment.
    func testAnUnknownFamilyFallsBackToContainment() {
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-newthing-1", configuredModel: "claude-newthing-1[1m]"),
            1_000_000
        )
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-newthing-1", configuredModel: "claude-otherthing-1[1m]"),
            200_000
        )
    }

    func testAFullModelIDInSettingsMatchesTheSameIDInTheTranscript() {
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-fable-5", configuredModel: "claude-fable-5[1m]"),
            1_000_000
        )
    }

    /// A marker with nothing left once it is stripped names no model at all,
    /// and containment against an empty string matches everything.
    func testABareMarkerInSettingsMatchesNothing() {
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-opus-5", configuredModel: "[1m]"),
            200_000
        )
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "", configuredModel: "opus[1m]"),
            200_000
        )
    }

    /// The backstop for a session whose selection Atelier cannot see — a
    /// `--model` flag or `ANTHROPIC_MODEL`. Past 200k the window provably is
    /// not the default one, so the meter must not sit pinned at 100%.
    func testUsageBeyondTheDefaultWindowProvesTheWindowIsLarger() {
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-opus-5", configuredModel: nil, usedTokens: 240_000),
            1_000_000
        )
        XCTAssertEqual(
            ContextLimits.limitTokens(transcriptModel: "claude-opus-5", configuredModel: nil, usedTokens: 199_000),
            200_000
        )
    }
}

final class ClaudeCodeSettingsTests: XCTestCase {
    private var home: URL!
    private var project: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atelier-settings-tests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        project = root.appendingPathComponent("project")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    private func configuredModel() -> String? {
        ClaudeCodeSettings.configuredModel(cwd: project.path, homeDirectory: home)
    }

    func testFallsBackToTheUserSettings() throws {
        try write(#"{"model":"opus[1m]"}"#, to: home.appendingPathComponent(".claude/settings.json"))
        XCTAssertEqual(configuredModel(), "opus[1m]")
    }

    func testProjectSettingsBeatUserSettings() throws {
        try write(#"{"model":"opus[1m]"}"#, to: home.appendingPathComponent(".claude/settings.json"))
        try write(#"{"model":"sonnet"}"#, to: project.appendingPathComponent(".claude/settings.json"))
        XCTAssertEqual(configuredModel(), "sonnet")
    }

    func testLocalProjectSettingsBeatCheckedInOnes() throws {
        try write(#"{"model":"sonnet"}"#, to: project.appendingPathComponent(".claude/settings.json"))
        try write(#"{"model":"haiku"}"#, to: project.appendingPathComponent(".claude/settings.local.json"))
        XCTAssertEqual(configuredModel(), "haiku")
    }

    /// A settings file with no `model` key is not an answer — resolution has to
    /// carry on to the next file rather than stopping at nil.
    func testAFileWithoutAModelKeyDoesNotEndTheSearch() throws {
        try write(#"{"effortLevel":"high"}"#, to: project.appendingPathComponent(".claude/settings.json"))
        try write(#"{"model":"opus[1m]"}"#, to: home.appendingPathComponent(".claude/settings.json"))
        XCTAssertEqual(configuredModel(), "opus[1m]")
    }

    func testMissingAndBrokenFilesResolveToNil() throws {
        XCTAssertNil(configuredModel())
        try write("{ not json", to: home.appendingPathComponent(".claude/settings.json"))
        XCTAssertNil(configuredModel())
    }

    func testNoCwdStillReadsTheUserSettings() throws {
        try write(#"{"model":"opus[1m]"}"#, to: home.appendingPathComponent(".claude/settings.json"))
        XCTAssertEqual(ClaudeCodeSettings.configuredModel(cwd: nil, homeDirectory: home), "opus[1m]")
    }
}
