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

    // MARK: - Validation

    func testAFixedPortAboveTheValidRangeIsRejected() throws {
        try write("ports:\n  API_PORT: { fixed: 70000 }")

        XCTAssertThrowsError(try PortsConfig.load(from: dir.path)) { error in
            guard case let .invalidEntry(name, reason) = error as? PortsConfig.LoadError else {
                return XCTFail("expected invalidEntry, got \(error)")
            }
            XCTAssertEqual(name, "API_PORT")
            XCTAssertTrue(reason.contains("65535"), reason)
        }
    }

    func testAFixedPortBelowTheValidRangeIsRejected() throws {
        for port in ["0", "-1"] {
            try write("ports:\n  API_PORT: { fixed: \(port) }")

            XCTAssertThrowsError(try PortsConfig.load(from: dir.path), "fixed: \(port) must be refused")
        }
    }

    func testTheEdgesOfTheValidRangeAreAccepted() throws {
        for port in [1, 65535] {
            try write("ports:\n  API_PORT: { fixed: \(port) }")

            let config = try XCTUnwrap(try PortsConfig.load(from: dir.path))
            XCTAssertEqual(config.entries.first?.kind, .fixed(port))
        }
    }

    /// `Workstream.Environment` merges declarations over the `ATELIER_*` set, so
    /// without this a declaration could replace a path with a port number in
    /// every namespace, and the `FF_*` mirror would carry the wrong value too.
    func testADeclarationCannotShadowAPathAtelierSets() throws {
        for name in ["ATELIER_WORKTREE_DIR", "ATELIER_PROJECT_DIR", "ATELIER_DEFAULT_BRANCH"] {
            try write("ports:\n  \(name): { assigned: true }")

            XCTAssertThrowsError(try PortsConfig.load(from: dir.path), "\(name) must be refused") { error in
                guard case let .invalidEntry(rejected, _) = error as? PortsConfig.LoadError else {
                    return XCTFail("expected invalidEntry for \(name), got \(error)")
                }
                XCTAssertEqual(rejected, name)
            }
        }
    }

    /// The one documented exception: a project may say what `ATELIER_PORT`
    /// means for it.
    func testATELIERPortMayStillBeDeclared() throws {
        try write("ports:\n  ATELIER_PORT: { assigned: true }")

        let config = try XCTUnwrap(try PortsConfig.load(from: dir.path))
        XCTAssertEqual(config.entries.map(\.name), ["ATELIER_PORT"])
    }

    func testAnFFDeclarationIsRejected() throws {
        try write("ports:\n  FF_PORT: { assigned: true }")

        XCTAssertThrowsError(try PortsConfig.load(from: dir.path))
    }

    /// `ports.yaml` names become environment variable names and reach `sh -c`
    /// through `TmuxSession.wrapCommand`, which escapes values and not keys.
    /// The file is repository content in an ordinary clone and has no approval
    /// gate, so this is the gate.
    func testANameThatIsNotAUsableVariableNameIsRejected() throws {
        for name in ["BFF PORT", "BFF\"PORT", "BFF$(id)", "1PORT", "BFF-PORT", "PORT;echo"] {
            try write("ports:\n  \"\(name)\": { assigned: true }")

            XCTAssertThrowsError(
                try PortsConfig.load(from: dir.path),
                "\(name) must be refused"
            )
        }
    }

    func testOrdinaryVariableNamesAreStillAccepted() throws {
        try write("ports:\n  BFF_PORT: { assigned: true }\n  _PRIVATE2: { fixed: 3005 }")

        let config = try XCTUnwrap(PortsConfig.load(from: dir.path))

        XCTAssertEqual(config.entries.map(\.name), ["BFF_PORT", "_PRIVATE2"])
    }

    /// Two names pinned to one port cannot both bind; every other
    /// self-contradiction here is refused, so this one is too.
    func testTwoNamesPinningTheSamePortAreRejected() throws {
        try write("ports:\n  A_PORT: { fixed: 3005 }\n  B_PORT: { fixed: 3005 }")

        XCTAssertThrowsError(try PortsConfig.load(from: dir.path)) { error in
            guard case let .invalidEntry(_, reason) = error as? PortsConfig.LoadError else {
                return XCTFail("expected invalidEntry, got \(error)")
            }
            XCTAssertTrue(reason.contains("3005"), reason)
        }
    }

    func testDistinctFixedPortsAreFine() throws {
        try write("ports:\n  A_PORT: { fixed: 3005 }\n  B_PORT: { fixed: 3006 }")

        XCTAssertNoThrow(try PortsConfig.load(from: dir.path))
    }

    /// All six, not the three the previous version looped over: removing any
    /// one from `reservedNames` must fail this.
    func testEveryNameAtelierSetsIsReserved() throws {
        for name in [
            "ATELIER_WORKSTREAM_ID", "ATELIER_PROJECT", "ATELIER_WORKSTREAM",
            "ATELIER_PROJECT_DIR", "ATELIER_WORKTREE_DIR", "ATELIER_DEFAULT_BRANCH",
        ] {
            try write("ports:\n  \(name): { assigned: true }")

            XCTAssertThrowsError(try PortsConfig.load(from: dir.path), "\(name) must be refused")
        }
    }
}
