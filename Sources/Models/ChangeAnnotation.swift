// ABOUTME: Line-anchored review comments for the Changes view, owned per workstream.
// ABOUTME: Store is the single source of truth; the Monaco webview only renders pushes.

import Foundation

/// Which side of the diff a comment anchors to.
enum DiffSide: String, Sendable {
    /// The base/HEAD side — a deleted line.
    case old
    /// The working side — an added or context line.
    case new
}

/// One review comment, anchored to a line (or range) of a file's diff.
struct ReviewComment: Identifiable, Equatable, Sendable {
    let id: UUID
    let filePath: String      // repo-relative, as in DiffFile.relativePath
    let mode: ChangesMode     // the diff scope it was written in
    let side: DiffSide
    var line: Int             // 1-based on `side`
    var endLine: Int?         // nil = single line
    let lineText: String      // trimmed anchor-line content, for re-anchoring
    var text: String          // sanitized single line
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
            lineText: lineText.trimmingCharacters(in: .whitespaces),
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
        let scope: String
        switch mode {
        case .uncommitted: scope = "uncommitted changes"
        case .branch: scope = "vs \(baseBranch ?? "base")"
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
