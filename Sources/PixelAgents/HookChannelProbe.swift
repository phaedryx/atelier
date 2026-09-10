// ABOUTME: Verifies that Claude Code hook events can still reach the app, by
// ABOUTME: sending a nonce through the real atelier-hook script and back.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "hook-channel")

/// Answers one question the rest of the app cannot: **are hook events still
/// arriving at all?**
///
/// Every other signal Atelier has about an agent is an *absence* — no
/// `PreToolUse`, no `Stop`, nothing for 45 seconds — and a broken delivery path
/// produces exactly the same absence as an agent thinking hard. `atelier-hook`
/// posts with `curl --max-time 1`, discards curl's output and exit status, and
/// returns 0 when the port file is missing, so every channel failure is silent
/// by construction: an app that quit and relaunched on a new port, a port file
/// removed, hook entries a different Atelier install rewrote, or a POST that
/// simply took longer than a second under load.
///
/// So the probe does not reason about silence. It sends a real payload through
/// the real script and waits for the nonce to come back out of
/// `HookEventReceiver`. A nonce that returns has proved the whole path — port
/// file, curl, its timeout, the listener, the parser — end to end. Nothing else
/// in the app can establish that.
@MainActor
final class HookChannelProbe: ObservableObject {
    static let shared = HookChannelProbe()

    /// What the app knows about the delivery path.
    ///
    /// `.unknown` is not a failure and must not be rendered as one: at launch,
    /// before the first check answers, nothing has gone wrong yet.
    ///
    /// Carries no timestamps, deliberately. This is `@Published` and every
    /// arriving hook event re-verifies the channel, so a date in here would
    /// publish a change on every tool call and invalidate the whole sidebar
    /// each time. The timestamps live beside it, unpublished.
    enum State: Equatable {
        case unknown
        case verified
        case down

        var isDown: Bool {
            self == .down
        }
    }

    @Published private(set) var state: State = .unknown

    /// When the channel was last shown to be delivering, by a ping or by a real
    /// event. Not published — see `State`.
    private(set) var lastVerifiedAt: Date?

    /// When the channel was given up on. Not published — see `State`.
    private(set) var downSince: Date?

    /// Shortest gap between two checks. Ten workstreams falling quiet together
    /// is one question about the channel, not ten.
    static let minimumInterval: TimeInterval = 60

    /// How long a ping may be outstanding before it counts as lost. Generous
    /// against the script's own one-second curl deadline, since the round trip
    /// also includes a process spawn.
    static let responseTimeout: TimeInterval = 5

    /// Attempts before the channel is called down. Two, because a single loss is
    /// expected: the script's `curl --max-time 1` drops a slow POST on the
    /// floor, and one dropped ping must not repaint the sidebar.
    static let attemptLimit = 2

    /// Delivers one ping payload on the app's behalf, by writing it to
    /// `atelier-hook`'s stdin exactly as Claude Code would.
    ///
    /// Injectable so the decision logic above can be tested without spawning a
    /// process — and without a test posting to whatever Atelier owns the shared
    /// port file, which is the hazard `HookEventReceiver.writePortFile`
    /// documents at length.
    lazy var deliver: (Data) -> Void = { [weak self] payload in
        self?.spawnHookScript(payload: payload)
    }

    private struct Attempt {
        let nonce: String
        let startedAt: Date
        let number: Int
    }

    private var outstanding: Attempt?
    private var lastCheckStartedAt: Date?

    init() {}

    // MARK: - Checking

    /// Sends a ping, unless one went out within `minimumInterval`.
    ///
    /// `force` is for launch, where the answer is wanted regardless of when the
    /// last check happened — a botched install or a stale port file is most
    /// likely and most fixable there.
    func verify(force: Bool = false, now: Date = Date()) {
        if !force, let last = lastCheckStartedAt, now.timeIntervalSince(last) < Self.minimumInterval {
            return
        }
        lastCheckStartedAt = now
        send(attempt: 1, now: now)
    }

