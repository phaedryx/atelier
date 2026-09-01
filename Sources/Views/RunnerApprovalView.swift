// ABOUTME: Approval pane for a runner config the repository provides, e.g. process-compose.yaml.
// ABOUTME: Shows the file's contents, because that file is what will execute.

import SwiftUI

struct RunnerApprovalView: View {
    let filePath: String
    let command: String
    let onApprove: () -> Void

    /// How much of the config to show. Long enough to read a normal stack
    /// definition, short enough that the approve button stays on screen.
    private static let previewLineLimit = 60

    private var fileName: String {
        (filePath as NSString).lastPathComponent
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
                    "%@ defines processes that run on your machine under your user account. %@ starts them.",
                    comment: ""
                ),
                fileName,
                command
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

            Button(NSLocalizedString("Approve and Start", comment: ""), action: onApprove)
                .buttonStyle(.borderedProminent)

            Text("Approval covers this repository until the file changes.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
