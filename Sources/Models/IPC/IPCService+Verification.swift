// ABOUTME: IPC.Service's verification tools, over the IPC.VerificationControlling seam.
// ABOUTME: Starts and reads runs, and posts each check's verdict into an agent's inbox.

import Foundation

extension IPC.Service {
    // MARK: - Verification

    /// Answers what the project declares in `verification.yaml`, running
    /// nothing.
    ///
    /// **This is the only way an agent can learn a check's name.** The file
    /// lives in the project directory, outside every work tree, and the
    /// "Restrict to worktree" system prompt is on by default — so before this
    /// existed a name could only be found by guessing one and reading
    /// `start_verification`'s refusal.
    func listVerificationChecks(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        guard let runner = verification else {
            return .failure(id: request.id, VerificationFailure.notAvailable.localizedDescription)
        }
        do {
            return try await .success(id: request.id, .verificationChecks(runner.verificationChecks(in: workstreamID)))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    /// Starts a verification run in the caller's own workstream and answers
    /// with its run id.
    ///
    /// **The answer is the id, not the result.** A real suite runs for
    /// minutes and an MCP tool call does not, so the result arrives two other
    /// ways: a notice posted into this agent's inbox as each check finishes
    /// (`postCheckNotice`, fired from `observeVerificationChecks`), and
    /// `check_verification` for an agent that never reads its inbox. A run
    /// that finishes having completed nothing gets one notice instead, since
    /// there is no per-check completion to have announced it.
    ///
    /// Nothing here decides whether the run is *allowed*. The preconditions
    /// are `Verification.Config.Load`'s own three cases — no file, a file that
    /// will not parse, a file declaring nothing — and `Verification.Runner.start`
    /// asks them behind the seam, deliberately the only copy. There is no
    /// approval gate to re-check: `verification.yaml` lives in the project
    /// directory, outside every work tree, so it cannot have arrived with the
    /// repository. A refusal arrives as the runner's error and is passed through
    /// verbatim.
    func startVerification(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        guard let runner = verification else {
            return .failure(id: request.id, VerificationFailure.notAvailable.localizedDescription)
        }

        let checks = ToolArguments(request).list("checks")
        // The caller is addressed by surface, never by workstream: two agents
        // in one worktree report the same workstream name, and a notice
        // addressed by workstream would land in the wrong pane's inbox half
        // the time.
        //
        // Parsed once and threaded through as its own string, rather than handing the
        // runner `request.client.surfaceID` raw: a non-UUID surface id would otherwise
        // be routed on the parsed (nil-safe) value here while the runner stored the raw
        // string as `requesterSurfaceID`, so the two disagreed about whether a requester
        // was known at all.
        let surfaceID = request.client.surfaceID.flatMap(UUID.init(uuidString:))

        let delivery = UUID()
        let target = surfaceID ?? workstreamID
        let onFinish: @Sendable (VerificationRunInfo) -> Void = { [weak self] info in
            // **Only for a run that completed nothing.** Every check that reaches a
            // terminal state posts its own notice, so a normal run's result has already
            // arrived check by check and a summary on top would be a second telling.
            //
            // A run that completed nothing is the case that would otherwise be silent,
            // and it must never read as a pass: `up -n` on an empty namespace never
            // exits so `PhaseExecutor` returns `.skipped` without spawning; an
            // undecodable config declares no processes at all; and a spawn that dies
            // before binding leaves every row `.notRun`. In all three, "0 of 0 failed"
            // is both true and a green suite.
            //
            // **A stopped run is excluded**, and it is not the same case. Stopping
            // before any check started also seals every row `.notRun`, but the user
            // caused that deliberately and knows it happened — the notice exists to
            // break a silence, not to report an action back to the person who took it.
            guard info.state != .stopped,
                  info.checks.allSatisfy({ $0.state == .notRun })
            else { return }
            Task { await self?.postVerificationNotice(info, to: target, delivery: delivery) }
        }

        do {
            let start = try await runner.startVerification(
                workstreamID: workstreamID,
                checks: checks,
                requesterSurfaceID: surfaceID?.uuidString,
                onFinish: onFinish
            )
            return .success(id: request.id, .text(startAnswer(for: start, deliverable: surfaceID != nil)))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    /// What an agent is told when a run starts. Says where the results will appear,
    /// because the one thing it must not do is wait here.
    ///
    /// **`deliverable` distinguishes whose inbox, not whether anything is posted.**
    /// `onFinish` and `postCheckNotice` both fall back to the workstream's Coding Agent
    /// surface when the caller's own surface id is unknown, so a notice always has a
    /// target — but for a caller Atelier did not launch, that target is not this
    /// caller's own pane. Telling such a caller to check its inbox would be a claim
    /// about a pane it may not be sitting in, so the honest answer names the fallback
    /// instead and points at `check_verification`.
    private nonisolated func startAnswer(for start: VerificationStart, deliverable: Bool) -> String {
        // `started` is the *resolved* list and is never empty — an agent that
        // omitted `checks` still needs to see what it set running, and a start
        // that would resolve to nothing is refused rather than minted. That
        // still holds now a start is partial: a call with every name already
        // running throws `alreadyRunning` and never reaches this.
        let names = start.started.joined(separator: ", ")
        let delivery = deliverable
            ? "Each check posts its own verdict to your inbox from \(VerificationSummary.sender) as it finishes — "
            + "receive_messages to read them, and remember delivery is a pull, so check at your next natural boundary."
            : "Nothing will be posted to your inbox: Atelier does not know which terminal you are running in. "
            + "check_verification is how you read this run."
        // **Said, not implied.** A refused check's verdict is posted under the
        // run that started it, so it will never arrive under this run id and
        // `check_verification` on this run will never list it. An agent told
        // only "refused: rspec" would sit waiting for a notice that cannot
        // come — the same silence the run-level notice exists to break.
        let refusals = start.refused.isEmpty
            ? ""
            : " Already running, so not part of this run: \(start.refused.joined(separator: ", ")). "
            + "Those belong to the run that started them: their verdicts arrive under that run id, "
            + "not this one, and check_verification on this run will not list them."
        return "Started verification run \(start.runID): \(names). It runs in the background — do not wait on it."
            + refusals
            + " " + delivery
            + " check_verification(run_id: \"\(start.runID)\") reads the whole run at any point, "
            + "including while it is still running."
    }

    /// Reads one run, scoped to the caller's own workstream.
    ///
    /// Not a security boundary — every process in this feature runs as the
    /// user, and `agent-ipc.md` says as much about the IPC token itself. The
    /// scope check is there because a run id is the tool's only argument and
    /// ids are short: an agent holding a stale or mistyped one should be told
    /// it is not its run rather than handed somebody else's results. Which is
    /// also what every other tool in this group does.
    func checkVerification(for request: Request) async -> Response {
        guard let workstreamID = callerWorkstreamID(request) else {
            return .failure(id: request.id, ToolError.notInWorkstream.localizedDescription)
        }
        guard let runner = verification else {
            return .failure(id: request.id, VerificationFailure.notAvailable.localizedDescription)
        }
        let runID: String
        do {
            runID = try ToolArguments(request).required("run_id")
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
        guard let info = await runner.verificationRun(id: runID, in: workstreamID) else {
            return .failure(id: request.id, VerificationFailure.unknownRun(runID).localizedDescription)
        }
        guard info.workstreamID.caseInsensitiveCompare(workstreamID.uuidString) == .orderedSame else {
            return .failure(id: request.id, VerificationFailure.runBelongsElsewhere.localizedDescription)
        }
        return .success(id: request.id, .verificationRun(info))
    }

    /// Posts a finished run's summary into the inbox of whatever agent now
    /// occupies `surfaceID`.
    ///
    /// **Called only for a run that completed nothing**, per `startVerification`'s
    /// `onFinish` guard. Every check that reaches a terminal state posts its own notice
    /// through `postCheckNotice`, so a run that reported on at least one check has
    /// already told the agent everything this would say a second time; the run-level
    /// notice survives only for the case that has no per-check notices to be silent
    /// through — nothing ran, so nothing completed.
    ///
    /// **Resolved at delivery time, not when the run started.** A helper that
    /// reconnects normally keeps its peer id, but one whose old socket has not
    /// closed yet is told the id belongs to another session and re-registers
    /// under a new one — so a peer id captured ten minutes ago can be dead
    /// while the pane it belonged to has an agent sitting in it. The surface
    /// is the stable address; the peer is looked up through it.
    private func postVerificationNotice(_ info: VerificationRunInfo, to surfaceID: UUID, delivery: UUID) async {
        guard deliveredNotices.insert(delivery).inserted else { return }
        guard let peerID = await peersBySurface()[surfaceID].flatMap({ UUID(uuidString: $0.id) }) else { return }

        do {
            // Nil means the agent has gone. Ordinary, and not worth
            // reporting anywhere: the run's results stay readable through
            // check_verification, and there is nobody left to tell.
            guard try await store.deliverSystemMessage(
                from: VerificationSummary.sender,
                to: peerID,
                content: VerificationSummary.message(for: info)
            ) != nil else { return }
        } catch {
            // The only throw is the store's content cap, and
            // `VerificationSummary.message` is bounded an order of magnitude
            // below it. Reaching here means that bound was broken, which is a
            // bug in the formatter rather than something an agent can act on.
            return
        }

        await nudge([peerID], senderName: VerificationSummary.sender)
    }

    /// Posts one check's completion into the inbox of whatever agent now occupies the
    /// addressed surface.
    ///
    /// **The address falls back to the workstream's Coding Agent tab**, whose surface
    /// id *is* the workstream id. That fallback is what makes a run the *user* pressed
    /// reach the agent — previously such a run finished silently, because only a run an
    /// agent had started carried a surface to deliver to. A run an agent did start is
    /// still addressed to the pane that asked, since two agents in one worktree report
    /// the same workstream name and the surface is the only discriminator.
    ///
    /// Resolved at delivery time, never when the run started: a helper whose old socket
    /// has not closed is told its id belongs to another session and re-registers under
    /// a new one, so an id captured minutes ago can be dead while its pane has an agent
    /// sitting in it.
    private func postCheckNotice(_ notice: VerificationCheckNotice) async {
        let surfaceID = notice.requesterSurfaceID.flatMap(UUID.init(uuidString:))
            ?? UUID(uuidString: notice.workstreamID)
        guard let surfaceID,
              let peerID = await peersBySurface()[surfaceID].flatMap({ UUID(uuidString: $0.id) })
        else { return }

        do {
            // Nil means the agent has gone. Ordinary, and not worth reporting anywhere:
            // the results stay readable through check_verification, and there is nobody
            // left to tell.
            guard try await store.deliverSystemMessage(
                from: VerificationSummary.sender,
                to: peerID,
                content: VerificationSummary.checkMessage(for: notice)
            ) != nil else { return }
        } catch {
            // The only throw is the store's content cap, and `checkMessage` is bounded
            // an order of magnitude below it. Reaching here is a bug in the formatter.
            return
        }

        await nudge([peerID], senderName: VerificationSummary.sender)
    }

    /// Installs the per-check observer. Called exactly once, beside the one bridge.
    func observeVerificationChecks() async {
        await verification?.observeCheckCompletions { [weak self] notice in
            Task { await self?.postCheckNotice(notice) }
        }
    }
}
