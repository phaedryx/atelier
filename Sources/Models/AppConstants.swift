// ABOUTME: Central place for app-wide constants.
// ABOUTME: Debug builds use separate IDs so they can run alongside release builds.

import Foundation

func resolvedConfigDirectory(
    configDirectoryName: String,
    environment: [String: String],
    defaultConfigBase: URL,
    isRunningTests: Bool
) -> URL {
    let configBase: URL
    if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
        configBase = URL(fileURLWithPath: xdg)
    } else {
        configBase = defaultConfigBase
    }

    if isRunningTests {
        return configBase.appendingPathComponent("\(configDirectoryName)-tests")
    }

    return configBase.appendingPathComponent(configDirectoryName)
}

func isRunningXCTest(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["XCTestConfigurationFilePath"] != nil
}

enum AppConstants {
    static let appID: String = {
        #if DEBUG
            "atelier-debug"
        #else
            "atelier"
        #endif
    }()

    static let appName: String = {
        "Atelier"
    }()

    /// GitHub `owner/repo` backing the repository and documentation URLs below.
    static let repositorySlug: String = "phaedryx/atelier"

    /// Home of the project. The fork has no marketing site, so docs and
    /// sponsorship links both point at GitHub.
    static let repositoryURL = URL(string: "https://github.com/\(repositorySlug)")!
    static let documentationURL = URL(string: "https://github.com/\(repositorySlug)#readme")!
    static let sponsorURL = URL(string: "https://github.com/sponsors/phaedryx")!

    /// Upstream projects this fork descends from, credited in Help and the About panel.
    static let upstreamURL = URL(string: "https://github.com/alltuner/factoryfloor")!
    static let upstreamAuthorURL = URL(string: "https://davidpoblador.com/")!
    static let upstreamEnhancerURL = URL(string: "https://github.com/AndresGonzalez5")!

    /// Sentry DSN, injected at build time via the `ATELIER_SENTRY_DSN` build setting.
    ///
    /// Empty by default so a plain checkout never ships crash reports to someone
    /// else's project; crash reporting simply stays off until a DSN is supplied.
    static var sentryDSN: String? {
        guard let dsn = Bundle.main.infoDictionary?["SentryDSN"] as? String else { return nil }
        let trimmed = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static let urlScheme: String = {
        #if DEBUG
            "atelier-debug"
        #else
            "atelier"
        #endif
    }()

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var displayVersion: String {
        #if DEBUG
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            if let build, build != "1", build != version {
                return "\(version) (\(build))"
            }
            return "\(version) (Debug)"
        #else
            return version
        #endif
    }

    /// Config directory: ~/.config/atelier/ (respects XDG_CONFIG_HOME).
    /// XCTest uses ~/.config/atelier-tests/ to keep test data isolated.
    static var configDirectory: URL {
        resolvedConfigDirectory(
            configDirectoryName: "atelier",
            environment: ProcessInfo.processInfo.environment,
            defaultConfigBase: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config"),
            isRunningTests: isRunningXCTest()
        )
    }

    /// Cache directory: ~/Library/Caches/atelier/.
    /// Used for transient files like run-state and tmux config.
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dirName = isRunningXCTest()
            ? "atelier-tests"
            : "atelier"
        return base.appendingPathComponent(dirName)
    }

    /// Path to the agent launch script for a given workstream.
    static func agentScriptPath(for workstreamID: UUID) -> String {
        cacheDirectory
            .appendingPathComponent("agent-scripts")
            .appendingPathComponent("\(workstreamID.uuidString.lowercased()).sh")
            .path
    }

    /// Worktrees are always shared between debug and release builds.
    static var worktreesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".atelier")
            .appendingPathComponent("worktrees")
    }
}
