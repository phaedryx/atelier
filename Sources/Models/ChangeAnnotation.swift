// ABOUTME: Line-anchored review comments for the Changes view, owned per workstream.
// ABOUTME: Store is the single source of truth; the Monaco webview only renders pushes.

import Foundation

/// Which side of the diff a comment anchors to.
enum DiffSide: String {
    /// The base/HEAD side — a deleted line.
    case old
    /// The working side — an added or context line.
    case new
}

/// One review comment, anchored to a line (or range) of a file's diff.
struct ReviewComment: Identifiable, Equatable {
    let id: UUID
    let filePath: String // repo-relative, as in DiffFile.relativePath
    let mode: ChangesMode // the diff scope it was written in
    let side: DiffSide
    var line: Int // 1-based on `side`
    var endLine: Int? // nil = single line
    let lineText: String // trimmed anchor-line content, for re-anchoring
    var text: String // sanitized single line
    var isOrphaned: Bool = false
}

/// In-memory review comments for one workstream. Lives on WorkspaceModel so it
/// survives tab switches and webview reloads, and dies with the workstream.
@MainActor
final class ChangeAnnotationStore: ObservableObject {
    @Published private(set) var comments: [ReviewComment] = []

    func comments(mode: ChangesMode) -> [ReviewComment] {
        comments.filter { $0.mode == mode }
    }

    func comments(for filePath: String, mode: ChangesMode) -> [ReviewComment] {
        comments.filter { $0.filePath == filePath && $0.mode == mode }
    }

    @discardableResult
    func add(
        filePath: String,
        mode: ChangesMode,
        side: DiffSide,
        line: Int,
        endLine: Int?,
        lineText: String,
        text: String
    ) -> ReviewComment? {
        let sanitized = Self.sanitize(text)
        guard !sanitized.isEmpty else { return nil }
        let comment = ReviewComment(
            id: UUID(),
            filePath: filePath,
            mode: mode,
            side: side,
            line: line,
            endLine: endLine,
            lineText: Self.sanitize(lineText),
            text: sanitized
        )
        comments.append(comment)
        return comment
    }

    func updateText(id: UUID, text: String) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        let sanitized = Self.sanitize(text)
        guard !sanitized.isEmpty else { return }
        comments[index].text = sanitized
    }

    func delete(id: UUID) {
        comments.removeAll { $0.id == id }
    }

    func clear(mode: ChangesMode) {
        comments.removeAll { $0.mode == mode }
    }

    /// Re-anchor comments after the diff underneath them refreshed.
    ///
    /// - `texts`: per-path (original, modified) full file texts for files whose
    ///   content was loaded this refresh (normal files only — binary/deferred
    ///   files have no texts and their comments are left untouched).
    /// - `presentPaths`: every path in the refreshed diff, including binary and
    ///   deferred files. A comment whose file is absent is orphaned.
    func reanchor(
        mode: ChangesMode,
        texts: [String: (original: String, modified: String)],
        presentPaths: Set<String>
    ) {
        comments = comments.map { comment in
            guard comment.mode == mode else { return comment }
            var updated = comment

            guard presentPaths.contains(updated.filePath) else {
                updated.isOrphaned = true
                return updated
            }
            guard let fileTexts = texts[updated.filePath] else {
                return updated // deferred/binary: nothing to match against, leave as-is
            }

            let content = updated.side == .old ? fileTexts.original : fileTexts.modified
            let normalized = content.hasSuffix("\n") ? String(content.dropLast()) : content
            let lines = normalized.components(separatedBy: "\n")
                .map { Self.sanitize($0) }

            if updated.lineText.isEmpty {
                // A blank anchor matches everything; only an exact positional hold counts.
                let holds = updated.line >= 1 && updated.line <= lines.count && lines[updated.line - 1].isEmpty
                updated.isOrphaned = !holds
                return updated
            }

            if let newLine = Self.matchLine(anchor: updated.lineText, near: updated.line, in: lines) {
                let delta = newLine - updated.line
                updated.line = newLine
                if let end = updated.endLine { updated.endLine = end + delta }
                updated.isOrphaned = false
            } else {
                updated.isOrphaned = true
            }
            return updated
        }
    }

    /// Find `anchor` in `lines` (1-based result), nearest to `line` within
    /// ±`window`. Exact position wins; ties between equal distances resolve to
    /// the earlier line.
    nonisolated static func matchLine(
        anchor: String,
        near line: Int,
        in lines: [String],
        window: Int = 50
    ) -> Int? {
        func matches(_ candidate: Int) -> Bool {
            candidate >= 1 && candidate <= lines.count && lines[candidate - 1] == anchor
        }
        if matches(line) { return line }
        guard window >= 1 else { return nil }
        for distance in 1 ... window {
            if matches(line - distance) { return line - distance } // earlier wins ties
            if matches(line + distance) { return line + distance }
        }
        return nil
    }

    /// Single-line, terminal-safe text: tabs and newlines become spaces, all
    /// other C0/C1 controls and DEL are stripped, ends trimmed. This text is
    /// later pasted into a terminal, so control characters must never survive.
    nonisolated static func sanitize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\t", "\n":
                out.append(" ")
            case let s where s.value < 0x20 || s.value == 0x7F || (0x80 ... 0x9F).contains(s.value):
                continue
            default:
                out.append(scalar)
            }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }
}

