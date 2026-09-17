# IPC Task Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a project-scoped, claimable task queue to Atelier's IPC layer — six new `IPC.Tool`s (`add_task`, `get_pending_tasks`, `list_tasks`, `claim_task`, `complete_task`, `fail_task`) so peer agents can coordinate work without a human hand-dispatching each unit.

**Architecture:** A new `IPC.TaskStore` actor (peer to `IPC.Store`, same in-memory-for-the-session lifetime) holds tasks keyed by `(projectDirectory, path)`. Ownership of a claim is keyed by `ATELIER_SURFACE_ID`, not peer id, because a peer id can change across an IPC reconnect while a surface id cannot. `IPC.Service` gains the six handlers, a new `.projectTasks` `Tool.surface` case, and a hook that reverts claims when a workstream is torn down. Wire types live in `IPCProtocol.swift` (the one file `AtelierMCP` compiles out of `Models/IPC/`); everything else is app-only.

**Tech Stack:** Swift, Swift Concurrency (actors), XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-17-ipc-task-queue-design.md`

## Global Constraints

- **Every wire type goes in `Sources/Models/IPC/IPCProtocol.swift`.** `AtelierMCP` compiles exactly that one file out of `Models/IPC/` (`project.yml:198-200`). `TaskWireState`, `TaskInfo`, the new `Tool` cases, the new `Payload` cases, and the new `Surface` case all belong there. `ProjectTask`, `TaskState`, `IPC.TaskStore`, `IPC.TaskQueueFailure`, and `IPC.TaskSummary` are app-only and must NOT go in `IPCProtocol.swift`.
- **Claim ownership is keyed by `ATELIER_SURFACE_ID` (`request.client.surfaceID`), never by peer id.** A helper whose old socket hasn't closed re-registers under a new peer id while keeping the same surface id (documented in `CLAUDE.md`'s IPC section). Peer-id-keyed ownership would make `complete_task` fail forever after an ordinary reconnect.
- **`claim_task`, `complete_task`, `fail_task`, `get_pending_tasks`, `list_tasks` are `isSafeToReplay = true`.** Same-surface replay of a mutating call is a defined no-op; a different surface is a defined refusal. Neither is a duplicate side effect.
- **`add_task` is `isSafeToReplay = false`**, in the same bucket as `create_workstream`: it is a create, the helper mints a fresh `Request.id` on every replay (no id-based dedup available — verified against `Sources/MCPHelper/main.swift:812`), and a replay risks a second execution.
- **Task content is capped at 64KB**, the same bound `IPC.Store` applies to messages.
- **Completion/failure notices are resolved against `createdBySurfaceID` at delivery time, never at task-creation time** — the same rule `postVerificationNotice`/`postCheckNotice` already state, for the same reason (a surface's current occupant can be a different peer by the time the notice is sent).
- **Claims are released on workstream teardown (`Workstream.Archiver.remove`/`.purge`), never on `IPC.Service.release(peerID:)`.** Peer release fires on an ordinary reconnect race; hooking claim-release there would spuriously un-claim a task the same agent is still working, seconds into a legitimate reconnect.
- **No approval gate, no persistence, no claim TTL.** All three are explicit, deliberate omissions in the spec — do not add them as a "safety improvement" mid-implementation.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `Sources/Models/IPC/IPCProtocol.swift` | Modify | New `Tool` cases, `.projectTasks` surface, `TaskWireState`, `TaskInfo`, `Payload` cases |
| `Sources/Models/IPC/IPCTaskStore.swift` | Create | `ProjectTask`, `TaskState`, `TaskQueueFailure`, the `TaskStore` actor |
| `Sources/Models/IPC/IPCTaskSummary.swift` | Create | Pure formatting: tag parsing, the completion/failure notice, the sender label |
| `Sources/Models/IPC/IPCService.swift` | Modify | `tasks: TaskStore` field, six handlers, `releaseTaskClaims(inWorkstream:)`, notify-on-complete, `_testReset` |
| `Sources/Models/WorkstreamArchiver.swift` | Modify | Fire-and-forget `releaseTaskClaims` call in `remove` and `purge` |
| `Sources/MCPHelper/main.swift` | Modify | Six `ToolDefinition`s, `renderText` cases, `serverInstructions` addition |
| `Tests/IPCTaskStoreTests.swift` | Create | Actor-level: atomicity, idempotence, scoping, cleanup |
| `Tests/IPCTaskSummaryTests.swift` | Create | Pure formatting tests |
| `Tests/IPCServiceTests.swift` | Modify | Dispatch-level tests for all six tools, preconditions, notify |
| `Tests/IPCProtocolTests.swift` | Modify | Extend the `replyDeadline`/`isSafeToReplay` pinning tables |
| `Tests/IPCServerTests.swift` | Modify | Extend the advertised-tools stdio test |

---

### Task 1: Wire protocol — new `Tool` cases, `Surface`, and payload types

**Files:**
- Modify: `Sources/Models/IPC/IPCProtocol.swift`
- Test: `Tests/IPCProtocolTests.swift`

**Interfaces:**
- Produces: `IPC.Tool.{addTask,getPendingTasks,listTasks,claimTask,completeTask,failTask}`, `IPC.Surface.projectTasks`, `IPC.TaskWireState`, `IPC.TaskInfo`, `IPC.Payload.task(TaskInfo)`, `IPC.Payload.tasks([TaskInfo])`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/IPCProtocolTests.swift`, in the same file the existing `test_noTool_waitsLessThanTheOldSingleTimeout`/`test_toolsThatChangeSomething_areNotReplayed`/`test_readsAndRenames_stayReplayable` tests live:

