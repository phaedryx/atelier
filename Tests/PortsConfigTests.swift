// ABOUTME: Tests for parsing and validating ports.yaml.
// ABOUTME: Covers the assigned/fixed/browser schema and its rejection rules.

@testable import Atelier
import XCTest

final class PortsConfigTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func write(_ yaml: String) throws {
        try yaml.write(to: dir.appendingPathComponent("ports.yaml"), atomically: true, encoding: .utf8)
    }

    func testParsesAssignedFixedAndBrowser() throws {
        try write("""
        ports:
          BFF_PORT:   { assigned: true, browser: true }
          RAILS_PORT: { fixed: 3005 }
          VITE_PORT:  { assigned: true }
        """)

        let config = try XCTUnwrap(PortsConfig.load(from: dir.path))

        XCTAssertEqual(config.entries.count, 3)
        let bff = try XCTUnwrap(config.entries.first { $0.name == "BFF_PORT" })
        XCTAssertEqual(bff.kind, .assigned)
        XCTAssertTrue(bff.isBrowser)
        let rails = try XCTUnwrap(config.entries.first { $0.name == "RAILS_PORT" })
        XCTAssertEqual(rails.kind, .fixed(3005))
        XCTAssertFalse(rails.isBrowser)
    }

    /// Entries are sorted so the resolved order — and therefore allocation — is
    /// stable regardless of YAML dictionary ordering.
    func testEntriesAreSortedByName() throws {
        try write("""
        ports:
          ZED_PORT:  { assigned: true }
          ALPHA_PORT: { assigned: true }
        """)

        let config = try XCTUnwrap(PortsConfig.load(from: dir.path))

        XCTAssertEqual(config.entries.map(\.name), ["ALPHA_PORT", "ZED_PORT"])
    }

    func testNoFileReturnsNil() throws {
        XCTAssertNil(try PortsConfig.load(from: dir.path))
    }

    func testRejectsEntryWithNeitherAssignedNorFixed() throws {
        try write("""
        ports:
          BFF_PORT: { browser: true }
        """)

        XCTAssertThrowsError(try PortsConfig.load(from: dir.path)) { error in
            guard case let PortsConfig.LoadError.invalidEntry(name, _) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(name, "BFF_PORT")
        }
    }

    func testRejectsEntryWithBothAssignedAndFixed() throws {
        try write("""
        ports:
          BFF_PORT: { assigned: true, fixed: 3006 }
        """)

        XCTAssertThrowsError(try PortsConfig.load(from: dir.path)) { error in
            guard case let PortsConfig.LoadError.invalidEntry(name, _) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(name, "BFF_PORT")
        }
    }

    func testRejectsMoreThanOneBrowserPort() throws {
        try write("""
        ports:
          BFF_PORT:  { assigned: true, browser: true }
          VITE_PORT: { assigned: true, browser: true }
        """)

        XCTAssertThrowsError(try PortsConfig.load(from: dir.path)) { error in
            guard case let PortsConfig.LoadError.multipleBrowserPorts(names) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(names.sorted(), ["BFF_PORT", "VITE_PORT"])
        }
    }

    /// `assigned: false` is a contradiction, not a way to opt out — say so
    /// rather than silently treating the entry as fixed-less.
    func testRejectsAssignedFalse() throws {
        try write("""
        ports:
          BFF_PORT: { assigned: false }
        """)

        XCTAssertThrowsError(try PortsConfig.load(from: dir.path))
    }

    func testRejectsMalformedYAML() throws {
        try write("ports: [this is not a map")

        XCTAssertThrowsError(try PortsConfig.load(from: dir.path)) { error in
            guard case PortsConfig.LoadError.malformed = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testAcceptsComments() throws {
        try write("""
        # the app's port
        ports:
          BFF_PORT: { assigned: true, browser: true }  # what the browser opens
        """)

        let config = try XCTUnwrap(PortsConfig.load(from: dir.path))
        XCTAssertEqual(config.entries.count, 1)
    }
}
