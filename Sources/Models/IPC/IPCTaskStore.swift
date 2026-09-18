// ABOUTME: In-memory actor holding a project's claimable task queue.
// ABOUTME: Pure logic — add/claim/complete/fail, keyed by project directory and surface id.

import Foundation

extension IPC {
    // MARK: - Models

    /// One task in a project's queue. App-only — never crosses the wire.
    /// `TaskInfo` (`IPCProtocol.swift`) is the projection an agent sees, the
    /// same relationship `Peer`/`PeerInfo` already have.
    struct ProjectTask: Sendable, Equatable {
        let path: String
        let name: String
        let content: String
        let tags: [String]
        let createdAt: Date
        /// Nil when the creator has no `ATELIER_SURFACE_ID` (an agent Atelier
        /// didn't launch). Disables the completion notice; does not block
        /// creation.
        let createdBySurfaceID: String?
        var state: TaskState
    }

    /// A task's lifecycle. Ownership is carried by **surface id**, never peer
    /// id — see this file's top-level doc comment on `TaskStore` for why.
    enum TaskState: Sendable, Equatable {
        case pending
        case claimed(bySurfaceID: String, inWorkstreamID: String, at: Date)
        case completed(bySurfaceID: String, at: Date)
        case failed(bySurfaceID: String, at: Date, reason: String)

        /// Test-only convenience: the Date a `.claimed` state was minted, so a
        /// test can assert equality without predicting the clock. Nil for any
        /// other case.
        var claimedAt: Date? {
            if case let .claimed(_, _, at) = self {
                at
            } else {
                nil
            }
        }
    }

    /// Why a task-queue tool could not act. Every case is something the
    /// calling agent can act on — the same rule `WorkspaceActions.Failure`
    /// states for the rest of this surface.
    enum TaskQueueFailure: Swift.Error, LocalizedError, Equatable {
        case noProject
        case noSurface
        case unknownTask(String)
        case alreadyExists(String)
        /// The surface id currently holding the claim, or nil when nobody
        /// does (a `.pending` task, or the claimer has since moved past it).
        /// `IPC.Service` resolves this to a display name — the Store has no
        /// way to look up a peer's name itself.
        case wrongClaimer(heldBySurfaceID: String?)
        case alreadyFinished(String)
        case contentTooLarge

        var errorDescription: String? {
            switch self {
            case .noProject:
                "The task queue is scoped to a project; Atelier could not determine yours."
            case .noSurface:
                "Task ownership needs a surface to attach to. This looks like an environment Atelier did not launch."
            case let .unknownTask(path):
                "No task at path \"\(path)\". Use get_pending_tasks or list_tasks to see what exists."
            case let .alreadyExists(path):
                "A task already exists at path \"\(path)\". add_task is not replayed automatically after a lost "
                    + "connection, so this may mean your earlier call already succeeded — check list_tasks rather "
                    + "than retrying under the same path."
            case .wrongClaimer:
                "That task is not claimed by you."
            case let .alreadyFinished(path):
                "Task \"\(path)\" is already finished; it cannot be claimed again."
            case .contentTooLarge:
                "Task content exceeds maximum size (64KB)."
            }
        }
    }

    // MARK: - Store

