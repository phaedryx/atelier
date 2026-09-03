// ABOUTME: GitHub operations using the gh CLI.
// ABOUTME: Fetches repo info, PRs, and branch-specific PR status including checks and review state.

import Foundation

/// The GitHub CLI (`gh`) and the shapes it returns. Separate from `Git`:
/// different system, different failure modes.
enum GitHub {}

extension GitHub {
    struct RepoInfo {
        let name: String
        let url: String
        let description: String?
        let stars: Int
        let forks: Int
        let openIssues: Int
    }
}

extension GitHub {
    struct PR: Equatable {
        let number: Int
        let title: String
        /// Raw gh state: OPEN, MERGED, or CLOSED. Prefer `status`, which also folds in `isDraft`.
        let state: String
        let branch: String
        let url: String
        let isDraft: Bool
        /// APPROVED, CHANGES_REQUESTED, or REVIEW_REQUIRED. Nil when no review is required —
        /// gh reports that as an empty string, which `decode` normalizes away so callers can
        /// use `if let` without rendering a blank row.
        let reviewDecision: String?
        let checks: ChecksRollup

        init(
            number: Int,
            title: String,
            state: String,
            branch: String,
            url: String,
            isDraft: Bool = false,
            reviewDecision: String? = nil,
            checks: ChecksRollup = .none
        ) {
            self.number = number
            self.title = title
            self.state = state
            self.branch = branch
            self.url = url
            self.isDraft = isDraft
            self.reviewDecision = reviewDecision
            self.checks = checks
        }

        /// What the PR actually is, as far as the UI is concerned.
        ///
        /// Exists so views stop re-deriving this from `state` string comparisons; three of them
        /// used `state == "MERGED" ? .purple : .green`, which painted a closed-unmerged PR green
        /// once those stopped being filtered out of the cache.
        enum Status {
            case draft
            case open
            case merged
            case closed
        }

        /// The combined state of every check on the PR's head commit.
        enum ChecksRollup {
            /// No checks ran, or none of them reported a pass or a failure.
            case none
            case pending
            case passing
            case failing
        }

        var status: Status {
            switch state.uppercased() {
            case "MERGED": .merged
            // A merged PR is never a draft, whatever the flag says, so this order matters.
            case "OPEN": isDraft ? .draft : .open
            default: .closed
            }
        }

        // MARK: - Decoding

        /// Parses the array `gh pr list --json` prints.
        ///
        /// Split out from the `gh` calls so the rollup reduction below is testable without a
        /// subprocess or a network round trip — this repo only ever produces one of the two
        /// `statusCheckRollup` shapes, so the app alone cannot exercise the other.
        static func decode(_ data: Data) -> [GitHub.PR] {
            guard let json = try? JSONSerialization.jsonObject(with: data),
                  let array = json as? [[String: Any]]
            else { return [] }
            return array.compactMap(from)
        }

