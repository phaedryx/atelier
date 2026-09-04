// ABOUTME: Handles atomic file writes for JSON persistence.
// ABOUTME: Writes to a temp file, fsyncs it, then renames — atomic and durable.

import Foundation

enum FilePersistence {
    /// Write data atomically to a file, creating parent directories if needed.
    ///
    /// The temp file is tightened to `0600` and flushed to disk *before* the
    /// rename, in that order, for two reasons:
    ///
    /// - Permissions after the rename left a window at whatever the umask gave
    ///   the temp file, and left the `catch` below trying to remove a path that
    ///   had already been renamed away.
    /// - Without the `fsync` the rename can be durable while the bytes it points
    ///   at are still only in the page cache. That is atomicity, not crash
    ///   safety, and this header used to promise the latter.
    ///
    /// `.usingNewMetadataOnly` is what makes the permissions stick: `replaceItemAt`
    /// otherwise carries the *original* file's metadata across, so replacing a
    /// file that was already group-readable would keep it that way.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tempURL.path
            )
            let handle = try FileHandle(forWritingTo: tempURL)
            try handle.synchronize()
            try handle.close()
            _ = try FileManager.default.replaceItemAt(
                url,
                withItemAt: tempURL,
                options: [.usingNewMetadataOnly]
            )
        } catch {
            // Clean up temp file on failure
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}