    /// Holds every project's task queue for the lifetime of the app.
    ///
    /// Deliberately in-memory, the same rationale `IPC.Store` states for
    /// peers and messages: this coordinates live agents in one Atelier
    /// session, and a restart already takes every workstream's Coding Agent
    /// process with it, so persisting the queue across a restart would buy
    /// nothing a real incident has asked for.
    ///
    /// **Ownership is keyed by surface id, not peer id**, and that is the one
    /// correction this design made against its own first draft: a helper
    /// whose old socket hasn't closed re-registers under a *new* peer id
    /// while keeping the same `ATELIER_SURFACE_ID`. Peer-id-keyed ownership
    /// would make `complete_task` refuse its own rightful claimer forever
    /// after an ordinary reconnect race. Surface id is stable for the life of
    /// a terminal regardless of how many times its helper reconnects, which
    /// is also what decouples a claim from `IPC.Store`'s own peer TTL — a
    /// task stays claimed even if the claimer's peer entry itself expires.
    ///
    /// Every mutating method here is a single synchronous body with no
    /// `await` between its check and its write — the same shape
    /// `IPC.Store.sendMessage`'s alive-check-then-append already has. Actor
    /// isolation is what makes "only one caller sees `.pending` and
    /// transitions it" true by construction.
    actor TaskStore {
        private var tasksByProject: [String: [String: ProjectTask]] = [:]
        private let maxContentSize = 65_536

        // MARK: - Adding

        func add(
            projectDirectory: String,
            path: String,
            name: String,
            content: String,
            tags: [String],
            createdBySurfaceID: String?
        ) throws -> ProjectTask {
            let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard content.utf8.count <= maxContentSize else { throw TaskQueueFailure.contentTooLarge }
            guard tasksByProject[projectDirectory]?[path] == nil else {
                throw TaskQueueFailure.alreadyExists(path)
            }
            let task = ProjectTask(
                path: path,
                name: name,
                content: content,
                tags: tags,
                createdAt: Date(),
                createdBySurfaceID: createdBySurfaceID,
                state: .pending
            )
            tasksByProject[projectDirectory, default: [:]][path] = task
            return task
        }

        // MARK: - Listing

        func pending(projectDirectory: String, pathPrefix: String?, tags: [String]) -> [ProjectTask] {
            matching(projectDirectory: projectDirectory, pathPrefix: pathPrefix, tags: tags)
                .filter {
                    if case .pending = $0.state {
                        true
                    } else {
                        false
                    }
                }
        }

        func all(projectDirectory: String, pathPrefix: String?, tags: [String]) -> [ProjectTask] {
            matching(projectDirectory: projectDirectory, pathPrefix: pathPrefix, tags: tags)
        }

        private func matching(projectDirectory: String, pathPrefix: String?, tags: [String]) -> [ProjectTask] {
            let all = (tasksByProject[projectDirectory] ?? [:]).values
            return all.filter { task in
                if let pathPrefix, !pathPrefix.isEmpty, !task.path.hasPrefix(pathPrefix) {
                    return false
                }
                guard !tags.isEmpty else { return true }
                // ALL supplied tags must be present — stated explicitly in the
                // tool descriptions in `main.swift` so an agent isn't left to
                // guess AND vs. OR.
                return tags.allSatisfy { task.tags.contains($0) }
            }
            // Deterministic order for a caller reading a list twice — a
            // dictionary's `.values` has none of its own.
            .sorted { $0.path < $1.path }
        }

        // MARK: - Claiming

        func claim(projectDirectory: String, path: String, surfaceID: String, workstreamID: String) throws -> ProjectTask {
            let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard var task = tasksByProject[projectDirectory]?[path] else {
                throw TaskQueueFailure.unknownTask(path)
            }
            switch task.state {
            case .pending:
                task.state = .claimed(bySurfaceID: surfaceID, inWorkstreamID: workstreamID, at: Date())
            case let .claimed(existing, _, _) where existing == surfaceID:
                break // idempotent replay: already yours
            case let .claimed(existing, _, _):
                throw TaskQueueFailure.wrongClaimer(heldBySurfaceID: existing)
            case .completed, .failed:
                throw TaskQueueFailure.alreadyFinished(path)
            }
            tasksByProject[projectDirectory]?[path] = task
            return task
        }

        // MARK: - Completing

        func complete(projectDirectory: String, path: String, surfaceID: String) throws -> (task: ProjectTask, transitioned: Bool) {
            let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard var task = tasksByProject[projectDirectory]?[path] else {
                throw TaskQueueFailure.unknownTask(path)
            }
            let transitioned: Bool
            switch task.state {
            case let .claimed(existing, _, _) where existing == surfaceID:
                task.state = .completed(bySurfaceID: surfaceID, at: Date())
                transitioned = true
            case let .completed(existing, _) where existing == surfaceID:
                transitioned = false // idempotent replay: nothing changed
            case let .claimed(existing, _, _):
                throw TaskQueueFailure.wrongClaimer(heldBySurfaceID: existing)
            case let .completed(existing, _):
                throw TaskQueueFailure.wrongClaimer(heldBySurfaceID: existing)
            case .pending:
                throw TaskQueueFailure.wrongClaimer(heldBySurfaceID: nil)
            case .failed:
                throw TaskQueueFailure.wrongClaimer(heldBySurfaceID: nil)
            }
            tasksByProject[projectDirectory]?[path] = task
            return (task, transitioned)
        }

        // MARK: - Failing

        func fail(
            projectDirectory: String, path: String, surfaceID: String, reason: String
        ) throws -> (task: ProjectTask, transitioned: Bool) {
            let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard var task = tasksByProject[projectDirectory]?[path] else {
                throw TaskQueueFailure.unknownTask(path)
            }
            let transitioned: Bool
            switch task.state {
            case let .claimed(existing, _, _) where existing == surfaceID:
                task.state = .failed(bySurfaceID: surfaceID, at: Date(), reason: reason)
                transitioned = true
            case let .failed(existing, _, _) where existing == surfaceID:
                transitioned = false // idempotent replay: the FIRST reason wins, never overwritten
            case let .claimed(existing, _, _):
                throw TaskQueueFailure.wrongClaimer(heldBySurfaceID: existing)
            case let .failed(existing, _, _):
                throw TaskQueueFailure.wrongClaimer(heldBySurfaceID: existing)
            case .pending:
                throw TaskQueueFailure.wrongClaimer(heldBySurfaceID: nil)
            case .completed:
                throw TaskQueueFailure.wrongClaimer(heldBySurfaceID: nil)
            }
            tasksByProject[projectDirectory]?[path] = task
            return (task, transitioned)
        }

        // MARK: - Teardown

        /// Reverts every task claimed by a surface in `workstreamID` back to
        /// `.pending`, across every project. Called when that workstream's
        /// surfaces are torn down for good — `Workstream.Archiver.remove`/
        /// `.purge` — never on an ordinary `IPC.Service.release(peerID:)`,
        /// which also fires on a reconnect race that leaves the same surface
        /// still legitimately working. See the design doc's "Failure/cleanup
        /// semantics" section.
        @discardableResult
        func releaseClaims(inWorkstreamID workstreamID: String) -> [ProjectTask] {
            var reverted: [ProjectTask] = []
            for (project, tasks) in tasksByProject {
                for (path, task) in tasks {
                    guard case let .claimed(_, taskWorkstreamID, _) = task.state, taskWorkstreamID == workstreamID else {
                        continue
                    }
                    var updated = task
                    updated.state = .pending
                    tasksByProject[project]?[path] = updated
                    reverted.append(updated)
                }
            }
            return reverted
        }

        func cleanup() {
            tasksByProject.removeAll()
        }
    }
}
