// ABOUTME: IPC.Service's six project-task tools — the shared, claimable work queue.
// ABOUTME: Project-scoped rather than workstream-scoped, which is what .projectTasks means.

import Foundation

extension IPC.Service {
    // MARK: - Task queue

    /// Every task-queue tool starts here — scoped to the project, not the
    /// workstream, the same scope peers and messages already have.
    private func projectDirectory(_ request: Request) throws -> String {
        guard let project = request.client.projectDirectory, !project.isEmpty else {
            throw TaskQueueFailure.noProject
        }
        return project
    }

    /// `claim_task`/`complete_task`/`fail_task` key ownership on the
    /// caller's surface id — see `IPC.TaskStore`'s doc comment for why —
    /// and on its workstream id, so a torn-down workstream's claims can be
    /// found and reverted without resolving individual surfaces back to
    /// it. Both are set together by every Atelier-launched terminal, so
    /// one guard covers both.
    private func surfaceAndWorkstream(_ request: Request) throws -> (surfaceID: String, workstreamID: String) {
        guard let surfaceID = request.client.surfaceID, let workstreamID = request.client.workstreamID else {
            throw TaskQueueFailure.noSurface
        }
        return (surfaceID, workstreamID)
    }

    func addTask(for request: Request) async -> Response {
        do {
            let project = try projectDirectory(request)
            let arguments = ToolArguments(request)
            let path = try arguments.requiredTrimmed("path")
            let name = try arguments.requiredTrimmed("name")
            let content = try arguments.required("content")
            let tags = arguments.list("tags")
            let task = try await tasks.add(
                projectDirectory: project, path: path, name: name, content: content,
                tags: tags, createdBySurfaceID: request.client.surfaceID
            )
            return await .success(id: request.id, .task(info(for: task)))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    func getPendingTasks(for request: Request) async -> Response {
        await listing(for: request) { [tasks] project, prefix, tagList in
            await tasks.pending(projectDirectory: project, pathPrefix: prefix, tags: tagList)
        }
    }

    func listTasks(for request: Request) async -> Response {
        await listing(for: request) { [tasks] project, prefix, tagList in
            await tasks.all(projectDirectory: project, pathPrefix: prefix, tags: tagList)
        }
    }

    private func listing(
        for request: Request,
        fetch: (String, String?, [String]) async -> [ProjectTask]
    ) async -> Response {
        do {
            let project = try projectDirectory(request)
            let arguments = ToolArguments(request)
            let prefix = arguments.optional("path_prefix")
            let tagList = arguments.list("tags")
            let found = await fetch(project, prefix, tagList)
            // Resolved once for the whole listing, not per task.
            // `info(for:)`'s own lookup is a `store.listPeers()` hop, so a
            // fifty-task listing made fifty of them to answer one question
            // whose answer cannot change inside the loop.
            let peers = await peersBySurface()
            let infos = found.map { info(for: $0, peers: peers) }
            return .success(id: request.id, .tasks(infos))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    func claimTask(for request: Request) async -> Response {
        do {
            let project = try projectDirectory(request)
            let (surfaceID, workstreamID) = try surfaceAndWorkstream(request)
            let path = try ToolArguments(request).required("path")
            let task = try await tasks.claim(projectDirectory: project, path: path, surfaceID: surfaceID, workstreamID: workstreamID)
            return await .success(id: request.id, .task(info(for: task)))
        } catch let failure as TaskQueueFailure {
            return await .failure(id: request.id, message(for: failure))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    func completeTask(for request: Request) async -> Response {
        do {
            let project = try projectDirectory(request)
            let (surfaceID, _) = try surfaceAndWorkstream(request)
            let path = try ToolArguments(request).required("path")
            let (task, transitioned) = try await tasks.complete(projectDirectory: project, path: path, surfaceID: surfaceID)
            if transitioned {
                await notifyCreator(of: task)
            }
            return await .success(id: request.id, .task(info(for: task)))
        } catch let failure as TaskQueueFailure {
            return await .failure(id: request.id, message(for: failure))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    func failTask(for request: Request) async -> Response {
        do {
            let project = try projectDirectory(request)
            let (surfaceID, _) = try surfaceAndWorkstream(request)
            let arguments = ToolArguments(request)
            let path = try arguments.required("path")
            let reason = try arguments.requiredTrimmed("reason")
            let (task, transitioned) = try await tasks.fail(projectDirectory: project, path: path, surfaceID: surfaceID, reason: reason)
            if transitioned {
                await notifyCreator(of: task)
            }
            return await .success(id: request.id, .task(info(for: task)))
        } catch let failure as TaskQueueFailure {
            return await .failure(id: request.id, message(for: failure))
        } catch {
            return .failure(id: request.id, error.localizedDescription)
        }
    }

    /// Enriches `wrongClaimer` with the current claimant's display name,
    /// resolved live via `peersBySurface()` — the same "resolved at
    /// delivery time, not creation time" rule the verification notices
    /// already follow. Every other failure's stored description is
    /// already complete.
    private func message(for failure: TaskQueueFailure) async -> String {
        guard case let .wrongClaimer(surfaceIDString) = failure else {
            return failure.errorDescription ?? "Task queue error."
        }
        guard let surfaceIDString, let surfaceID = UUID(uuidString: surfaceIDString),
              let peer = await peersBySurface()[surfaceID]
        else {
            return failure.errorDescription ?? "That task is not claimed by you."
        }
        return "That task is claimed by \(peer.name), not you."
    }

    /// Projects an app-side `ProjectTask` into the wire `TaskInfo`,
    /// resolving display names live — never storing them — the same
    /// pattern `MessageInfo.fromName` and the verification notices use.
    private func info(for task: ProjectTask) async -> TaskInfo {
        await info(for: task, peers: peersBySurface())
    }

    /// The same projection against a map the caller already holds, so a
    /// listing resolves the peers once rather than once per task.
    private func info(for task: ProjectTask, peers: [UUID: (id: String, name: String)]) -> TaskInfo {
        func resolved(_ surfaceID: String?) -> (id: String?, name: String?) {
            guard let surfaceID, let uuid = UUID(uuidString: surfaceID), let peer = peers[uuid] else { return (nil, nil) }
            return (peer.id, peer.name)
        }
        let now = Date()
        let created = resolved(task.createdBySurfaceID)

        let wireState: TaskWireState
        var claimedBy: String?
        var claimedByName: String?
        var claimedSecondsAgo: Int?
        var failureReason: String?

        switch task.state {
        case .pending:
            wireState = .pending
        case let .claimed(surfaceID, _, at):
            wireState = .claimed
            let claimant = resolved(surfaceID)
            claimedBy = claimant.id
            claimedByName = claimant.name
            claimedSecondsAgo = Int(now.timeIntervalSince(at))
        case let .completed(surfaceID, at):
            wireState = .completed
            let claimant = resolved(surfaceID)
            claimedBy = claimant.id
            claimedByName = claimant.name
            claimedSecondsAgo = Int(now.timeIntervalSince(at))
        case let .failed(surfaceID, at, reason):
            wireState = .failed
            let claimant = resolved(surfaceID)
            claimedBy = claimant.id
            claimedByName = claimant.name
            claimedSecondsAgo = Int(now.timeIntervalSince(at))
            failureReason = reason
        }

        return TaskInfo(
            path: task.path, name: task.name, content: task.content, tags: task.tags,
            state: wireState, createdSecondsAgo: Int(now.timeIntervalSince(task.createdAt)),
            createdBy: created.id, createdByName: created.name,
            claimedBy: claimedBy, claimedByName: claimedByName, claimedSecondsAgo: claimedSecondsAgo,
            failureReason: failureReason
        )
    }

    /// Posts a notice to a completed/failed task's creator, resolved from
    /// `createdBySurfaceID` **at delivery time** — the same rule
    /// `postVerificationNotice` states, and for the identical reason: the
    /// surface's current occupant can be a different peer than the one
    /// that created the task.
    ///
    /// Best-effort, like the verification notices: no surface recorded,
    /// or no peer currently resolvable there, is an ordinary silent
    /// no-op — the task's result stays readable through
    /// `list_tasks`/`get_pending_tasks` either way.
    private func notifyCreator(of task: ProjectTask) async {
        guard let surfaceIDString = task.createdBySurfaceID, let surfaceID = UUID(uuidString: surfaceIDString) else { return }
        guard let peerID = await peersBySurface()[surfaceID].flatMap({ UUID(uuidString: $0.id) }) else { return }

        let content = TaskSummary.notice(for: task)
        do {
            guard try await store.deliverSystemMessage(from: TaskSummary.sender, to: peerID, content: content) != nil else { return }
        } catch {
            return
        }
        await nudge([peerID], senderName: TaskSummary.sender)
    }

    /// Reverts every task claimed by a surface in `workstreamID` back to
    /// pending. Called from `Workstream.Archiver.remove`/`.purge` when
    /// that workstream's surfaces are torn down for good — never from
    /// `release(peerID:)`, which also fires on an ordinary reconnect race
    /// that must not disturb a live claim. See `IPC.TaskStore
    /// .releaseClaims(inWorkstreamID:)`'s doc comment.
    func releaseTaskClaims(inWorkstream workstreamID: UUID) async {
        _ = await tasks.releaseClaims(inWorkstreamID: workstreamID.uuidString)
    }
}
