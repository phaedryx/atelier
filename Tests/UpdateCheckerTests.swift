// ABOUTME: Tests for parsing the GitHub Releases API payload and version comparison.
// ABOUTME: Covers tag normalization, draft/prerelease filtering, and newer-than filtering.

@testable import Atelier
import XCTest

final class UpdateCheckerTests: XCTestCase {
    private func json(_ releases: String) -> Data {
        Data("[\(releases)]".utf8)
    }

    private func release(
        tag: String,
        body: String? = "Notes",
        withURL: Bool = true,
        draft: Bool = false,
        prerelease: Bool = false
    ) -> String {
        let bodyField = body.map { "\"body\": \"\($0)\"" } ?? "\"body\": null"
        let urlField = withURL
            ? "\"html_url\": \"\(Self.releaseURL(for: tag))\""
            : "\"html_url\": null"
        return "{\"tag_name\": \"\(tag)\", \(urlField), \(bodyField), "
            + "\"draft\": \(draft), \"prerelease\": \(prerelease)}"
    }

    private static func releaseURL(for tag: String) -> String {
        "https://github.com/phaedryx/atelier/releases/tag/\(tag)"
    }

    func testParsesVersionFromLatestRelease() {
        let version = UpdateChecker.parseVersion(from: json(release(tag: "v0.2.0")))
        XCTAssertEqual(version, "0.2.0")
    }

    func testAcceptsTagsWithoutLeadingV() {
        let version = UpdateChecker.parseVersion(from: json(release(tag: "0.2.0")))
        XCTAssertEqual(version, "0.2.0")
    }

    func testReturnsNilForEmptyPayload() {
        XCTAssertNil(UpdateChecker.parseVersion(from: json("")))
    }

    func testReturnsNilForMalformedJSON() {
        XCTAssertNil(UpdateChecker.parseVersion(from: Data("not json".utf8)))
    }

    func testSkipsDraftsAndPrereleases() {
        let data = json([
            release(tag: "v0.4.0", draft: true),
            release(tag: "v0.3.0", prerelease: true),
            release(tag: "v0.2.0"),
        ].joined(separator: ","))
        let releases = UpdateChecker.parseReleases(from: data)
        XCTAssertEqual(releases.map(\.version), ["0.2.0"])
    }

    func testSkipsNonNumericTags() {
        let data = json([
            release(tag: "nightly"),
            release(tag: "v1.0.0-beta"),
            release(tag: "v0.2.0"),
        ].joined(separator: ","))
        XCTAssertEqual(UpdateChecker.parseReleases(from: data).map(\.version), ["0.2.0"])
    }

    func testParsesReleaseNotesURL() {
        let releases = UpdateChecker.parseReleases(from: json(release(tag: "v0.2.0")))
        XCTAssertEqual(
            releases.first?.releaseNotesURL?.absoluteString,
            Self.releaseURL(for: "v0.2.0")
        )
    }

    func testParsesReleaseWithoutNotesURL() {
        let releases = UpdateChecker.parseReleases(from: json(release(tag: "v0.2.0", withURL: false)))
        XCTAssertEqual(releases.first?.version, "0.2.0")
        XCTAssertNil(releases.first?.releaseNotesURL)
    }

    func testTreatsEmptyBodyAsNoNotes() {
        let releases = UpdateChecker.parseReleases(from: json(release(tag: "v0.2.0", body: "")))
        XCTAssertNil(releases.first?.releaseNotes)
    }

    func testParsesBodyAsReleaseNotes() {
        let releases = UpdateChecker.parseReleases(from: json(release(tag: "v0.2.0", body: "Fixed a crash")))
        XCTAssertEqual(releases.first?.releaseNotes, "Fixed a crash")
    }

    func testParsesMultipleReleasesNewestFirst() {
        let data = json([
            release(tag: "v0.3.0"),
            release(tag: "v0.2.0"),
            release(tag: "v0.1.0"),
        ].joined(separator: ","))
        XCTAssertEqual(UpdateChecker.parseReleases(from: data).map(\.version), ["0.3.0", "0.2.0", "0.1.0"])
    }

    func testReleasesNewerThanFiltersCorrectly() {
        let releases = [
            ReleaseInfo(version: "0.3.0", releaseNotesURL: nil, releaseNotes: "Three"),
            ReleaseInfo(version: "0.2.0", releaseNotesURL: nil, releaseNotes: "Two"),
            ReleaseInfo(version: "0.1.5", releaseNotesURL: nil, releaseNotes: "One-five"),
            ReleaseInfo(version: "0.1.0", releaseNotesURL: nil, releaseNotes: "One"),
        ]
        let pending = UpdateChecker.releasesNewer(than: "0.1.5", in: releases)
        XCTAssertEqual(pending.map(\.version), ["0.3.0", "0.2.0"])
    }

    func testReleasesNewerThanReturnsEmptyWhenUpToDate() {
        let releases = [ReleaseInfo(version: "0.2.0", releaseNotesURL: nil, releaseNotes: nil)]
        XCTAssertTrue(UpdateChecker.releasesNewer(than: "0.2.0", in: releases).isEmpty)
    }

    func testIsNewerComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.37"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.38", than: "0.1.37"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.37", than: "0.1.37"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.36", than: "0.1.37"))
    }
}
