// ABOUTME: Approval pane for a process-compose config the repository provides.
// ABOUTME: Shows the file's contents, because that file is what will execute.

import SwiftUI

/// Asks the user to approve the unattended phases of a config that arrived with
/// the repository — `bootstrap` at worktree creation and `dispose` at archive,
/// neither of which the user is present for.
///
/// `execute` is deliberately not covered: it is a deliberate press on a command
/// the Environment pane is already displaying, so gating it would ask about a
/// file the user has just chosen to run.
struct ConfigApprovalView: View {
    let filePath: String
    let onApprove: () -> Void
    let onCancel: () -> Void

    /// How much of the config to show. Long enough to read a normal stack
    /// definition, short enough that the approve button stays on screen.
    private static let previewLineLimit = 60

    private var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    /// A file with no fingerprint cannot be approved — `ScriptTrust.approve`
    /// would silently do nothing — so the button is disabled rather than left as
    /// one that never takes effect. The preview says why.
    private var isReadable: Bool {
        ScriptTrust.fingerprint(configFile: filePath) != nil
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 30))
                .foregroundStyle(.orange)

            Text("Approve this repository's process config?")
                .font(.system(size: 15, weight: .semibold))

            Text(String(
                format: NSLocalizedString(
                    "%@ came with this repository. Its bootstrap phase runs automatically when a workstream is created, and its dispose phase when one is archived — both without asking. They run on your machine under your user account.",
                    comment: ""
                ),
                fileName
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)

            ScrollView {
                Text(preview)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: 460, maxHeight: 260)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 10) {
                Button(NSLocalizedString("Not Now", comment: ""), action: onCancel)
                Button(NSLocalizedString("Approve and Run Bootstrap", comment: ""), action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isReadable)
            }

            Text("Approval covers this repository until the file changes. Start is never gated by it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 520)
    }

    /// The config's text, truncated. An unreadable file shows as such rather
    /// than as an empty box: approving something you cannot see is the one
    /// outcome this pane exists to prevent.
    private var preview: String {
        guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return NSLocalizedString("Could not read this file.", comment: "")
        }
        let lines = contents.components(separatedBy: .newlines)
        guard lines.count > Self.previewLineLimit else { return contents }
        return lines.prefix(Self.previewLineLimit).joined(separator: "\n")
            + "\n…\n"
            + String(
                format: NSLocalizedString("(%d more lines)", comment: ""),
                lines.count - Self.previewLineLimit
            )
    }
}
