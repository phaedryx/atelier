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

    /// Cleans a name and caps it at `limit` *characters*, not scalars.
    ///
    /// Counting graphemes matters at the boundary: cutting mid-cluster can
    /// strand a combining mark or a joiner that then attaches to whatever the
    /// template puts next, so a name can smear into the surrounding text.
    static func sanitized(_ raw: String, limit: Int, fallback: String) -> String {
        var result = ""
        for character in raw {
            var scalars = String.UnicodeScalarView()
            for scalar in character.unicodeScalars where !forbidden.contains(scalar) {
                // Any other flavour of space becomes a plain one. A no-break
                // space is harmless in a terminal but invisible in a roster, so
                // without this two peers can be given names that render
                // identically and an agent picking one out of `list_peers` has
                // nothing to go on.
                scalars.append(CharacterSet.whitespaces.contains(scalar) ? " " : scalar)
            }
            guard !scalars.isEmpty else { continue }

            result += String(scalars)
            if result.count >= limit {
                break
            }
        }

        let cleaned = result.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : cleaned
    }
}
