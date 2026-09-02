// ABOUTME: Central place for app-wide constants.
// ABOUTME: Debug builds use separate IDs so they can run alongside release builds.

import Foundation

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

    static let appName: String = "Atelier"

    /// GitHub `owner/repo` backing the repository and documentation URLs below.
    static let repositorySlug: String = "phaedryx/atelier"

    /// Home of the project. The fork has no marketing site, so the
    /// documentation link points at GitHub.
    static let repositoryURL = URL(string: "https://github.com/\(repositorySlug)")!
    static let documentationURL = URL(string: "https://github.com/\(repositorySlug)#readme")!

    /// Upstream projects this fork descends from, credited in Help and the About panel.
    static let upstreamURL = URL(string: "https://github.com/alltuner/factoryfloor")!
    static let upstreamAuthorURL = URL(string: "https://davidpoblador.com/")!
    static let upstreamEnhancerURL = URL(string: "https://github.com/AndresGonzalez5")!

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

    /// Cache directory: ~/Library/Caches/atelier/.
    /// Used for transient files like run-state and tmux config.
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        // `appID`, not a literal. Debug and release have different bundle
        // identifiers but shared this directory, so the two could run side by
        // side over one set of phase sockets and run-state files — and quitting
        // one swept the other's live process-compose servers, mid-run, via
        // `PhaseExecutor.stopAllServers`.
        let dirName = isRunningXCTest()
            ? "atelier-tests"
            : appID
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
