// ABOUTME: Tests for seed-directory config resolution and the rsync into a worktree.
// ABOUTME: Covers partial .atelier.json decoding, seed overrides, and copy semantics.

@testable import Atelier
import XCTest

final class EnvSeedSyncTests: XCTestCase {
    private static let defaultsSuiteName = "atelier.tests.envSeedSync"

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        UserDefaults(suiteName: Self.defaultsSuiteName)?
            .removePersistentDomain(forName: Self.defaultsSuiteName)
        super.tearDown()
    }

    // MARK: - Seed configuration

    func testSeedDefaultsToSeedFilesWhenThereIsNoConfig() {
        let config = WorktreeSetupConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.seed, "seed-files")
        XCTAssertEqual(config.seedDirectory(in: "/repo"), "/repo/seed-files")
    }

    func testConfigWithOnlyASeedKeyStillDecodes() throws {
        try writeConfig(["seed": "config/secrets"])
        let config = WorktreeSetupConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.seed, "config/secrets")
        // The untouched keys keep their defaults rather than the whole config
        // collapsing back to `.default`.
        XCTAssertEqual(config.baseBranch, WorktreeSetupConfig.default.baseBranch)
        XCTAssertEqual(config.symlinks, WorktreeSetupConfig.default.symlinks)
    }

    func testSeedOverrideResolvesAgainstTheProjectDirectory() throws {
        try writeConfig(["seed": "config/secrets"])
        let config = WorktreeSetupConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.seedDirectory(in: "/repo"), "/repo/config/secrets")
    }

    func testAbsoluteSeedIsUsedAsWritten() throws {
        try writeConfig(["seed": "/etc/app-secrets"])
        let config = WorktreeSetupConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.seedDirectory(in: "/repo"), "/etc/app-secrets")
    }

    func testTildeSeedExpandsToTheHomeDirectory() throws {
        try writeConfig(["seed": "~/app-secrets"])
        let config = WorktreeSetupConfig.load(from: tmpDir.path)
        XCTAssertEqual(
            config.seedDirectory(in: "/repo"),
            NSHomeDirectory() + "/app-secrets"
        )
    }

    func testOtherConfigKeysStillDecode() throws {
        try writeConfig([
            "base_branch": "trunk",
            "package_manager": "pnpm",
            "symlinks": ["vendor"],
            "post_setup_commands": ["echo hi"],
        ])
        let config = WorktreeSetupConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.baseBranch, "trunk")
        XCTAssertEqual(config.packageManager, .pnpm)
        XCTAssertEqual(config.symlinks, ["vendor"])
        XCTAssertEqual(config.postSetupCommands, ["echo hi"])
        XCTAssertEqual(config.seed, "seed-files")
    }

    // MARK: - Syncing

    func testCopiesSeedContentsPreservingRelativePaths() throws {
        try write("seed/.env", "ROOT")
        try write("seed/apps/api/.env", "API")
        try makeDirectory("worktree")

        let outcome = EnvSeedSync.sync(seedDirectory: path("seed"), to: path("worktree"))

        XCTAssertEqual(outcome, .copied(2))
        XCTAssertNil(outcome.problemDescription)
        XCTAssertEqual(try read("worktree/.env"), "ROOT")
        XCTAssertEqual(try read("worktree/apps/api/.env"), "API")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path("worktree/seed")),
            "the seed directory's contents are copied, not the directory itself"
        )
    }

    func testDoesNotOverwriteFilesAlreadyInTheWorktree() throws {
        try write("seed/.env", "FROM SEED")
        try write("worktree/.env", "ALREADY THERE")

        let outcome = EnvSeedSync.sync(seedDirectory: path("seed"), to: path("worktree"))

        XCTAssertEqual(outcome, .copied(0))
        XCTAssertEqual(try read("worktree/.env"), "ALREADY THERE")
    }

    func testReplacesASymlinkLeftByAnOlderWorktree() throws {
        try write("seed/.env", "FROM SEED")
        try write("main/.env", "FROM MAIN")
        try makeDirectory("worktree")
        try FileManager.default.createSymbolicLink(
            atPath: path("worktree/.env"),
            withDestinationPath: path("main/.env")
        )

        let outcome = EnvSeedSync.sync(seedDirectory: path("seed"), to: path("worktree"))

        XCTAssertEqual(outcome, .copied(1))
        XCTAssertEqual(try read("worktree/.env"), "FROM SEED")
        XCTAssertFalse(isSymlink("worktree/.env"))
    }

    func testSeedSymlinksLandAsRealFiles() throws {
        try makeDirectory("seed")
        try write("elsewhere/.env", "ELSEWHERE")
        try makeDirectory("worktree")
        try FileManager.default.createSymbolicLink(
            atPath: path("seed/.env"),
            withDestinationPath: path("elsewhere/.env")
        )

        let outcome = EnvSeedSync.sync(seedDirectory: path("seed"), to: path("worktree"))

        XCTAssertEqual(outcome, .copied(1))
        XCTAssertEqual(try read("worktree/.env"), "ELSEWHERE")
        XCTAssertFalse(isSymlink("worktree/.env"))
    }

    func testMissingSeedDirectoryCopiesNothing() throws {
        try makeDirectory("worktree")

        let outcome = EnvSeedSync.sync(seedDirectory: path("nope"), to: path("worktree"))

        XCTAssertEqual(outcome, .noSeedDirectory)
        XCTAssertNil(outcome.problemDescription, "a missing seed is not a failure")
        let contents = try FileManager.default.contentsOfDirectory(atPath: path("worktree"))
        XCTAssertTrue(contents.isEmpty)
    }

    // MARK: - Toggle

    func testSeedingIsOnByDefault() throws {
        let defaults = try makeDefaults()
        XCTAssertTrue(EnvSeedSync.isEnabled(defaults))
    }

    func testSeedingRespectsAnExplicitOptOut() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: EnvSeedSync.defaultsKey)
        XCTAssertFalse(EnvSeedSync.isEnabled(defaults))
    }

    /// The old `atelier.symlinkEnv` gated only the symlinks; env files were
    /// copied unconditionally alongside them. Carrying a `false` across would
    /// turn copying off for people who never asked for that, so it is not read.
    func testTheOldSymlinkToggleDoesNotDisableSeeding() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "atelier.symlinkEnv")
        XCTAssertTrue(EnvSeedSync.isEnabled(defaults))
    }

    // MARK: - Failure reporting

    func testAFailedRsyncIsReportedAsAProblem() throws {
        try write("seed/.env", "SECRET")
        // A destination that cannot be created makes rsync exit non-zero.
        let blocked = path("worktree")
        try "not a directory".write(toFile: blocked, atomically: true, encoding: .utf8)

        let outcome = EnvSeedSync.sync(seedDirectory: path("seed"), to: blocked)

        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertNotNil(outcome.problemDescription)
        XCTAssertEqual(outcome.copiedCount, 0)
    }

    func testAFailedRsyncLeavesAnExistingSymlinkIntact() throws {
        try write("seed/.env", "FROM SEED")
        try write("main/.env", "FROM MAIN")
        try makeDirectory("worktree")
        try FileManager.default.createSymbolicLink(
            atPath: path("worktree/.env"),
            withDestinationPath: path("main/.env")
        )
        // Point rsync at a source that disappears mid-call by making the seed
        // unreadable, so the transfer fails after the symlink survey.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path("seed"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path("seed"))
        }

        _ = EnvSeedSync.sync(seedDirectory: path("seed"), to: path("worktree"))

        XCTAssertTrue(
            isSymlink("worktree/.env") || (try? read("worktree/.env")) != nil,
            "the worktree must never end up with neither the symlink nor a real file"
        )
    }

    // MARK: - Directory metadata

    func testExistingWorktreeDirectoriesKeepTheirMode() throws {
        try write("seed/apps/api/.env", "API")
        try makeDirectory("worktree/apps/api")
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path("seed"))
        let before = try (fm.attributesOfItem(atPath: path("worktree")))[.posixPermissions] as? NSNumber

        _ = EnvSeedSync.sync(seedDirectory: path("seed"), to: path("worktree"))

        let after = try (fm.attributesOfItem(atPath: path("worktree")))[.posixPermissions] as? NSNumber
        XCTAssertEqual(after, before, "the seed's mode must not clamp the worktree root")
        XCTAssertEqual(try read("worktree/apps/api/.env"), "API")
    }

    // MARK: - Seed validation

    func testEmptySeedFallsBackToTheDefault() throws {
        try writeConfig(["seed": "   "])
        let config = WorktreeSetupConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.seedDirectory(in: "/repo"), "/repo/seed-files")
    }

    func testSeedPointingAtTheProjectItselfFallsBackToTheDefault() throws {
        try writeConfig(["seed": "."])
        let config = WorktreeSetupConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.seedDirectory(in: "/repo"), "/repo/seed-files")
    }

    func testSeedEscapingTheProjectFallsBackToTheDefault() throws {
        try writeConfig(["seed": "../.."])
        let config = WorktreeSetupConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.seedDirectory(in: "/repo/nested"), "/repo/nested/seed-files")
    }

    func testNestedRelativeSeedIsStillAllowed() throws {
        try writeConfig(["seed": "config/../config/secrets"])
        let config = WorktreeSetupConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.seedDirectory(in: "/repo"), "/repo/config/secrets")
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.defaultsSuiteName))
        defaults.removePersistentDomain(forName: Self.defaultsSuiteName)
        return defaults
    }

    private func path(_ relative: String) -> String {
        tmpDir.appendingPathComponent(relative).path
    }

    private func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent(relative),
            withIntermediateDirectories: true
        )
    }

    private func write(_ relative: String, _ contents: String) throws {
        let url = tmpDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: tmpDir.appendingPathComponent(relative), encoding: .utf8)
    }

    private func isSymlink(_ relative: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path(relative))
        return attrs?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func writeConfig(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: tmpDir.appendingPathComponent(".atelier.json"))
    }
}
