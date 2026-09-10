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
        /// Lines of a failing check's output carried in the notice. A test
        /// runner puts the useful part last, so this is a tail.
        static let maxFailureTailLines = 20
        /// Bytes of one failing check's output in the notice.
        static let maxFailureTailBytes = 1_200
        /// Below this there is no room for output worth reading, so the notice
        /// carries verdicts alone and says the output was trimmed.
        static let minTailBytes = 200

        /// Cap on all the output in one `check_verification` answer.
        static let maxReadOutputBytes = 16_000
        /// Cap on one check's output in a `check_verification` answer.
        static let maxReadTailBytesPerCheck = 4_000

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
        /// Assembled against a byte budget rather than assumed to fit: verdicts
        /// first, since one line per check is what the agent needs to act, then
        /// as much failing output as the remaining room allows, then a pointer at
        /// `check_verification` for the rest.
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
            var spent = included.reduce(0) { $0 + $1.text.utf8.count + 1 }
            var overflow: String?
            if omitted > 0 {
                overflow = overflowNote(count: omitted, runID: run.runID)
                spent += (overflow?.utf8.count ?? 0) + 1
            }

            let tails = failureTails(for: included.map(\.check), budget: budget - spent)

            var lines = [header]
            if run.isStale {
                lines.append(staleNotice)
            }
            for entry in included {
                lines.append(entry.text)
                if let tail = tails[entry.check.name] {
                    lines.append(tail)
                }
            }
            if let overflow {
                lines.append(overflow)
            }
            if let pointer {
                lines.append(pointer)
            }
            return lines.joined(separator: "\n")
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

        /// An indented output tail per failing check, sharing `budget` evenly.
        ///
        /// Evenly rather than first-come: a suite where the third linter is the
        /// one that failed should not lose its output to the first two, and an
        /// even split is the only division that is predictable enough to pin.
        private static func failureTails(
            for checks: [VerificationCheckInfo],
            budget: Int
        ) -> [String: String] {
            let failing = checks.filter { $0.state == .failed && !($0.outputTail ?? "").isEmpty }
            guard !failing.isEmpty, budget > 0 else { return [:] }

            // The newline that joins each block to the line above it comes out of
            // the same budget, so it is charged here rather than discovered as a
            // few bytes of overshoot per failing check.
            let even = budget / failing.count - 1
            // An even split below the floor is not worth reading, so past that
            // point the budget goes to as many failures as the floor allows,
            // in order, rather than to none of them. Thirty failing checks
            // would otherwise take the notice from "some output" to "no output"
            // in one step.
            let allowance = min(maxFailureTailBytes, max(even, minTailBytes))

            var result: [String: String] = [:]
            var remaining = budget
            for check in failing {
                guard remaining >= allowance + 1 else { break }
                guard let output = check.outputTail,
                      let block = indentedTail(of: output, allowance: allowance)
                else { continue }
                result[check.name] = block
                remaining -= block.utf8.count + 1
            }
            return result
        }

        /// The last lines of `output`, indented, fitting in `allowance` bytes —
        /// or nil when nothing worth reading fits.
        private static func indentedTail(of output: String, allowance: Int) -> String? {
            let indent = "    "
            var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            guard !lines.isEmpty else { return nil }
            if lines.count > maxFailureTailLines {
                lines.removeFirst(lines.count - maxFailureTailLines)
            }

            var block = lines.map { indent + $0 }.joined(separator: "\n")
            while block.utf8.count > allowance, lines.count > 1 {
                lines.removeFirst()
                block = lines.map { indent + $0 }.joined(separator: "\n")
            }
            if block.utf8.count > allowance {
                // One line, still too long: keep its end, which is where a
                // stack trace or a failure count sits.
                let room = allowance - indent.utf8.count
                guard room >= 24 else { return nil }
                block = indent + clamped(lines[0], to: room).text
            }
            return block
        }

        // MARK: - Bounding a read

        /// The same run with every check's output bounded, so one answer cannot
        /// hand an agent a whole suite's log.
        ///
        /// `check_verification` is where the output an agent actually needs
        /// lives, so the caps here are far looser than the notice's — but they
        /// are caps: a run with twenty chatty failures would otherwise answer
        /// with more text than an agent can afford to read.
        static func bounded(_ run: VerificationRunInfo) -> VerificationRunInfo {
            let withOutput = run.checks.filter { !($0.outputTail ?? "").isEmpty }.count
            guard withOutput > 0 else { return run }
            let share = min(maxReadTailBytesPerCheck, maxReadOutputBytes / withOutput)

            let checks = run.checks.map { check -> VerificationCheckInfo in
                guard let output = check.outputTail, !output.isEmpty else { return check }
                let clamped = clamped(output, to: share)
                return VerificationCheckInfo(
                    name: check.name,
                    state: check.state,
                    exitCode: check.exitCode,
                    durationSeconds: check.durationSeconds,
                    outputTail: clamped.text,
                    // The runner fetched a bounded tail from the control API to
                    // begin with. If it already trimmed, this answer is not whole
                    // whatever happened here.
                    outputTruncated: check.outputTruncated || clamped.truncated
                )
            }

            return VerificationRunInfo(
                runID: run.runID,
                workstreamID: run.workstreamID,
                workstreamName: run.workstreamName,
                state: run.state,
                startedSecondsAgo: run.startedSecondsAgo,
                durationSeconds: run.durationSeconds,
                checks: checks,
                isStale: run.isStale
            )
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
                // `up -n` on an empty namespace never exits, so `PhaseExecutor`
                // returns `.skipped` without spawning, and a config Yams cannot
                // decode declares no processes at all — both land here.
                guard total > 0 else {
                    return "run \(run.runID) finished\(elapsed) — no checks ran; the verify namespace declared none"
                }
                return failed == 0
                    ? "run \(run.runID) finished\(elapsed) — all \(total) checks passed"
                    : "run \(run.runID) finished\(elapsed) — \(failed) of \(total) checks failed"
            }
        }

        /// One check's verdict.
        ///
        /// The three states that are not a result — `skipped`, `notRun`,
        /// `pending` — share a mark and each say what they are, because a
        /// `Skipped` check carries exit 1 from process-compose and must never
        /// render as a failure it never had.
        private static func line(for check: VerificationCheckInfo) -> String {
            let elapsed = check.durationSeconds.map { "  \(IPC.durationText($0))" } ?? ""
            switch check.state {
            case .passed:
                return "✓ \(check.name)\(elapsed)"
            case .failed:
                return "✗ \(check.name)\(elapsed)" + (check.exitCode.map { "  exit \($0)" } ?? "")
            case .skipped:
                return "· \(check.name)  skipped (a check it depends on failed)"
            case .notRun:
                return "· \(check.name)  not run"
            case .pending:
                return "· \(check.name)  waiting on a dependency"
            case .stopped:
                return "· \(check.name)\(elapsed)  stopped"
            case .running:
                return "~ \(check.name)\(elapsed)  running"
            }
        }

        private static let staleNotice =
            "The worktree has changed since this run started, so these results no longer describe the code on disk."

        private static func pointerLine(runID: String) -> String {
            "check_verification(run_id: \"\(runID)\") has more of each check's captured output."
        }

        private static func overflowNote(count: Int, runID: String) -> String {
            "… and \(count) more checks — check_verification(run_id: \"\(runID)\") lists all of them."
        }

        /// `text` cut to `limit` bytes, **keeping its end**, without splitting a
        /// UTF-8 scalar. Whole lines go first so what is left still parses as
        /// output.
        ///
        /// Measured backwards from the end rather than by dropping leading lines
        /// and re-measuring: a failing suite's log is the input here, and
        /// re-joining a 200k-line one per line dropped is quadratic — 90 seconds
        /// for what this now does in milliseconds.
        private static func clamped(_ text: String, to limit: Int) -> (text: String, truncated: Bool) {
            guard text.utf8.count > limit else { return (text, false) }

            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            var kept: [Substring] = []
            var size = 0
            for line in lines.reversed() {
                let cost = line.utf8.count + (kept.isEmpty ? 0 : 1)
                guard size + cost <= limit else { break }
                size += cost
                kept.append(line)
            }
            if !kept.isEmpty {
                return (kept.reversed().joined(separator: "\n"), true)
            }

            // Not even the last line fits — a minified stack trace, or a runner
            // that never wrapped. Cut inside it, keeping its end.
            let bytes = Array((lines.last ?? "").utf8)
            var start = max(0, bytes.count - limit)
            // 0b10xxxxxx is a continuation byte: starting on one would cut a
            // scalar in half and lose the whole tail to a decode failure.
            while start < bytes.count, bytes[start] & 0xC0 == 0x80 {
                start += 1
            }
            return (String(decoding: bytes[start...], as: UTF8.self), true)
        }
    }
}
