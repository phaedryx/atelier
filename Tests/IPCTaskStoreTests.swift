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
        XCTAssertEqual(claimed.state, try .claimed(bySurfaceID: surfaceX, inWorkstreamID: workstream1, at: XCTUnwrap(claimed.state.claimedAt)))
    }

    /// A second claim from the SAME surface is a no-op success — this is what
    /// makes `claim_task` safe to replay after a reconnect.
    func test_claim_bySameSurfaceTwice_isIdempotent() async throws {
        _ = try await store.add(projectDirectory: projectA, path: "p", name: "n", content: "x", tags: [], createdBySurfaceID: nil)
        _ = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)
        let second = try await store.claim(projectDirectory: projectA, path: "p", surfaceID: surfaceX, workstreamID: workstream1)
        XCTAssertEqual(second.state, try .claimed(bySurfaceID: surfaceX, inWorkstreamID: workstream1, at: XCTUnwrap(second.state.claimedAt)))
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
