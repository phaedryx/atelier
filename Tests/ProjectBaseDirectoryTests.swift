// ABOUTME: Tests the guard on the base directory new projects and clones are created under.
// ABOUTME: An unset or relative setting must not resolve to the process's working directory.

@testable import Atelier
import XCTest

final class ProjectBaseDirectoryTests: XCTestCase {
    /// `URL(fileURLWithPath: "")` resolves to the *process's* working directory
    /// — for a launched app, wherever it happens to be — and both project
    /// creation paths then `createDirectory` and `git init` inside it. The
    /// setting is stored in `@AppStorage` with a `?? ""` default, so empty is
    /// reachable without the user doing anything unusual.
    func testAnEmptyBaseDirectoryIsRejected() {
        XCTAssertNil(projectBaseDirectory(from: ""))
    }

    /// Whitespace survives the trim as a real path component: it would create a
    /// directory literally named `"   "` under the working directory.
    func testAWhitespaceOnlyBaseDirectoryIsRejected() {
        XCTAssertNil(projectBaseDirectory(from: "   "))
        XCTAssertNil(projectBaseDirectory(from: "\t\n"))
    }

    /// Same failure mode as empty, one step removed.
    func testARelativeBaseDirectoryIsRejected() {
        XCTAssertNil(projectBaseDirectory(from: "Code"))
        XCTAssertNil(projectBaseDirectory(from: "./Code"))
        XCTAssertNil(projectBaseDirectory(from: "../Code"))
    }

    func testAnAbsolutePathIsAccepted() {
        XCTAssertEqual(projectBaseDirectory(from: "/Users/test/Code")?.path, "/Users/test/Code")
    }

    /// The setting is user-editable text, so a stray trailing space is likely
    /// and is not a reason to refuse a perfectly good path.
    func testSurroundingWhitespaceIsTrimmedRatherThanRejected() {
        XCTAssertEqual(projectBaseDirectory(from: "  /Users/test/Code  ")?.path, "/Users/test/Code")
    }
}
