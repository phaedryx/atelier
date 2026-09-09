// ABOUTME: Validates the branch name typed into the "New workstream from GitHub" dialog.
// ABOUTME: Accepts a branch name only, and turns pasted pull-request references away by name.

import Foundation

extension GitHub {
    /// What the "New workstream from GitHub" field accepts.
    ///
    /// A branch name and nothing else — the dialog resolves it against `origin` rather than
    /// asking `gh` to translate anything. Pull-request references are recognised only so the
    /// message can say what the field wants; they are never resolved to their head branch.
    enum BranchInput {
        /// Why the field's contents cannot be used. The dialog renders `message` and never
        /// re-inspects the input, so a rejection and its wording stay in one place.
        enum Rejection: Error, Equatable {
            case empty
            /// `#82`, or a pull-request URL.
            case pullRequestReference
            /// Anything else git will not accept as a branch.
            case notABranchName

            var message: String {
                switch self {
                case .empty:
                    NSLocalizedString(
                        "Enter a branch name.",
                        comment: "Error when the GitHub branch field is empty"
                    )
                case .pullRequestReference:
                    NSLocalizedString(
                        "That's a pull request. Enter the name of its branch instead.",
                        comment: "Error when a pull request number or URL is pasted into the GitHub branch field"
                    )
                case .notABranchName:
                    NSLocalizedString(
                        "That isn't a valid git branch name.",
                        comment: "Error when the GitHub branch field holds something git would refuse"
                    )
                }
            }
        }

        /// The branch name to look for on origin, or why the input is not one.
        static func branch(from raw: String) -> Result<String, Rejection> {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.empty) }
            guard !isPullRequestReference(trimmed) else { return .failure(.pullRequestReference) }
            guard Git.Operations.isValidBranchName(trimmed) else { return .failure(.notABranchName) }
            return .success(trimmed)
        }

        /// The two unambiguous pull-request pastes: `#82`, and a URL with a `/pull/` segment
        /// — with or without a scheme, since GitHub's own copy button drops it.
        ///
        /// A bare `82` is deliberately *not* one of them. It is a legal branch name, and
        /// guessing at a pull request would refuse a name origin can resolve; an unknown
        /// branch is reported by the remote lookup instead.
        private static func isPullRequestReference(_ input: String) -> Bool {
            if input.hasPrefix("#") {
                return true
            }
            let path = input.contains("://") ? String(input.drop(while: { $0 != "/" }).dropFirst(2)) : input
            return path.contains("/pull/") || path.contains("/pulls/")
        }
    }
}
