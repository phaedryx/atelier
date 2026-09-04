// ABOUTME: Approval pane for the process-compose files a repository provides.
// ABOUTME: Shows every file that will execute, in full, because that is what is approved.

import SwiftUI

/// Asks the user to approve the unattended phases of the files that arrived with
/// the repository — `bootstrap` at worktree creation and `dispose` at archive,
/// neither of which the user is present for.
///
/// Takes a *list*, never one file. process-compose loads a base config and
/// whatever override sits beside it, and a pane that displayed only the base
/// would show a benign file while an unseen sibling ran. The list is
/// `ProcessCompose.Config.repositoryProvidedFiles`, and it is exactly what
/// `ScriptTrust` fingerprints, so what is shown and what is approved cannot
/// drift apart.
///
/// `execute` is deliberately not covered: it is attended. The user presses
/// Start, its output arrives in a terminal surface in front of them, and Stop is
/// one click away — so gating it would ask about a file the user has just chosen
/// to run. What makes the difference is attendance, not display; the Environment
/// pane does not show the command Start runs, and never did.
struct ConfigApprovalView: View {
    /// The repository-provided files, in the order they are fingerprinted.
    let filePaths: [String]
    let onApprove: () -> Void
    let onCancel: () -> Void

    /// One file, read once. Both this and `isReadable` used to be computed from
    /// `body`: the fingerprint hashed every file and the preview did a synchronous
    /// `String(contentsOfFile:)` per file, on every re-render of a security
    /// dialog. Read on appear instead — the set of files does not change while
    /// the pane is up, and if it did, `.onChange` reloads.
    private struct LoadedFile: Identifiable {
        var id: String {
            path
        }

        let path: String
        let text: String
    }

    @State private var loadedFiles: [LoadedFile] = []

    /// A file with no fingerprint cannot be approved — `ScriptTrust.approve`
    /// would silently do nothing — so the button is disabled rather than left as
    /// one that never takes effect. The previews say which file is unreadable.
    @State private var isReadable = false

    private var fileNames: String {
        filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
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
                fileNames
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)

            // Every file, in full. Truncating the preview would leave a payload
            // below the cut unreachable but still covered by the button, and
            // this is a gate on unattended execution: nobody will be watching
            // when these processes run.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(loadedFiles) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            Text((file.path as NSString).lastPathComponent)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Text(file.path)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                            Text(file.text)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: 520, minHeight: 240)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 10) {
                Button(NSLocalizedString("Not Now", comment: ""), action: onCancel)
                Button(NSLocalizedString("Approve and Run Bootstrap", comment: ""), action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isReadable)
            }

            Text("Approval covers this repository until any of these files changes. Start is never gated by it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(24)
        .frame(minWidth: 580, minHeight: 560)
        .onAppear(perform: load)
        .onChange(of: filePaths) { load() }
    }

    private func load() {
        loadedFiles = filePaths.map { LoadedFile(path: $0, text: contents(of: $0)) }
        isReadable = ScriptTrust.fingerprint(configFiles: filePaths) != nil
    }

    /// One file's whole text. An unreadable file shows as such rather than as an
    /// empty box: approving something you cannot see is the one outcome this
    /// pane exists to prevent.
    private func contents(of path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8))
            ?? NSLocalizedString("Could not read this file.", comment: "")
    }
}
