// ABOUTME: The whiteboard namespace and its on-disk store.
// ABOUTME: One board per workstream, in the cache directory, swept when it ends.

import Foundation
import OSLog

private let logger = Logger(subsystem: AppConstants.appID, category: "whiteboard")

/// The whiteboard's namespace. Declared here because the store owns most of it;
/// `Whiteboard.Host` and `Whiteboard.AssetSchemeHandler` extend it.
enum Whiteboard {}

extension Whiteboard {
    /// Where one workstream's board lives.
    ///
    /// `~/Library/Caches/atelier/whiteboard/<workstream-id>/`, beside where
    /// `IPC.Config` already writes. Deliberately **not** in the worktree: a
    /// board file there would show up in `git status` and in the Changes tab,
    /// which is noise on every diff the user reads — and pasted screenshots
    /// would make it a repository-shaped problem, with `.gitignore` being the
    /// repository's file rather than Atelier's to edit on a user's behalf.
    /// Rejected in full in `tad/why-nots/whiteboard-file-in-the-worktree.md`.
    /// The cache directory is Atelier's existing convention for per-workstream
    /// transient state, it is swept when a workstream ends, and it survives a
    /// reboot (which a literal `/tmp` would not).
    ///
    /// **Swift never edits a scene.** The web app is the sole writer of
    /// `board.excalidraw`; this type persists what the page hands over and reads
    /// it back. That one rule is what keeps the feature from becoming a sync
    /// engine with a conflict story, and it is why there is no merge, no diff
    /// and no element model here.
    enum Store {
        static func directory(for workstreamID: UUID) -> URL {
            AppConstants.cacheDirectory
                .appendingPathComponent("whiteboard")
                .appendingPathComponent(workstreamID.uuidString.lowercased())
        }

        static func assetsDirectory(for workstreamID: UUID) -> URL {
            directory(for: workstreamID).appendingPathComponent("assets")
        }

        static func sceneURL(for workstreamID: UUID) -> URL {
            directory(for: workstreamID).appendingPathComponent("board.excalidraw")
        }

        /// The saved scene, or nil for a board nobody has drawn on.
        ///
        /// Nil means *empty*, never *broken*: an empty board is the first state
        /// every workstream is in, and rendering it as a failure would send the
        /// user looking for a problem that is not there. That is the distinction
        /// `Verification.Config.Load` draws between "declares no checks" and
        /// "could not be read", and it exists because the two send a reader to
        /// completely different places.
        ///
        /// A scene that exists but cannot be read is logged and also returns
        /// nil, so the page starts empty rather than refusing to mount — an
        /// empty canvas the user can draw on beats a blank pane — and the next
        /// save replaces it.
        static func loadScene(for workstreamID: UUID) -> String? {
            let url = sceneURL(for: workstreamID)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                return try String(contentsOf: url, encoding: .utf8)
            } catch {
                logger.error("Unreadable board scene at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        static func saveScene(_ json: String, for workstreamID: UUID) throws {
            try FileManager.default.createDirectory(
                at: directory(for: workstreamID),
                withIntermediateDirectories: true
            )
            try json.write(to: sceneURL(for: workstreamID), atomically: true, encoding: .utf8)
        }

        /// Writes one image into `assets/` and returns where it landed.
        ///
        /// Image bytes never go in the scene file — the same separation
        /// Excalidraw's own `files` map makes, and the thing that keeps a later
        /// text digest from silently blowing an agent's context.
        ///
        /// `id` and `ext` come from the page, so they are checked rather than
        /// trusted: a file id carrying `../` would otherwise write outside the
        /// board entirely.
        ///
        /// **Refused rather than sanitized, and that is the whole point.** The
        /// file name *is* the identity — `Host` lists this directory into a
        /// manifest and the page rebuilds `files[id]` from each name's stem, so
        /// the stem has to equal the `fileId` on the image element. Silently
        /// rewriting an unsafe id into a safe one would break that equality and
        /// the image would come back missing, with nothing logged and nothing to
        /// look at: the exact failure shape this feature has already produced
        /// twice. A refusal loses the same image and says so.
        ///
        /// Nothing Excalidraw generates can hit it: a `fileId` is a SHA-1 digest
        /// rendered as lowercase hex.
        @discardableResult
        static func writeAsset(
            _ data: Data,
            id: String,
            ext: String,
            for workstreamID: UUID
        ) throws -> URL {
            guard isSafeComponent(id), isSafeComponent(ext) else {
                logger.error("Refusing a board asset whose name would not round-trip: \(id, privacy: .public).\(ext, privacy: .public)")
                throw AssetError.unsafeName
            }
            let dir = assetsDirectory(for: workstreamID)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(id).\(ext)")
            try data.write(to: url, options: .atomic)
            return url
        }

        /// Removes the whole board.
        ///
        /// Called from **both** archive paths, the way
        /// `Verification.Runner.forget` is. A no-op for a workstream whose board
        /// was never opened, which is the common case rather than an edge case.
        static func sweep(for workstreamID: UUID) {
            let dir = directory(for: workstreamID)
            guard FileManager.default.fileExists(atPath: dir.path) else { return }
            do {
                try FileManager.default.removeItem(at: dir)
            } catch {
                logger.error("Could not sweep board \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        enum AssetError: Error {
            case unsafeName
        }

        /// Whether a string is usable as one path component, unchanged.
        ///
        /// A whitelist rather than a blocklist: the input is a file id chosen by
        /// the page, and enumerating what to strip is how a traversal eventually
        /// gets through. ASCII-only, because `isLetter` is true for characters
        /// that are not safe in a file name.
        static func isSafeComponent(_ raw: String) -> Bool {
            !raw.isEmpty
                && raw.count <= 128
                && raw.allSatisfy { c in
                    c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
                }
        }
    }
}
