// ABOUTME: Tests for ScriptConfig loading from multiple config file formats.
// ABOUTME: Validates priority order and parsing of atelier, emdash, conductor, and superset configs.

@testable import Atelier
import XCTest

final class ScriptConfigTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - Empty directory

    func testEmptyDirectoryReturnsEmpty() {
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertNil(config.setup)
        XCTAssertNil(config.run)
        XCTAssertNil(config.teardown)
        XCTAssertNil(config.source)
        XCTAssertFalse(config.hasAnyScript)
    }

    // MARK: - .atelier.json (primary)

    func testAtelierJSON() {
        writeJSON(".atelier.json", ["setup": "npm install", "run": "npm start"])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.setup, "npm install")
        XCTAssertEqual(config.run, "npm start")
        XCTAssertNil(config.teardown)
        XCTAssertEqual(config.source, ".atelier.json")
    }

    func testAtelierTakesPriorityOverConductor() {
        writeJSON(".atelier.json", ["run": "atelier-run"])
        writeJSON("conductor.json", ["scripts": ["run": "conductor-run"]])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.run, "atelier-run")
        XCTAssertEqual(config.source, ".atelier.json")
    }

    func testAtelierTakesPriorityOverSuperset() throws {
        writeJSON(".atelier.json", ["run": "atelier-run"])
        let supersetDir = tmpDir.appendingPathComponent(".superset")
        try FileManager.default.createDirectory(at: supersetDir, withIntermediateDirectories: true)
        writeJSON(".superset/config.json", ["run": ["superset-run"]])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.run, "atelier-run")
        XCTAssertEqual(config.source, ".atelier.json")
    }

    // MARK: - conductor.json (fallback)

    // MARK: - .factoryfloor.json (legacy)

    func testLegacyFactoryFloorJSON() {
        writeJSON(".factoryfloor.json", ["setup": "npm install", "run": "npm start"])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.setup, "npm install")
        XCTAssertEqual(config.run, "npm start")
        XCTAssertEqual(config.source, ".factoryfloor.json")
    }

    func testAtelierTakesPriorityOverLegacyFactoryFloor() {
        writeJSON(".atelier.json", ["run": "new"])
        writeJSON(".factoryfloor.json", ["run": "old"])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.run, "new")
        XCTAssertEqual(config.source, ".atelier.json")
    }

    func testLegacyFactoryFloorTakesPriorityOverConductor() {
        writeJSON(".factoryfloor.json", ["run": "atelier-run"])
        writeJSON("conductor.json", ["scripts": ["run": "conductor-run"]])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.run, "atelier-run")
        XCTAssertEqual(config.source, ".factoryfloor.json")
    }

    func testConductorJSON() {
        writeJSON("conductor.json", ["scripts": ["setup": "make build", "run": "make serve", "archive": "make clean"]])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.setup, "make build")
        XCTAssertEqual(config.run, "make serve")
        XCTAssertEqual(config.teardown, "make clean")
        XCTAssertEqual(config.source, "conductor.json")
    }

    func testConductorMapsArchiveToTeardown() {
        writeJSON("conductor.json", ["scripts": ["archive": "rm -rf dist"]])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.teardown, "rm -rf dist")
        XCTAssertNil(config.setup)
        XCTAssertNil(config.run)
    }

    func testConductorWithoutScriptsKeyReturnsEmpty() {
        writeJSON("conductor.json", ["setup": "npm install"])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertFalse(config.hasAnyScript)
    }

    func testConductorTakesPriorityOverSuperset() throws {
        writeJSON("conductor.json", ["scripts": ["run": "conductor-run"]])
        let supersetDir = tmpDir.appendingPathComponent(".superset")
        try FileManager.default.createDirectory(at: supersetDir, withIntermediateDirectories: true)
        writeJSON(".superset/config.json", ["run": ["superset-run"]])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.run, "conductor-run")
        XCTAssertEqual(config.source, "conductor.json")
    }

    // MARK: - .superset/config.json (fallback)

    func testSupersetJSON() throws {
        let supersetDir = tmpDir.appendingPathComponent(".superset")
        try FileManager.default.createDirectory(at: supersetDir, withIntermediateDirectories: true)
        writeJSON(".superset/config.json", ["setup": ["npm install", "cp .env.example .env"], "run": ["npm run dev"], "teardown": ["rm -rf node_modules"]])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.setup, "npm install && cp .env.example .env")
        XCTAssertEqual(config.run, "npm run dev")
        XCTAssertEqual(config.teardown, "rm -rf node_modules")
        XCTAssertEqual(config.source, ".superset/config.json")
    }

    func testSupersetFiltersEmptyStrings() throws {
        let supersetDir = tmpDir.appendingPathComponent(".superset")
        try FileManager.default.createDirectory(at: supersetDir, withIntermediateDirectories: true)
        writeJSON(".superset/config.json", ["run": ["npm start", "", "  "]])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.run, "npm start")
    }

    func testSupersetAcceptsPlainStrings() throws {
        let supersetDir = tmpDir.appendingPathComponent(".superset")
        try FileManager.default.createDirectory(at: supersetDir, withIntermediateDirectories: true)
        writeJSON(".superset/config.json", ["run": "npm start"])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.run, "npm start")
    }

    // MARK: - .emdash.json (fallback)

    func testEmdashJSON() {
        writeJSON(".emdash.json", ["scripts": ["setup": "npm install", "run": "npm start", "teardown": "npm run clean"]])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.setup, "npm install")
        XCTAssertEqual(config.run, "npm start")
        XCTAssertEqual(config.teardown, "npm run clean")
        XCTAssertEqual(config.source, ".emdash.json")
    }

    func testEmdashWithoutScriptsKeyReturnsEmpty() {
        writeJSON(".emdash.json", ["setup": "npm install"])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertFalse(config.hasAnyScript)
    }

    func testAtelierTakesPriorityOverEmdash() {
        writeJSON(".atelier.json", ["run": "atelier-run"])
        writeJSON(".emdash.json", ["scripts": ["run": "emdash-run"]])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.run, "atelier-run")
        XCTAssertEqual(config.source, ".atelier.json")
    }

    func testEmdashTakesPriorityOverConductor() {
        writeJSON(".emdash.json", ["scripts": ["run": "emdash-run"]])
        writeJSON("conductor.json", ["scripts": ["run": "conductor-run"]])
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertEqual(config.run, "emdash-run")
        XCTAssertEqual(config.source, ".emdash.json")
    }

    func testInvalidEmdashJSONReportsError() {
        let path = tmpDir.appendingPathComponent(".emdash.json").path
        FileManager.default.createFile(atPath: path, contents: "not json".data(using: .utf8))
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertNotNil(config.loadError)
        XCTAssertEqual(config.source, ".emdash.json")
    }

    // MARK: - Error handling

    func testInvalidJSONReportsError() {
        let path = tmpDir.appendingPathComponent(".atelier.json").path
        FileManager.default.createFile(atPath: path, contents: "not json".data(using: .utf8))
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertNotNil(config.loadError)
        XCTAssertEqual(config.source, ".atelier.json")
    }

    func testInvalidConductorJSONReportsError() {
        let path = tmpDir.appendingPathComponent("conductor.json").path
        FileManager.default.createFile(atPath: path, contents: "not json".data(using: .utf8))
        let config = ScriptConfig.load(from: tmpDir.path)
        XCTAssertNotNil(config.loadError)
        XCTAssertEqual(config.source, "conductor.json")
    }

    // MARK: - Helpers

    private func writeJSON(_ name: String, _ dict: [String: Any]) {
        let path = tmpDir.appendingPathComponent(name).path
        let data = try! JSONSerialization.data(withJSONObject: dict)
        FileManager.default.createFile(atPath: path, contents: data)
    }
}
