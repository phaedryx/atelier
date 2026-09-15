// ABOUTME: The initialization step loop and what a finished run means.
// ABOUTME: Pure, so order, halt-on-failure and cancellation can be tested without a subprocess.

import Foundation

extension Initialization {
    /// One run of a project's initialization steps.
    ///
    /// Split out of `Initialization.Runner` for the reason `PhasePolicy` was
    /// split out of the actor it serves: the actor's own surface — a detached
    /// `Task`, a real worktree, real subprocesses — is almost impossible to
    /// test, while these branches are the part that can actually be got wrong.
    enum Run {
        /// What one step's command did.
        enum StepResult: Equatable {
            case succeeded
            /// Carries whatever the output said, because a bare exit code tells
            /// the user nothing.
            case failed(detail: String)
        }

        /// A step about to start. Reported so the Info row can name it rather
        /// than saying "Running bootstrap" for however long setup takes.
        struct Progress: Equatable {
            let name: String
            /// 1-based, so the wording reads as the user counts.
            let position: Int
            let total: Int

            var detail: String {
                String(
                    format: NSLocalizedString(
                        "Running “%1$@” (%2$d of %3$d)",
                        comment: "Info tab: which initialization step is running"
                    ),
                    name, position, total
                )
            }

            /// How much of the run is *done* — so the first step reports zero
            /// rather than a bar that is already part-full before anything ran.
            var fraction: Double {
                guard total > 0 else { return 0 }
                return Double(position - 1) / Double(total)
            }
        }

        /// How a run ended.
        enum Outcome: Equatable {
            case succeeded(steps: Int)
            /// There was nothing to run, and this says why. The worktree exists
            /// and is usable in every one of these cases.
            case nothingToDo(String)
            /// A step's command exited non-zero. Nothing after it ran.
            case failed(step: String, detail: String)
            /// The caller stopped the run — an archive, in practice. Names the
            /// step that was killed, or the one that never started because the
            /// cancel landed first.
            ///
            /// **A cancel that arrives after the last step has already succeeded
            /// yields `.succeeded`, not this**, and that is right rather than a
            /// gap: every step ran and the cancel was simply too late to stop
            /// anything. What cancellation guarantees is that no step is reported
            /// as *failed* because the user stopped it.
            case cancelled(step: String)
        }

        /// Run the steps in file order, stopping at the first failure.
        ///
        /// **Sequential and halting, which is the one deliberate difference from
        /// `Verification.Runner`.** Verification checks are independent by
        /// design — rubocop says nothing about rspec — so they run at once and
        /// each reports for itself. Setup steps are the opposite: `bundle
        /// install` before `rails db:prepare` is the ordinary case, and it is
        /// what the `depends_on: process_completed_successfully` graphs in the
        /// `bootstrap` namespace existed to express. Running the rest after a
        /// failure would run them against a half-built worktree and bury the
        /// error that mattered under the ones it caused.
        ///
        /// `isCancelled` is consulted before each step, and again when one
        /// fails. Before, so a cancel landing between steps does not start a
        /// command in a worktree that is being removed. On a failure, because a
        /// step killed by that cancel comes back as an ordinary non-zero exit and
        /// this is the only thing that can tell the two apart — asking after a
        /// step that *succeeded* would name it as the one that was stopped, when
        /// the step actually stopped is the one that never started.
        static func drive(
            steps: [Initialization.Config.Step],
            isCancelled: () -> Bool,
            report: (Progress) -> Void,
            execute: (Initialization.Config.Step) -> StepResult
        ) -> Outcome {
            for (index, step) in steps.enumerated() {
                guard !isCancelled() else { return .cancelled(step: step.name) }
                report(Progress(name: step.name, position: index + 1, total: steps.count))
                if case let .failed(detail) = execute(step) {
                    // Asked only about a step that failed, and that is the whole
                    // subtlety: a cancel kills the running command, so it comes
                    // back as an ordinary non-zero failure and this is the only
                    // thing that can tell the two apart. A step that *succeeded*
                    // before the cancel landed is not the one that was stopped —
                    // the guard at the top of the next iteration names that one.
                    guard !isCancelled() else { return .cancelled(step: step.name) }
                    return .failed(step: step.name, detail: detail)
                }
            }
            return .succeeded(steps: steps.count)
        }

        /// Why nothing ran, in one sentence for the Info row.
        ///
        /// `declaresBootstrapNamespace` is the migration note and nothing else.
        /// A project whose `process-compose.yaml` still carries a `bootstrap`
        /// namespace used to get its setup from there and now gets none at all,
        /// and every other symptom of that is silence — the namespace is simply
        /// never named on a command line again. It replaces only the
        /// "there is no file" reason: a file that is present and broken has its
        /// own, and that is the one the user needs, since telling them to move
        /// their steps into a file they have already written is advice for a
        /// problem they do not have.
        ///
        /// **The caller passes `namespacePresence("bootstrap") == .present`, so a
        /// config Yams cannot decode (`.unknown`) gets the generic note instead
        /// of this one — stated rather than papered over.** Widening it to
        /// `!= .empty` was considered and declined: this note makes a factual
        /// claim about the user's file, and `.unknown` is exactly the case where
        /// that claim is unverified. Asserting "your process-compose.yaml still
        /// declares a bootstrap namespace" about a file nothing could parse
        /// trades one wrong answer for another.
        static func nothingToDoNote(
            load: Initialization.Config.Load,
            declaresBootstrapNamespace: Bool
        ) -> String {
            if case .missing = load, declaresBootstrapNamespace {
                return NSLocalizedString(
                    "This project's execution.process-compose.yaml still declares a bootstrap namespace, which is no longer run. Move those steps to an initialization.yaml in the project directory.",
                    comment: "Info tab: bootstrap steps stranded by the move to initialization.yaml"
                )
            }
            return load.unavailableReason ?? NSLocalizedString(
                "There was nothing to run.",
                comment: "Info tab: initialization had nothing to do, with no reason to give"
            )
        }

        /// How a finished run is reported on the Info tab.
        ///
        /// `.nothingToDo` and `.cancelled` are both notes rather than failures,
        /// and for the same reason: neither describes a broken worktree. A
        /// project that declares no setup asked for none, and a cancelled run was
        /// stopped by the user archiving the worktree it was setting up.
        static func state(for outcome: Outcome) -> Initialization.State {
            switch outcome {
            case .succeeded:
                .completed
            case let .nothingToDo(note):
                .completedWithNote(note)
            case let .failed(step, detail):
                .failed(String(
                    format: NSLocalizedString(
                        "Initialization failed at “%1$@”: %2$@",
                        comment: "Info tab: a step's command exited non-zero"
                    ),
                    step, detail
                ))
            case let .cancelled(step):
                .completedWithNote(String(
                    format: NSLocalizedString(
                        "Initialization was stopped at “%@”.",
                        comment: "Info tab: the run was cancelled, in practice by an archive"
                    ),
                    step
                ))
            }
        }
    }
}
