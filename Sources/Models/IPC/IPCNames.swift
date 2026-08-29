// ABOUTME: Sanitizes agent-supplied peer names and roles.
// ABOUTME: These strings are typed into other agents' terminals, so they are not free text.

import Foundation

/// Cleans the identifiers one agent chooses and another agent sees.
///
/// `register_peer` takes a name from the calling agent, and the terminal nudge
/// types that name into a *different* agent's pane, followed by synthetic
/// Returns. Unfiltered, that is an injection channel: a newline splits the
/// notice into two submitted lines, `ESC` opens an escape sequence, and `\u{3}`
/// is Ctrl-C to whatever holds the foreground. None of it is legitimate in a
/// handle, so it is stripped where the value enters the system.
enum IPCNames {
    private static let forbidden: CharacterSet = {
        var set = CharacterSet.controlCharacters
        set.formUnion(.newlines)
        set.formUnion(.illegalCharacters)
        return set
    }()

    static func sanitized(_ raw: String, limit: Int, fallback: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where !forbidden.contains(scalar) {
            // Any other flavour of space becomes a plain one. A no-break space
            // is harmless in a terminal but invisible in a roster, so without
            // this two peers can be given names that render identically and an
            // agent picking one out of `list_peers` has nothing to go on.
            scalars.append(CharacterSet.whitespaces.contains(scalar) ? " " : scalar)
            if scalars.count >= limit { break }
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : cleaned
    }
}
