// ABOUTME: Tests for FileFinder: recursive scanning with skipped directories and fuzzy scoring.

@testable import Atelier
import XCTest

final class FileFinderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFinderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeFile(_ relativePath: String) throws {
        let url = tempDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "test".write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Scanning

    func testScanFindsNestedFiles() throws {
        try makeFile("README.md")
        try makeFile("Sources/Models/FileFinder.swift")
        try makeFile("Sources/Views/EditorView.swift")

        let files = FileFinder.scanFiles(at: tempDir.path).map(\.path)

        XCTAssertTrue(files.contains("README.md"))
        XCTAssertTrue(files.contains("Sources/Models/FileFinder.swift"))
        XCTAssertTrue(files.contains("Sources/Views/EditorView.swift"))
    }

    func testScanSkipsGitAndNodeModules() throws {
        try makeFile(".git/config")
        try makeFile(".git/objects/pack/pack-abc.pack")
        try makeFile("node_modules/pkg/index.js")
        try makeFile("package.json")

        let files = FileFinder.scanFiles(at: tempDir.path).map(\.path)

        XCTAssertEqual(files, ["package.json"])
    }

    func testScanSkipsBuildDirectories() throws {
        try makeFile("build/out.o")
        try makeFile("dist/bundle.js")
        try makeFile("DerivedData/Build/foo.swiftmodule")
        try makeFile("src/main.c")

        let files = FileFinder.scanFiles(at: tempDir.path).map(\.path)

        XCTAssertEqual(files, ["src/main.c"])
    }

    // MARK: - Scoring

    func testBasenameMatchOutranksPathMatch() throws {
        let query = "editor"
        let basename = try XCTUnwrap(FileFinder.score(query: query, path: "Sources/Views/EditorView.swift"))
        let pathOnly = try XCTUnwrap(FileFinder.score(query: query, path: "editorial/README.md"))
        let noMatch = FileFinder.score(query: query, path: "Sources/Models/FileFinder.swift")

        XCTAssertGreaterThan(basename, pathOnly)
        XCTAssertNil(noMatch)
    }

    func testPrefixOutranksLaterMatch() throws {
        let first = try XCTUnwrap(FileFinder.score(query: "file", path: "FileFinder.swift"))
        let later = try XCTUnwrap(FileFinder.score(query: "file", path: "MyFile.swift"))
        XCTAssertGreaterThan(first, later)
    }

    func testContiguousMatchOutranksSubsequence() throws {
        let contiguous = try XCTUnwrap(FileFinder.score(query: "finder", path: "Source/FileFinder.swift"))
        let subsequence = try XCTUnwrap(FileFinder.score(query: "fd", path: "Source/FileFinder.swift"))
        XCTAssertGreaterThan(contiguous, subsequence)
    }

    func testSubsequenceMatching() {
        XCTAssertNotNil(FileFinder.score(query: "smf", path: "Sources/Models/FileFinder.swift"))
        XCTAssertNil(FileFinder.score(query: "xyz", path: "Sources/Models/FileFinder.swift"))
    }

    func testEmptyQueryMatchesNothing() {
        XCTAssertNil(FileFinder.score(query: "", path: "FileFinder.swift"))
    }

    func testCaseInsensitiveMatch() {
        XCTAssertNotNil(FileFinder.score(query: "SWIFT", path: "Sources/Models/FileFinder.swift"))
    }

    // MARK: - Ranking

    func testExactNameRanksFirstOverCloseNames() {
        let entries = [
            "hooks/use-auth.tsx",
            "hooks/use-tasks.ts",
            "hooks/use-toast.tsx",
            "hooks/use toast.tsx",
        ].map { FileFinder.Entry(path: $0) }

        let results = FileFinder.results(matching: "use toast", in: entries)

        XCTAssertEqual(results.first, "hooks/use toast.tsx")
        XCTAssertTrue(results.contains("hooks/use-toast.tsx"))
        XCTAssertTrue(results.allSatisfy { $0.hasPrefix("hooks/use") })
    }

    /// The name promises equivalence, so assert equivalence: three `XCTAssertNotNil`
    /// calls only prove the three names match *something*, which they would even if
    /// each separator scored differently.
    func testSeparatorEquivalenceMatchesDashedName() throws {
        let dash = try XCTUnwrap(FileFinder.score(query: "use toast", path: "hooks/use-toast.tsx"))
        let underscore = try XCTUnwrap(FileFinder.score(query: "use toast", path: "hooks/use_toast.tsx"))
        let dot = try XCTUnwrap(FileFinder.score(query: "use toast", path: "hooks/use.toast.tsx"))

        XCTAssertEqual(dash, underscore, "`-` and `_` must be interchangeable, not merely both matchable")
        XCTAssertEqual(dash, dot, "`-` and `.` must be interchangeable, not merely both matchable")
        XCTAssertEqual(dash, try XCTUnwrap(FileFinder.score(query: "use-toast", path: "hooks/use-toast.tsx")))
    }

