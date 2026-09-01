// ABOUTME: Presentation for GitHubPR status, check rollup, and review decision.
// ABOUTME: Shared so the two PR badges and the Info tab cannot drift apart on color or wording.

import SwiftUI

extension GitHubPR.Status {
    var color: Color {
        switch self {
        // Draft is deliberately not green: its whole point is that it is not ready, and the
        // badge previously rendered it identically to an open PR.
        case .draft: .secondary
        case .open: .green
        case .merged: .purple
        case .closed: .red
        }
    }

    var symbolName: String {
        switch self {
        case .draft, .open: "arrow.triangle.pull"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .draft: "Draft"
        case .open: "Open"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}

extension GitHubPR.ChecksRollup {
    var color: Color {
        switch self {
        case .none: .secondary
        case .pending: .orange
        case .passing: .green
        case .failing: .red
        }
    }

    var symbolName: String {
        switch self {
        case .none: "minus.circle"
        case .pending: "clock"
        case .passing: "checkmark.circle.fill"
        case .failing: "xmark.circle.fill"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .none: "No checks"
        case .pending: "Running"
        case .passing: "Passing"
        case .failing: "Failing"
        }
    }
}

/// How a `reviewDecision` string renders.
///
/// Kept as a lookup on the raw gh value rather than a decoded enum: an unfamiliar decision
/// should show through as-is rather than being swallowed by a `default` case.
enum GitHubReviewDecision {
    static func label(_ decision: String) -> String {
        switch decision.uppercased() {
        case "APPROVED":
            NSLocalizedString("Approved", comment: "PR review decision")
        case "CHANGES_REQUESTED":
            NSLocalizedString("Changes requested", comment: "PR review decision")
        case "REVIEW_REQUIRED":
            NSLocalizedString("Review required", comment: "PR review decision")
        default:
            decision.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func color(_ decision: String) -> Color {
        switch decision.uppercased() {
        case "APPROVED": .green
        case "CHANGES_REQUESTED": .red
        default: .secondary
        }
    }

    static func symbolName(_ decision: String) -> String {
        switch decision.uppercased() {
        case "APPROVED": "checkmark.seal.fill"
        case "CHANGES_REQUESTED": "exclamationmark.bubble.fill"
        default: "eye"
        }
    }
}