        /// One entry, or nil when a field the UI needs is missing. Optional fields default rather
        /// than fail the entry, so a caller requesting a narrower `--json` set still decodes.
        private static func from(_ dict: [String: Any]) -> GitHub.PR? {
            guard let number = dict["number"] as? Int,
                  let title = dict["title"] as? String,
                  let state = dict["state"] as? String,
                  let branch = dict["headRefName"] as? String,
                  let url = dict["url"] as? String
            else { return nil }

            let decision = (dict["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }

            return GitHub.PR(
                number: number,
                title: title,
                state: state,
                branch: branch,
                url: url,
                isDraft: dict["isDraft"] as? Bool ?? false,
                reviewDecision: decision,
                checks: ChecksRollup(entries: dict["statusCheckRollup"] as? [[String: Any]] ?? [])
            )
        }

        /// The best PR per branch.
        ///
        /// `gh pr list --state all` can return several PRs for one branch, and now that closed
        /// ones are retained, an abandoned PR can shadow the live one. Ranking by status first
        /// and recency second makes the choice deterministic instead of leaving it to gh's
        /// ordering — which is what `uniquingKeysWith: { first, _ in first }` did before.
        static func byBranch(_ prs: [GitHub.PR]) -> [String: GitHub.PR] {
            Dictionary(prs.map { ($0.branch, $0) }, uniquingKeysWith: { lhs, rhs in
                if lhs.rank != rhs.rank {
                    return lhs.rank < rhs.rank ? lhs : rhs
                }
                return lhs.number > rhs.number ? lhs : rhs
            })
        }

        /// Lower sorts first. Draft ranks with open: it is still the live PR for the branch.
        private var rank: Int {
            switch status {
            case .draft, .open: 0
            case .merged: 1
            case .closed: 2
            }
        }
    }
}

extension GitHub.PR.ChecksRollup {
    /// Reduces the `statusCheckRollup` array to a single state.
    ///
    /// Failing outranks pending: a run with one failed check is already doomed, so reporting
    /// it as still-running would be misleading.
    init(entries: [[String: Any]]) {
        var sawPending = false
        var sawPassing = false

        for entry in entries {
            switch Self.signal(for: entry) {
            case .failing:
                self = .failing
                return
            case .pending:
                sawPending = true
            case .passing:
                sawPassing = true
            case .none:
                continue
            }
        }

        if sawPending {
            self = .pending
        } else if sawPassing {
            self = .passing
        } else {
            self = .none
        }
    }

    /// Normalizes the two entry shapes gh emits into one signal.
    ///
    /// `CheckRun` carries `status` plus `conclusion`; `StatusContext` carries `state` and
    /// neither of the others. Dispatching on which key is present rather than on `__typename`
    /// means an entry kind gh adds later degrades to `.none` instead of being misread.
    private static func signal(for entry: [String: Any]) -> Self {
        if let state = entry["state"] as? String {
            return fromStatusContext(state: state)
        }
        if let status = entry["status"] as? String {
            return fromCheckRun(status: status, conclusion: entry["conclusion"] as? String)
        }
        return .none
    }

    private static func fromCheckRun(status: String, conclusion: String?) -> Self {
        guard status.uppercased() == "COMPLETED" else { return .pending }
        switch conclusion?.uppercased() {
        case "SUCCESS":
            return .passing
        case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE":
            return .failing
        // SKIPPED, NEUTRAL, and CANCELLED are not failures — this matches GitHub's own
        // rollup, which shows a green check when the only non-successes are skips.
        default:
            return .none
        }
    }

    private static func fromStatusContext(state: String) -> Self {
        switch state.uppercased() {
        case "SUCCESS":
            .passing
        case "FAILURE", "ERROR":
            .failing
        case "PENDING", "EXPECTED":
            .pending
        default:
            .none
        }
    }
}

extension GitHub {
    enum Operations {
        private static var gitPath: String? {
            CommandLineTools.path(for: "git")
        }

        /// The `--json` field set every PR query requests. Kept in one place so a field added for
        /// one call site cannot silently go missing from another and decode as its default.
        private static let prFields = "number,title,state,headRefName,url,isDraft,reviewDecision,statusCheckRollup"

        /// Check if the project has a GitHub remote.
        static func hasGitHubRemote(at path: String) -> Bool {
            guard let gitPath,
                  let remote = run(gitPath, args: ["remote", "get-url", "origin"], in: path) else { return false }
            return remote.contains("github.com")
        }

