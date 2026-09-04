// ABOUTME: Extracts context-window usage from harness transcripts.
// ABOUTME: Claude Code transcripts are append-only JSONL; only the file tail is read.

import Foundation

enum TranscriptContextReader {
    /// Usage lines are appended to the transcript as turns progress, so the
    /// newest assistant entry is always near the end. Parsing only the last
    /// ~256KB keeps huge sessions cheap to poll.
    private static let tailByteCount = 256 * 1024

    /// Reads the tail of a Claude Code transcript and extracts context usage.
    /// Returns nil when the file is missing, unreadable, or has no usable line.
    static func usage(transcriptPath: String) -> (usedTokens: Int, limitTokens: Int)? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let start = size > UInt64(tailByteCount) ? size - UInt64(tailByteCount) : 0
            try handle.seek(toOffset: start)

            // `read(upToCount:)` is one read(2) and may come back short, so keep
            // asking until the file dries up.
            var data = Data()
            while data.count < tailByteCount,
                  let chunk = try handle.read(upToCount: tailByteCount - data.count),
                  !chunk.isEmpty
            {
                data.append(chunk)
            }

            // The seek lands on an arbitrary byte, which is mid-codepoint the
            // moment the tail carries an emoji or a box-drawing character — and
            // `String(data:encoding:.utf8)` then returns nil for the *whole*
            // window rather than for the broken prefix, so the meter showed
            // nothing at all. The content is JSONL, so a partial first line is
            // unusable anyway: skip to the first newline.
            if start > 0 {
                guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
                data = data[data.index(after: newline)...]
            }

            guard let contents = String(data: data, encoding: .utf8) else { return nil }
            return usage(contents: contents)
        } catch {
            return nil
        }
    }

    /// Pure variant over JSONL contents: finds the LAST assistant line carrying
    /// `message.usage` and sums its input-side token counts (missing → 0).
    /// Malformed lines are skipped; never throws. Returns nil when no usable line.
    static func usage(contents: String) -> (usedTokens: Int, limitTokens: Int)? {
        var latest: (usedTokens: Int, limitTokens: Int)?
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let usageDict = message["usage"] as? [String: Any]
            else { continue }
            let used = int(usageDict, "input_tokens")
                + int(usageDict, "cache_creation_input_tokens")
                + int(usageDict, "cache_read_input_tokens")
            latest = (used, ContextLimits.limitTokens(forModel: message["model"] as? String))
        }
        return latest
    }

    private static func int(_ dict: [String: Any], _ key: String) -> Int {
        (dict[key] as? Int) ?? 0
    }
}
