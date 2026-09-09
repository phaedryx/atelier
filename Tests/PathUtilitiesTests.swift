// ABOUTME: Tests for canonical path comparison, which several destructive guards rest on.
// ABOUTME: The interesting cases are the ones where a path is not on disk.

@testable import Atelier
import XCTest

/// `URL.resolvingSymlinksInPath()` is a no-op on a path that does not exist, so
/// the guards that compare two paths were correct only while both happened to be
/// on disk. These pin the behaviour that replaced it.
final class PathUtilitiesTests: XCTestCase {
    private var root: URL!

    /// `<root>/real/deep` with `<root>/link` pointing at it, so the same
    /// directory is reachable under two spellings.
    private var real: URL!
    private var link: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canonical-\(UUID().uuidString)")
        real = root.appendingPathComponent("real/deep")
        link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - canonicalPath

    func testTwoSpellingsOfAnExistingDirectoryAgree() {
        XCTAssertEqual(link.path.canonicalPath, real.path.canonicalPath)
    }

    /// The case that motivated all of this: `resolvingSymlinksInPath()` alone
    /// returns both of these unchanged, so they compare unequal.
    func testTwoSpellingsAgreeWhenTheLeafDoesNotExist() {
        let viaLink = link.appendingPathComponent("nope").path
        let viaReal = real.appendingPathComponent("nope").path

        XCTAssertNotEqual(
            URL(fileURLWithPath: viaLink).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: viaReal).resolvingSymlinksInPath().path,
            "precondition: Foundation on its own does not settle this"
        )
        XCTAssertEqual(viaLink.canonicalPath, viaReal.canonicalPath)
    }

    func testTwoSpellingsAgreeWhenSeveralComponentsAreMissing() {
        let viaLink = link.appendingPathComponent("a/b/c").path
        let viaReal = real.appendingPathComponent("a/b/c").path

        XCTAssertEqual(viaLink.canonicalPath, viaReal.canonicalPath)
    }

    /// A canonicalizer that collapsed everything to one value would pass the
    /// tests above and nothing else.
    func testGenuinelyDifferentPathsStayDifferent() {
        XCTAssertNotEqual(
            link.appendingPathComponent("one").path.canonicalPath,
            link.appendingPathComponent("two").path.canonicalPath
        )
        XCTAssertNotEqual(
            real.path.canonicalPath,
            root.appendingPathComponent("real").path.canonicalPath
        )
    }

    func testTrailingSlashesAndDotSegmentsDoNotMatter() {
        XCTAssertEqual((real.path + "/").canonicalPath, real.path.canonicalPath)
        XCTAssertEqual((real.path + "/./").canonicalPath, real.path.canonicalPath)
        XCTAssertEqual(real.appendingPathComponent("../deep").path.canonicalPath, real.path.canonicalPath)
    }

    func testAPathThatIsEntirelyAbsentIsStillCanonicalized() {
        // Nothing under here exists, so the walk runs to "/" and stops there.
        XCTAssertEqual("/no/such/place".canonicalPath, "/no/such/place")
    }

    /// A non-existent path ending in `..` used to hang: walking up with
    /// `deletingLastPathComponent()` returns that path unchanged, with the same
    /// component count, so the loop never advanced and never hit its floor.
    /// Reachable from `Project.hoistedLocation`, whose candidate is built from a
    /// `gitdir:` string read off disk — on the launch path, inside a decoder.
    func testADotDotSuffixOnAMissingPathTerminates() {
        XCTAssertEqual("/no/such/place/..".canonicalPath, "/no/such")
        XCTAssertEqual("/no/such/place/../..".canonicalPath, "/no")
        XCTAssertEqual("/no/../..".canonicalPath, "/")
    }

    /// The same shape, spelled through a symlink, since that is how it would
    /// actually arrive: a relative `gitdir:` resolved against a checkout.
    func testADotDotSuffixResolvesAgainstTheRealAncestor() {
        let viaLink = link.appendingPathComponent("gone/..").path
        XCTAssertEqual(viaLink.canonicalPath, real.path.canonicalPath)
    }

    func testRootCanonicalizesToItself() {
        XCTAssertEqual("/".canonicalPath, "/")
    }

    // MARK: - isCanonicallyInside

    /// Strict, because the one guard that asks this — a worktree's `gitdir:`
    /// against the container's `.bare` — is malformed if the two are the same
    /// directory, and refused hoisting on that basis before.
    func testAPathIsNotInsideItself() {
        XCTAssertFalse(real.path.isCanonicallyInside(link.path))
        XCTAssertFalse(real.path.isCanonicallyInside(real.path))
    }

    func testAChildIsInsideItsParentAcrossSpellings() {
        XCTAssertTrue(link.appendingPathComponent("child").path.isCanonicallyInside(real.path))
        XCTAssertTrue(real.appendingPathComponent("child").path.isCanonicallyInside(link.path))
    }

    /// The case the whole helper exists for: neither path is on disk, and they
    /// are spelled through different ancestors.
    func testAMissingChildIsInsideItsParentAcrossSpellings() {
        XCTAssertTrue(link.appendingPathComponent("a/b/c").path.isCanonicallyInside(real.path))
    }

    func testASiblingIsNotInside() {
        XCTAssertFalse(root.appendingPathComponent("elsewhere").path.isCanonicallyInside(real.path))
    }

    /// The separator is the whole point: `/repo-backup` is not inside `/repo`.
    func testASharedNamePrefixIsNotContainment() throws {
        let repo = root.appendingPathComponent("repo")
        let backup = root.appendingPathComponent("repo-backup")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)

        XCTAssertFalse(backup.path.isCanonicallyInside(repo.path))
    }
}