/// Formats a set of review comments into the text block pasted into the agent's
/// terminal. Pure and nonisolated so it is trivially testable.
enum ChangeReviewFormatter {
    static func payload(
        comments: [ReviewComment],
        mode: ChangesMode,
        branch: String?,
        baseBranch: String?
    ) -> String {
        let scope = switch mode {
        case .uncommitted: "uncommitted changes"
        case .branch: "vs \(baseBranch ?? "base")"
        }

        var lines = ["[Code Review] \(branch ?? "worktree") (\(scope))"]
        let grouped = Dictionary(grouping: comments, by: \.filePath)
        for path in grouped.keys.sorted() {
            lines.append("")
            lines.append(path)
            let sorted = grouped[path]!.sorted { a, b in
                if a.line != b.line { return a.line < b.line }
                return (a.endLine ?? a.line) < (b.endLine ?? b.line)
            }
            for comment in sorted {
                lines.append("  \(label(for: comment)): \(comment.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func label(for comment: ReviewComment) -> String {
        let location = comment.endLine.map { "L\(comment.line)-L\($0)" } ?? "L\(comment.line)"
        if comment.isOrphaned {
            return "\(location) (orphaned, was: \"\(comment.lineText)\")"
        }
        return "\(location) (\(comment.side.rawValue))"
    }
}

/// A comment mutation reported by diff.js. Parsed from the WKScriptMessage body
/// as a pure function so the decoding is testable without a WebView.
enum ReviewCommentEvent: Equatable {
    case added(filePath: String, side: DiffSide, line: Int, endLine: Int?, lineText: String, text: String)
    case edited(id: UUID, text: String)
    case deleted(id: UUID)

    static func parse(_ body: [String: Any]) -> ReviewCommentEvent? {
        switch body["type"] as? String {
        case "commentAdded":
            guard let filePath = body["filePath"] as? String,
                  let sideRaw = body["side"] as? String,
                  let side = DiffSide(rawValue: sideRaw),
                  let line = body["line"] as? Int,
                  let text = body["text"] as? String
            else { return nil }
            return .added(
                filePath: filePath,
                side: side,
                line: line,
                endLine: body["endLine"] as? Int,
                lineText: body["lineText"] as? String ?? "",
                text: text
            )
        case "commentEdited":
            guard let idString = body["id"] as? String, let id = UUID(uuidString: idString),
                  let text = body["text"] as? String else { return nil }
            return .edited(id: id, text: text)
        case "commentDeleted":
            guard let idString = body["id"] as? String, let id = UUID(uuidString: idString) else { return nil }
            return .deleted(id: id)
        default:
            return nil
        }
    }
}
