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
/// There is deliberately no `dismantleNSView` parking. `Host.attach` re-parents
/// and the host parks itself when nothing else has claimed the webview, so
/// parking from here would fight a tab switch that is already in flight.
struct WhiteboardView: NSViewRepresentable {
    let host: Whiteboard.Host

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        host.attach(to: container)
    }
}
