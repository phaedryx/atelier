// ABOUTME: Captures a screen region with `screencapture -i` and names it the way Excalidraw would.
// ABOUTME: The third documented ProcessRunner exemption — see `run`.

import AppKit
import CryptoKit
import Foundation
import OSLog

private let logger = Logger(subsystem: AppConstants.appID, category: "whiteboard")

extension Whiteboard {
    /// Puts a region of the user's screen on the board.
    ///
    /// Three pieces, and only the middle one touches a process: run the system's
    /// own interactive capture, name the bytes the way Excalidraw names a pasted
    /// image, and work out how big to draw it.
    enum Capture {
        /// The longest edge a capture is drawn at on the board.
        ///
        /// A capture arrives at *pixel* size, which on a retina display is twice
        /// what the user selected — a screenshot of one settings pane lands 2800
        /// points wide and dwarfs every box on the board, leaving the user to
        /// zoom out to find their own diagram. Scaled down on placement rather
        /// than resampled: the file in `assets/` keeps every pixel it captured,
        /// so the image stays sharp when it is zoomed into and the agent reads
        /// the full-resolution original through `board.png`.
        static let maxOnBoardEdge: Double = 640

        /// The name this image's bytes get in `assets/`.
        ///
        /// **SHA-1 hex, because that is Excalidraw's own `fileId` convention.**
        /// The stem of a file in `assets/` *is* the `fileId` on its image
        /// element — `Store.assetPaths` joins on the equality and
        /// `Host.assetManifestScript` rebuilds the page's files map from it —
        /// so a captured image and a pasted one have to be named by one rule or
        /// the join quietly has two. Two consequences, both wanted: capturing
        /// the same region twice writes one file, and `Store.writeAsset` never
        /// has to refuse a name this produced.
        ///
        /// Not a security claim, and SHA-1's weakness is not one here: this
        /// names local bytes for local lookup and nothing is authenticated by
        /// it.
        static func fileID(for data: Data) -> String {
            Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        /// How big to draw those bytes, or nil if they are not an image.
        ///
        /// Nil rather than a guessed default: an element placed at a size
        /// nothing measured is one the digest describes and the picture does not
        /// show, which is the disagreement this feature is organized around.
        static func onBoardSize(of data: Data) -> (width: Double, height: Double)? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
                  let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                  let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
                  pixelWidth > 0, pixelHeight > 0
            else { return nil }
            let longest = max(pixelWidth, pixelHeight)
            guard longest > maxOnBoardEdge else { return (pixelWidth, pixelHeight) }
            let scale = maxOnBoardEdge / longest
            return (pixelWidth * scale, pixelHeight * scale)
        }

        /// Runs the system's interactive capture and answers with the PNG bytes,
        /// or nil if the user cancelled.
        ///
        /// **Deliberately not `ProcessRunner`, and this is the third exemption.**
        /// It has the same two properties the other two state at their own spawn
        /// sites (`BareRepoClone.run`, `QuickAction.Runner.runShellCommand`):
        ///
        /// 1. **No honest deadline.** The child blocks until the user drags a
        ///    selection or presses Escape, which is unbounded human time. Every
        ///    tier in `ProcessRunner.Timeout` is sized for work whose duration
        ///    something other than a person decides.
        /// 2. **A cancel the user drives**, and here it is *in band*. The capture
        ///    overlay owns the screen while it is up, so there is no Atelier
        ///    button left to press — Escape, in the system's own UI, is the
        ///    cancel, and it is the child's own rather than one this app had to
        ///    provide.
        ///
        /// A third fact makes the exemption cheap rather than a concession:
        /// there is nothing to drain. `screencapture` writes to a file and
        /// prints nothing, so `ProcessRunner`'s pipe pump would buy none of its
        /// value while costing a blocked thread for the length of a human
        /// gesture — precisely the corollary that design states for callers.
        /// `terminationHandler` blocks nothing.
        ///
        /// **Cancelling is not an error.** A non-zero exit, or an exit that
        /// wrote no file, is the user deciding not to capture after all, and is
        /// answered with nil so the caller can do nothing quietly. That also
        /// covers the case where macOS refuses for want of Screen Recording
        /// permission, which it reports itself, in its own alert, naming the
        /// setting to change — a second alert from Atelier would say less.
        static func run() async -> Data? {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("atelier-capture-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: destination) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // `-i` interactive, `-o` to leave out a captured window's drop
            // shadow, which is transparent margin nobody wants on a board.
            process.arguments = ["-i", "-o", destination.path]

            let exited: Bool = await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume(returning: true) }
                do {
                    try process.run()
                } catch {
                    logger.error("Could not start screencapture: \(error.localizedDescription, privacy: .public)")
                    process.terminationHandler = nil
                    continuation.resume(returning: false)
                }
            }
            guard exited, process.terminationStatus == 0 else { return nil }
            // Escape leaves a zero exit on some releases and simply writes
            // nothing, so the file is the signal rather than the status.
            return try? Data(contentsOf: destination)
        }
    }
}
