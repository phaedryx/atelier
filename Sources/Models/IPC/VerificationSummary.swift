// ABOUTME: The pure half of the verification tools — argument parsing, the completion
// ABOUTME: notice an agent finds in its inbox, and the bounding that keeps both deliverable.

import Foundation

extension IPC {
    /// Formatting and bounding for the two verification tools.
    ///
    /// Everything here is a pure function of a `VerificationRunInfo`, which is
    /// the point: the state mapping, the wording and the truncation are where
    /// this feature's bugs live, and none of them need a suite, a
    /// process-compose binary or a worktree to pin.
    ///
    /// Named flat rather than nested under an `IPC.Verification` namespace on
    /// purpose. The runner declares a top-level `Verification`, and an
    /// `IPC.Verification` would shadow it for every file that says `extension
    /// IPC` — so `Verification.Run` inside this module would silently resolve to
    /// the wrong thing.
    enum VerificationSummary {
        /// Cap on the assembled completion notice.
        ///
        /// `IPC.Store` refuses content over 64KB **outright**, so a notice that
        /// overshoots is not trimmed on delivery — it is lost, silently, exactly
        /// when the agent is waiting for it. This sits an order of magnitude
        /// below that cap because the real constraint is the reader: a summary
        /// is worth having only if an agent can afford to read it, and the
        /// failing output it points at is served by `check_verification`.
        static let maxMessageBytes = 6_000

        /// Cap on one check's completion notice.
        ///
        /// Below `maxMessageBytes` because there are N of these per run where there
        /// was one summary, and an agent reads them all. `IPC.Store` refuses content over
        /// 64KB outright — it throws rather than trimming — so overshooting loses the
        /// notice silently at the moment the agent is waiting for it.
        ///
        /// **No output is carried by either one.** A check runs in its own terminal
        /// surface and Atelier keeps no copy of what it printed, so these budgets are
        /// spent entirely on verdicts. That is what retired the tail-splitting this
        /// type used to do — an even share of a byte budget across the failing checks,
        /// with a floor — along with the caps on a `check_verification` read.
        ///
        /// It still binds, because a **check name is the user's** and nothing bounds
        /// one: a 200KB name in `verification.yaml` is legal YAML and would lose the
        /// notice the same way a suite's log used to.
        static let maxCheckMessageBytes = 4_000

        /// The label an app-originated completion notice arrives from.
        ///
        /// Not a peer id, and deliberately not one: there is nothing inside
        /// Atelier for an agent to `send_message` back to.
        static let sender = "atelier/verification"

        // MARK: - Arguments

        /// The check names in a `checks` argument, in the order asked, without
        /// duplicates. Empty means all of them.
        ///
        /// `IPC.Request.arguments` is `[String: String]`, so however a model
        /// spells a list it arrives as text: a comma-separated string is what the
        /// schema asks for, and a JSON array or a space-separated list is what a
        /// plural argument invites. All three are the same intent and none of
        /// them is worth a refusal.
        static func checks(from raw: String?) -> [String] {
            guard let raw else { return [] }
            let separators = CharacterSet(charactersIn: ",[]\"'").union(.whitespacesAndNewlines)
            var seen: Set<String> = []
            var result: [String] = []
            for token in raw.components(separatedBy: separators) where !token.isEmpty {
                if seen.insert(token).inserted {
                    result.append(token)
                }
            }
            return result
        }

        // MARK: - The completion notice

