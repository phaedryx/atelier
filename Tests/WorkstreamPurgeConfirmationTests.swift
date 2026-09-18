// ABOUTME: Tests the owner of the Remove/Purge confirmation — the asking, not the archiving.
// ABOUTME: Covers the button-title rule, orphan routing, the orphan refusal and the post-purge closure.

@testable import Atelier
import XCTest

/// `Workstream.PurgeConfirmation` moved the pending target, the warning and the
/// alert copy out of three views. Nothing under `Tests/` mounts a SwiftUI view,
/// so what is pinned here is everything the alert reads and everything `perform`
/// decides — which is the whole of it, since the modifier only renders.
@MainActor
final class WorkstreamPurgeConfirmationTests: XCTestCase {
    private let projectDirectory = "/tmp/atelier-test/project"
    private let checkoutDirectory = "/tmp/atelier-test/project/main"

    /// Records what `perform` reached, so "called no Archiver method" is
    /// something a test can assert rather than infer.
    @MainActor
    private final class Spy {
        var orphanPurges: [(projectDirectory: String, worktreePath: String)] = []

        var operations: Workstream.PurgeConfirmation.Operations {
            Workstream.PurgeConfirmation.Operations { projectDirectory, worktreePath in
                self.orphanPurges.append((projectDirectory, worktreePath))
            }
        }
    }

    private func confirmation(_ spy: Spy) -> Workstream.PurgeConfirmation {
        Workstream.PurgeConfirmation(operations: spy.operations)
    }

    // MARK: - The button-title rule

    /// The one rule the three copies each spelled out for themselves:
    /// "Purge Anyway" is offered exactly when there is a warning to overrule.
    func test_confirmButtonTitle_isPurgeAnywayExactlyWhenThereIsAWarning() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let confirmation = confirmation(Spy())

        // A path that is not a git repository: `hasUncommittedChanges` cannot
        // read it, which is the "could not establish what would be lost" warning.
        confirmation.confirm(orphanWorktree: directory, projectDirectory: projectDirectory)
        XCTAssertNotNil(confirmation.warning)
        XCTAssertEqual(confirmation.confirmButtonTitle, "Purge Anyway")

