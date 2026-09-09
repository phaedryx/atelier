// ABOUTME: Shared path and UUID utilities used across the app.
// ABOUTME: Provides path abbreviation and deterministic UUID derivation.

import CryptoKit
import Foundation

/// Deterministic UUID derived from a base UUID and a salt string.
///
/// The same `(base, salt)` always yields the same UUID, and different inputs are
/// expected not to collide. That second half is the whole point — these are surface
/// identities, and two tabs sharing one would make the app address the wrong pane.
///
/// This used to fold input bytes with `bytes[i % 16] &+= byte &+ UInt8(i & 0xFF)`,
/// which is not a hash: swapping two characters exactly 16 apart lands both in the
/// same bucket with the same index contribution and produces an identical UUID, and
/// the `i & 0xFF` term makes positions *k* and *k + 256* indistinguishable. SHA-256
/// truncated to 16 bytes has neither property.
///
/// Tagged version 8 (RFC 9562, "custom") because that is what this is. The old code
/// stamped version 4 and called itself random in a comment, which it never was.
func derivedUUID(from base: UUID, salt: String) -> UUID {
    var hasher = SHA256()
    withUnsafeBytes(of: base.uuid) { hasher.update(bufferPointer: $0) }
    // A length-prefixed separator so ("ab", "c") and ("a", "bc") cannot hash alike.
    hasher.update(data: Data([0xFF]))
    hasher.update(data: Data(salt.utf8))

    var bytes = Array(hasher.finalize().prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x80 // version 8 — custom/deterministic
    bytes[8] = (bytes[8] & 0x3F) | 0x80 // variant 1 (RFC 4122/9562)
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                       bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11],
                       bytes[12], bytes[13], bytes[14], bytes[15]))
}

extension String: @retroactive Identifiable {
    public var id: String {
        self
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID {
        self
    }
}

extension String {
    /// Replaces the home directory prefix with ~ for compact display.
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if hasPrefix(home) {
            return "~" + dropFirst(home.count)
        }
        return self
    }

    /// This path with every symlink above it resolved, whether or not the path
    /// itself is on disk.
    ///
    /// `URL.resolvingSymlinksInPath()` is a no-op on a path that does not exist
    /// — verified on macOS 15 — so two spellings of one location canonicalize to
    /// two different strings the moment the leaf is missing. With `link` a
    /// symlink to `real/deep`:
    ///
    ///     <root>/link/nope       stays  <root>/link/nope
    ///     <root>/real/deep/nope  stays  <root>/real/deep/nope
    ///
    /// A guard that compares those two is then correct only by accident of what
    /// happens to be on disk. This resolves the deepest ancestor that *does*
    /// exist and re-appends the rest, so the answer turns on how the path is
    /// spelled rather than on whether its leaf is there.
    ///
    /// The input is deliberately not standardized first. Stripping `..`
    /// lexically before the prefix is symlink-free is the one part Foundation
    /// already gets right unaided — `link/..` resolves to the link's parent, not
    /// the link's *lexical* parent — and doing it early would throw that away.
    /// Standardization happens once at the end, by which point every symlink
    /// above the missing tail is gone.
    var canonicalPath: String {
        let fileManager = FileManager.default
        var missing: [String] = []
        var url = URL(fileURLWithPath: self)

        // `fileExists` follows symlinks, so a different spelling of a directory
        // that is present stops the walk immediately. The floor is "/", which
        // always exists, so this terminates; each turn costs one `stat`, and
        // only for a component that is not there.
        while !fileManager.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            missing.append(url.lastPathComponent)
            url = url.deletingLastPathComponent()
        }

        var resolved = url.resolvingSymlinksInPath()
        for component in missing.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    /// Whether this path sits strictly beneath `other` — compared canonically,
    /// so a trailing slash, a `.` segment, or a symlinked ancestor cannot defeat
    /// it. A path is **not** inside itself.
    ///
    /// Worth a name of its own because the separator is the whole of it: a bare
    /// `hasPrefix(other)` makes `/repo-backup` a child of `/repo`, and that is
    /// the shape a hand-rolled copy keeps arriving in.
    func isCanonicallyInside(_ other: String) -> Bool {
        canonicalPath.hasPrefix(other.canonicalPath + "/")
    }
}
