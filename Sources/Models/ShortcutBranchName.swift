// ABOUTME: Renders a git branch name for a Shortcut story from a user-supplied template.
// ABOUTME: Mirrors the `just story` convention, e.g. tad@sc-${STORY_ID}-${SLUG}.

import Foundation

enum ShortcutBranchName {
    /// How many dash-separated words of the title `${SLUG}` keeps. Matches the
    /// `cut -d- -f1-6` in the project's `just story` recipe; `${SLUG_FULL}` is the
    /// untruncated form.
    private static let slugWordLimit = 6

    /// The variables a template may use, in the order Settings lists them.
    static let variables = ["STORY_ID", "SLUG", "SLUG_FULL", "MENTION", "TYPE"]

    /// Expands `template` against `story`. An empty template falls back to Shortcut's own
    /// `formatted_vcs_branch_name`, which is also what the app used before templates existed.
    static func render(_ template: String, story: ShortcutStory) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return story.branchName }

        var result = trimmed
        for (name, value) in values(for: story) {
            result = result.replacingOccurrences(of: "${\(name)}", with: value)
        }
        // An empty ${SLUG} would otherwise leave the separator that preceded it dangling,
        // e.g. "tad@sc-9-". Trailing separators are also invalid or ugly as branch names.
        return trim(result)
    }

    /// A rendered example for the Settings preview, so a typo is visible before it becomes
    /// a branch. Uses the same substitution as the real thing.
    static func preview(_ template: String) -> String {
        render(template, story: sampleStory)
    }

    private static func values(for story: ShortcutStory) -> [(String, String)] {
        let full = slugify(story.name, limit: nil)
        return [
            ("STORY_ID", String(story.id)),
            // SLUG_FULL first: substituting SLUG first would corrupt "${SLUG_FULL}" into
            // the SLUG value followed by a stray "_FULL}".
            ("SLUG_FULL", full),
            ("SLUG", slugify(story.name, limit: slugWordLimit)),
            ("MENTION", mention(from: story)),
            ("TYPE", story.storyType ?? ""),
        ]
    }

    /// Shortcut leads its suggested branch name with the member's mention name, so it is the
    /// only place to read it without a second API call.
    private static func mention(from story: ShortcutStory) -> String {
        story.branchName.split(separator: "/").first.map(String.init) ?? ""
    }

    private static func slugify(_ title: String, limit: Int?) -> String {
        let collapsed = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var words = String(collapsed).split(separator: "-", omittingEmptySubsequences: true)
        if let limit { words = Array(words.prefix(limit)) }
        return words.joined(separator: "-")
    }

    private static func trim(_ value: String) -> String {
        var result = value
        while let last = result.last, last == "-" || last == "/" || last == "@" || last == "_" {
            result.removeLast()
        }
        while let first = result.first, first == "-" || first == "/" {
            result.removeFirst()
        }
        return result
    }

    /// Deliberately mundane so the preview reads as an example rather than real data.
    private static let sampleStory: ShortcutStory = {
        let json = """
        {
          "id": 123,
          "name": "Fix the flaky login redirect",
          "description": null,
          "story_type": "bug",
          "app_url": "https://app.shortcut.com/workspace/story/123",
          "formatted_vcs_branch_name": "you/sc-123/fix-the-flaky-login-redirect",
          "workflow_state_id": 0
        }
        """
        // The literal is fixed and valid, so a failure here is a programming error.
        return try! JSONDecoder().decode(ShortcutStory.self, from: Data(json.utf8))
    }()
}