    /// Records that the nonce of the outstanding ping came back.
    ///
    /// A nonce the probe is not waiting for is discarded rather than treated as
    /// good news: a late reply from a check that already gave up would otherwise
    /// report the channel healthy on evidence that predates the failure.
    func noteNonce(_ nonce: String, now: Date = Date()) {
        guard let outstanding, outstanding.nonce == nonce else { return }
        self.outstanding = nil
        logger.info("Hook channel verified in \(now.timeIntervalSince(outstanding.startedAt), privacy: .public)s")
        markVerified(now: now)
    }

    /// Records that a genuine hook event arrived.
    ///
    /// Stronger evidence than a ping and free, so it short-circuits everything:
    /// an event that was delivered proves delivery works. It also cancels any
    /// check in flight, which is what stops a healthy channel being dragged back
    /// down by the timeout of a ping whose answer had already been overtaken by
    /// real traffic — and what clears `.down` the moment events resume, rather
    /// than at the end of the debounce.
    func noteTraffic(now: Date = Date()) {
        outstanding = nil
        markVerified(now: now)
    }

    /// Records a verification, publishing only on an actual transition.
    ///
    /// `noteTraffic` runs on **every** hook event, so an unconditional
    /// assignment here would publish a change per tool call and redraw the
    /// sidebar with it.
    private func markVerified(now: Date) {
        lastVerifiedAt = now
        downSince = nil
        guard state != .verified else { return }
        state = .verified
    }

    /// Gives up on the outstanding ping: retries once, then calls the channel
    /// down.
    ///
    /// Internal rather than private so tests drive the deadline directly. In the
    /// app it is scheduled `responseTimeout` after each send.
    func timeoutPending(now: Date = Date()) {
        guard let attempt = outstanding else { return }
        outstanding = nil
        guard attempt.number >= Self.attemptLimit else {
            logger.info("Hook channel ping \(attempt.number, privacy: .public) went unanswered; retrying")
            send(attempt: attempt.number + 1, now: now)
            return
        }
        logger.warning("Hook channel is not delivering events; \(Self.attemptLimit, privacy: .public) pings unanswered")
        downSince = now
        state = .down
    }

    private func send(attempt: Int, now: Date) {
        let nonce = UUID().uuidString
        outstanding = Attempt(nonce: nonce, startedAt: now, number: attempt)

        // Shaped like a Claude Code hook payload because that is what the script
        // forwards: it wraps whatever arrives on stdin as the envelope's
        // `event_input` without inspecting it.
        let body: [String: Any] = [
            "hook_event_name": HookEventReceiver.pingEventName,
            "nonce": nonce,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        deliver(payload)
        scheduleTimeout(for: nonce)
    }

    /// Arms the deadline for one attempt. Skipped under XCTest, where the suite
    /// calls `timeoutPending` itself: a real timer would fire seconds after the
    /// test that armed it had finished.
    private func scheduleTimeout(for nonce: String) {
        guard !isRunningXCTest() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.responseTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.outstanding?.nonce == nonce else { return }
                self.timeoutPending()
            }
        }
    }

    // MARK: - Delivery

    /// Runs the bundled `atelier-hook` with the payload on its stdin — the same
    /// entry point, reading the same port file, that every Claude Code session
    /// uses. Calling the listener directly would prove only that the app can
    /// reach itself, which was never in doubt.
    private func spawnHookScript(payload: Data) {
        guard let script = Self.hookScriptPath else {
            logger.warning("No bundled atelier-hook to probe with")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            // The exit status is deliberately ignored, and would be useless
            // anyway: the script swallows curl's status and returns 0 whether
            // the POST landed, was refused, or was never attempted for want of
            // a port file. That silence is the reason this type exists. The
            // only answer that counts is the nonce arriving back at
            // `HookEventReceiver`.
            //
            // `local`: the script's own `curl --max-time 1` bounds the work,
            // and nothing here scales with the user's repository.
            ProcessRunner.succeeds(
                executable: "/bin/sh",
                arguments: [script],
                standardInput: payload,
                timeout: ProcessRunner.Timeout.local
            )
        }
    }

    /// Where the hook script lives inside the app bundle. Both lookups match
    /// `AtelierApp`'s, which installs whichever it finds.
    static var hookScriptPath: String? {
        Bundle.main.url(forResource: "atelier-hook", withExtension: nil, subdirectory: "Scripts")?.path
            ?? Bundle.main.url(forResource: "atelier-hook", withExtension: nil)?.path
    }
}