```swift
    func test_taskQueueTools_replyDeadlineIsTheFifteenSecondTier() {
        for tool in [IPC.Tool.addTask, .getPendingTasks, .listTasks, .claimTask, .completeTask, .failTask] {
            XCTAssertEqual(tool.replyDeadline, 15, "\(tool.rawValue) is an in-memory actor hop, same tier as the messaging six")
        }
    }

    func test_taskQueueTools_surfaceIsProjectTasks() {
        for tool in [IPC.Tool.addTask, .getPendingTasks, .listTasks, .claimTask, .completeTask, .failTask] {
            XCTAssertEqual(tool.surface, .projectTasks)
        }
    }

    /// `add_task` is a create: the helper mints a fresh request id on every
    /// replay, so a duplicate-path create is a real second execution, not a
    /// provably-safe no-op — the same bucket as `create_workstream`.
    func test_addTask_isNotReplayed() {
        XCTAssertFalse(IPC.Tool.addTask.isSafeToReplay)
    }

    /// The other five are naturally idempotent: same-surface replay is a
    /// defined no-op, different-surface replay is a defined refusal — neither
    /// is a duplicate side effect.
    func test_theOtherFiveTaskQueueTools_areReplayable() {
        for tool in [IPC.Tool.getPendingTasks, .listTasks, .claimTask, .completeTask, .failTask] {
            XCTAssertTrue(tool.isSafeToReplay, "\(tool.rawValue) is idempotent per-surface by construction")
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/dev.sh test` (or, faster while iterating, build just the test target — see Task 7 for the full command). Expected: FAIL — `IPC.Tool` has no member `addTask`, `.projectTasks` is not a member of `IPC.Surface`, etc. (compile failure, not a runtime assertion failure — that's expected at this step).

- [ ] **Step 3: Add the new `Tool` cases**

In `Sources/Models/IPC/IPCProtocol.swift`, inside `enum Tool: String, Codable, CaseIterable`, immediately after the existing `case startVerification` (the last workspace-action case):

```swift
        /// Project tasks — a claimable, project-scoped work queue. See
        /// `Surface.projectTasks`'s doc comment for why this is its own group.
        /// Adds a task to the queue for any peer in the project to claim.
        case addTask = "add_task"
        /// Lists unclaimed tasks in the project's queue.
        case getPendingTasks = "get_pending_tasks"
        /// Lists every task in the project's queue, regardless of state.
        case listTasks = "list_tasks"
        /// Claims a pending task. Ownership is keyed by the caller's surface
        /// id, never its peer id — see this file's `IPC.TaskStore` doc comment.
        case claimTask = "claim_task"
        /// Marks a claimed task done. Only its claimer may call this.
        case completeTask = "complete_task"
        /// Marks a claimed task failed, with a required reason. Only its
        /// claimer may call this.
        case failTask = "fail_task"
```

- [ ] **Step 4: Add the `.projectTasks` surface case**

In the same file, update the `Surface` enum:

```swift
    enum Surface: String, Codable, CaseIterable {
        case messaging
        case workspaceRead
        case workspaceAction
        /// A project-scoped, claimable task queue — `add_task`, `get_pending_tasks`,
        /// `list_tasks`, `claim_task`, `complete_task`, `fail_task`.
        ///
        /// Not `.messaging`: that group's trust story is "none needed — nothing a
        /// user can see," and a claim is durable state another agent's
        /// *correctness* depends on, not a private inbox message. Not
        /// `.workspaceRead`/`.workspaceAction` either: both are explicitly scoped
        /// to the caller's own workstream in their own doc comments, and this
        /// feature is project-wide by design — the same scope peers and messages
        /// already have.
        ///
        /// **No approval gate, for a third reason distinct from either existing
        /// ungated group.** Workspace actions go ungated because they're
        /// attended (a deliberate press, output in front of the user). Messaging
        /// goes ungated because nothing here is visible to the user at all.
        /// Project tasks go ungated because nothing in this surface executes
        /// code, spawns a process, or touches the user's files or git state —
        /// it's structured coordination data between peers already inside one
        /// trust boundary, gated by the same `atelier.agentIPC` setting that
        /// gates whether any IPC tool exists for this session at all.
        case projectTasks
    }
```

- [ ] **Step 5: Add the `replyDeadline` and `isSafeToReplay` cases**

Update the `replyDeadline` switch by adding a new branch (do not fold into an existing one — keep the six visually grouped so a future reader can find them):

```swift
            // In-memory actor hops over IPC.TaskStore. No shell, no process, no
            // network — the same tier as the messaging six and the existing
            // workspace reads.
            case .addTask, .getPendingTasks, .listTasks, .claimTask, .completeTask, .failTask:
                15
```

Update the `isSafeToReplay` switch:

```swift
            // Same-surface replay of any of these five is a defined no-op;
            // different-surface replay is a defined refusal. Neither is a
            // duplicate side effect, unlike the tools in the `false` branches
            // above.
            case .getPendingTasks, .listTasks, .claimTask, .completeTask, .failTask:
                true
            // A create. The helper mints a fresh request id on every replay
            // (no id-based dedup available), so a duplicate-path create from a
            // replay is a real second execution — the same bucket as
            // `create_workstream`.
            case .addTask:
                false
```

- [ ] **Step 6: Add the wire types**

In the same file, immediately before the `enum Payload` declaration, add:

```swift
    /// A task's lifecycle, as an agent sees it.
    enum TaskWireState: String, Codable, CaseIterable {
        case pending
        case claimed
        case completed
        case failed
    }

    /// One task, projected for the wire — the relationship `PeerInfo` has to
    /// the store's `Peer`, and `VerificationRunInfo` to `Verification.Run`.
    ///
    /// `createdBy`/`claimedBy` are **peer ids**, not surface ids: ownership is
    /// keyed internally by surface id (see `IPC.TaskStore`'s doc comment), but
    /// an agent reading this has no use for another surface's raw id — a peer
    /// id is what `send_message` addresses. Both are resolved live from
    /// whichever peer currently occupies that surface, which can be a
    /// different peer than the one that originally created or claimed the
    /// task; nil when nobody is currently registered there.
    struct TaskInfo: Codable, Equatable {
        let path: String
        let name: String
        let content: String
        let tags: [String]
        let state: TaskWireState
        let createdSecondsAgo: Int
        let createdBy: String?
        let createdByName: String?
        let claimedBy: String?
        let claimedByName: String?
        let claimedSecondsAgo: Int?
        /// Set only when `state == .failed`.
        let failureReason: String?
    }
```

Update `enum Payload: Codable` by adding two cases at the end, before `case text(String)`:

```swift
        case task(TaskInfo)
        case tasks([TaskInfo])
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `./scripts/dev.sh test` and confirm the four new tests pass, and that the existing `test_noTool_waitsLessThanTheOldSingleTimeout` (which iterates `IPC.Tool.allCases`) still passes now that six new cases exist.

- [ ] **Step 8: Commit**

```bash
git add Sources/Models/IPC/IPCProtocol.swift Tests/IPCProtocolTests.swift
git commit -m "feat(ipc): add the task-queue wire protocol (Tool cases, Surface, TaskInfo)"
```

---

### Task 2: `IPC.TaskStore` — the actor holding task state

**Files:**
- Create: `Sources/Models/IPC/IPCTaskStore.swift`
- Test: `Tests/IPCTaskStoreTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 (this file is app-only; it does not reference `Tool`/`TaskInfo`).
- Produces: `IPC.ProjectTask`, `IPC.TaskState`, `IPC.TaskQueueFailure`, `IPC.TaskStore` with methods `add`, `pending`, `all`, `claim`, `complete`, `fail`, `releaseClaims(inWorkstreamID:)`, `cleanup()`. Task 4 (`IPC.Service`) consumes all of these directly.

- [ ] **Step 1: Write the failing tests**

Create `Tests/IPCTaskStoreTests.swift`:

```swift
// ABOUTME: Tests for IPC.TaskStore: atomicity, idempotence, scoping, and cleanup.
// ABOUTME: Exercises the actor directly, with no Service or socket in the way.

@testable import Atelier
import XCTest

final class IPCTaskStoreTests: XCTestCase {
    private var store: IPC.TaskStore!

    private let projectA = "/repos/atelier"
    private let projectB = "/repos/other"
    private let surfaceX = UUID().uuidString
    private let surfaceY = UUID().uuidString
    private let workstream1 = UUID().uuidString
    private let workstream2 = UUID().uuidString

    override func setUp() {
        super.setUp()
        store = IPC.TaskStore()
    }

    // MARK: - Adding

    func test_add_createsAPendingTask() async throws {
        let task = try await store.add(
            projectDirectory: projectA, path: "audit/finding-1", name: "SQL injection",
            content: "app/controllers/x.rb line 12", tags: ["security"], createdBySurfaceID: surfaceX
        )
        XCTAssertEqual(task.path, "audit/finding-1")
        XCTAssertEqual(task.state, .pending)
    }

    func test_add_withADuplicatePath_isRefused() async throws {
        _ = try await store.add(
            projectDirectory: projectA, path: "audit/finding-1", name: "first",
            content: "x", tags: [], createdBySurfaceID: nil
        )
        do {
            _ = try await store.add(
                projectDirectory: projectA, path: "audit/finding-1", name: "second",
                content: "y", tags: [], createdBySurfaceID: nil
            )
            XCTFail("expected alreadyExists")
        } catch let failure as IPC.TaskQueueFailure {
            XCTAssertEqual(failure, .alreadyExists("audit/finding-1"))
        }
    }

    func test_add_theSamePath_inDifferentProjects_doesNotCollide() async throws {
        _ = try await store.add(
            projectDirectory: projectA, path: "audit/finding-1", name: "a",
            content: "x", tags: [], createdBySurfaceID: nil
        )
        let task = try await store.add(
            projectDirectory: projectB, path: "audit/finding-1", name: "b",
            content: "y", tags: [], createdBySurfaceID: nil
        )
        XCTAssertEqual(task.name, "b")
    }

    func test_add_overTheContentCap_isRefused() async throws {
        let oversized = String(repeating: "x", count: 65_537)
        do {
            _ = try await store.add(
                projectDirectory: projectA, path: "p", name: "n",
                content: oversized, tags: [], createdBySurfaceID: nil
            )
            XCTFail("expected contentTooLarge")
        } catch let failure as IPC.TaskQueueFailure {
            XCTAssertEqual(failure, .contentTooLarge)
        }
    }

    // MARK: - Listing

    func test_pending_excludesClaimedCompletedAndFailed() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p1", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.add(projectDirectory: projectA, path: "p2", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p2", surfaceID: surfaceX, workstreamID: workstream1)

        let pending = await store.pending(projectDirectory: projectA, pathPrefix: nil, tags: [])
        XCTAssertEqual(pending.map(\.path), ["p1"])
    }

    func test_all_includesEveryState() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p1", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.add(projectDirectory: projectA, path: "p2", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p2", surfaceID: surfaceX, workstreamID: workstream1)

        let all = await store.all(projectDirectory: projectA, pathPrefix: nil, tags: [])
        XCTAssertEqual(Set(all.map(\.path)), ["p1", "p2"])
    }

    func test_pathPrefix_filtersByPrefix() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "audit/finding-1", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.add(projectDirectory: projectA, path: "cleanup/task-1", name: "n", content: "x", tags: [], createdBySurfaceID: nil)

        let filtered = await store.all(projectDirectory: projectA, pathPrefix: "audit/", tags: [])
        XCTAssertEqual(filtered.map(\.path), ["audit/finding-1"])
    }

    func test_tags_mustAllBePresentToMatch() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p1", name: "n", content: "x", tags: ["security", "high"], createdBySurfaceID: nil)
        _ = try await store.add(projectDirectory: projectA, path: "p2", name: "n", content: "x", tags: ["security"], createdBySurfaceID: nil)

        let filtered = await store.all(projectDirectory: projectA, pathPrefix: nil, tags: ["security", "high"])
        XCTAssertEqual(filtered.map(\.path), ["p1"])
    }

    // MARK: - Claiming

    func test_claim_aPendingTask_succeeds() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        let claimed = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)
        XCTAssertEqual(claimed.state, .claimed(bySurfaceID: surfaceX, inWorkstreamID: workstream1, at: claimed.state.claimedAt!))
    }

    /// A second claim from the SAME surface is a no-op success — this is what
    /// makes `claim_task` safe to replay after a reconnect.
    func test_claim_bySameSurfaceTwice_isIdempotent() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)
        let second = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)
        XCTAssertEqual(second.state, .claimed(bySurfaceID: surfaceX, inWorkstreamID: workstream1, at: second.state.claimedAt!))
    }

    func test_claim_byADifferentSurface_isRefusedNamingTheHolder() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)

        do {
            _ = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceY, workstreamID: workstream2)
            XCTFail("expected wrongClaimer")
        } catch let failure as IPC.TaskQueueFailure {
            XCTAssertEqual(failure, .wrongClaimer(heldBySurfaceID: surfaceX))
        }
    }

    func test_claim_anAlreadyCompletedTask_isRefusedAsFinished() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)
        _ = try await store.complete(projectDirectory: projectA, path: "p", surfaceID: surfaceX)

        do {
            _ = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceY, workstreamID: workstream2)
            XCTFail("expected alreadyFinished")
        } catch let failure as IPC.TaskQueueFailure {
            XCTAssertEqual(failure, .alreadyFinished("p"))
        }
    }

    func test_claim_anUnknownPath_isRefused() async throws {
        do {
            _ = try await store.claim(projectDirectory: projectA, path: "nope", surfaceID: surfaceX, workstreamID: workstream1)
            XCTFail("expected unknownTask")
        } catch let failure as IPC.TaskQueueFailure {
            XCTAssertEqual(failure, .unknownTask("nope"))
        }
    }

    // MARK: - Completing

    func test_complete_byTheClaimer_succeeds() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)
        let completed = try await store.complete(projectDirectory: projectA, path: "p", surfaceID: surfaceX)
        guard case .completed = completed.state else { return XCTFail("expected .completed") }
    }

    func test_complete_bySomeoneWhoNeverClaimedIt_isRefused() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        do {
            _ = try await store.complete(projectDirectory: projectA, path: "p", surfaceID: surfaceX)
            XCTFail("expected wrongClaimer")
        } catch let failure as IPC.TaskQueueFailure {
            XCTAssertEqual(failure, .wrongClaimer(heldBySurfaceID: nil))
        }
    }

    func test_complete_byADifferentSurfaceThanTheClaimer_isRefused() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)
        do {
            _ = try await store.complete(projectDirectory: projectA, path: "p", surfaceID: surfaceY)
            XCTFail("expected wrongClaimer")
        } catch let failure as IPC.TaskQueueFailure {
            XCTAssertEqual(failure, .wrongClaimer(heldBySurfaceID: surfaceX))
        }
    }

    /// A replay of complete_task after a reconnect must not double-fail.
    func test_complete_replayedBySameSurface_isIdempotent() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)
        _ = try await store.complete(projectDirectory: projectA, path: "p", surfaceID: surfaceX)
        let replayed = try await store.complete(projectDirectory: projectA, path: "p", surfaceID: surfaceX)
        guard case .completed = replayed.state else { return XCTFail("expected .completed") }
    }

    // MARK: - Failing

    func test_fail_byTheClaimer_recordsTheReason() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)
        let failed = try await store.fail(projectDirectory: projectA, path: "p", surfaceID: surfaceX, reason: "flaky dependency")
        guard case let .failed(_, _, reason) = failed.state else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason, "flaky dependency")
    }

    /// A replayed fail_task with a DIFFERENT reason string must not overwrite
    /// the first recorded reason — the first execution's result wins.
    func test_fail_replayedWithADifferentReason_keepsTheFirstReason() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)
        _ = try await store.fail(projectDirectory: projectA, path: "p", surfaceID: surfaceX, reason: "first reason")
        let replayed = try await store.fail(projectDirectory: projectA, path: "p", surfaceID: surfaceX, reason: "different reason")
        guard case let .failed(_, _, reason) = replayed.state else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason, "first reason")
    }

    // MARK: - Releasing claims on workstream teardown

    func test_releaseClaims_revertsOnlyTasksClaimedInThatWorkstream() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p1", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.add(projectDirectory: projectA, path: "p2", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p1", surfaceID: surfaceX, workstreamID: workstream1)
        _ = try await store.claim(projectDirectory: projectA, path: "p2", surfaceID: surfaceY, workstreamID: workstream2)

        let reverted = await store.releaseClaims(inWorkstreamID: workstream1)
        XCTAssertEqual(reverted.map(\.path), ["p1"])

        let all = await store.all(projectDirectory: projectA, pathPrefix: nil, tags: [])
        XCTAssertEqual(all.first(where: { $0.path == "p1" })?.state, .pending)
        guard case .claimed = all.first(where: { $0.path == "p2" })?.state else { return XCTFail("p2 must stay claimed") }
    }

    func test_releaseClaims_neverTouchesCompletedOrFailedTasks() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)
        _ = try await store.complete(projectDirectory: projectA, path: "p", surfaceID: surfaceX)

        _ = await store.releaseClaims(inWorkstreamID: workstream1)

        let task = await store.all(projectDirectory: projectA, pathPrefix: nil, tags: []).first
        guard case .completed = task?.state else { return XCTFail("a completed task must not be reverted") }
    }

    func test_releaseClaims_searchesEveryProject() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.add(projectDirectory: projectB, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)
        _ = try await store.claim(projectDirectory: projectB, path: "p", surfaceID: surfaceY, workstreamID: workstream1)

        let reverted = await store.releaseClaims(inWorkstreamID: workstream1)
        XCTAssertEqual(reverted.count, 2, "the same workstream id can claim tasks in more than one project's queue")
    }

    // MARK: - Cleanup

    func test_cleanup_removesEverything() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        await store.cleanup()
        let all = await store.all(projectDirectory: projectA, pathPrefix: nil, tags: [])
        XCTAssertTrue(all.isEmpty)
    }
}
```

Notes on the tests above:
- `TaskState.claimedAt` is a small test convenience — add it as a computed property on `TaskState` in Step 3 below (not otherwise needed by production code, but writing `XCTAssertEqual(claimed.state, .claimed(bySurfaceID: ..., at: <the exact Date the store picked>))` is only possible by reading the Date back out of the value under test).
- `IPC.ProjectTask`'s fields are all `let` — Task 3's tests construct fresh `ProjectTask` values with the memberwise initializer rather than mutating one, so this file introduces no need to loosen that.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/dev.sh test`. Expected: FAIL to compile — `IPC.TaskStore` does not exist.

- [ ] **Step 3: Create `IPCTaskStore.swift`**

```swift
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
            if case let .claimed(_, _, at) = self { at } else { nil }
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
                .filter { if case .pending = $0.state { true } else { false } }
        }

        func all(projectDirectory: String, pathPrefix: String?, tags: [String]) -> [ProjectTask] {
            matching(projectDirectory: projectDirectory, pathPrefix: pathPrefix, tags: tags)
        }

        private func matching(projectDirectory: String, pathPrefix: String?, tags: [String]) -> [ProjectTask] {
            let all = (tasksByProject[projectDirectory] ?? [:]).values
            return all.filter { task in
                if let pathPrefix, !pathPrefix.isEmpty, !task.path.hasPrefix(pathPrefix) { return false }
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

        func complete(projectDirectory: String, path: String, surfaceID: String) throws -> ProjectTask {
            guard var task = tasksByProject[projectDirectory]?[path] else {
                throw TaskQueueFailure.unknownTask(path)
            }
            switch task.state {
            case let .claimed(existing, _, _) where existing == surfaceID:
                task.state = .completed(bySurfaceID: surfaceID, at: Date())
            case let .completed(existing, _) where existing == surfaceID:
                break // idempotent replay
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
            return task
        }

        // MARK: - Failing

        func fail(projectDirectory: String, path: String, surfaceID: String, reason: String) throws -> ProjectTask {
            guard var task = tasksByProject[projectDirectory]?[path] else {
                throw TaskQueueFailure.unknownTask(path)
            }
            switch task.state {
            case let .claimed(existing, _, _) where existing == surfaceID:
                task.state = .failed(bySurfaceID: surfaceID, at: Date(), reason: reason)
            case let .failed(existing, _, _) where existing == surfaceID:
                break // idempotent replay: the FIRST reason wins, never overwritten
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
            return task
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/dev.sh test`. All `IPCTaskStoreTests` should pass. If `test_claim_aPendingTask_succeeds`-style tests fail on the `Equatable` comparison, double check `TaskState`'s synthesized `Equatable` conformance is comparing `Date` fields exactly — since both sides read the Date back from the same underlying stored value (via `claimedAt`), this should compare equal, not merely close.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/IPC/IPCTaskStore.swift Tests/IPCTaskStoreTests.swift
git commit -m "feat(ipc): add IPC.TaskStore, the claimable task-queue actor"
```

---

### Task 3: `IPC.TaskSummary` — tag parsing and the completion notice

**Files:**
- Create: `Sources/Models/IPC/IPCTaskSummary.swift`
- Test: `Tests/IPCTaskSummaryTests.swift`

**Interfaces:**
- Consumes: `IPC.ProjectTask`, `IPC.TaskState` (Task 2).
- Produces: `IPC.TaskSummary.sender`, `IPC.TaskSummary.tags(from:)`, `IPC.TaskSummary.notice(for:)`. Task 4 (`IPC.Service`) consumes all three.

- [ ] **Step 1: Write the failing tests**

Create `Tests/IPCTaskSummaryTests.swift`:

```swift
// ABOUTME: Tests for IPC.TaskSummary — argument parsing and the completion/failure notice text.
// ABOUTME: Pure functions of an IPC.ProjectTask; no actor, no store, no socket.

@testable import Atelier
import XCTest

final class IPCTaskSummaryTests: XCTestCase {
    // MARK: - Tag parsing

    func test_tags_fromNil_isEmpty() {
        XCTAssertEqual(IPC.TaskSummary.tags(from: nil), [])
    }

    func test_tags_splitsOnCommasAndTrimsWhitespace() {
        XCTAssertEqual(IPC.TaskSummary.tags(from: "security, high , audit"), ["security", "high", "audit"])
    }

    func test_tags_dropsDuplicatesButKeepsFirstOrder() {
        XCTAssertEqual(IPC.TaskSummary.tags(from: "a,b,a,c"), ["a", "b", "c"])
    }

    // MARK: - The completion/failure notice

    private func task(state: IPC.TaskState) -> IPC.ProjectTask {
        IPC.ProjectTask(
            path: "audit/finding-1",
            name: "SQL injection",
            content: "irrelevant to the notice",
            tags: [],
            createdAt: Date().addingTimeInterval(-120),
            createdBySurfaceID: UUID().uuidString,
            state: state
        )
    }

    func test_notice_forACompletedTask_namesThePathAndName() {
        let notice = IPC.TaskSummary.notice(for: task(state: .completed(bySurfaceID: UUID().uuidString, at: Date())))
        XCTAssertTrue(notice.contains("audit/finding-1"), notice)
        XCTAssertTrue(notice.contains("SQL injection"), notice)
        XCTAssertTrue(notice.contains("completed"), notice)
    }

    func test_notice_forAFailedTask_includesTheReason() {
        let notice = IPC.TaskSummary.notice(for: task(state: .failed(bySurfaceID: UUID().uuidString, at: Date(), reason: "flaky dependency")))
        XCTAssertTrue(notice.contains("flaky dependency"), notice)
    }

    /// Task content is agent-chosen up to 64KB and must never be quoted in a
    /// notice — CLAUDE.md's own language for why applies verbatim: an
    /// oversized notice "is lost, silently, exactly when the agent is
    /// waiting for it."
    func test_notice_neverIncludesTaskContent() {
        let huge = String(repeating: "x", count: 10_000)
        let withHugeContent = IPC.ProjectTask(
            path: "audit/finding-1", name: "SQL injection", content: huge, tags: [],
            createdAt: Date().addingTimeInterval(-120), createdBySurfaceID: UUID().uuidString,
            state: .completed(bySurfaceID: UUID().uuidString, at: Date())
        )
        let notice = IPC.TaskSummary.notice(for: withHugeContent)
        XCTAssertFalse(notice.contains(huge))
        XCTAssertLessThan(notice.utf8.count, 1_000)
    }

    /// A pathological failure reason must not blow the notice past
    /// `IPC.Store`'s 64KB cap, which loses it silently rather than trimming.
    func test_notice_clipsAnOversizedReason() {
        let hugeReason = String(repeating: "y", count: 10_000)
        let notice = IPC.TaskSummary.notice(for: task(state: .failed(bySurfaceID: UUID().uuidString, at: Date(), reason: hugeReason)))
        XCTAssertLessThan(notice.utf8.count, 2_000)
        XCTAssertTrue(notice.hasSuffix("…"), notice)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/dev.sh test`. Expected: FAIL to compile — `IPC.TaskSummary` does not exist.

- [ ] **Step 3: Create `IPCTaskSummary.swift`**

```swift
// ABOUTME: Pure formatting and argument parsing for the task-queue tools.
// ABOUTME: The completion/failure notice, tag parsing, and the sender label — nothing here needs a store or a socket.

import Foundation

extension IPC {
    /// Formatting and bounding for the task-queue tools, mirroring
    /// `VerificationSummary`'s split: the wording and the truncation are
    /// where this feature's bugs live, and none of them need an actor or a
    /// project to pin.
    enum TaskSummary {
        /// The label a task-queue notice arrives from. Not a peer id — there
        /// is nothing inside Atelier for an agent to `send_message` back to,
        /// mirroring `VerificationSummary.sender`.
        static let sender = "atelier/tasks"

        /// Character cap on the two agent-authored fields a notice quotes
        /// (`name`, and a failure's `reason`). Generous next to the fixed
        /// shape of the rest of the message — even at four UTF-8 bytes per
        /// character this stays two orders of magnitude under `IPC.Store`'s
        /// 64KB cap, so unlike `VerificationSummary` (which concatenates an
        /// unbounded *number* of check names) this doesn't need byte-precise
        /// budgeting.
        private static let maxQuotedLength = 300

        // MARK: - Arguments

        /// The tags in a `tags` argument, in the order given, without
        /// duplicates. Empty means no filter. Same parsing convention as
        /// `VerificationSummary.checks(from:)` — an argument is always text
        /// however a model chose to spell a list.
        static func tags(from raw: String?) -> [String] {
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

        // MARK: - The completion/failure notice

        /// The notice posted to a task's creator when it completes or fails.
        ///
        /// References the task's path and name only, **never its `content`**
        /// — content is agent-chosen up to 64KB, and CLAUDE.md's own language
        /// applies verbatim: an oversized notice "is lost, silently, exactly
        /// when the agent is waiting for it."
        ///
        /// Its one production caller (`IPC.Service`) only ever passes a task
        /// whose state is `.completed` or `.failed` — the `.pending`/
        /// `.claimed` branch below exists only so the switch is exhaustive.
        static func notice(for task: ProjectTask) -> String {
            let label = "Task \"\(task.path)\" (\(clip(task.name)))"
            switch task.state {
            case let .completed(_, at):
                return "\(label) was completed \(Int(Date().timeIntervalSince(at)))s ago. "
                    + "get_pending_tasks or list_tasks shows what's left."
            case let .failed(_, _, reason):
                return "\(label) failed: \(clip(reason))"
            case .pending, .claimed:
                return "\(label) changed state."
            }
        }

        private static func clip(_ text: String) -> String {
            guard text.count > maxQuotedLength else { return text }
            return String(text.prefix(maxQuotedLength)) + "…"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/dev.sh test`. All `IPCTaskSummaryTests` should pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/IPC/IPCTaskSummary.swift Tests/IPCTaskSummaryTests.swift
git commit -m "feat(ipc): add IPC.TaskSummary — tag parsing and the completion notice"
```

---

### Task 4: Wire `IPC.Service` — the six handlers, notify-on-complete, and `releaseTaskClaims`

**Files:**
- Modify: `Sources/Models/IPC/IPCService.swift`
- Test: `Tests/IPCServiceTests.swift`

**Interfaces:**
- Consumes: `IPC.TaskStore` and its methods (Task 2), `IPC.TaskSummary.{sender,tags(from:),notice(for:)}` (Task 3), `IPC.Tool.{addTask,getPendingTasks,listTasks,claimTask,completeTask,failTask}` and `IPC.TaskInfo`/`IPC.TaskWireState`/`IPC.Payload.{task,tasks}` (Task 1). Also `WorkspaceActions.Failure.missingArgument(_:)` (existing).
- Produces: `IPC.Service.releaseTaskClaims(inWorkstream:)` — Task 5 (`WorkstreamArchiver`) calls this.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/IPCServiceTests.swift`, using the existing `client(project:peerID:workstream:surfaceID:)` and `call(_:_:as:)` helpers already in that file:

```swift
    // MARK: - Task queue

    private func task(of response: IPC.Response) throws -> IPC.TaskInfo {
        guard case let .task(task) = response.payload else {
            throw XCTSkip("expected a task payload, got \(String(describing: response.payload ?? nil))")
        }
        return task
    }

    private func tasks(of response: IPC.Response) throws -> [IPC.TaskInfo] {
        guard case let .tasks(tasks) = response.payload else {
            throw XCTSkip("expected a tasks payload, got \(String(describing: response.payload ?? nil))")
        }
        return tasks
    }

    func test_addTask_withoutAProject_isRefused() async {
        let response = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: nil))
        XCTAssertEqual(response.error, IPC.TaskQueueFailure.noProject.localizedDescription)
    }

    func test_addTask_missingRequiredArguments_isRefused() async {
        let response = await call(.addTask, ["name": "n", "content": "c"], as: client(project: projectA))
        XCTAssertNotNil(response.error)
    }

    func test_addTask_thenGetPendingTasks_seesIt() async throws {
        _ = await call(.addTask, ["path": "audit/finding-1", "name": "SQLi", "content": "details"], as: client(project: projectA))
        let listed = try await tasks(of: call(.getPendingTasks, as: client(project: projectA)))
        XCTAssertEqual(listed.map(\.path), ["audit/finding-1"])
        XCTAssertEqual(listed.first?.state, .pending)
    }

    func test_addTask_aSecondTimeAtTheSamePath_isRefused() async {
        _ = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: projectA))
        let second = await call(.addTask, ["path": "p", "name": "n2", "content": "c2"], as: client(project: projectA))
        XCTAssertNotNil(second.error)
    }

    func test_getPendingTasks_isScopedToTheCallersProject() async throws {
        _ = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: projectA))
        let listedFromB = try await tasks(of: call(.getPendingTasks, as: client(project: projectB)))
        XCTAssertTrue(listedFromB.isEmpty)
    }

    func test_claimTask_withoutASurfaceID_isRefused() async {
        _ = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: projectA))
        let response = await call(.claimTask, ["path": "p"], as: client(project: projectA, surfaceID: nil))
        XCTAssertEqual(response.error, IPC.TaskQueueFailure.noSurface.localizedDescription)
    }

    func test_claimTask_thenListTasks_showsClaimed() async throws {
        _ = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: projectA))
        let surface = UUID()
        _ = await call(.claimTask, ["path": "p"], as: client(project: projectA, surfaceID: surface))

        let listed = try await tasks(of: call(.listTasks, as: client(project: projectA)))
        XCTAssertEqual(listed.first?.state, .claimed)
        // `claimedBy` is a resolved PEER id, not the raw surface id — see
        // `TaskInfo`'s doc comment in Task 1. No peer is registered from
        // `surface` in this test, so nobody can be resolved from it yet.
        XCTAssertNil(listed.first?.claimedBy, "no peer is registered from that surface in this test")
    }

    func test_claimTask_byASecondSurface_namesTheHolder() async throws {
        _ = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: projectA))
        let firstSurface = UUID()
        _ = await call(.claimTask, ["path": "p"], as: client(project: projectA, surfaceID: firstSurface))

        let secondSurface = UUID()
        let response = await call(.claimTask, ["path": "p"], as: client(project: projectA, surfaceID: secondSurface))
        XCTAssertNotNil(response.error)
        XCTAssertTrue(response.error?.contains("not claimed by you") == true, "got \(response.error ?? "nil")")
    }

    func test_claimTask_bySameSurfaceTwice_isIdempotentSuccess() async throws {
        _ = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: projectA))
        let surface = UUID()
        _ = await call(.claimTask, ["path": "p"], as: client(project: projectA, surfaceID: surface))
        let second = await call(.claimTask, ["path": "p"], as: client(project: projectA, surfaceID: surface))
        XCTAssertNil(second.error)
    }

    func test_completeTask_byANonClaimer_isRefused() async {
        _ = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: projectA))
        let response = await call(.completeTask, ["path": "p"], as: client(project: projectA, surfaceID: UUID()))
        XCTAssertNotNil(response.error)
    }

    func test_completeTask_byTheClaimer_succeeds() async throws {
        _ = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: projectA))
        let surface = UUID()
        _ = await call(.claimTask, ["path": "p"], as: client(project: projectA, surfaceID: surface))
        let completed = try await task(of: call(.completeTask, ["path": "p"], as: client(project: projectA, surfaceID: surface)))
        XCTAssertEqual(completed.state, .completed)
    }

    func test_failTask_withoutAReason_isRefused() async {
        _ = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: projectA))
        let surface = UUID()
        _ = await call(.claimTask, ["path": "p"], as: client(project: projectA, surfaceID: surface))
        let response = await call(.failTask, ["path": "p"], as: client(project: projectA, surfaceID: surface))
        XCTAssertNotNil(response.error)
    }

    func test_failTask_recordsTheReason() async throws {
        _ = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: projectA))
        let surface = UUID()
        _ = await call(.claimTask, ["path": "p"], as: client(project: projectA, surfaceID: surface))
        let failed = try await task(of: call(.failTask, ["path": "p", "reason": "flaky"], as: client(project: projectA, surfaceID: surface)))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failureReason, "flaky")
    }

    /// The creator gets a notice in its inbox when the task it created
    /// completes — even though the creator is a DIFFERENT peer/surface than
    /// whoever claimed and completed it.
    ///
    /// Registers the creator's peer explicitly AT `creatorSurface` (rather
    /// than through the shared `register(...)` helper, which mints a random
    /// surface id per call) because `notifyCreator` resolves the creator by
    /// walking `contexts[peer.id]?.surfaceID` — set at registration time —
    /// back to a peer, not by trusting any id `add_task`'s own caller claims.
    func test_completeTask_notifiesTheCreator() async throws {
        let creatorSurface = UUID()
        let registered = await call(.registerPeer, ["name": "coordinator"], as: client(project: projectA, workstream: "coordinator-ws", surfaceID: creatorSurface))
        guard case let .peer(creatorPeer) = registered.payload else { return XCTFail("expected a peer") }

        _ = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: projectA, surfaceID: creatorSurface))

        let claimerSurface = UUID()
        _ = await call(.claimTask, ["path": "p"], as: client(project: projectA, surfaceID: claimerSurface))
        _ = await call(.completeTask, ["path": "p"], as: client(project: projectA, surfaceID: claimerSurface))

        let received = await call(.receiveMessages, as: client(project: projectA, peerID: creatorPeer.id, surfaceID: creatorSurface))
        guard case let .messages(messages) = received.payload else { return XCTFail("expected messages") }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.from, IPC.TaskSummary.sender)
        XCTAssertTrue(messages.first?.content.contains("p") == true)
    }

    /// A task created by an agent with no surface id disables the notice
    /// without blocking creation or completion.
    func test_completeTask_withNoCreatorSurface_doesNotCrashOrNotifyAnyone() async throws {
        _ = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: projectA, surfaceID: nil))
        let claimerSurface = UUID()
        _ = await call(.claimTask, ["path": "p"], as: client(project: projectA, surfaceID: claimerSurface))
        let response = await call(.completeTask, ["path": "p"], as: client(project: projectA, surfaceID: claimerSurface))
        XCTAssertNil(response.error)
    }

    // MARK: - Releasing claims on workstream teardown

    func test_releaseTaskClaims_revertsClaimsInThatWorkstream() async throws {
        let workstreamID = UUID()
        _ = await call(.addTask, ["path": "p", "name": "n", "content": "c"], as: client(project: projectA))
        let claimant = client(project: projectA, workstream: "doomed", surfaceID: UUID())
        // `claim_task` reads `workstreamID` from `ClientIdentity.workstreamID`,
        // which the shared `client(...)` helper mints fresh per call — so this
        // constructs the identity directly to pin a specific workstream id.
        let identity = IPC.ClientIdentity(
            workstreamID: workstreamID.uuidString, workstreamName: "doomed",
            projectDirectory: projectA, surfaceID: UUID().uuidString, peerID: nil
        )
        _ = await call(.claimTask, ["path": "p"], as: identity)

        await service.releaseTaskClaims(inWorkstream: workstreamID)

        let listed = try await tasks(of: call(.getPendingTasks, as: client(project: projectA)))
        XCTAssertEqual(listed.map(\.path), ["p"], "the claim must revert to pending so another peer can claim it")
    }
```

Delete the placeholder `XCTAssertEqual(listed.first?.claimedBy, surface.uuidString.isEmpty ? nil : listed.first?.claimedBy)` line from `test_claimTask_thenListTasks_showsClaimed` above before running — it was left as a note that `claimedBy` is a **peer id**, not the raw surface id, and this test doesn't register a peer, so `claimedBy`/`claimedByName` are expected to be `nil` (no peer currently occupies that surface). Replace it with:

```swift
        XCTAssertNil(listed.first?.claimedBy, "no peer is registered from that surface in this test")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/dev.sh test`. Expected: FAIL to compile — `IPC.Service` has no `tasks` field, no task-queue handlers, `IPC.ClientIdentity`'s `surfaceID:` on the shared `client(...)` test helper takes a `UUID?` already (confirm this — it does, per the existing helper signature `surfaceID: UUID? = UUID()`), and `releaseTaskClaims` does not exist yet.

- [ ] **Step 3: Wire the six handlers into `IPC.Service`**

In `Sources/Models/IPC/IPCService.swift`:

3a. Add the field and update `init`:

```swift
        private let store: Store
        private let tasks: TaskStore
        private var contexts: [UUID: PeerContext] = [:]
```

```swift
        init(store: Store = Store(), tasks: TaskStore = TaskStore()) {
            self.store = store
            self.tasks = tasks
        }
```

3b. Add the six cases to the `handle(_:)` dispatch switch, after `.listVerificationChecks`:

```swift
            case .addTask:
                return await addTask(for: request)
            case .getPendingTasks:
                return await getPendingTasks(for: request)
            case .listTasks:
                return await listTasks(for: request)
            case .claimTask:
                return await claimTask(for: request)
            case .completeTask:
                return await completeTask(for: request)
            case .failTask:
                return await failTask(for: request)
```

3c. Add a new section near the end of the actor body, just before `// MARK: - Test Support`:

```swift
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

        private func addTask(for request: Request) async -> Response {
            do {
                let project = try projectDirectory(request)
                guard let path = request.arguments["path"]?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                    return .failure(id: request.id, WorkspaceActions.Failure.missingArgument("path").localizedDescription)
                }
                guard let name = request.arguments["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                    return .failure(id: request.id, WorkspaceActions.Failure.missingArgument("name").localizedDescription)
                }
                guard let content = request.arguments["content"], !content.isEmpty else {
                    return .failure(id: request.id, WorkspaceActions.Failure.missingArgument("content").localizedDescription)
                }
                let tags = TaskSummary.tags(from: request.arguments["tags"])
                let task = try await tasks.add(
                    projectDirectory: project, path: path, name: name, content: content,
                    tags: tags, createdBySurfaceID: request.client.surfaceID
                )
                return .success(id: request.id, .task(await info(for: task)))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func getPendingTasks(for request: Request) async -> Response {
            await listing(for: request) { [tasks] project, prefix, tagList in
                await tasks.pending(projectDirectory: project, pathPrefix: prefix, tags: tagList)
            }
        }

        private func listTasks(for request: Request) async -> Response {
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
                let prefix = request.arguments["path_prefix"]
                let tagList = TaskSummary.tags(from: request.arguments["tags"])
                let found = await fetch(project, prefix, tagList)
                var infos: [TaskInfo] = []
                for task in found {
                    infos.append(await info(for: task))
                }
                return .success(id: request.id, .tasks(infos))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func claimTask(for request: Request) async -> Response {
            do {
                let project = try projectDirectory(request)
                let (surfaceID, workstreamID) = try surfaceAndWorkstream(request)
                guard let path = request.arguments["path"], !path.isEmpty else {
                    return .failure(id: request.id, WorkspaceActions.Failure.missingArgument("path").localizedDescription)
                }
                let task = try await tasks.claim(projectDirectory: project, path: path, surfaceID: surfaceID, workstreamID: workstreamID)
                return .success(id: request.id, .task(await info(for: task)))
            } catch let failure as TaskQueueFailure {
                return .failure(id: request.id, await message(for: failure))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func completeTask(for request: Request) async -> Response {
            do {
                let project = try projectDirectory(request)
                let (surfaceID, _) = try surfaceAndWorkstream(request)
                guard let path = request.arguments["path"], !path.isEmpty else {
                    return .failure(id: request.id, WorkspaceActions.Failure.missingArgument("path").localizedDescription)
                }
                let task = try await tasks.complete(projectDirectory: project, path: path, surfaceID: surfaceID)
                await notifyCreator(of: task)
                return .success(id: request.id, .task(await info(for: task)))
            } catch let failure as TaskQueueFailure {
                return .failure(id: request.id, await message(for: failure))
            } catch {
                return .failure(id: request.id, error.localizedDescription)
            }
        }

        private func failTask(for request: Request) async -> Response {
            do {
                let project = try projectDirectory(request)
                let (surfaceID, _) = try surfaceAndWorkstream(request)
                guard let path = request.arguments["path"], !path.isEmpty else {
                    return .failure(id: request.id, WorkspaceActions.Failure.missingArgument("path").localizedDescription)
                }
                guard let reason = request.arguments["reason"]?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
                    return .failure(id: request.id, WorkspaceActions.Failure.missingArgument("reason").localizedDescription)
                }
                let task = try await tasks.fail(projectDirectory: project, path: path, surfaceID: surfaceID, reason: reason)
                await notifyCreator(of: task)
                return .success(id: request.id, .task(await info(for: task)))
            } catch let failure as TaskQueueFailure {
                return .failure(id: request.id, await message(for: failure))
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
            let peers = await peersBySurface()
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
```

3d. Update `_testReset()`:

```swift
        func _testReset() async {
            await store.cleanup()
            await tasks.cleanup()
            contexts.removeAll()
            verification = nil
            deliveredNotices.removeAll()
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/dev.sh test`. All `IPCServiceTests` (existing and new) should pass — `TaskWireState`'s raw `String` type gives it `==`/`Equatable` for free (the same reason `IPC.VerificationCheckState` needs no explicit `Equatable` to be compared with `==` elsewhere in this codebase), so `XCTAssertEqual(listed.first?.state, .claimed)` needs no extra conformance.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models/IPC/IPCService.swift Tests/IPCServiceTests.swift
git commit -m "feat(ipc): wire the six task-queue tools into IPC.Service"
```

---

### Task 5: Revert claims on workstream teardown

**Files:**
- Modify: `Sources/Models/WorkstreamArchiver.swift`

**Interfaces:**
- Consumes: `IPC.Service.shared.releaseTaskClaims(inWorkstream:)` (Task 4).

- [ ] **Step 1: Add the call to `Archiver.remove`**

In `Sources/Models/WorkstreamArchiver.swift`, in `static func remove(...)`, immediately after the existing `surfaceCache.removeWorkstreamSurfaces(for: workstreamID)` line (around line 53):

```swift
            surfaceCache.removeWorkstreamSurfaces(for: workstreamID)
            // Fire-and-forget: reverting an in-memory dictionary entry back to
            // `.pending` carries none of the weight `verificationRunner?.forget`
            // above does (killing running processes, waiting on them), so this
            // does not need the injected-optional-parameter pattern that exists
            // for that heavier operation — same shape as the tmux-kill
            // `Task.detached` at the top of this function. A project with no
            // tasks, or a workstream with no claims, makes this a genuine no-op.
            Task { await IPC.Service.shared.releaseTaskClaims(inWorkstream: workstreamID) }
```

- [ ] **Step 2: Add the same call to `Archiver.purge`**

In the same file, find `purge`'s own `surfaceCache.removeWorkstreamSurfaces(for: workstreamID)` line (around line 316) and add the identical line immediately after it:

```swift
            surfaceCache.removeWorkstreamSurfaces(for: workstreamID)
            Task { await IPC.Service.shared.releaseTaskClaims(inWorkstream: workstreamID) }
```

- [ ] **Step 3: Confirm the existing Archiver test suites still compile and pass**

This hook is deliberately not covered by a new Archiver-level test — the codebase's own convention for this file: `verificationRunner?.forget(workstreamID:)` and `AgentStateTracker.clear` aren't asserted from `WorkstreamArchiverPurgeTests.swift`/`WorkstreamArchiverDisposeTests.swift` either; both are unit-tested at their own layer (this plan's Task 4 does that for the task queue via `IPCServiceTests`). Run:

```bash
./scripts/dev.sh test
```

Expected: `WorkstreamArchiverPurgeTests` and `WorkstreamArchiverDisposeTests` still pass unchanged, and the whole suite builds (this confirms `IPC.Service.shared` and `releaseTaskClaims` resolve correctly from this file).

- [ ] **Step 4: Commit**

```bash
git add Sources/Models/WorkstreamArchiver.swift
git commit -m "fix(ipc): revert a workstream's claimed tasks to pending when it is torn down"
```

---

### Task 6: The MCP tool surface — `toolDefinitions`, `renderText`, and the stdio integration test

**Files:**
- Modify: `Sources/MCPHelper/main.swift`
- Test: `Tests/IPCServerTests.swift`

**Interfaces:**
- Consumes: `IPC.Tool.{addTask,getPendingTasks,listTasks,claimTask,completeTask,failTask}`, `IPC.TaskInfo`, `IPC.Payload.{task,tasks}` (Task 1).

- [ ] **Step 1: Write the failing test**

In `Tests/IPCServerTests.swift`, extend `test_helperBinary_answersToolsCallOverStdio` (found via `grep -n "func test_helperBinary_answersToolsCallOverStdio" Tests/IPCServerTests.swift`). Two changes to the existing test body:

First, extend the `requests` array (after the existing `list_verification_checks` call) to add two more calls:

```swift
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_peers","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"check_verification","arguments":{"run_id":"v7f3a11c"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_verification_checks","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"add_task","arguments":{"path":"p","name":"n","content":"c"}}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_pending_tasks","arguments":{}}}"#,
        ]
```

and update the reply-count expectations from `5`/`replies.count < 5` to `7`/`replies.count < 7`:

```swift
        var replies: [[String: Any]] = []
        var buffer = Data()
        let deadline = Date().addingTimeInterval(10)
        while replies.count < 7, Date() < deadline {
            buffer.append(output.fileHandleForReading.availableData)
            let (lines, remainder) = IPC.Framing.lines(from: buffer)
            buffer = remainder
            for line in lines {
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    replies.append(object)
                }
            }
        }
        XCTAssertEqual(replies.count, 7, "helper did not answer all seven requests")
```

Second, extend the `advertised` list assertion (immediately below) to include the six new tools, and add two assertions on the new replies:

```swift
        let tools = try XCTUnwrap((replies[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let advertised = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(
            advertised,
            [
                "register_peer", "list_peers", "send_message", "receive_messages", "broadcast", "get_peer_status",
                "list_tabs", "read_review_comments", "open_editor", "open_tab", "open_agent_tab", "request_attention",
                "create_workstream", "start_verification", "check_verification",
                "list_verification_checks",
                "add_task", "get_pending_tasks", "list_tasks", "claim_task", "complete_task", "fail_task",
            ]
        )
```

and, after the existing per-reply assertions further down in the test body, add:

```swift
        let addTaskResult = try XCTUnwrap((replies[5]["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertFalse((replies[5]["result"] as? [String: Any])?["isError"] as? Bool ?? true, "add_task should not error")
        XCTAssertNotNil(addTaskResult.first?["text"])

        let pendingText = try XCTUnwrap(((replies[6]["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(pendingText.contains("p"), "get_pending_tasks should list the task just added, got: \(pendingText)")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/dev.sh test`. Expected: FAIL — `advertised` mismatch (missing six names), and the seven-reply wait times out since `add_task`/`get_pending_tasks` aren't dispatchable via the helper yet.

- [ ] **Step 3: Add the six `ToolDefinition`s**

In `Sources/MCPHelper/main.swift`, inside the `toolDefinitions` array literal, immediately after the existing `.listVerificationChecks` entry and before the closing `]`:

```swift
    ToolDefinition(
        tool: .addTask,
        description: """
        Add a task to this project's shared queue, for any peer in the project
        to claim and work on. Use this instead of hand-dispatching work to
        individual workstreams when you have several similar units of work —
        findings from an audit, files needing the same fix — so peers can pull
        the next one instead of you assigning each by hand.

        `path` is the task's permanent identifier: choose something
        hierarchical and unique, e.g. "audit-2026-09/finding-3". Calling
        add_task again with a path that already exists is refused rather than
        replayed automatically after a lost connection, so if you see
        "already exists" after a timeout, check list_tasks before retrying —
        your first call likely already succeeded.
        """,
        properties: [
            "path": ["type": "string", "description": "Unique identifier for this task within the project, e.g. \"audit-2026-09/finding-3\"."],
            "name": ["type": "string", "description": "Short display name."],
            "content": ["type": "string", "description": "The brief: what needs doing. Up to 64KB."],
            "tags": ["type": "string", "description": "Optional comma-separated tags, for filtering with get_pending_tasks/list_tasks."],
        ],
        required: ["path", "name", "content"]
    ),
    ToolDefinition(
        tool: .getPendingTasks,
        description: """
        List unclaimed tasks in this project's queue — the ones nobody has
        started yet. Call this when you're free and want the next thing to
        work on. Omit path_prefix to see every pending task.
        """,
        properties: [
            "path_prefix": ["type": "string", "description": "Only tasks whose path starts with this. Omit for every pending task in the project."],
            "tags": ["type": "string", "description": "Optional comma-separated tags — a task must have ALL of them to match. Omit for no filtering."],
        ],
        required: []
    ),
    ToolDefinition(
        tool: .listTasks,
        description: """
        List every task in this project's queue regardless of state —
        pending, claimed, completed, or failed. Use this for an overview of
        the whole queue's progress; use get_pending_tasks when you just want
        the next thing to claim.
        """,
        properties: [
            "path_prefix": ["type": "string", "description": "Only tasks whose path starts with this. Omit for every task in the project."],
            "tags": ["type": "string", "description": "Optional comma-separated tags — a task must have ALL of them to match. Omit for no filtering."],
        ],
        required: []
    ),
    ToolDefinition(
        tool: .claimTask,
        description: """
        Claim a pending task so no other peer works on it too. Only one claim
        wins — calling this again yourself on a task you already hold is a
        safe no-op; calling it on a task someone else holds is refused,
        naming them. Requires a surface to attach ownership to, so this only
        works from an agent Atelier launched.
        """,
        properties: [
            "path": ["type": "string", "description": "The task's path, from add_task or get_pending_tasks."],
        ],
        required: ["path"]
    ),
    ToolDefinition(
        tool: .completeTask,
        description: """
        Mark a task you hold as done. Only the peer that claimed it may
        complete it — calling this on someone else's claim, or a task nobody
        claimed, is refused. The task's creator is notified in its inbox.
        """,
        properties: [
            "path": ["type": "string", "description": "The task's path."],
        ],
        required: ["path"]
    ),
    ToolDefinition(
        tool: .failTask,
        description: """
        Mark a task you hold as failed, with a reason. Only the peer that
        claimed it may fail it. The task's creator is notified in its inbox,
        including your reason.
        """,
        properties: [
            "path": ["type": "string", "description": "The task's path."],
            "reason": ["type": "string", "description": "Why it failed. Required, and shown to the task's creator."],
        ],
        required: ["path", "reason"]
    ),
```

- [ ] **Step 4: Add `renderText` cases**

In the same file, inside `func renderText(_ payload: IPC.Payload?) -> String`, add two new cases immediately before `case let .text(text):`:

```swift
    case let .task(task):
        return renderTask(task)
    case let .tasks(list):
        guard !list.isEmpty else { return "No tasks match." }
        return list.map(renderTask).joined(separator: "\n\n")
```

and add the helper function at file scope, immediately after `renderText`'s closing brace:

```swift
/// Renders one task for the plain text an agent reads.
func renderTask(_ task: IPC.TaskInfo) -> String {
    var lines = ["\(task.path) [\(task.state.rawValue)] \(task.name)"]
    lines.append("created \(task.createdSecondsAgo)s ago" + (task.createdByName.map { " by \($0)" } ?? ""))
    if let claimedByName = task.claimedByName, let claimedSecondsAgo = task.claimedSecondsAgo {
        lines.append("claimed by \(claimedByName) \(claimedSecondsAgo)s ago")
    }
    if !task.tags.isEmpty {
        lines.append("tags: \(task.tags.joined(separator: ", "))")
    }
    if let reason = task.failureReason {
        lines.append("failure reason: \(reason)")
    }
    return lines.joined(separator: "\n")
}
```

- [ ] **Step 5: Extend `serverInstructions`**

In the same file, in the `serverInstructions` string constant, add one paragraph before its closing `"""` (after the existing `create_workstream` paragraph):

```swift
add_task/get_pending_tasks/list_tasks/claim_task/complete_task/fail_task are a shared, project-scoped work queue — add several units of work once, and any peer in the project can claim, complete, or fail them, instead of you dispatching each by hand. Claiming is exclusive: only one peer wins, and it needs a surface to attach to, so this only works from an agent Atelier launched. Completing or failing a task notifies whoever created it.
"""
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `./scripts/dev.sh test`. `test_helperBinary_answersToolsCallOverStdio` and every other `IPCServerTests` test should pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/MCPHelper/main.swift Tests/IPCServerTests.swift
git commit -m "feat(ipc): advertise the task-queue tools over MCP"
```

---

### Task 7: Full verification pass

**Files:** none (verification only).

- [ ] **Step 1: Regenerate the Xcode project**

Two new files were created (`IPCTaskStore.swift`, `IPCTaskSummary.swift`), per this repo's own rule ("If you added/removed files... run xcodegen generate first"):

```bash
xcodegen generate
```

- [ ] **Step 2: Full debug build**

```bash
./scripts/dev.sh build
```

Expected: builds clean. If `AtelierMCP` fails to build, check that no task-queue type outside `IPCProtocol.swift` (`ProjectTask`, `TaskState`, `TaskQueueFailure`, `TaskStore`, `TaskSummary`) is referenced from `Sources/MCPHelper/main.swift` — only `Tool`, `TaskWireState`, `TaskInfo`, and `Payload` may cross that boundary.

- [ ] **Step 3: Full test suite**

```bash
./scripts/dev.sh test
```

Expected: every test passes, including all of `IPCTaskStoreTests`, `IPCTaskSummaryTests`, the extended `IPCServiceTests`/`IPCProtocolTests`/`IPCServerTests`, and every pre-existing test (in particular `WorkstreamArchiverPurgeTests`, `WorkstreamArchiverDisposeTests`, and every other `IPC*Tests` file, to confirm nothing about the existing six tools regressed).

- [ ] **Step 4: Manual smoke check (optional but recommended)**

If you want to see the real end-to-end path rather than trust the stdio test alone: turn on Settings → "Agent IPC", open two workstreams of the same project, register a peer in each (or just let a Coding Agent auto-register), and from one call `add_task`, from the other call `get_pending_tasks` → `claim_task` → `complete_task`, and confirm the first agent's `receive_messages` shows the completion notice.

- [ ] **Step 5: Update CLAUDE.md**

Add a short subsection to CLAUDE.md's "Agent workspace tools (IPC)" section (the file lives at the repo root, not inside this worktree's `docs/`) documenting: the fourth `Surface` case and why it isn't `.messaging`; the surface-id-not-peer-id ownership decision and the reconnect race it avoids; the workstream-teardown (not peer-release) cleanup hook; and that `add_task` is the one non-replayable tool in this group, alongside `create_workstream`. Model the writing on the existing "Two ways to create a worktree" / "The verification tools" subsections — dense, decision-first, citing the actual file/line where each invariant lives.

- [ ] **Step 6: Final commit**

```bash
git add CLAUDE.md
git commit -m "docs: document the IPC task queue in CLAUDE.md"
```

(`project.yml` is not modified anywhere in this plan — new files are picked up by the existing directory globs, and `xcodegen generate` in Step 1 only regenerates the gitignored `Atelier.xcodeproj`, never `project.yml` itself.)
