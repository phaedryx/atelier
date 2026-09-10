// ABOUTME: Tests for the hook-channel liveness probe's decision logic.
// ABOUTME: Delivery is injected, so nothing here spawns the real hook script.

@testable import Atelier
import Combine
import XCTest

@MainActor
final class HookChannelProbeTests: XCTestCase {
    /// Payloads the probe asked to have delivered, newest last.
    private var delivered: [Data] = []

    private func makeProbe() -> HookChannelProbe {
        let probe = HookChannelProbe()
        probe.deliver = { [weak self] payload in
            self?.delivered.append(payload)
        }
        return probe
    }

    override func setUp() {
        super.setUp()
        delivered = []
    }

    /// The nonce inside the most recently delivered payload.
    private func lastNonce() throws -> String {
        let payload = try XCTUnwrap(delivered.last, "the probe delivered nothing")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any],
            "the payload was not a JSON object"
        )
        XCTAssertEqual(
            json["hook_event_name"] as? String, HookEventReceiver.pingEventName,
            "the payload has to look like a hook event or the script will not carry it"
        )
        return try XCTUnwrap(json["nonce"] as? String, "the payload carried no nonce")
    }

    // MARK: - The round trip

    func test_verify_deliversAPingCarryingANonce() throws {
        let probe = makeProbe()

        probe.verify(force: true)

        XCTAssertEqual(delivered.count, 1)
        XCTAssertFalse(try lastNonce().isEmpty)
    }

    func test_theNonceComingBack_verifiesTheChannel() throws {
        let probe = makeProbe()
        let now = Date()

        probe.verify(force: true, now: now)
        try probe.noteNonce(lastNonce(), now: now)

        XCTAssertEqual(probe.state, .verified)
        XCTAssertEqual(probe.lastVerifiedAt, now)
    }

    /// A nonce from an earlier probe must not answer the current one. Without
    /// this a late reply from a check that had already given up would report the
    /// channel healthy on evidence that predates the failure.
    func test_aNonceTheProbeIsNotWaitingFor_isIgnored() {
        let probe = makeProbe()

        probe.verify(force: true)
        probe.noteNonce("some-other-nonce")

        XCTAssertEqual(probe.state, .unknown)
    }

    // MARK: - Giving up

    /// One dropped datagram is not a broken channel: `atelier-hook` posts with
    /// `curl --max-time 1`, so a single loss under load is expected and must not
    /// repaint the sidebar.
    func test_theFirstTimeout_retriesRatherThanDeclaringItDown() {
        let probe = makeProbe()

        probe.verify(force: true)
        probe.timeoutPending()

        XCTAssertEqual(delivered.count, 2, "the probe should have tried again")
        XCTAssertEqual(probe.state, .unknown, "one loss is not evidence the channel is down")
    }

    func test_theSecondTimeout_declaresTheChannelDown() {
        let probe = makeProbe()
        let downAt = Date()

        probe.verify(force: true)
        probe.timeoutPending()
        probe.timeoutPending(now: downAt)

        XCTAssertEqual(probe.state, .down)
        XCTAssertEqual(probe.downSince, downAt)
        XCTAssertEqual(delivered.count, 2, "the retry is the last attempt, not the start of a third")
    }

    /// The retry has to be answerable. It carries a fresh nonce, so the reply
    /// the probe is waiting for is the one it asked for most recently.
    func test_theRetrysNonce_verifiesTheChannel() throws {
        let probe = makeProbe()

        probe.verify(force: true)
        probe.timeoutPending()
        try probe.noteNonce(lastNonce())

        XCTAssertEqual(probe.state, .verified)
    }

    // MARK: - Not spawning more than it has to

    func test_verify_isDebouncedWithinTheMinimumInterval() {
        let probe = makeProbe()
        let start = Date()

        probe.verify(force: true, now: start)
        probe.verify(now: start.addingTimeInterval(HookChannelProbe.minimumInterval - 1))

        XCTAssertEqual(delivered.count, 1, "ten quiet rows must not mean ten spawns")
    }

    func test_verify_runsAgainOnceTheMinimumIntervalHasPassed() {
        let probe = makeProbe()
        let start = Date()

        probe.verify(force: true, now: start)
        probe.verify(now: start.addingTimeInterval(HookChannelProbe.minimumInterval + 1))

        XCTAssertEqual(delivered.count, 2)
    }

    /// Launch is the one check that always runs: it is the moment a botched
    /// install or a stale port file is most likely and most fixable.
    func test_force_ignoresTheDebounce() {
        let probe = makeProbe()
        let start = Date()

        probe.verify(force: true, now: start)
        probe.verify(force: true, now: start)

        XCTAssertEqual(delivered.count, 2)
    }

    // MARK: - Real traffic is proof too

    /// A delivered hook event is direct evidence the channel works — better
    /// evidence than a synthetic ping, and free. Nothing should be spawned to
    /// re-establish what an arriving event just demonstrated.
    func test_realTraffic_verifiesTheChannelWithoutAProbe() {
        let probe = makeProbe()
        let now = Date()

        probe.noteTraffic(now: now)

        XCTAssertEqual(probe.state, .verified)
        XCTAssertEqual(probe.lastVerifiedAt, now)
        XCTAssertTrue(delivered.isEmpty)
    }

    /// The recovery path. Without this the sidebar would keep saying No Signal
    /// until the debounce expired, despite events arriving again.
    func test_realTraffic_clearsADownChannel() {
        let probe = makeProbe()

        probe.verify(force: true)
        probe.timeoutPending()
        probe.timeoutPending()
        XCTAssertTrue(probe.state.isDown)

        probe.noteTraffic()

        XCTAssertFalse(probe.state.isDown)
    }

    /// Traffic also answers the check in flight, so the pending nonce is not
    /// left to time out and drag a healthy channel back down.
    func test_realTraffic_cancelsTheCheckInFlight() {
        let probe = makeProbe()

        probe.verify(force: true)
        probe.noteTraffic()
        probe.timeoutPending()

        XCTAssertFalse(probe.state.isDown, "a timeout for a cancelled check must not count")
        XCTAssertEqual(delivered.count, 1, "no retry was owed")
    }

    /// A verified channel can still break later.
    func test_aVerifiedChannel_canGoDownAgain() throws {
        let probe = makeProbe()
        let start = Date()

        probe.verify(force: true, now: start)
        try probe.noteNonce(lastNonce(), now: start)
        XCTAssertFalse(probe.state.isDown)

        probe.verify(force: true, now: start.addingTimeInterval(120))
        probe.timeoutPending()
        probe.timeoutPending()

        XCTAssertTrue(probe.state.isDown)
    }

    /// `noteTraffic` runs on every single hook event, so it must publish only
    /// when the channel's state actually changes. Publishing per event would
    /// invalidate the whole sidebar on every tool call.
    func test_repeatedTraffic_publishesOnlyTheTransition() {
        let probe = makeProbe()
        var publishes = 0
        let token = probe.objectWillChange.sink { _ in publishes += 1 }
        defer { token.cancel() }

        probe.noteTraffic()
        XCTAssertEqual(publishes, 1, "the first event is a real transition out of .unknown")

        for _ in 0 ..< 20 {
            probe.noteTraffic()
        }

        XCTAssertEqual(publishes, 1, "a channel already known to be up has not changed")
    }

    /// A timeout with nothing outstanding is not evidence of anything.
    func test_aTimeoutWithNoCheckInFlight_changesNothing() {
        let probe = makeProbe()

        probe.timeoutPending()

        XCTAssertEqual(probe.state, .unknown)
        XCTAssertTrue(delivered.isEmpty)
    }
}
