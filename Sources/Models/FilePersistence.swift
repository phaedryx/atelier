// ABOUTME: Handles atomic file writes for JSON persistence.
// ABOUTME: Writes a temp file, flushes it, renames, then flushes the directory.

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
    ///   safety, and this file used to promise the latter. The directory is
    ///   flushed after the rename for the other half of the same reason.
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
            // The file's own fsync covers its contents, not the directory entry
            // the rename created. Both halves are needed for the rename to be
            // there after a crash.
            syncDirectory(directory)
        } catch {
            // Clean up temp file on failure
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// fsync a directory. `FileHandle` will not open one, so this goes through
    /// `open(2)` directly. Best-effort: the write has already landed, and a
    /// failure here costs durability rather than correctness.
    private static func syncDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fsync(descriptor)
    }
}
