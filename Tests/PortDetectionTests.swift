// ABOUTME: Tests for run-script port detection and browser retargeting behavior.
// ABOUTME: Covers launcher command building, port selection stabilization, and browser navigation policy.

@testable import Atelier
import XCTest

final class PortDetectionTests: XCTestCase {
    func testRunLauncherWrapsRunScriptInLoginShell() throws {
        let workstreamID = try XCTUnwrap(UUID(uuidString: "12345678-1234-1234-1234-123456789ABC"))

        let command = runScriptCommand(
            script: "just dev",
            workstreamID: workstreamID,
            launcherPath: "/Applications/Atelier.app/Contents/Helpers/atelier-run",
            shell: "/bin/zsh"
        )

        XCTAssertEqual(
            command,
            "/Applications/Atelier.app/Contents/Helpers/atelier-run --workstream-id 12345678-1234-1234-1234-123456789abc -- /bin/zsh -lic 'just dev'"
        )
    }

    func testRunLauncherQuotesLauncherPathContainingSpaces() throws {
        let workstreamID = try XCTUnwrap(UUID(uuidString: "12345678-1234-1234-1234-123456789ABC"))

        let command = runScriptCommand(
            script: "just dev",
            workstreamID: workstreamID,
            launcherPath: "/Users/me/My Apps/Atelier.app/Contents/Helpers/atelier-run",
            shell: "/bin/zsh"
        )

        XCTAssertEqual(
            command,
            "'/Users/me/My Apps/Atelier.app/Contents/Helpers/atelier-run' --workstream-id 12345678-1234-1234-1234-123456789abc -- /bin/zsh -lic 'just dev'"
        )
    }

    func testSingleNewPortRequiresTwoPollsBeforeSelection() {
        var tracker = RunState.PortSelectionTracker(expectedPort: 40001)

        let first = tracker.update(listeningPorts: [5173])
        XCTAssertEqual(first.detectedPorts, [5173])
        XCTAssertNil(first.selectedPort)

        let second = tracker.update(listeningPorts: [5173])
        XCTAssertEqual(second.selectedPort, 5173)
    }

    func testMultiplePortsPreferExpectedPort() {
        var tracker = RunState.PortSelectionTracker(expectedPort: 40001)
        _ = tracker.update(listeningPorts: [40001, 5173])

        let second = tracker.update(listeningPorts: [40001, 5173])

        XCTAssertEqual(second.detectedPorts, [40001, 5173])
        XCTAssertEqual(second.selectedPort, 40001)
    }

    func testMultiplePortsWithoutExpectedPortDoNotAutoSelect() {
        var tracker = RunState.PortSelectionTracker(expectedPort: 40001)
        _ = tracker.update(listeningPorts: [3000, 5173])

        let second = tracker.update(listeningPorts: [3000, 5173])

        XCTAssertEqual(second.detectedPorts, [3000, 5173])
        XCTAssertNil(second.selectedPort)
    }

    func testBrowserRetargetsWhenStillOnPreviousDefaultURL() {
        XCTAssertTrue(shouldRetargetBrowser(
            currentURL: "http://localhost:40001/",
            displayedURL: "http://localhost:40001/",
            previousDefaultURL: "http://localhost:40001/",
            nextDefaultURL: "http://localhost:5173/",
            connectionError: false
        ))
    }

    func testBrowserRetargetsWhenShowingConnectionErrorForPreviousDefaultURL() {
        XCTAssertTrue(shouldRetargetBrowser(
            currentURL: nil,
            displayedURL: "http://localhost:40001/",
            previousDefaultURL: "http://localhost:40001/",
            nextDefaultURL: "http://localhost:5173/",
            connectionError: true
        ))
    }

    func testBrowserDoesNotRetargetWhenUserNavigatedElsewhere() {
        XCTAssertFalse(shouldRetargetBrowser(
            currentURL: "https://example.com/",
            displayedURL: "https://example.com/",
            previousDefaultURL: "http://localhost:40001/",
            nextDefaultURL: "http://localhost:5173/",
            connectionError: false
        ))
    }

    func testQuotesAShellPathContainingASpace() {
        // `shell` defaults to $SHELL and was interpolated raw while everything
        // around it was quoted, so a shell installed under a path with a space
        // broke the command apart.
        let command = runScriptCommand(
            script: "bun dev",
            workstreamID: UUID(),
            launcherPath: "/path/to/atelier-run",
            shell: "/Applications/My Shells/zsh"
        )

        XCTAssertTrue(
            command.contains("'/Applications/My Shells/zsh' -lic"),
            "Expected a quoted shell path, got: \(command)"
        )
    }
}
