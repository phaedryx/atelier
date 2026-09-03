// ABOUTME: Tests for the SettingsPane enum backing the tabbed Settings view.
// ABOUTME: Covers raw-value persistence stability, tab order, and deep-link parsing.

@testable import Atelier
import XCTest

final class SettingsPaneTests: XCTestCase {
    func testRawValuesAreStable() {
        // Raw values are persisted in UserDefaults (atelier.settingsPane)
        // and carried in .openSettings notifications; renaming one silently
        // resets the user's remembered pane.
        XCTAssertEqual(SettingsPane.environment.rawValue, "environment")
        XCTAssertEqual(SettingsPane.general.rawValue, "general")
        XCTAssertEqual(SettingsPane.codingAgent.rawValue, "codingAgent")
        XCTAssertEqual(SettingsPane.prompts.rawValue, "prompts")
        XCTAssertEqual(SettingsPane.advanced.rawValue, "advanced")
        XCTAssertEqual(SettingsPane.integrations.rawValue, "integrations")
    }

    func testTabOrderStartsWithGeneral() {
        XCTAssertEqual(
            SettingsPane.allCases,
            [.general, .environment, .codingAgent, .prompts, .integrations, .advanced]
        )
    }

    func testIntegrationsIsDeepLinkable() {
        // The Shortcut dialog's "unauthorized" error links straight to the token field.
        let note = Notification(name: .openSettings, object: "integrations")
        XCTAssertEqual(SettingsPane.deepLinkTarget(from: note), .integrations)
    }

    func testEveryPaneHasTitleAndIcon() {
        for pane in SettingsPane.allCases {
            XCTAssertFalse(pane.title.isEmpty, "\(pane) has no title")
            XCTAssertFalse(pane.icon.isEmpty, "\(pane) has no icon")
        }
    }

    func testDeepLinkTargetParsesRawValueObject() {
        let note = Notification(name: .openSettings, object: "codingAgent")
        XCTAssertEqual(SettingsPane.deepLinkTarget(from: note), .codingAgent)
    }

    func testDeepLinkTargetIsNilForPlainOpen() {
        XCTAssertNil(SettingsPane.deepLinkTarget(from: Notification(name: .openSettings)))
    }

    func testDeepLinkTargetIsNilForUnknownOrNonStringObjects() {
        XCTAssertNil(SettingsPane.deepLinkTarget(from: Notification(name: .openSettings, object: "notAPane")))
        XCTAssertNil(SettingsPane.deepLinkTarget(from: Notification(name: .openSettings, object: 42)))
    }
}

final class BaseBranchSettingTests: XCTestCase {
    /// `atelier.baseBranch` lives in the app's own defaults domain, which the
    /// test host shares with a real debug build. A tearDown that reset to a
    /// hardcoded value (rather than restoring what was there) has previously
    /// clobbered a developer's actual preference — save and put back instead.
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: BaseBranchSetting.storageKey)
        UserDefaults.standard.removeObject(forKey: BaseBranchSetting.storageKey)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: BaseBranchSetting.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: BaseBranchSetting.storageKey)
        }
        saved = nil
        super.tearDown()
    }

    /// Not just "an absent key yields .main" (true for any `?? .main`, and
    /// setUp already clears the key) — also covers a value that doesn't
    /// decode to a case at all, e.g. left behind by an older build or a
    /// hand-edited plist. Fails if the coalesce is ever swapped for a
    /// force-unwrap, or the fallback case changes.
    func testBaseBranchDefaultsToMainWhenUnsetOrUnrecognized() {
        UserDefaults.standard.removeObject(forKey: BaseBranchSetting.storageKey)
        XCTAssertEqual(BaseBranchSetting.current, .main)

        UserDefaults.standard.set("nonsense", forKey: BaseBranchSetting.storageKey)
        XCTAssertEqual(BaseBranchSetting.current, .main)
    }

    func testExplicitBaseBranchIsUsedVerbatim() {
        BaseBranchSetting.current = .develop
        XCTAssertEqual(BaseBranchSetting.resolve(for: "/nonexistent"), "develop")
    }

    /// A weak version of this test would only check that `resolve` returns
    /// *something* non-empty for `.repositoryDefault` — but `"HEAD"`, git's own
    /// last-resort fallback, would satisfy that even if the setting were wired
    /// to nothing. Instead, build a real repo whose actual branch is
    /// "development" — one of `Git.Operations.defaultBranch`'s recognized names,
    /// but not "main" — and check both directions: `.repositoryDefault` must
    /// pick it up via git, and an explicit `.main` set against that *same* repo
    /// must NOT follow git — it must return "main" verbatim even though no such
    /// branch exists there. The pair fails if `resolve` ever ignores the setting
    /// (ever hardcodes) and fails if it always asks git regardless of the
    /// setting (never uses the literal name).
    func testRepositoryDefaultAsksGitAndNamedBranchDoesNot() throws {
        let repoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("base-branch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        try git(["init", "-b", "development"], in: repoDir)
        try git(["-c", "user.email=test@test.com", "-c", "user.name=Test",
                 "commit", "--allow-empty", "-m", "init"], in: repoDir)

        BaseBranchSetting.current = .repositoryDefault
        XCTAssertEqual(BaseBranchSetting.resolve(for: repoDir.path), "development")

        BaseBranchSetting.current = .main
        XCTAssertEqual(BaseBranchSetting.resolve(for: repoDir.path), "main")
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
