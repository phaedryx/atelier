// ABOUTME: Reads a Shortcut story public id out of whatever the user typed.
// ABOUTME: Accepts a bare id, an sc- prefix, or a pasted story URL.

import Foundation

enum ShortcutStoryID {
    private static let urlMarker = "/story/"
    private static let prefix = "sc-"

    /// Returns the story id, or nil when the input is not one.
    ///
    /// Nil is the signal the dialog uses to reject input, so this must stay strict:
    /// an ordinary branch name like `release-2` has to come back nil rather than
    /// being coerced into an id.
    static func parse(_ input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if let marker = trimmed.range(of: urlMarker) {
            // A pasted URL usually carries a trailing slug: .../story/17411/some-title
            candidate = String(trimmed[marker.upperBound...].prefix { $0.isNumber })
        } else if trimmed.count > prefix.count, trimmed.prefix(prefix.count).lowercased() == prefix {
            candidate = String(trimmed.dropFirst(prefix.count))
        } else {
            candidate = trimmed
        }

        // Public ids are positive, so 0 and negatives are malformed input rather than ids.
        guard let id = Int(candidate), id > 0 else { return nil }
        return id
    }
}
