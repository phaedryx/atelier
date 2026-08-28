// ABOUTME: Polls the GitHub Releases API for versions newer than the running build.
// ABOUTME: Drives the sidebar update badge; the fork ships no in-app updater.

import Foundation
import os

struct ReleaseInfo {
    let version: String
    let releaseNotesURL: URL?
    let releaseNotes: String?
}

private let releasesURL = URL(
    string: "https://api.github.com/repos/\(AppConstants.repositorySlug)/releases?per_page=20"
)!

@MainActor
class UpdateChecker: ObservableObject {
    @Published var pendingReleases: [ReleaseInfo] = []

    var availableVersion: String? {
        pendingReleases.first?.version
    }

    var releaseNotesURL: URL? {
        pendingReleases.first?.releaseNotesURL
    }

    private let currentVersion: String
    private let logger = Logger(subsystem: AppConstants.appID, category: "UpdateChecker")

    init() {
        currentVersion = AppConstants.version
    }

    func check() {
        #if DEBUG
            return
        #else
            Task.detached { [currentVersion, logger] in
                do {
                    var request = URLRequest(url: releasesURL)
                    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                    let (data, _) = try await URLSession.shared.data(for: request)
                    let releases = Self.parseReleases(from: data)
                    let pending = Self.releasesNewer(than: currentVersion, in: releases)
                    guard !pending.isEmpty else { return }
                    await MainActor.run { [weak self] in
                        self?.pendingReleases = pending
                    }
                } catch {
                    logger.debug("Update check failed: \(error.localizedDescription)")
                }
            }
        #endif
    }

    /// Decodes a GitHub Releases API payload, newest first.
    ///
    /// Drafts and pre-releases are skipped: neither is something a user on a
    /// stable build should be prompted to upgrade to.
    nonisolated static func parseReleases(from data: Data) -> [ReleaseInfo] {
        guard let payload = try? JSONDecoder().decode([GitHubRelease].self, from: data) else { return [] }
        return payload.compactMap { release in
            guard !release.draft, !release.prerelease else { return nil }
            guard let version = normalizedVersion(release.tagName) else { return nil }
            let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ReleaseInfo(
                version: version,
                releaseNotesURL: release.htmlURL.flatMap(URL.init(string:)),
                releaseNotes: (notes?.isEmpty ?? true) ? nil : notes
            )
        }
    }

    /// Returns the version of the newest eligible release, if any.
    nonisolated static func parseVersion(from data: Data) -> String? {
        parseReleases(from: data).first?.version
    }

    /// Strips the conventional leading "v" from a tag and rejects anything that
    /// isn't a dotted numeric version, so stray tags never masquerade as releases.
    nonisolated static func normalizedVersion(_ tag: String) -> String? {
        var trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") { trimmed.removeFirst() }
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return trimmed
    }

    /// Filters releases to those newer than the given version.
    nonisolated static func releasesNewer(than version: String, in releases: [ReleaseInfo]) -> [ReleaseInfo] {
        releases.filter { isNewer($0.version, than: version) }
    }

    /// Simple semver comparison: returns true if `remote` is newer than `local`.
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0 ..< max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case draft
        case prerelease
    }
}
