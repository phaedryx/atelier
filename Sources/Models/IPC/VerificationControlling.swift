// ABOUTME: The seam the verification IPC tools reach the check runner through.
// ABOUTME: Declared on this side on purpose, so the tools compile and test against a stub.

import Foundation

extension IPC {
    /// What `start_verification` and `check_verification` need from the app.
    ///
    /// **This side declares it and the runner conforms**, mirroring
    /// `ProcessCompose.Controlling`: the tools then have a test seam that does
    /// not need a `verify` namespace, a process-compose binary, or a worktree,
    /// and the two halves of the feature can land in either order.
    ///
    /// Everything crossing it is an `IPC` projection rather than the runner's own
    /// `Verification.Run` — the relationship `PeerInfo` has to the store's `Peer`,
    /// and `TabInfo` to what `WorkspaceActions` reads. That keeps the mapping in
    /// one place (the runner, which owns both types) and keeps `Date`, whole suite
    /// logs and the staleness stamp off a wire an agent reads.
    ///
    /// ### The contract, beyond the signatures
    ///
    /// - **`startVerification` must return without waiting for the suite.** A real
    ///   suite outlives an MCP tool call; the run id is the answer, and the result
    ///   arrives through `onFinish` and `verificationRun(id:)`.
    /// - **It must refuse while a run is already in flight for that workstream.**
    ///   Not a nicety: `ProcessCompose.PhaseExecutor.run` calls `shutDown` at the
    ///   *top* to clear a server a killed run left behind, so a second start on the
    ///   same `<id>-verify.sock` kills the first mid-suite and strands its results.
    /// - **It must refuse rather than mint a run that cannot report.** An absent or
    ///   empty `verify` namespace, or a name in `checks` the config does not
    ///   declare, is a refusal naming what is available — not a run id whose
    ///   completion never arrives.
    /// - **Run ids are opaque, short, and unique for the app's lifetime**, not just
    ///   within a workstream: `check_verification` takes a run id and nothing else.
    /// - **`onFinish` fires exactly once per run, on every terminal path** — sealed
    ///   normally, stopped by the user, timed out, or skipped. This side guards
    ///   against a second call, but a path that never fires is a completion notice
    ///   the agent never gets.
    /// - **Approval and the rest of the preconditions are the runner's**, through
    ///   `ProcessCompose.PhasePolicy.plan`. There is deliberately no second copy
    ///   here; a refusal reaches the agent as the error this throws.
    protocol VerificationControlling: Sendable {
        /// Starts a run in `workstreamID` and returns as soon as it has an id.
        ///
        /// - Parameters:
        ///   - checks: the processes to run. **Empty means all of them**, which is
        ///     already this codebase's convention for a process selection.
        ///   - onFinish: called once, when the run reaches a terminal state, with
        ///     the same projection `verificationRun(id:)` would then return.
        func startVerification(
            workstreamID: UUID,
            checks: [String],
            onFinish: @escaping @Sendable (VerificationRunInfo) -> Void
        ) async throws -> VerificationStart

        /// A run by id, or nil when no run has that id.
        ///
        /// Nil covers both "never existed" and "was started before Atelier
        /// restarted" — runs are in-memory, like the peer store, and this side
        /// says so rather than pretending to tell the two apart.
        func verificationRun(id: String) async -> VerificationRunInfo?
    }

    /// What a start answers with: the run's id, and the checks it actually
    /// started.
    ///
    /// `started` is the *resolved* list, never the empty one that was asked for —
    /// an agent that omits `checks` still needs to see what it set running.
    struct VerificationStart: Sendable, Equatable {
        let runID: String
        let started: [String]
    }

    /// Why a verification tool could not act, on this side of the seam.
    ///
    /// Every case is something the calling agent can act on. The runner's own
    /// refusals — no `verify` namespace, no binary, unapproved config, a run
    /// already in flight — arrive as its errors and are passed through verbatim.
    enum VerificationFailure: Swift.Error, LocalizedError {
        case notAvailable
        case unknownRun(String)
        case runBelongsElsewhere

        var errorDescription: String? {
            switch self {
            case .notAvailable:
                "Verification is not available: Atelier has no check runner wired up."
            case let .unknownRun(id):
                "No verification run with id \(id). Run ids do not survive an Atelier restart — start a new run."
            case .runBelongsElsewhere:
                "That verification run belongs to a different workstream. You can only read runs in your own."
            }
        }
    }
}
