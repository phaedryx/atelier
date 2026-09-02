// ABOUTME: Tests for the Environment process table's selection storage and port matching.
// ABOUTME: Polling and control are exercised against a real binary by hand.

@testable import Atelier
import XCTest

final class ProcessTableModelTests: XCTestCase {
    /// Random per instance, so these never collide with a real workstream's
    /// selection in the test host's own defaults domain.
    private let workstreamID = UUID()

    override func tearDown() {
        ProcessTableModel.setSelected([], for: workstreamID)
        super.tearDown()
    }

    /// No stored selection means everything runs — a fresh workstream should
    /// start the whole stack, not nothing.
    func testNoSelectionMeansAll() {
        XCTAssertTrue(ProcessTableModel.selected(for: workstreamID).isEmpty)
    }

    func testSelectionRoundTrips() {
        ProcessTableModel.setSelected(["bff", "api"], for: workstreamID)

        XCTAssertEqual(ProcessTableModel.selected(for: workstreamID).sorted(), ["api", "bff"])
    }

    func testSelectionIsPerWorkstream() {
        let other = UUID()
        defer { ProcessTableModel.setSelected([], for: other) }
        ProcessTableModel.setSelected(["bff"], for: workstreamID)
        ProcessTableModel.setSelected(["api"], for: other)

        XCTAssertEqual(ProcessTableModel.selected(for: workstreamID), ["bff"])
        XCTAssertEqual(ProcessTableModel.selected(for: other), ["api"])
    }

    func testClearingSelectionRemovesIt() {
        ProcessTableModel.setSelected(["bff"], for: workstreamID)
        ProcessTableModel.setSelected([], for: workstreamID)

        XCTAssertTrue(ProcessTableModel.selected(for: workstreamID).isEmpty)
    }

    // MARK: - Port matching

    func testPortMatchesTheVariableNamedAfterTheProcess() {
        XCTAssertEqual(ProcessTableModel.port(for: "bff", in: ["BFF_PORT": "4001"]), "4001")
    }

    /// Separators differ freely between a process name and a variable name.
    func testPortMatchIgnoresSeparatorsAndCase() {
        let ports = ["HTML_TO_JSON_PORT": "4002"]

        XCTAssertEqual(ProcessTableModel.port(for: "html-to-json", in: ports), "4002")
        XCTAssertEqual(ProcessTableModel.port(for: "HTML_TO_JSON", in: ports), "4002")
        XCTAssertEqual(ProcessTableModel.port(for: "htmltojson", in: ports), "4002")
    }

    /// The `_PORT` suffix is optional on the variable, not required.
    func testPortMatchesAVariableWithoutTheSuffix() {
        XCTAssertEqual(ProcessTableModel.port(for: "bff", in: ["BFF": "4001"]), "4001")
    }

    /// An exact name match beats one that only matches after the suffix is
    /// allowed for, so a process actually called `bffport` gets its own value.
    func testExactMatchWinsOverSuffixMatch() {
        let ports = ["BFF_PORT": "4001", "BFF_PORT_PORT": "4002"]

        XCTAssertEqual(ProcessTableModel.port(for: "bff_port", in: ports), "4001")
    }

    func testUnmatchedProcessHasNoPort() {
        XCTAssertNil(ProcessTableModel.port(for: "worker", in: ["BFF_PORT": "4001"]))
    }

    /// A variable named only `PORT` must not become a wildcard that every
    /// process matches once the suffix is stripped.
    func testBarePortVariableMatchesNothing() {
        XCTAssertNil(ProcessTableModel.port(for: "bff", in: ["PORT": "3000"]))
    }

    /// Two variables can normalize to the same key. The lowest variable name
    /// wins, so the column is stable rather than showing whichever way the
    /// dictionary happened to iterate.
    func testCollidingVariablesResolveByLowestName() throws {
        let ports = ["BFF_PORT": "4001", "BFFPORT": "4002"]

        XCTAssertEqual(ProcessTableModel.port(for: "bff", in: ports), try ports[XCTUnwrap(ports.keys.min())])
        XCTAssertEqual(ProcessTableModel.port(for: "bff", in: ports), "4002")
    }
}