        /// The notice posted into the calling agent's inbox when a run ends.
        ///
        /// Assembled against a byte budget rather than assumed to fit: one line
        /// per check, then a pointer at `check_verification` for a run too long to
        /// list.
        ///
        /// **Its one production caller is `IPC.Service.startVerification`'s
        /// `onFinish`, and that closure only calls it when `info.state != .stopped
        /// && info.checks.allSatisfy { $0.state == .notRun }`** — every check
        /// that reaches a terminal state posts its own per-check notice instead,
        /// so a normal run's result has already arrived by the time a run
        /// finishes. So in production this function only ever runs over a
        /// non-stopped run whose rows are all `.notRun`, and its pass/fail
        /// verdict branch below is dead there. Keep it that way on purpose: this
        /// line is what stops a future caller from re-broadening who invokes this
        /// and reviving the bug it was narrowed to prevent — a run that started
        /// nothing rendering here as "0 of 0 failed", which reads as a pass.
        static func message(for run: VerificationRunInfo) -> String {
            let header = headerLine(for: run)
            let pointer = run.checks.isEmpty ? nil : pointerLine(runID: run.runID)

            var budget = maxMessageBytes - header.utf8.count
            if run.isStale {
                budget -= staleNotice.utf8.count + 1
            }
            if let pointer {
                budget -= pointer.utf8.count + 1
            }

            let (included, omitted) = fitVerdicts(run.checks, budget: budget)
            var overflow: String?
            if omitted > 0 {
                overflow = overflowNote(count: omitted, runID: run.runID)
            }

            var lines = [header]
            if run.isStale {
                lines.append(staleNotice)
            }
            for entry in included {
                lines.append(entry.text)
            }
            if let overflow {
                lines.append(overflow)
            }
            if let pointer {
                lines.append(pointer)
            }
            return lines.joined(separator: "\n")
        }

        /// The notice an agent finds in its inbox when one check finishes.
        ///
        /// A verdict and nothing else. The check ran in a terminal surface, so its
        /// output is on screen in the Verification tab and nowhere Atelier can read
        /// — there is no tail to carry and nothing here may imply one can be
        /// fetched. Re-running the one check is the honest pointer, and asking the
        /// user to look at the tab is the other.
        static func checkMessage(for notice: VerificationCheckNotice) -> String {
            let verdict = switch notice.check.state {
            case .passed: "passed"
            case .failed: notice.check.exitCode.map { "failed (exit \($0))" } ?? "failed"
            case .skipped: "was skipped"
            case .stopped: "was stopped"
            case .notRun: "did not run"
            case .pending, .running: "is still going"
            }
            let duration = notice.check.durationSeconds.map { String(format: " in %.1fs", $0) } ?? ""
            let trailer = "\(verdict)\(duration). "
                + "Its output is in the Verification tab for as long as Atelier is running; "
                + "nothing else keeps a copy. "
                + "Run \(notice.runID); check_verification(run_id: \"\(notice.runID)\") reads the whole run."
            // The name is the only unbounded part, so it is the part that is cut —
            // and cut from its *end*, unlike output, since a name is read from the
            // front. `IPC.Store` throws rather than trimming, so an overshoot here
            // loses the notice entirely.
            // The ellipsis is charged too — it is three bytes in UTF-8, and
            // forgetting it overshot the cap by exactly that much.
            let ellipsis = "…"
            let room = maxCheckMessageBytes
                - trailer.utf8.count
                - "Verification check  ".utf8.count
                - ellipsis.utf8.count
            var name = notice.check.name
            if name.utf8.count > room, room > 0 {
                // Cut on a UTF-8 boundary: `String(decoding:)` would replace a
                // half-scalar with U+FFFD, which is 3 bytes where the truncated
                // scalar may have been 2 — an overshoot in the other direction.
                var bytes = Array(name.utf8.prefix(room))
                while let last = bytes.last, last & 0xC0 == 0x80 {
                    bytes.removeLast()
                }
                name = String(decoding: bytes, as: UTF8.self) + ellipsis
            }
            return "Verification check \(name) \(trailer)"
        }

