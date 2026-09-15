// ABOUTME: The seam the verification IPC tools reach the check runner through.
// ABOUTME: Declared on this side on purpose, so the tools compile and test against a stub.

import Foundation

extension IPC {
    /// What `start_verification`, `check_verification` and
    /// `list_verification_checks` need from the app.
    ///
    /// **This side declares it and the runner conforms**, mirroring
    /// `ProcessCompose.Controlling`: the tools then have a test seam that does
    /// not need a `verification.yaml`, a shell, or a worktree, and the two
    /// halves of the feature can land in either order.
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
    /// - **It must refuse a check that is already running — per check, not per
    ///   workstream, and not the whole call.** Checks are independent and two
    ///   *different* ones at once is the design, so the refusal is scoped to the
    ///   one name: a second start of a live check would replace its terminal
    ///   surface and strand the first. A call naming a live check and an idle one
    ///   starts the idle one and reports the other on `VerificationStart.refused`;
    ///   only a call with *nothing* left to start throws. Refusing the whole call
    ///   would make `checks: []` — which means all of them — fail outright whenever
    ///   a single check happened to be going.
    /// - **It must refuse rather than mint a run that cannot report.** No
    ///   `verification.yaml`, one that will not parse, one declaring nothing, or a
    ///   name in `checks` the config does not declare — each is a refusal naming
    ///   what is available, not a run id whose completion never arrives.
    /// - **Run ids are opaque, short, and unique for the app's lifetime**, not just
    ///   within a workstream: `check_verification` takes a run id and nothing else.
    /// - **`onFinish` fires exactly once per run, on every terminal path** — sealed
    ///   normally, stopped, timed out, or skipped. It is now the *run-level*
    ///   notice only, and the service posts it only for a run that completed
    ///   nothing.
    /// - **Every check completion is announced through `observeCheckCompletions`,
    ///   exactly once.** A path that records a completion without announcing it
    ///   is a notice the agent never gets.
    /// - **The preconditions are the runner's**, through the three cases of
    ///   `Verification.Config.Load`. There is deliberately no second copy here,
    ///   and no approval gate anywhere: `verification.yaml` lives in the project
    ///   directory, outside every work tree, so it cannot have arrived with the
    ///   repository. A refusal reaches the agent as the error this throws.
    protocol VerificationControlling: Sendable {
        /// Starts a run in `workstreamID` and returns as soon as it has an id.
        ///
        /// - Parameters:
        ///   - checks: the processes to run. **Empty means all of them**, which is
        ///     already this codebase's convention for a process selection.
        ///   - requesterSurfaceID: the surface of the agent asking, so its own
        ///     run's notices come back to it. Nil for a caller Atelier did not
        ///     launch.
        ///   - onFinish: called once, when the run reaches a terminal state, with
        ///     the same projection `verificationRun(id:)` would then return.
        func startVerification(
            workstreamID: UUID,
            checks: [String],
            requesterSurfaceID: String?,
            onFinish: @escaping @Sendable (VerificationRunInfo) -> Void
        ) async throws -> VerificationStart

        /// What `verification.yaml` declares for the project `workstreamID`
        /// belongs to, without running anything.
        ///
        /// **The three load cases must stay distinguishable.** `.missing`,
        /// `.invalid` and a file declaring zero checks all yield an empty list,
        /// and telling an agent "this project declares no checks" for the middle
        /// one sends it looking for a file that is right there and broken. The
        /// answer therefore carries `Load.unavailableReason` alongside the list,
        /// rather than a bare array or a throw.
        ///
        /// Throws only when the workstream cannot be resolved to a project at
        /// all — the same `WorkspaceActions` failure a start throws.
        func verificationChecks(in workstreamID: UUID) async throws -> VerificationChecksInfo

        /// A run by id within one workstream, or nil when that workstream has
        /// no run with that id.
        ///
        /// **Scoped by workstream because only a workstream can be looked up
        /// after a restart.** Live runs are in memory and findable by id alone,
        /// but the only one that outlives a restart is a workstream's most
        /// recent — kept because the staleness stamp needs it — and it is stored
        /// under that workstream's key. Handed only an id, this could answer
        /// about a live run and then lie about every older one by saying it
        /// never existed. The caller's scoping is not what this parameter is
        /// for; `IPC.Service` does that itself, against the run it gets back.
        func verificationRun(id: String, in workstreamID: UUID) async -> VerificationRunInfo?

        /// Observe every check completion the app performs, in every workstream.
        ///
        /// **Not per run.** A run the user pressed produces notices too — that is what
        /// makes the agent aware of checks its human ran — so the handler is installed once
        /// and each notice says who, if anyone, asked for its run. One handler: installing
        /// a second replaces the first, the same single-slot constraint `Runner.onFinish`
        /// carries.
        @MainActor
        func observeCheckCompletions(_ handler: @escaping @MainActor @Sendable (VerificationCheckNotice) -> Void)
    }

    /// One check's completion, addressed.
    ///
    /// Carries `requesterSurfaceID` rather than a resolved peer for the reason
    /// `postVerificationNotice` resolves at delivery time: a helper whose old socket has
    /// not closed re-registers under a new peer id, so an id captured when the run started
    /// can be dead while its pane has an agent sitting in it. Nil means no agent asked for
    /// this run — the user pressed Run — and the service addresses the workstream's Coding
    /// Agent surface instead.
    struct VerificationCheckNotice: Sendable, Equatable {
        let runID: String
        let workstreamID: String
        let requesterSurfaceID: String?
        let check: VerificationCheckInfo
    }

    /// What a start answers with: the run's id, and the checks it actually
    /// started.
    ///
    /// `started` is the *resolved* list, never the empty one that was asked for —
    /// an agent that omits `checks` still needs to see what it set running. It is
    /// also never *empty*: a start with nothing left to start is refused rather
    /// than minted.
    ///
    /// `refused` is the names that were already running, and it is reported here
    /// and nowhere else. It is deliberately **not** on `VerificationRunInfo`: none
    /// of the seven check states honestly describes "not part of this run", and a
    /// refused check's own completion notice carries the *earlier* run's id — so
    /// this answer is the only place an agent can be told, and it has to say that
    /// those verdicts will not arrive under this run id.
    struct VerificationStart: Sendable, Equatable {
        let runID: String
        let started: [String]
        let refused: [String]
    }

    /// Why a verification tool could not act, on this side of the seam.
    ///
    /// Every case is something the calling agent can act on. The runner's own
    /// refusals — no `verification.yaml`, one that will not parse or declares
    /// nothing, an undeclared check name, a check already running — arrive as its
    /// errors and are passed through verbatim.
    enum VerificationFailure: Swift.Error, LocalizedError {
        case notAvailable
        case unknownRun(String)
        case runBelongsElsewhere

        var errorDescription: String? {
            switch self {
            case .notAvailable:
                "Verification is not available: Atelier has no check runner wired up."
            case let .unknownRun(id):
                "No verification run with id \(id). Only a workstream's most recent run survives an Atelier restart; "
                    + "older ids are gone. Start a new run."
            case .runBelongsElsewhere:
                "That verification run belongs to a different workstream. You can only read runs in your own."
            }
        }
    }
}
