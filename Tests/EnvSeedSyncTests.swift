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

    func testSeedDefaultsToAtelierSeedWhenThereIsNoConfig() {
        let config = WorktreeSetupConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.seed, ".atelier-seed")
        XCTAssertEqual(config.seedDirectory(in: "/repo"), "/repo/.atelier-seed")
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
        XCTAssertEqual(config.seed, ".atelier-seed")
    }

    // MARK: - Syncing

    func testCopiesSeedContentsPreservingRelativePaths() throws {
        try write("seed/.env", "ROOT")
        try write("seed/apps/api/.env", "API")
        try makeDirectory("worktree")

        let copied = EnvSeedSync.sync(seedDirectory: path("seed"), to: path("worktree"))

        XCTAssertEqual(copied, 2)
        XCTAssertEqual(try read("worktree/.env"), "ROOT")
        XCTAssertEqual(try read("worktree/apps/api/.env"), "API")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path("worktree/.atelier-seed")),
            "the seed directory's contents are copied, not the directory itself"
        )
    }

    func testDoesNotOverwriteFilesAlreadyInTheWorktree() throws {
        try write("seed/.env", "FROM SEED")
        try write("worktree/.env", "ALREADY THERE")

        let copied = EnvSeedSync.sync(seedDirectory: path("seed"), to: path("worktree"))

        XCTAssertEqual(copied, 0)
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

        let copied = EnvSeedSync.sync(seedDirectory: path("seed"), to: path("worktree"))

        XCTAssertEqual(copied, 1)
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

        let copied = EnvSeedSync.sync(seedDirectory: path("seed"), to: path("worktree"))

        XCTAssertEqual(copied, 1)
        XCTAssertEqual(try read("worktree/.env"), "ELSEWHERE")
        XCTAssertFalse(isSymlink("worktree/.env"))
    }

    func testMissingSeedDirectoryCopiesNothing() throws {
        try makeDirectory("worktree")

        let copied = EnvSeedSync.sync(seedDirectory: path("nope"), to: path("worktree"))

        XCTAssertEqual(copied, 0)
        let contents = try FileManager.default.contentsOfDirectory(atPath: path("worktree"))
        XCTAssertTrue(contents.isEmpty)
    }

    func testDirectoriesAreNotCountedAsCopiedFiles() {
        let output = "./\napps/\napps/api/\napps/api/.env\n.env\n"
        XCTAssertEqual(EnvSeedSync.copiedFileCount(rsyncOutput: output), 2)
    }

    // MARK: - Toggle migration

    func testMigrationAdoptsTheOldSymlinkToggle() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "atelier.symlinkEnv")

        EnvSeedSync.migrateDefaults(defaults)

        XCTAssertFalse(EnvSeedSync.isEnabled(defaults))
    }

    func testMigrationLeavesAnExplicitNewValueAlone() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "atelier.symlinkEnv")
        defaults.set(true, forKey: EnvSeedSync.defaultsKey)

        EnvSeedSync.migrateDefaults(defaults)

        XCTAssertTrue(EnvSeedSync.isEnabled(defaults))
    }

    func testSeedingIsOnWhenNeitherToggleWasEverSet() throws {
        let defaults = try makeDefaults()

        EnvSeedSync.migrateDefaults(defaults)

        XCTAssertTrue(EnvSeedSync.isEnabled(defaults))
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
