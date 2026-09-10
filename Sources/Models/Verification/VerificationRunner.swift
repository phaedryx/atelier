// ABOUTME: The app-level runner for the verify namespace, keyed by workstream.
// ABOUTME: One run per workstream at a time; every refusal happens before a spawn.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "verification")

extension Verification {
    /// Starts and tracks verification runs for every workstream.
    ///
    /// App-level rather than owned by the tab, for two reasons. A run an agent
    /// started through `start_verification` has to appear in the user's tab, and
    /// `<id>-verify.sock` admits exactly one server — so "one run per
    /// workstream" needs a single enforcement point rather than one in the tab
    /// and another in the IPC handler. `PhaseExecutor.run` calls `shutDown` at
    /// the top, so a second start would kill the first run mid-suite.
    @MainActor
    final class Runner: ObservableObject {
        @Published private(set) var runs: [UUID: Verification.Run] = [:]

        /// Issued ids, so "unique for the app's lifetime" is enforced rather
        /// than hoped for. Eight hex characters is short enough that a
        /// collision is a real if unlikely event, and a reissued id would make
        /// `run(id:)` answer about the wrong run.
        ///
        /// Unbounded deliberately: one entry per run for one app session is
        /// nothing, and a cap would reintroduce exactly the reuse it prevents.
        private var issuedRunIDs: Set<String> = []

        enum Failure: Error, Equatable, LocalizedError {
            case alreadyRunning(String)
            case nothingDeclared
            case unavailable(String)
            case unknownChecks([String], valid: [String])

            var errorDescription: String? {
                switch self {
                case let .alreadyRunning(id):
                    String(format: NSLocalizedString(
                        "Verification run %@ is already running in this workstream.", comment: ""
                    ), id)
                case .nothingDeclared:
                    NSLocalizedString("This project declares no verify processes.", comment: "")
                case let .unavailable(reason):
                    reason
                case let .unknownChecks(unknown, valid):
                    String(format: NSLocalizedString(
                        "No such check: %@. This project declares: %@.", comment: ""
                    ), unknown.joined(separator: ", "), valid.joined(separator: ", "))
                }
            }
        }

        /// Eight lowercase hex characters, never reissued.
        ///
        /// Length is about collisions and mistaken ids, not secrecy — every
        /// process here runs as the user, and even the IPC token is documented
        /// as not being a boundary against the agent. `run(id:)` below scans
        /// every workstream's runs unscoped; it is the IPC handler that is
        /// meant to confine a caller to its own workstream, not this type.
        func makeRunID() -> String {
            while true {
                let candidate = String(
                    UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        .prefix(8).lowercased()
                )
                if issuedRunIDs.insert(candidate).inserted {
                    return candidate
                }
            }
        }

        /// Which checks a request resolves to, or why it cannot.
        ///
        /// Empty means all, matching the process-selection convention — but an
        /// empty *declared* list is a refusal rather than a run of everything,
        /// because `up -n verify` on a namespace with no processes never exits.
        ///
        /// Unknown names are refused rather than dropped: `PhaseRunner.command`
        /// filters trailing names beginning with `-` as a flag-injection guard,
        /// so an unvalidated name does not fail loudly, it silently vanishes and
        /// the run comes back missing a check nobody declined.
        static func resolveChecks(
            requested: [String], declared: [String]
        ) -> Result<[String], Failure> {
            guard !declared.isEmpty else { return .failure(.nothingDeclared) }
            guard !requested.isEmpty else { return .success(declared) }
            let unknown = requested.filter { !declared.contains($0) }
            guard unknown.isEmpty else {
                return .failure(.unknownChecks(unknown, valid: declared))
            }
            return .success(requested)
        }

        func run(id: String) -> Verification.Run? {
            runs.values.first { $0.id == id }
        }

        /// Test seam: the in-flight refusal is otherwise only reachable by
        /// spawning a real process-compose.
        func seedInFlightForTesting(workstreamID: UUID, runID: String) {
            runs[workstreamID] = Verification.Run(
                id: runID, workstreamID: workstreamID, startedAt: Date(), stamp: "",
                checks: [.init(name: "x", state: .running, duration: nil, output: nil)],
                wasStopped: false
            )
        }

        func start(
            workstreamID: UUID,
            worktreePath: String,
            projectDirectory: String,
            checks: [String]
        ) throws -> (runID: String, started: [String]) {
            if let live = runs[workstreamID], !live.isFinished {
                throw Failure.alreadyRunning(live.id)
            }

            // The one gate. Identical to bootstrap's and dispose's, and
            // deliberately the same copy: captured output means nobody is
            // watching a TTY, so the argument that leaves `execute` ungated
            // does not apply — to a user press or to an agent call.
            let plan = PhasePolicy.plan(
                phase: .verify,
                isEnabled: ProcessCompose.Settings.isEnabled,
                config: ProcessCompose.Config.locate(
                    worktree: worktreePath, projectDirectory: projectDirectory
                ),
                binary: ProcessCompose.Settings.resolveBinary(),
                isApproved: {
                    ScriptTrust.isApproved(
                        configFiles: $0.repositoryProvidedFiles, for: projectDirectory
                    )
                }
            )
            let config: ProcessCompose.Config
            switch plan {
            case let .run(planConfig, _):
                config = planConfig
            case let .nothingToDo(reason):
                throw Failure.unavailable(reason)
            }

            // `declaredProcesses` returns nil when a file could not be parsed —
            // never fold that into an empty list. Doing so would report a
            // malformed process-compose.yaml as "this project declares no verify
            // processes", the same message a project with genuinely no verify
            // checks gets, which is false and the only diagnostic this path gives.
            guard let declared = config.declaredProcesses(
                in: ProcessCompose.Phase.verify.namespace
            ) else {
                throw Failure.unavailable(NSLocalizedString(
                    "This project's process-compose files could not be parsed, so its verify checks are unknown.",
                    comment: ""
                ))
            }
            let resolved = try Self.resolveChecks(requested: checks, declared: declared).get()

            let runID = makeRunID()
            let stamp = Git.Operations.diffFingerprint(
                worktreePath: worktreePath, projectPath: projectDirectory, mode: "uncommitted"
            )
            runs[workstreamID] = Verification.Run(
                id: runID, workstreamID: workstreamID, startedAt: Date(), stamp: stamp,
                checks: resolved.map {
                    .init(name: $0, state: .pending, duration: nil, output: nil)
                },
                wasStopped: false
            )
            return (runID, resolved)
        }
    }
}
