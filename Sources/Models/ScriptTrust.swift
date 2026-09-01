// ABOUTME: Records which repository-provided setup/run/teardown commands the user has approved.
// ABOUTME: Approval is bound to the command text, so an edited config has to be approved again.

import CryptoKit
import Foundation

enum ScriptTrust {
    private static let userDefaultsKey = "atelier.approvedScripts"
    private static let runnerFileKey = "atelier.approvedRunnerFiles"

    /// Identifies the executable content of a config. Any change to a command,
    /// to the role a command sits in, or to the file it was read from produces a
    /// different value.
    static func fingerprint(_ config: ScriptConfig) -> String {
        let canonical = [
            config.source ?? "",
            config.setup ?? "",
            config.run ?? "",
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

    // MARK: - Runner config files

    /// Whether a runner config the repository provides — a `process-compose.yaml`
    /// and the commands inside it — may run for this project.
    ///
    /// Tracked separately from `.atelier.json` scripts because the two are
    /// approved at different moments, but on the same terms: the fingerprint
    /// covers the file's contents, so editing the config asks again. An
    /// unreadable file is treated as unapproved rather than as nothing to
    /// approve — the command would fail anyway, and silently running it is the
    /// wrong direction to fail in.
    static func isApproved(runnerFile path: String, for projectDirectory: String) -> Bool {
        guard let fingerprint = fingerprint(runnerFile: path) else { return false }
        return runnerApprovals()[projectDirectory] == fingerprint
    }

    static func approve(runnerFile path: String, for projectDirectory: String) {
        guard let fingerprint = fingerprint(runnerFile: path) else { return }
        var current = runnerApprovals()
        current[projectDirectory] = fingerprint
        saveRunnerApprovals(current)
    }

    static func fingerprint(runnerFile path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data((path as NSString).lastPathComponent.utf8))
        hasher.update(data: Data([0x01]))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func revoke(for projectDirectory: String) {
        var current = approvals()
        guard current.removeValue(forKey: projectDirectory) != nil else { return }
        save(current)
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

    private static func runnerApprovals() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: runnerFileKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveRunnerApprovals(_ approvals: [String: String]) {
        guard let data = try? JSONEncoder().encode(approvals) else { return }
        UserDefaults.standard.set(data, forKey: runnerFileKey)
    }
}