        /// Convert a git remote URL to a browser-openable HTTPS URL.
        /// Handles SSH (`git@github.com:owner/repo.git`),
        /// HTTPS (`https://github.com/owner/repo.git`),
        /// and SSH protocol (`ssh://git@github.com/owner/repo.git`) formats.
        static func browserURL(from remoteURL: String) -> URL? {
            var cleaned = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasSuffix(".git") {
                cleaned = String(cleaned.dropLast(4))
            }
            // SSH shorthand: git@github.com:owner/repo
            if let atIndex = cleaned.firstIndex(of: "@"),
               let colonIndex = cleaned.firstIndex(of: ":"),
               colonIndex > atIndex,
               !cleaned.hasPrefix("https://"),
               !cleaned.hasPrefix("ssh://")
            {
                let host = cleaned[cleaned.index(after: atIndex) ..< colonIndex]
                let path = cleaned[cleaned.index(after: colonIndex)...]
                return URL(string: "https://\(host)/\(path)")
            }
            // ssh://git@github.com/owner/repo
            if cleaned.hasPrefix("ssh://") {
                cleaned = cleaned.replacingOccurrences(of: "ssh://", with: "https://")
                if let atIndex = cleaned.firstIndex(of: "@") {
                    cleaned = "https://" + cleaned[cleaned.index(after: atIndex)...]
                }
                return URL(string: cleaned)
            }
            // Already HTTPS
            if cleaned.hasPrefix("https://") || cleaned.hasPrefix("http://") {
                return URL(string: cleaned)
            }
            return nil
        }

        /// Fetch repo info via gh CLI.
        static func repoInfo(ghPath: String, at path: String) -> GitHub.RepoInfo? {
            guard let json = run(ghPath, args: ["repo", "view", "--json", "name,url,description,stargazerCount,forkCount,openIssueCount"], in: path) else { return nil }
            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

            return GitHub.RepoInfo(
                name: dict["name"] as? String ?? "",
                url: dict["url"] as? String ?? "",
                description: dict["description"] as? String,
                stars: dict["stargazerCount"] as? Int ?? 0,
                forks: dict["forkCount"] as? Int ?? 0,
                openIssues: dict["openIssueCount"] as? Int ?? 0
            )
        }

        /// Fetch open PRs for this repo.
        static func openPRs(ghPath: String, at path: String, limit: Int = 5) -> [GitHub.PR] {
            decode(run(ghPath, args: ["pr", "list", "--json", prFields, "--limit", "\(limit)"], in: path))
        }

        /// Fetch PRs for this repo in every state, most-recent-first.
        ///
        /// Closed-but-unmerged PRs used to be filtered out here, which made them indistinguishable
        /// from a branch that never had a PR at all — the section simply vanished. They are kept
        /// now and rendered as closed; `GitHub.PR.byBranch` is what stops a stale one winning.
        static func recentPRs(ghPath: String, at path: String, limit: Int = 100) -> [GitHub.PR] {
            decode(run(ghPath, args: ["pr", "list", "--state", "all", "--json", prFields, "--limit", "\(limit)"], in: path))
        }

        /// Find the PR for a specific branch, in whatever state it is in.
        ///
        /// Asks for several rather than `--limit 1`: a branch can carry an abandoned PR plus a
        /// live one, and gh's ordering does not guarantee which arrives first.
        static func prForBranch(ghPath: String, at path: String, branch: String) -> GitHub.PR? {
            let prs = decode(run(
                ghPath,
                args: ["pr", "list", "--head", branch, "--state", "all", "--json", prFields, "--limit", "10"],
                in: path
            ))
            return GitHub.PR.byBranch(prs)[branch] ?? prs.first
        }

        private static func decode(_ json: String?) -> [GitHub.PR] {
            guard let data = json?.data(using: .utf8) else { return [] }
            return GitHub.PR.decode(data)
        }

        /// Bounded: `gh` reaches the GitHub API, and an unreachable host would
        /// otherwise stall the caller with nothing to cancel it.
        private static func run(_ command: String, args: [String], in directory: String) -> String? {
            guard let data = ProcessRunner.run(
                executable: command,
                arguments: args,
                currentDirectory: URL(fileURLWithPath: directory),
                timeout: ProcessRunner.Timeout.network
            ) else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
