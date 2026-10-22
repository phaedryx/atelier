// ABOUTME: Tests detection, default resolution and menu grouping for external editors and terminals.
// ABOUTME: Installation is an injected predicate, so nothing here asks LaunchServices.

@testable import Atelier
import XCTest

final class ExternalAppTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "atelier.tests.externalApp"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func apps(_ ids: String...) -> [AppInfo] {
        ids.map { AppInfo(name: $0, bundleID: $0) }
    }

    // MARK: - Catalog

    func testCatalogCarriesTheBuiltInEditors() {
        let names = ExternalApp.catalog.filter { $0.kind == .editor }.map(\.name)
        for expected in ["VS Code", "Cursor", "RubyMine", "IntelliJ IDEA", "Zed"] {
            XCTAssertTrue(names.contains(expected), expected)
        }
    }

    func testCatalogCarriesTheBuiltInTerminals() {
        let names = ExternalApp.catalog.filter { $0.kind == .terminal }.map(\.name)
        for expected in ["Terminal", "iTerm2", "Ghostty", "Warp", "WezTerm"] {
            XCTAssertTrue(names.contains(expected), expected)
        }
    }

    func testCatalogBundleIDsAreUnique() {
        let ids = ExternalApp.catalog.map(\.bundleID)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    // MARK: - Detection

    func testDetectOffersOnlyInstalledAppsOfTheKind() {
        let detected = ExternalApp.detect(.editor) { $0 == "com.microsoft.VSCode" || $0 == "com.apple.Terminal" }
        XCTAssertEqual(detected.map(\.bundleID), ["com.microsoft.VSCode"])
    }

    func testDetectKeepsCatalogOrder() {
        let editors = ExternalApp.catalog.filter { $0.kind == .editor }
        let detected = ExternalApp.detect(.editor) { _ in true }
        XCTAssertEqual(detected.map(\.bundleID), editors.map(\.bundleID))
    }

    func testDetectFindsNothingWhenNothingIsInstalled() {
        XCTAssertTrue(ExternalApp.detect(.editor) { _ in false }.isEmpty)
    }

    // MARK: - Resolution

    func testResolvePrefersTheStoredDefaultWhenInstalled() {
        XCTAssertEqual(ExternalApp.resolve(stored: "b", installed: apps("a", "b"))?.bundleID, "b")
    }

    func testResolveFallsBackToFirstInstalledWhenNothingIsStored() {
        XCTAssertEqual(ExternalApp.resolve(stored: nil, installed: apps("a", "b"))?.bundleID, "a")
        XCTAssertEqual(ExternalApp.resolve(stored: "", installed: apps("a", "b"))?.bundleID, "a")
    }

    /// An uninstalled default must not strand the action: the user removed the
    /// app, and an installed alternative is still a better answer than nothing.
    func testResolveFallsBackToFirstInstalledWhenStoredIsUninstalled() {
        XCTAssertEqual(ExternalApp.resolve(stored: "gone", installed: apps("a", "b"))?.bundleID, "a")
    }

    func testResolveIsNilWhenNothingIsInstalled() {
        XCTAssertNil(ExternalApp.resolve(stored: "a", installed: []))
    }

    // MARK: - Defaults

    /// `atelier.defaultTerminal` predates this type and the Settings picker
    /// already writes it; renaming it would silently reset everyone's choice.
    func testTerminalKeepsItsExistingDefaultsKey() {
        XCTAssertEqual(ExternalApp.Kind.terminal.defaultsKey, "atelier.defaultTerminal")
        XCTAssertEqual(ExternalApp.Kind.editor.defaultsKey, "atelier.defaultEditor")
    }

    func testChooseStoresTheDefaultPerKind() {
        ExternalApp.choose(AppInfo(name: "Zed", bundleID: "dev.zed.Zed"), as: .editor, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "atelier.defaultEditor"), "dev.zed.Zed")
        XCTAssertNil(defaults.string(forKey: "atelier.defaultTerminal"))
    }

    func testPreferredReadsTheStoredDefault() {
        defaults.set("b", forKey: "atelier.defaultEditor")
        XCTAssertEqual(ExternalApp.preferred(.editor, installed: apps("a", "b"), defaults: defaults)?.bundleID, "b")
        XCTAssertEqual(ExternalApp.preferred(.terminal, installed: apps("a", "b"), defaults: defaults)?.bundleID, "a")
    }

    // MARK: - Menu

    func testMenuGroupsByKindEditorsFirstAndMarksEachKindsDefault() {
        let sections = ExternalApp.menuSections(
            installed: [.editor: apps("e1", "e2"), .terminal: apps("t1", "t2")],
            stored: [.terminal: "t2"]
        )
        XCTAssertEqual(sections.map(\.kind), [.editor, .terminal])
        XCTAssertEqual(sections[0].items.map(\.app.bundleID), ["e1", "e2"])
        XCTAssertEqual(sections[0].items.map(\.isDefault), [true, false])
        XCTAssertEqual(sections[1].items.map(\.isDefault), [false, true])
    }

    func testMenuOmitsAKindWithNothingInstalled() {
        let sections = ExternalApp.menuSections(
            installed: [.editor: [], .terminal: apps("t1")],
            stored: [:]
        )
        XCTAssertEqual(sections.map(\.kind), [.terminal])
    }
}
