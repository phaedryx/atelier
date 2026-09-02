// ABOUTME: Records which repository-provided commands and config files the user has approved.
// ABOUTME: Approval is bound to the content, so an edited config has to be approved again.

import CryptoKit
import Foundation

enum ScriptTrust {
    private static let userDefaultsKey = "atelier.approvedScripts"

    /// Identifies the executable content of a config. Any change to a command,
    /// to the role a command sits in, or to the file it was read from produces a
    /// different value.
    static func fingerprint(_ config: ScriptConfig) -> String {
        let canonical = [
            config.source ?? "",
            config.setup ?? "",
            config.teardown ?? "",
        ].joined(separator: "\u{1}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the commands in this config may run for this project.
    /// A config that carries no commands has nothing to approve.
    static func isApproved(_ config: ScriptConfig, for projectDirectory: String) -> Bool {
        guard config.hasAnyScript else { return true }
        return approvals()[projectDirectory] == fingerprint(config)
    }

    static func approve(_ config: ScriptConfig, for projectDirectory: String) {
        var current = approvals()
        current[projectDirectory] = fingerprint(config)
        save(current)
    }

    static func revoke(for projectDirectory: String) {
        var current = approvals()
        guard current.removeValue(forKey: projectDirectory) != nil else { return }
        save(current)
    }

    // MARK: - Config files

    private static let configFileKey = "atelier.approvedConfigFiles"

    /// Whether a repository-provided process-compose config may run its
    /// unattended phases — `bootstrap` at worktree creation, `dispose` at
    /// archive — for this project.
    ///
    /// Only configs that arrived with the repository are gated. One in the
    /// project directory was placed there by hand, outside git, and asking about
    /// the user's own file every time they edit it is friction with no risk
    /// behind it. `execute` is never gated in either case, because it is a
    /// deliberate press on a command the pane is already showing.
    ///
    /// A file that cannot be read has no fingerprint and is therefore never
    /// approved. Failing open here would run something nobody could review.
    static func isApproved(configFile path: String, for projectDirectory: String) -> Bool {
        guard let fingerprint = fingerprint(configFile: path) else { return false }
        return configApprovals()[projectDirectory] == fingerprint
    }

    static func approve(configFile path: String, for projectDirectory: String) {
        guard let fingerprint = fingerprint(configFile: path) else { return }
        var current = configApprovals()
        current[projectDirectory] = fingerprint
        saveConfigApprovals(current)
    }

    static func revokeConfigFile(for projectDirectory: String) {
        var current = configApprovals()
        guard current.removeValue(forKey: projectDirectory) != nil else { return }
        saveConfigApprovals(current)
    }

    /// Identifies a config file by its name and its whole contents, so an edit
    /// invalidates the approval. The full path is deliberately *not* hashed: a
    /// repository-provided config lives in every worktree at a different path,
    /// and re-approving the same bytes per worktree would train the user to
    /// click through it. Nil when the file cannot be read.
    static func fingerprint(configFile path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data((path as NSString).lastPathComponent.utf8))
        hasher.update(data: Data([0x01]))
        hasher.update(data: data)
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

    // MARK: - Storage

    private static func approvals() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ approvals: [String: String]) {
        guard let data = try? JSONEncoder().encode(approvals) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
