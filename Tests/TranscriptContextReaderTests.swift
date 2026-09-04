// ABOUTME: Tests for transcript context-usage parsing and model-based
// ABOUTME: context limit lookup.

@testable import Atelier
import XCTest

final class TranscriptContextReaderTests: XCTestCase {
    private let userLine = #"{"type":"user","message":{"role":"user","content":"hello"}}"#
    private let sonnetLine =
        #"{"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":4,"cache_creation_input_tokens":123,"cache_read_input_tokens":45000,"output_tokens":99}}}"#
    private let opusOneMLine =
        #"{"type":"assistant","message":{"model":"claude-opus-4-1[1m]","usage":{"input_tokens":10,"cache_read_input_tokens":2000000}}}"#

    // MARK: - JSONL parsing

    func testSumsInputAndCacheFields() {
        let usage = TranscriptContextReader.usage(contents: sonnetLine)
        XCTAssertEqual(usage?.usedTokens, 4 + 123 + 45000)
        XCTAssertEqual(usage?.limitTokens, 200_000)
    }

    func testLastAssistantEntryWins() {
        let contents = [userLine, sonnetLine, "not json at all", opusOneMLine].joined(separator: "\n")
        let usage = TranscriptContextReader.usage(contents: contents)
        XCTAssertEqual(usage?.usedTokens, 10 + 2_000_000)
        XCTAssertEqual(usage?.limitTokens, 1_000_000)
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

    func testLimitComesFromEntryModel() {
        let usage = TranscriptContextReader.usage(contents: opusOneMLine)
        XCTAssertEqual(usage?.limitTokens, 1_000_000)
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
    func testDefaultLimitIs200k() {
        XCTAssertEqual(ContextLimits.limitTokens(forModel: nil), 200_000)
        XCTAssertEqual(ContextLimits.limitTokens(forModel: ""), 200_000)
        XCTAssertEqual(ContextLimits.limitTokens(forModel: "claude-sonnet-4-5"), 200_000)
    }

    func testExtendedMarkersYieldOneMillion() {
        XCTAssertEqual(ContextLimits.limitTokens(forModel: "claude-sonnet-4-5[1m]"), 1_000_000)
        XCTAssertEqual(ContextLimits.limitTokens(forModel: "claude-sonnet-4-5-1m"), 1_000_000)
    }

    func testMarkerMatchIsCaseInsensitive() {
        XCTAssertEqual(ContextLimits.limitTokens(forModel: "claude-sonnet-4-5[1M]"), 1_000_000)
        XCTAssertEqual(ContextLimits.limitTokens(forModel: "CLAUDE-SONNET-4-5-1M"), 1_000_000)
    }
}
