// ABOUTME: The name a Shortcut story's workstream gets, and the three collisions that refuse it.
// ABOUTME: One decision, two audiences — the sidebar's sheet and an agent over IPC.

import Foundation

extension Shortcut {
    /// What the Shortcut button and `create_shortcut_workstream` both have to
    /// decide: given a story and the project's existing workstreams, which
    /// branch name this one gets, or why it cannot have one.
    ///
    /// Pure, and deliberately not the whole sequence. The fetch, the staging and
    /// the launch stay at each caller, because the sidebar's are entangled with
    /// its sheet — `shortcutFetching`, `shortcutErrorNeedsToken`, task
    /// cancellation — and none of that belongs in a handler. What the two share
    /// is the *decision*, which is the `Project.ConfigLoad` shape: one type with
    /// the wording per consumer, since the sheet's copy is localized user-facing
    /// text and an agent's is a non-localized instruction to do something
    /// different.
    enum WorkstreamName {
        /// Why a story cannot have a workstream here.
        ///
        /// The two collisions are distinct on purpose and their order is
        /// load-bearing: checking the name first blamed the story when an
        /// unrelated workstream happened to match it, and let the same story
        /// through twice once the Branch Name Pattern changed.
        enum Refusal: Swift.Error, Equatable {
            /// The rendered name, which git will not take as a branch.
            case invalidBranchName(String)
            /// The name of the workstream already carrying this story.
            case storyAlreadyHasWorkstream(String)
            /// The rendered name, held by a workstream with no story of its own.
            case nameInUse(String)
        }

        /// The rendered branch name, or the first collision that stops it.
        ///
        /// `template` is `Shortcut.Settings.branchTemplateKey`; empty falls back
        /// to Shortcut's own suggestion, which `BranchName.render` handles.
        static func resolve(
            template: String,
            story: Story,
            existing: [Workstream]
        ) -> Result<String, Refusal> {
            let name = BranchName.render(template, story: story)
            guard Git.Operations.isValidBranchName(name) else {
                return .failure(.invalidBranchName(name))
            }
            if let owner = existing.first(where: { $0.shortcutStoryID == story.id }) {
                return .failure(.storyAlreadyHasWorkstream(owner.name))
            }
            guard !existing.contains(where: { $0.name == name }) else {
                return .failure(.nameInUse(name))
            }
            return .success(name)
        }
    }
}

extension Shortcut.WorkstreamName.Refusal {
    /// For the sidebar's sheet. Localized, and worded for somebody looking at it.
    var localizedMessage: String {
        switch self {
        case .invalidBranchName:
            NSLocalizedString(
                "Shortcut suggested a branch name git will not accept.",
                comment: "Shortcut branch name validation error"
            )
        case .storyAlreadyHasWorkstream:
            NSLocalizedString(
                "A workstream for this story already exists.",
                comment: "Error when a Shortcut story already has a workstream"
            )
        case .nameInUse:
            NSLocalizedString(
                "A workstream with this name already exists.",
                comment: "Error when the workstream name collides with an existing workstream"
            )
        }
    }

    /// For an agent over IPC. Deliberately not localized, for the reason
    /// `Workstream.Launcher.Failure` gives: these are written to tell a caller
    /// what to do differently, not to be read by the user. They name the thing
    /// that collided, because an agent cannot see the sidebar to find out.
    var agentMessage: String {
        switch self {
        case let .invalidBranchName(name):
            "The Branch Name Pattern rendered \(name), which git will not accept as a branch name. "
                + "The pattern is the user's, in Settings → Shortcut; report this rather than working around it."
        case let .storyAlreadyHasWorkstream(workstream):
            "The workstream \(workstream) already covers this story. Use it rather than creating a second one."
        case let .nameInUse(name):
            "A workstream named \(name) already exists in this project, and it is not this story's. "
                + "Nothing was created; report the collision rather than retrying."
        }
    }
}
