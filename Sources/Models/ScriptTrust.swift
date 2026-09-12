// ABOUTME: Records which repository-provided process-compose files the user has approved.
// ABOUTME: Approval is bound to the contents, so an edited config has to be approved again.

import CryptoKit
import Foundation

enum ScriptTrust {
    private static let configFileKey = "atelier.approvedConfigFiles"

    /// Whether the repository-provided process-compose files a config will load
    /// may run their unattended phases — `bootstrap` at worktree creation,
    /// `dispose` at archive — for this project. These are the only gated
    /// phases: `execute` is *attended* — a deliberate press, output in a
    /// terminal surface the user is looking at, Stop within reach — and is never
    /// held behind approval. It is attendance that decides, not display: the
    /// string the Execution pane renders is not the command Start runs, which
    /// is `ProcessCompose.PhaseRunner`'s phase-scoped `prepare && execute`.
    ///
    /// Takes a list, never a single path, because the thing being approved is
    /// the *set* process-compose will be told to load:
    /// `ProcessCompose.Config.repositoryProvidedFiles` is the list that has to be
    /// passed here, whatever it happens to hold. Fingerprinting one file out of
    /// a loaded set would let a repository ship a benign
    /// `process-compose.yaml`, have the user approve it, and execute an unseen
    /// sibling unattended — the hole the list API exists to close. A config
    /// currently loads exactly one file, so the list is short; it is the
    /// equality with `loadedFiles` that matters, not the length.
    ///
    /// A config in the project directory was placed there by hand, outside git,
    /// and contributes nothing to that list: asking about the user's own file
    /// every time they edit it is friction with no risk behind it. Location is
    /// what decides, not content.
    ///
    /// An empty list is *not* approved. Callers gate on
    /// `ProcessCompose.Config.requiresApproval`, which is false exactly when the
    /// list is empty, so the question is never asked; answering "yes" here would
    /// make a mistaken call site fail open.
    static func isApproved(configFiles paths: [String], for projectDirectory: String) -> Bool {
        guard let fingerprint = fingerprint(configFiles: paths) else { return false }
        return configApprovals()[projectDirectory] == fingerprint
    }

    /// Approve the files the user actually reviewed.
    ///
    /// `reviewed` is the fingerprint of the bytes the approval pane displayed,
    /// and the files are re-read here and compared against it: the pane can sit
    /// open for minutes, and the coding agent runs in the same worktree, so the
    /// file on disk at the moment of the click is not necessarily the file that
    /// was on screen. Approving the disk copy would fingerprint content nobody
    /// saw and hand it straight to `bootstrap`, which runs unattended — the one
    /// outcome the pane exists to prevent.
    ///
    /// There is deliberately no overload that approves whatever is on disk. The
    /// reviewed fingerprint is the only thing that makes this a gate, so it is a
    /// required argument rather than something a call site can forget, and the
    /// refusal is returned rather than discardable so ignoring it is a warning.
    ///
    /// Returns false when nothing was recorded: the files changed, or one of
    /// them cannot be read.
    static func approve(
        configFiles paths: [String],
        for projectDirectory: String,
        matching reviewed: String
    ) -> Bool {
        guard let fingerprint = fingerprint(configFiles: paths), fingerprint == reviewed else {
            return false
        }
        var current = configApprovals()
        current[projectDirectory] = fingerprint
        saveConfigApprovals(current)
        return true
    }

    static func revokeConfigFiles(for projectDirectory: String) {
        var current = configApprovals()
        guard current.removeValue(forKey: projectDirectory) != nil else { return }
        saveConfigApprovals(current)
    }

    /// Identifies a set of config files by each one's name and whole contents,
    /// in order. An edit to any of them, and the appearance or disappearance of
    /// any of them, all change the value — so a file added to the loaded set
    /// after approval asks again.
    ///
    /// The full path is deliberately *not* hashed: a repository-provided config
    /// lives in every worktree at a different path, and re-approving the same
    /// bytes per worktree would train the user to click through the pane. The
    /// file *name* is hashed, so the same bytes under a different name are a
    /// different thing to approve.
    ///
    /// Nil for an empty list, and nil if any single file cannot be read. Failing
    /// open here would run something nobody could review.
    static func fingerprint(configFiles paths: [String]) -> String? {
        var loaded: [(path: String, data: Data)] = []
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            loaded.append((path: path, data: data))
        }
        return fingerprint(reviewedFiles: loaded)
    }

    /// The same value for bytes already in hand — what the approval pane
    /// displayed, rather than what a second read would find. It is the one
    /// caller: hashing the bytes on screen is what lets `approve` tell a config
    /// that changed under the pane from one that did not.
    static func fingerprint(reviewedFiles files: [(path: String, data: Data)]) -> String? {
        guard !files.isEmpty else { return nil }
        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data((file.path as NSString).lastPathComponent.utf8))
            hasher.update(data: Data([0x01]))
            hasher.update(data: file.data)
            hasher.update(data: Data([0x02]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func configApprovals() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: configFileKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveConfigApprovals(_ approvals: [String: String]) {
        guard let data = try? JSONEncoder().encode(approvals) else { return }
        UserDefaults.standard.set(data, forKey: configFileKey)
    }
}