        // And a workstream with no worktree at all: `purgeWarning` returns nil,
        // because there is nothing on disk to lose.
        confirmation.confirm(workstream: Workstream(name: "scan-deep-thr", worktreePath: nil))
        XCTAssertNil(confirmation.warning)
        XCTAssertEqual(confirmation.confirmButtonTitle, "Purge")
    }

    func test_title_namesWhatIsBeingPurged() {
        let confirmation = confirmation(Spy())

        XCTAssertEqual(confirmation.title, "Purge Workstream", "with nothing pending")

        confirmation.confirm(workstream: Workstream(name: "scan-deep-thr", worktreePath: nil))
        XCTAssertEqual(confirmation.title, "Purge Workstream")

        confirmation.confirm(
            orphanWorktree: "\(projectDirectory)/stray", projectDirectory: projectDirectory
        )
        XCTAssertEqual(confirmation.title, "Purge Worktree")
    }

    /// The message falls back to the generic sentence rather than going blank
    /// when there is nothing to warn about.
    func test_message_fallsBackToTheGenericSentenceWithNoWarning() {
        let confirmation = confirmation(Spy())
        confirmation.confirm(workstream: Workstream(name: "scan-deep-thr", worktreePath: nil))

        XCTAssertEqual(
            confirmation.message, "The worktree and its branch will be permanently deleted."
        )
    }

    // MARK: - Routing

    func test_perform_routesAnOrphanTargetToPurgeOrphanWorktree() {
        let spy = Spy()
        let confirmation = confirmation(spy)
        confirmation.confirm(
            orphanWorktree: "\(projectDirectory)/stray", projectDirectory: projectDirectory
        )

        confirmation.perform(archiving: nil) { _ in }

        XCTAssertEqual(spy.orphanPurges.count, 1)
        XCTAssertEqual(spy.orphanPurges.first?.projectDirectory, projectDirectory)
        XCTAssertEqual(spy.orphanPurges.first?.worktreePath, "\(projectDirectory)/stray")
    }

    func test_perform_runsThePostPurgeClosureAfterTheArchiverCall() {
        let spy = Spy()
        let confirmation = confirmation(spy)
        confirmation.confirm(
            orphanWorktree: "\(projectDirectory)/stray", projectDirectory: projectDirectory
        )

        var completions: [Workstream.PurgeConfirmation.Completion] = []
        var purgesSeenWhenClosureRan = -1
        confirmation.perform(archiving: nil) { completion in
            purgesSeenWhenClosureRan = spy.orphanPurges.count
            completions.append(completion)
        }

        XCTAssertEqual(completions, [.orphanWorktree(path: "\(projectDirectory)/stray")])
        XCTAssertEqual(purgesSeenWhenClosureRan, 1, "the closure must run after the purge, not before")
    }

    func test_perform_dismissesTheAlert() {
        let confirmation = confirmation(Spy())
        confirmation.confirm(
            orphanWorktree: "\(projectDirectory)/stray", projectDirectory: projectDirectory
        )
        XCTAssertTrue(confirmation.isPresented)

        confirmation.perform(archiving: nil) { _ in }

        XCTAssertFalse(confirmation.isPresented)
        XCTAssertNil(confirmation.warning)
    }

    // MARK: - The refusal

    /// `purgeOrphanWorktree` hands its argument straight to `removeWorktree`,
    /// which deletes the path it is given, and has never had a guard of its own.
    /// `destroyablePath` answering nil has to stop the call, not just dim a
    /// button — a future caller that reaches `perform` without going through
    /// `WorktreeInfoRow`'s `isMain`/`isProtected` filter would otherwise walk
    /// straight past it.
    func test_perform_refusesWhenTheTargetIsTheProjectDirectory() {
        let spy = Spy()
        let confirmation = confirmation(spy)
        confirmation.confirm(orphanWorktree: projectDirectory, projectDirectory: projectDirectory)

        var closureRan = false
        confirmation.perform(archiving: nil) { _ in closureRan = true }

        XCTAssertTrue(spy.orphanPurges.isEmpty, "no Archiver method may be reached")
        XCTAssertFalse(closureRan, "the post-purge closure reads as 'it happened'")
        XCTAssertFalse(confirmation.isPresented)
    }

    func test_perform_refusesWhenTheTargetIsTheProjectsCheckout() {
        let spy = Spy()
        let confirmation = confirmation(spy)
        confirmation.confirm(
            orphanWorktree: checkoutDirectory,
            projectDirectory: projectDirectory,
            checkoutDirectory: checkoutDirectory
        )

        confirmation.perform(archiving: nil) { _ in }

        XCTAssertTrue(spy.orphanPurges.isEmpty)
    }

    /// A relative path never equals the protected set, so it would sail through a
    /// guard written as a string comparison. `destroyablePath` refuses it, and
    /// `perform` has to honour that.
    func test_perform_refusesARelativeTarget() {
        let spy = Spy()
        let confirmation = confirmation(spy)
        confirmation.confirm(orphanWorktree: "stray", projectDirectory: projectDirectory)

        confirmation.perform(archiving: nil) { _ in }

        XCTAssertTrue(spy.orphanPurges.isEmpty)
    }

    /// A `.workstream` target reaches `Archiver.purge`, which needs a live
    /// surface cache and verification runner; with no context there is nothing
    /// to call, and half-performing it would drop the workstream from the list
    /// without touching anything else.
    func test_perform_refusesAWorkstreamTargetWithNoArchiveContext() {
        let spy = Spy()
        let confirmation = confirmation(spy)
        confirmation.confirm(workstream: Workstream(name: "scan-deep-thr", worktreePath: nil))

        var closureRan = false
        confirmation.perform(archiving: nil) { _ in closureRan = true }

        XCTAssertTrue(spy.orphanPurges.isEmpty)
        XCTAssertFalse(closureRan)
        XCTAssertFalse(confirmation.isPresented)
    }

    // MARK: - Cancelling

    func test_cancel_clearsTheTargetAndItsWarning() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let spy = Spy()
        let confirmation = confirmation(spy)
        confirmation.confirm(orphanWorktree: directory, projectDirectory: projectDirectory)
        XCTAssertNotNil(confirmation.warning)

        confirmation.cancel()

        XCTAssertNil(confirmation.target)
        XCTAssertNil(confirmation.warning)
        XCTAssertFalse(confirmation.isPresented)

        // And an answered alert reaches no Archiver method.
        confirmation.perform(archiving: nil) { _ in XCTFail("nothing is pending") }
        XCTAssertTrue(spy.orphanPurges.isEmpty)
    }

    /// The modifier binds to `isPresented`; SwiftUI writes false when the alert
    /// is dismissed by the escape key, and that has to clear the target the way
    /// the Cancel button does.
    func test_isPresented_clearsTheTargetWhenSetFalse() {
        let confirmation = confirmation(Spy())
        confirmation.confirm(
            orphanWorktree: "\(projectDirectory)/stray", projectDirectory: projectDirectory
        )

        confirmation.isPresented = false

        XCTAssertNil(confirmation.target)
    }

    private func temporaryDirectory() throws -> String {
        let path = NSTemporaryDirectory().appending("atelier-purge-confirmation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