    /// This is the case the contiguous and subsequence stages used to disagree on.
    /// "use toast" matched "use-toast.tsx" contiguously, then fell through to the
    /// subsequence stage for "use-my-toast.tsx" — which compared with a bare `==`
    /// and rejected the space against the dash.
    func testSeparatorEquivalenceAppliesToTheSubsequenceFallbackToo() {
        XCTAssertNotNil(
            FileFinder.score(query: "use toast", path: "hooks/use-my-toast.tsx"),
            "A non-contiguous match must honour separator equivalence, like the contiguous stage does"
        )
        XCTAssertNotNil(FileFinder.score(query: "use_toast", path: "hooks/use-my-toast.tsx"))
        XCTAssertNotNil(FileFinder.score(query: "use.toast", path: "hooks/use-my-toast.tsx"))
    }

    /// The carve-out on the rule above: a trailing query separator is a filter, not a
    /// word break to find, so it keeps the strict comparison. Without this, "useTheme "
    /// binds its space to the dot in ".tsx" and stops filtering anything.
    func testATrailingQuerySeparatorStillRequiresARealBreak() {
        XCTAssertNotNil(FileFinder.score(query: "useTheme ", path: "hooks/useTheme-Sync.tsx"))
        XCTAssertNil(
            FileFinder.score(query: "useTheme ", path: "hooks/useThemeSync.tsx"),
            "A trailing separator must not bind to the extension dot"
        )
        // The interior case is unaffected — that is the bug this pairs with.
        XCTAssertNotNil(FileFinder.score(query: "useTheme Sync", path: "hooks/useTheme-Sync.tsx"))
    }

    /// Selecting the top K on score alone dropped equal-scoring candidates at the
    /// boundary, so the documented shorter-path tiebreak only applied to whichever
    /// candidate happened to be scanned first.
    func testEqualScoringCandidatesAtTheLimitAreRankedNotDroppedByArrivalOrder() {
        let short = "a/thing.swift"
        let long = "deeply/nested/directory/tree/thing.swift"

        let longFirst = FileFinder.results(
            matching: "thing",
            in: [long, short].map { FileFinder.Entry(path: $0) },
            limit: 1
        )
        let shortFirst = FileFinder.results(
            matching: "thing",
            in: [short, long].map { FileFinder.Entry(path: $0) },
            limit: 1
        )

        XCTAssertEqual(longFirst, [short], "The shorter path must win the tiebreak even when scanned second")
        XCTAssertEqual(shortFirst, [short])
        XCTAssertEqual(longFirst, shortFirst, "Results must not depend on scan order")
    }

    func testRankingIgnoresUnrelatedFiles() {
        let entries = [
            "hooks/use-tasks.ts",
            "README.md",
            "package.json",
            "hooks/use-toast.tsx",
            "vendor/jquery.min.js",
        ].map { FileFinder.Entry(path: $0) }

        let results = FileFinder.results(matching: "use toast", in: entries)

        XCTAssertEqual(results, ["hooks/use-toast.tsx"])
    }

    func testResultsOrderMatchesTypedQuery() {
        let entries = [
            "app/notifications/use toast.tsx",
            "app/use auth.tsx",
            "app/use tasks.ts",
            "app/use toast.tsx",
        ].map { FileFinder.Entry(path: $0) }

        let results = FileFinder.results(matching: "use toast", in: entries)

        XCTAssertEqual(results.first, "app/use toast.tsx")
        XCTAssertEqual(results.last, "app/notifications/use toast.tsx")
    }

    /// The exact scenario reported as broken: typing "UseThemeSync" character by
    /// character must keep the file visible at every prefix and first once the
    /// prefix disambiguates, never being crowded out by other use* files.
    func testUseThemeSyncRanksFirstAtDisambiguatingPrefixes() {
        let entries = [
            "hooks/useAuth.tsx",
            "hooks/useTasks.ts",
            "hooks/useToast.tsx",
            "hooks/useThemeSync.tsx",
            "hooks/useThemeStore.tsx",
            "hooks/useThemeTest.tsx",
        ].map { FileFinder.Entry(path: $0) }
        let target = "hooks/useThemeSync.tsx"

        for prefix in Self.prefixes(of: "usethemesync") {
            let results = FileFinder.results(matching: prefix, in: entries)
            XCTAssertTrue(results.contains(target), "lost \(target) at prefix \(prefix)")
        }

        for prefix in ["usethemes", "usethemesy", "usethemesyn", "usethemesync"] {
            let results = FileFinder.results(matching: prefix, in: entries)
            XCTAssertEqual(results.first, target, "did not rank first at prefix \(prefix)")
        }
    }

    func testTrailingSpaceRequiresSeparatorInTarget() {
        let entries = ["hooks/useThemeSync.tsx", "hooks/useTheme-Sync.tsx"]
            .map { FileFinder.Entry(path: $0) }

        let withSpace = FileFinder.results(matching: "useTheme ", in: entries)
        let separated = FileFinder.results(matching: "useTheme Sync", in: entries)

        XCTAssertEqual(withSpace, ["hooks/useTheme-Sync.tsx"])
        XCTAssertEqual(separated.first, "hooks/useTheme-Sync.tsx")
    }

    private static func prefixes(of word: String) -> [String] {
        var result: [String] = []
        for length in 1 ... word.count {
            result.append(String(word.prefix(length)))
        }
        return result
    }
}
