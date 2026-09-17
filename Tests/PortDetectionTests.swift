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

    /// The reported bug: a `ports.yaml` with several named ports (none of them
    /// `ATELIER_PORT`) never lets `PortSelectionTracker` resolve a `selectedPort`,
    /// so `status` sits at `.starting` forever even once the declared `browser:
    /// true` port is genuinely listening. A known browser port must be judged on
    /// its own liveness instead.
    func testKnownBrowserPortStopsWaitingOnceItIsAmongDetectedPorts() {
        XCTAssertFalse(Port.isWaitingForServer(
            browserPort: 44449,
            browserPortIsFixed: false,
            status: .starting,
            detectedPorts: [42935, 43625, 44449, 44542, 46759],
            browserStartPending: false
        ))
    }

    func testKnownBrowserPortKeepsWaitingUntilItIsDetected() {
        XCTAssertTrue(Port.isWaitingForServer(
            browserPort: 44449,
            browserPortIsFixed: false,
            status: .starting,
            detectedPorts: [42935, 43625],
            browserStartPending: false
        ))
    }

    /// Every other "stops waiting" case above uses `status: .starting`. This is the
    /// `.running` counterpart of `testKnownBrowserPortStopsWaitingOnceItIsAmongDetectedPorts`
    /// — the combination the PR #167 review flagged as untested. Passes today because the
    /// non-nil-`browserPort` branch of `isWaitingForServer` never actually consults `status`
    /// beyond `.none` (see `PortDetector.swift`): `.starting` and `.running` both fall through
    /// to `!detectedPorts.contains(browserPort)`.
    func testKnownBrowserPortStopsWaitingWhenRunningAndPortIsDetected() {
        XCTAssertFalse(Port.isWaitingForServer(
            browserPort: 44449,
            status: .running,
            detectedPorts: [42935, 43625, 44449, 44542, 46759],
            browserStartPending: false
        ))
    }

    /// KNOWN FAILURE against `main` — pins the exact regression flagged in code review: a
    /// declared `browser: true` port that is absent from `detectedPorts` (a `fixed:` port
    /// per `ports.yaml` bound somewhere the launcher's scan never observes it is one way
    /// this happens) leaves `isWaitingForServer`'s non-nil-`browserPort` branch asking only
    /// `!detectedPorts.contains(browserPort)` — true forever, even once `status` reaches
    /// `.running` — so the browser pane hangs on "Starting dev server…" indefinitely while
    /// the server is actually up.
    ///
    /// This asserts the *correct* behavior (a `.running` session should stop waiting on its
    /// own known port), not what `PortDetector.swift` currently returns. The `fix-browser-port-hang`
    /// workstream owns the actual fix; expect this case to start passing once that lands,
    /// with no change needed here — do not "fix" this test by asserting the buggy `true`.
    func testKnownBrowserPortStopsWaitingWhenRunningEvenIfFixedPortWasNeverDetected() {
        XCTAssertFalse(Port.isWaitingForServer(
            browserPort: 4000,
            status: .running,
            detectedPorts: [5173],
            browserStartPending: false
        ))
    }

    func testKnownBrowserPortWaitsOnBrowserStartPendingBeforeAnySessionExists() {
        XCTAssertTrue(Port.isWaitingForServer(
            browserPort: 44449,
            browserPortIsFixed: false,
            status: .none,
            detectedPorts: [],
            browserStartPending: true
        ))

        XCTAssertFalse(Port.isWaitingForServer(
            browserPort: 44449,
            browserPortIsFixed: false,
            status: .none,
            detectedPorts: [],
            browserStartPending: false
        ))
    }

    /// A declared but not-yet-detected browser port must not hang forever just
    /// because a *sibling* port came up first and let `PortSelectionTracker`
    /// resolve a `selectedPort` (`status == .running`) — reachable when the
    /// browser's own server crashed or never bound while another declared
    /// process started fine. Once the launcher has resolved anything at all,
    /// further waiting can never be justified by more detection: either the
    /// browser port shows up (and this branch is moot) or it never will, and
    /// only `BrowserView`'s own connection-error/retry UI can tell those apart.
    func testKnownBrowserPortStopsWaitingOnceStatusIsRunningEvenIfNeverDetected() {
        XCTAssertFalse(Port.isWaitingForServer(
            browserPort: 44449,
            browserPortIsFixed: false,
            status: .running,
            detectedPorts: [42935],
            browserStartPending: false
        ))
    }

    /// A `fixed` browser port (ports.yaml, `fixed: <port>`) exists precisely for
    /// values registered off the machine — a Docker-forwarded port, a service
    /// nothing in the launched command's own process tree binds — so it can
    /// never appear in `detectedPorts`, which comes from `atelier-run` scanning
    /// only that tree via libproc. There is therefore no status past `.none`
    /// that detection could ever resolve for it, including `.starting`: a
    /// fixed browser port is typically declared alongside several `assigned`
    /// siblings (that's the whole reason it needs pinning), and per PR #167's
    /// own bug, `status` can sit at `.starting` forever for a multi-port stack.
    /// A fixed browser port must therefore stop waiting the moment any session
    /// exists at all, leaving `BrowserView`'s connection-error/retry UI to
    /// judge its actual liveness.
    func testFixedBrowserPortNeverWaitsOnceASessionExists() {
        XCTAssertFalse(Port.isWaitingForServer(
            browserPort: 4000,
            browserPortIsFixed: true,
            status: .starting,
            detectedPorts: [42935, 43625],
            browserStartPending: false
        ))
        XCTAssertFalse(Port.isWaitingForServer(
            browserPort: 4000,
            browserPortIsFixed: true,
            status: .running,
            detectedPorts: [42935, 43625],
            browserStartPending: false
        ))
    }

    func testFixedBrowserPortWaitsOnBrowserStartPendingBeforeAnySessionExists() {
        XCTAssertTrue(Port.isWaitingForServer(
            browserPort: 4000,
            browserPortIsFixed: true,
            status: .none,
            detectedPorts: [],
            browserStartPending: true
        ))

        XCTAssertFalse(Port.isWaitingForServer(
            browserPort: 4000,
            browserPortIsFixed: true,
            status: .none,
            detectedPorts: [],
            browserStartPending: false
        ))
    }

    /// With no declared browser port, behavior is unchanged: waiting follows
    /// `status` and `browserStartPending` exactly as before.
    func testWithNoBrowserPortWaitingStillFollowsStatus() {
        XCTAssertTrue(Port.isWaitingForServer(
            browserPort: nil,
            browserPortIsFixed: false,
            status: .starting,
            detectedPorts: [3000, 5173],
            browserStartPending: false
        ))
        XCTAssertFalse(Port.isWaitingForServer(
            browserPort: nil,
            browserPortIsFixed: false,
            status: .running,
            detectedPorts: [5173],
            browserStartPending: false
        ))
        XCTAssertTrue(Port.isWaitingForServer(
            browserPort: nil,
            browserPortIsFixed: false,
            status: .none,
            detectedPorts: [],
            browserStartPending: true
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
