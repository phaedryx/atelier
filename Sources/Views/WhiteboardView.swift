// ABOUTME: The Whiteboard tab — attaches the workstream's existing host.
// ABOUTME: Never creates one; the cache owns the board's life, not this view.

import AppKit
import SwiftUI

/// Attaches the workstream's whiteboard webview.
///
/// The same rule `VerificationSurfaceView` follows: this **attaches an existing
/// host and never creates one**. The board's life belongs to
/// `TerminalSurfaceCache`, because `ContentView` keys `TerminalContainerView`
/// `.id(workstreamID)` and this view is destroyed the moment the user navigates
/// away — while the board, and a save still sitting on its debounce, must not
/// be.
///
/// Teardown hands the webview back to the host's offscreen window, which is
/// what keeps it in a window at all: left in a container SwiftUI is releasing,
/// it ends up with no superview and no window. The park is **conditional on the
/// webview still being in this container**, which is what makes it safe to do
/// from teardown at all — SwiftUI does not order dismantling the outgoing view
/// against creating the incoming one, so an unconditional park could steal the
/// webview back out of a container that had just claimed it.
struct WhiteboardView: NSViewRepresentable {
    let host: Whiteboard.Host

    /// Carries the host into `dismantleNSView`, which is static and has no other
    /// way to reach it.
    final class Coordinator {
        let host: Whiteboard.Host

        init(host: Whiteboard.Host) {
            self.host = host
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(host: host)
    }

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        host.attach(to: container)
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.host.detachIfAttached(to: container)
    }
}
