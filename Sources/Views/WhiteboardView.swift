// ABOUTME: The Whiteboard tab — a capture button above the workstream's existing host.
// ABOUTME: Never creates a host; the cache owns the board's life, not this view.

import AppKit
import SwiftUI

/// The Whiteboard tab: the board, and the one thing the board cannot do for
/// itself.
///
/// The capture button lives here rather than inside the web app because
/// `screencapture` is a process, and the page has no way to run one. Everything
/// behind it — the spawn, naming the file, placing the image — belongs to
/// `Whiteboard.Host.captureToBoard`, so this view holds no part of the flow that
/// a second caller would have to reimplement.
struct WhiteboardTabView: View {
    let host: Whiteboard.Host

    /// Drives the button's `.disabled` only. `Host.isCapturing` is the real
    /// re-entry guard, and the two are deliberately not one.
    ///
    /// This looks like the view-owned run state this codebase has shipped twice
    /// (`runGeneration`, then `browserStartPending`), so it is worth saying why
    /// it is not. `Host` is not an `ObservableObject`, so SwiftUI cannot watch
    /// its flag; and the state that would matter if this view were destroyed
    /// mid-capture — whether a capture is in flight, and whether the image
    /// landed — lives on the host, which outlives the view. All this copy can
    /// lose is a button's disabled look, and only while the capture overlay
    /// owns the screen, which is exactly when the user cannot navigate away.
    @State private var isCapturing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    capture()
                } label: {
                    Label("Capture Screen", systemImage: "camera.viewfinder")
                }
                .disabled(isCapturing)
                .help("Capture a region of the screen onto this board")
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            // Deliberately NOT inside an `if`. `attach` and `detachIfAttached`
            // are keyed on container identity, so a conditional branch here
            // would remount the representable and thrash the webview between
            // this container and the offscreen window.
            WhiteboardSurfaceView(host: host)
        }
    }

    /// The button does nothing visible when the user cancels, which is the
    /// ordinary outcome of pressing Escape — there is nothing to report, and an
    /// alert saying "you cancelled" is worse than silence.
    ///
    /// This used to add that a capture refused for want of Screen Recording
    /// permission is reported by macOS in its own alert, naming the setting to
    /// change. `Whiteboard.Capture.run` explicitly retracts that claim as
    /// unmeasured — what was measured is that `screencapture` exits 1 and
    /// writes no file, not what the user sees — so the sentence is gone rather
    /// than restated here, where it would read as a second, independent
    /// observation of something nobody has observed.
    private func capture() {
        isCapturing = true
        Task {
            await host.captureToBoard()
            isCapturing = false
        }
    }
}

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
struct WhiteboardSurfaceView: NSViewRepresentable {
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
