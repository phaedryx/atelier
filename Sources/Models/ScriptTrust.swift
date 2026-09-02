// ABOUTME: Records which repository-provided process-compose files the user has approved.
// ABOUTME: Approval is bound to the contents, so an edited config has to be approved again.

import CryptoKit
import Foundation

enum ScriptTrust {
    private static let configFileKey = "atelier.approvedConfigFiles"

    /// Whether the repository-provided process-compose files a config will load
    /// may run their unattended phases — `bootstrap` at worktree creation,
    /// `dispose` at archive — for this project. These are the only gated
    /// phases: `execute` runs a command the Environment pane is already
    /// displaying, on a deliberate press, and is never held behind approval.
    ///
    /// Takes the whole list, never a single file. process-compose loads a base
    /// config *and* whatever override sits beside it, so fingerprinting only the
    /// base would let a repository ship a benign `process-compose.yaml`, have the
    /// user approve it, and execute an unseen `process-compose.override.yaml`
    /// unattended. `ProcessComposeConfig.repositoryProvidedFiles` is the list
    /// that has to be passed here.
    ///
    /// A config in the project directory was placed there by hand, outside git,
    /// and contributes nothing to that list: asking about the user's own file
    /// every time they edit it is friction with no risk behind it. Location is
    /// what decides, not content.
    ///
    /// An empty list is *not* approved. Callers gate on
    /// `ProcessComposeConfig.requiresApproval`, which is false exactly when the
    /// list is empty, so the question is never asked; answering "yes" here would
    /// make a mistaken call site fail open.
    static func isApproved(configFiles paths: [String], for projectDirectory: String) -> Bool {
        guard let fingerprint = fingerprint(configFiles: paths) else { return false }
        return configApprovals()[projectDirectory] == fingerprint
    }

    static func approve(configFiles paths: [String], for projectDirectory: String) {
        guard let fingerprint = fingerprint(configFiles: paths) else { return }
        var current = configApprovals()
        current[projectDirectory] = fingerprint
        saveConfigApprovals(current)
    }

    static func revokeConfigFiles(for projectDirectory: String) {
        var current = configApprovals()
        guard current.removeValue(forKey: projectDirectory) != nil else { return }
        saveConfigApprovals(current)
    }

    /// Identifies a set of config files by each one's name and whole contents,
    /// in order. An edit to any of them, and the appearance or disappearance of
    /// any of them, all change the value — so an override added after approval
    /// asks again.
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
        guard !paths.isEmpty else { return nil }
        var hasher = SHA256()
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            hasher.update(data: Data((path as NSString).lastPathComponent.utf8))
            hasher.update(data: Data([0x01]))
            hasher.update(data: data)
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