        /// As many verdict lines as `budget` holds, and how many were left out.
        ///
        /// Verdicts are never sacrificed for output, so this runs first. A run
        /// with hundreds of checks is the case that makes it necessary — the list
        /// alone can overshoot, and a list silently cut reads as a complete one.
        private static func fitVerdicts(
            _ checks: [VerificationCheckInfo],
            budget: Int
        ) -> (included: [(check: VerificationCheckInfo, text: String)], omitted: Int) {
            let all = checks.map { (check: $0, text: line(for: $0)) }
            let total = all.reduce(0) { $0 + $1.text.utf8.count + 1 }
            if total <= budget {
                return (all, 0)
            }

            // The note that reports the cut has to be paid for out of the same
            // budget, and its length depends on the count — so reserve the worst
            // case rather than discovering the overshoot after assembling.
            let reserved = budget - (overflowNote(count: checks.count, runID: "").utf8.count + 24)
            var included: [(check: VerificationCheckInfo, text: String)] = []
            var spent = 0
            for entry in all {
                let cost = entry.text.utf8.count + 1
                guard spent + cost <= reserved else { break }
                included.append(entry)
                spent += cost
            }
            return (included, all.count - included.count)
        }

        // MARK: - Lines

        private static func headerLine(for run: VerificationRunInfo) -> String {
            let total = run.checks.count
            let failed = run.checks.filter { $0.state == .failed }.count

            switch run.state {
            case .running:
                let elapsed = run.durationSeconds.map { " after \(IPC.durationText($0))" } ?? ""
                return "run \(run.runID) is still running\(elapsed) — \(failed) of \(total) checks have failed so far"
            case .stopped:
                let elapsed = run.durationSeconds.map { " after \(IPC.durationText($0))" } ?? ""
                guard total > 0 else { return "run \(run.runID) was stopped\(elapsed) before any checks ran" }
                return failed == 0
                    ? "run \(run.runID) was stopped\(elapsed) — \(total) checks, none of them failing"
                    : "run \(run.runID) was stopped\(elapsed) — \(failed) of \(total) had failed by then"
            case .finished:
                let elapsed = run.durationSeconds.map { " in \(IPC.durationText($0))" } ?? ""
                // Not "0 of 0 failed", which is true and reads as a green suite.
                guard total > 0 else {
                    return "run \(run.runID) finished\(elapsed) — no checks ran; this project declares none"
                }
                // The same trap under a different shape: a press where every check
                // failed to get a terminal leaves rows present and `.notRun` rather
                // than an empty `checks` array. "0 of N failed" is exactly as true
                // and exactly as green as "0 of 0 failed".
                guard !run.checks.allSatisfy({ $0.state == .notRun }) else {
                    return "run \(run.runID) finished\(elapsed) — declared \(total) checks but none of them ran"
                }
                return failed == 0
                    ? "run \(run.runID) finished\(elapsed) — all \(total) checks passed"
                    : "run \(run.runID) finished\(elapsed) — \(failed) of \(total) checks failed"
            }
        }

        /// One check's verdict.
        ///
        /// The three states that are not a result — `skipped`, `notRun`,
        /// `pending` — share a mark and each say what they are, so none of them
        /// can read as a verdict it never had.
        private static func line(for check: VerificationCheckInfo) -> String {
            let elapsed = check.durationSeconds.map { "  \(IPC.durationText($0))" } ?? ""
            switch check.state {
            case .passed:
                return "✓ \(check.name)\(elapsed)"
            case .failed:
                return "✗ \(check.name)\(elapsed)" + (check.exitCode.map { "  exit \($0)" } ?? "")
            case .skipped:
                return "· \(check.name)  skipped"
            case .notRun:
                return "· \(check.name)  not run"
            case .pending:
                return "· \(check.name)  waiting to start"
            case .stopped:
                return "· \(check.name)\(elapsed)  stopped"
            case .running:
                return "~ \(check.name)\(elapsed)  running"
            }
        }

        private static let staleNotice =
            "The worktree has changed since this run started, so these results no longer describe the code on disk."

        private static func pointerLine(runID: String) -> String {
            "check_verification(run_id: \"\(runID)\") lists every check in this run."
        }

        private static func overflowNote(count: Int, runID: String) -> String {
            "… and \(count) more checks — check_verification(run_id: \"\(runID)\") lists all of them."
        }
    }
}
