// ABOUTME: Banner over the Coding Agent tab for a tool permission the agent is blocked on.
// ABOUTME: Non-modal and per-workstream, so two agents asking at once do not fight over one dialog.

import SwiftUI

/// Watches the approval store for one workstream and draws the banner when that
/// workstream has something waiting.
///
/// Split from `TerminalContainerView` so the observation lives here: the store
/// publishes on every request and every answer, and the workspace view is far
/// too large to re-render for that.
struct PermissionRequestBannerHost: View {
    let workstreamID: UUID
    /// The surface this tab is showing, so the banner can say when the request
    /// came from a *different* pane in the same workstream.
    let agentSurfaceID: UUID?

    @ObservedObject private var store = PermissionApprovalStore.shared

    var body: some View {
        if let request = store.frontmost(for: workstreamID) {
            PermissionRequestBanner(
                request: request,
                queued: store.count(for: workstreamID) - 1,
                isFromAnotherPane: request.surfaceID != nil && request.surfaceID != agentSurfaceID,
                onAllow: { store.answer(request.id, with: .allow) },
                onDeny: { store.answer(request.id, with: .deny) }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(request.id)
        }
    }
}

struct PermissionRequestBanner: View {
    let request: PendingPermission
    /// How many more are behind this one.
    let queued: Int
    let isFromAnotherPane: Bool
    let onAllow: () -> Void
    let onDeny: () -> Void

    /// Drives the countdown only. The deadline itself is the store's timer —
    /// this view showing a stale number would be a cosmetic bug, whereas this
    /// view *owning* the deadline would mean a request going unanswered whenever
    /// the tab is not on screen.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var remaining: TimeInterval {
        max(0, request.expiresAt.timeIntervalSince(now))
    }

    private var countdown: String {
        let seconds = Int(remaining.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                Text(String(
                    format: NSLocalizedString("Claude wants to run %@", comment: "Permission request headline; %@ is a tool name"),
                    request.toolName
                ))
                .font(.system(size: 13, weight: .semibold))

                if isFromAnotherPane {
                    Text("from another pane")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if queued > 0 {
                    Text(String(format: NSLocalizedString("+%d waiting", comment: "More permission requests queued behind this one"), queued))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let detail = request.detail {
                // Scrolls rather than truncates. What is being approved is the
                // thing in this box, and a command whose tail is cut off is a
                // command that was approved unread.
                ScrollView(.vertical) {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 84)
            }

            HStack(spacing: 8) {
                // No keyboard shortcuts, deliberately. This sits directly above a
                // focused terminal, and binding Return or Escape here would take
                // those keys away from the agent's own prompt.
                Button(action: onAllow) {
                    Text("Allow")
                }
                .buttonStyle(.borderedProminent)

                Button(action: onDeny) {
                    Text("Deny")
                }
                .buttonStyle(.bordered)

                Spacer()

                Text(String(
                    format: NSLocalizedString("Claude Code asks in %@", comment: "Countdown to the app releasing a held permission request"),
                    countdown
                ))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .help(Text("If nobody answers here, Atelier stops holding the agent and Claude Code shows its own prompt in the terminal."))
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onReceive(tick) { now = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(
            format: NSLocalizedString("Permission requested for %@", comment: "Accessibility label for the permission banner"),
            request.toolName
        )))
    }
}
