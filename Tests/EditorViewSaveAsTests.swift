// ABOUTME: Tests where the editor points after Save As, which decides what the next ⌘S writes to.
// ABOUTME: `saveFileAs` left the old path in place, so ⌘S went back to the file the user saved away from.

@testable import Atelier
import XCTest

/// `currentFilePath` is relative to the working directory and is the only thing
/// `saveFile` consults. Save As can write anywhere, so re-pointing it is not
/// cosmetic: leaving it alone means the next ⌘S overwrites the original file
/// with the content the user deliberately saved somewhere else.
final class EditorViewSaveAsTests: XCTestCase {
    private let workingDirectory = "/Users/test/project"

    func testAFileSavedInsideTheWorkingDirectoryBecomesTheEditedFile() {
        let path = EditorView.editedPath(
            forFileSavedTo: URL(fileURLWithPath: "/Users/test/project/src/main.swift"),
            workingDirectory: workingDirectory
        )

        XCTAssertEqual(path, "src/main.swift")
    }

    func testAFileSavedAtTheRootOfTheWorkingDirectoryBecomesTheEditedFile() {
        let path = EditorView.editedPath(
            forFileSavedTo: URL(fileURLWithPath: "/Users/test/project/README.md"),
            workingDirectory: workingDirectory
        )

        XCTAssertEqual(path, "README.md")
    }

    /// Outside the worktree there is no relative path to track the file by. The
    /// editor detaches rather than keeping a path that now names a different
    /// file — the whole bug is that ⌘S trusted a stale one.
    func testAFileSavedOutsideTheWorkingDirectoryDetachesTheEditor() {
        XCTAssertNil(
            EditorView.editedPath(
                forFileSavedTo: URL(fileURLWithPath: "/Users/test/elsewhere/main.swift"),
                workingDirectory: workingDirectory
            )
        )
    }

    /// A sibling directory sharing the working directory's name as a prefix is
    /// outside it. A plain `hasPrefix` says otherwise.
    func testASiblingDirectoryWithASharedPrefixIsOutside() {
        XCTAssertNil(
            EditorView.editedPath(
                forFileSavedTo: URL(fileURLWithPath: "/Users/test/project-backup/main.swift"),
                workingDirectory: workingDirectory
            )
        )
    }

    /// Save panels hand back paths with `..` and `.` segments in them.
    func testAnUnstandardizedPathInsideTheWorkingDirectoryStillResolves() {
        let path = EditorView.editedPath(
            forFileSavedTo: URL(fileURLWithPath: "/Users/test/project/src/../src/main.swift"),
            workingDirectory: workingDirectory
        )

        XCTAssertEqual(path, "src/main.swift")
    }

    /// The working directory itself is not a file the editor can point at.
    func testTheWorkingDirectoryItselfIsNotAnEditedPath() {
        XCTAssertNil(
            EditorView.editedPath(
                forFileSavedTo: URL(fileURLWithPath: workingDirectory),
                workingDirectory: workingDirectory
            )
        )
    }
}
