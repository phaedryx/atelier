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

        static func pngURL(for workstreamID: UUID) -> URL {
            directory(for: workstreamID).appendingPathComponent("board.png")
        }

        static func digestURL(for workstreamID: UUID) -> URL {
            directory(for: workstreamID).appendingPathComponent("board.md")
        }

        /// Says that `board.png` was rendered from the scene currently on disk.
        ///
        /// **Its presence is the whole signal, and that is the design rather
        /// than a shortcut.** The obvious alternative, comparing modification
        /// times, cannot work here: the scene is always written first and the
        /// render always second, so the PNG is always the newer file whether it
        /// matches the scene or not. A content hash would work and costs a hash
        /// of the whole scene on every save and every read, to answer a question
        /// one file's existence already answers — `invalidateRender` deletes
        /// this the instant a new scene lands, and only a render that arrives
        /// *for that scene* puts it back.
        private static func stampURL(for workstreamID: UUID) -> URL {
            directory(for: workstreamID).appendingPathComponent("board.png.json")
        }

        /// Writes the render and stamps it as matching the scene on disk.
        static func writeRender(png: Data, width: Int, height: Int, for workstreamID: UUID) throws {
            try FileManager.default.createDirectory(
                at: directory(for: workstreamID),
                withIntermediateDirectories: true
            )
            try png.write(to: pngURL(for: workstreamID), options: .atomic)
            let stamp = try JSONSerialization.data(withJSONObject: ["width": width, "height": height])
            try stamp.write(to: stampURL(for: workstreamID), options: .atomic)
        }

        /// Marks whatever render exists as no longer describing the scene.
        ///
        /// The PNG is deliberately **kept**. A picture of the board a moment ago
        /// is nearly always still worth looking at; the thing that must never
        /// happen is an agent reading it as current, and that is what the stamp
        /// decides. Deleting instead would trade an accurate description of a
        /// slightly old picture for no picture at all.
        static func invalidateRender(for workstreamID: UUID) {
            try? FileManager.default.removeItem(at: stampURL(for: workstreamID))
        }

        static func renderState(for workstreamID: UUID) -> Whiteboard.Digest.Render {
            let png = pngURL(for: workstreamID)
            guard FileManager.default.fileExists(atPath: png.path) else { return .none }
            guard let data = try? Data(contentsOf: stampURL(for: workstreamID)),
                  let stamp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let width = stamp["width"] as? Int,
                  let height = stamp["height"] as? Int
            else {
                return .stale(path: png.path)
            }
            return .current(width: width, height: height, path: png.path)
        }

        /// Regenerates `board.md`.
        ///
        /// Called from **both** arms of the save path — when the scene lands and
        /// again when its render does — because the render line is part of the
        /// digest and the second arm is what makes it true. Two calls to one
        /// pure generator, rather than two generators that agree by convention.
        static func refreshDigest(for workstreamID: UUID) {
            let text = digestText(for: workstreamID, now: Date())
            do {
                try FileManager.default.createDirectory(
                    at: directory(for: workstreamID),
                    withIntermediateDirectories: true
                )
                try text.write(to: digestURL(for: workstreamID), atomically: true, encoding: .utf8)
            } catch {
                logger.error("Could not write board digest: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// The digest as of **now**, generated from the scene rather than read
        /// back from `board.md`.
        ///
        /// `read_whiteboard` calls this rather than reading the file, because
        /// two things in a digest are answers to "right now" and a file cannot
        /// hold either: how long ago the board was updated, and whether the
        /// render still matches it. `board.md` is a convenience copy for anyone
        /// reading the directory, not the source of the tool's answer.
        static func digestText(for workstreamID: UUID, now: Date) -> String {
            Whiteboard.Digest.text(
                load: Whiteboard.SceneLoad.load(for: workstreamID),
                render: renderState(for: workstreamID),
                updated: updatedText(for: workstreamID, now: now)
            )
        }

        private static func updatedText(for workstreamID: UUID, now: Date) -> String {
            guard let modified = try? FileManager.default
                .attributesOfItem(atPath: sceneURL(for: workstreamID).path)[.modificationDate] as? Date
            else { return "at an unknown time" }
            return IPC.durationText(max(0, now.timeIntervalSince(modified))) + " ago"
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
