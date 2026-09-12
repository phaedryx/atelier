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
/// to run. What makes the difference is attendance, not display; the Execution
/// pane does not show the command Start runs, and never did.
struct ConfigApprovalView: View {
    /// The repository-provided files, in the order they are fingerprinted.
    let filePaths: [String]
    /// Hands over the fingerprint of the bytes this pane *displayed*, and
    /// answers whether the approval took. False means the files on disk are no
    /// longer the ones on screen — see `approve()`.
    let onApprove: (String) -> Bool
    let onCancel: () -> Void

    /// One file, read once. Both this and `reviewedFingerprint` used to be
    /// computed from `body`: the fingerprint hashed every file and the preview did
    /// a synchronous `String(contentsOfFile:)` per file, on every re-render of a
    /// security dialog. Read on appear instead — and the one read is now the
    /// point, not just the saving: it is the same bytes that are displayed and
    /// fingerprinted. If the set of files changes while the pane is up,
    /// `.onChange` reloads.
    private struct LoadedFile: Identifiable {
        var id: String {
            path
        }

        let path: String
        /// The bytes, kept rather than re-read: they are what the fingerprint
        /// Approve offers is computed from. Nil for a file that cannot be read.
        let data: Data?

        /// Rendered lossily on purpose. Bytes that are not valid UTF-8 are still
        /// the bytes that will run, and refusing to show them would leave the
        /// project's bootstrap unapprovable with no way back. The gate needs the
        /// bytes hashed to be the bytes shown, which holds however they render.
        var text: String {
            guard let data else {
                return NSLocalizedString("Could not read this file.", comment: "")
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    @State private var loadedFiles: [LoadedFile] = []

    /// The fingerprint of what is on screen — what Approve offers, and nil when
    /// any file could not be read. A file with no fingerprint cannot be approved
    /// so the button is disabled rather than left as one that never takes
    /// effect; the previews say which file is unreadable.
    ///
    /// This is the whole of the fix for approving a file nobody saw: the value
    /// handed to `onApprove` is computed from the bytes displayed, never from a
    /// second read at click time. The pane can sit open for minutes and the
    /// coding agent writes in this same worktree.
    @State private var reviewedFingerprint: String?

    /// Set when Approve was refused because the files changed while the pane was
    /// open. Deliberately not cleared by `load()`, which runs immediately after:
    /// the reload is what replaces the content, and the user has to be told that
    /// is why their click did nothing.
    @State private var changedWhileOpen = false

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

            if changedWhileOpen {
                Text("These files changed while you were reviewing them, so nothing was approved. What is shown above is what is on disk now — review it and approve again.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 10) {
                Button(NSLocalizedString("Not Now", comment: ""), action: onCancel)
                Button(NSLocalizedString("Approve and Run Bootstrap", comment: ""), action: approve)
                    .buttonStyle(.borderedProminent)
                    .disabled(reviewedFingerprint == nil)
            }

            Text("Approval covers this repository until any of these files changes. Start is never gated by it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(24)
        .frame(minWidth: 580, minHeight: 560)
        // The warning is about the press that was just refused, so a pane
        // presented afresh must not open carrying it. SwiftUI discards this
        // view's state when the sheet is dismissed, so this is belt and braces
        // rather than a fix — but a stale warning would accuse the repository
        // of a change it did not make.
        .onAppear {
            changedWhileOpen = false
            load()
        }
        .onChange(of: filePaths) { load() }
    }

    /// Offers the reviewed fingerprint, and on a refusal shows what is on disk
    /// now instead of approving it. Approving the current contents on the user's
    /// behalf is the bug: they clicked about the file they had read.
    private func approve() {
        guard let reviewedFingerprint else { return }
        guard !onApprove(reviewedFingerprint) else { return }
        changedWhileOpen = true
        load()
    }

    private func load() {
        let files = filePaths.map {
            LoadedFile(path: $0, data: FileManager.default.contents(atPath: $0))
        }
        loadedFiles = files

        var reviewed: [(path: String, data: Data)] = []
        for file in files {
            // One unreadable file makes the whole set unapprovable — the rule
            // `ScriptTrust.fingerprint` follows, for the same reason: a list
            // that is not the list is not what will run.
            guard let data = file.data else {
                reviewedFingerprint = nil
                return
            }
            reviewed.append((path: file.path, data: data))
        }
        reviewedFingerprint = ScriptTrust.fingerprint(reviewedFiles: reviewed)
    }
}
