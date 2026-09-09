// ABOUTME: Maps harness model identifiers to their context-window token limits.

import Foundation

enum ContextLimits {
    static let defaultLimit = 200_000
    static let extendedLimit = 1_000_000

    /// Absolute token count where response quality starts degrading
    /// regardless of the advertised window (~200–300k decay zone on large-
    /// context models). Floors the context meter at caution color; a
    /// candidate for a user-facing setting later.
    static let qualityCautionThreshold = 200_000

    /// Absolute token count where the meter goes red regardless of window:
    /// well into the decay zone even for large-context models.
    static let qualityCriticalThreshold = 300_000

    /// How Claude's extended-context selection is spelled: "[1m]" or a "-1m"
    /// suffix (e.g. "opus[1m]", "claude-sonnet-4-5-1m").
    private static let extendedMarkers = ["[1m]", "-1m"]

    /// Context window for a session, from the two signals Atelier can see.
    ///
    /// `transcriptModel` is `message.model` from the transcript. It is the
    /// *resolved* model — Claude Code writes "claude-opus-5" whether or not the
    /// 1M beta is on, so it can only ever confirm an extended window, never
    /// rule one out. `configuredModel` is the `model` value from Claude Code's
    /// settings, which is where the "[1m]" marker actually survives.
    ///
    /// The settings value is global, so it is only allowed to widen the window
    /// when it names the same model the transcript recorded: a Haiku session
    /// running under a global `opus[1m]` selection still gets 200k.
    static func limitTokens(transcriptModel: String?, configuredModel: String?, usedTokens: Int = 0) -> Int {
        if isExtendedWindow(transcriptModel) {
            return extendedLimit
        }
        if isExtendedWindow(configuredModel),
           let configuredModel,
           let transcriptModel,
           namesSameModel(baseModelID(configuredModel), baseModelID(transcriptModel))
        {
            return extendedLimit
        }
        // Backstop: a session cannot have consumed more than its own window, so
        // past the default limit the window provably is not the default one —
        // whatever the two signals above managed to say.
        return usedTokens > defaultLimit ? extendedLimit : defaultLimit
    }

    /// True when a model identifier carries an extended-context marker.
    /// Case-insensitive.
    private static func isExtendedWindow(_ modelID: String?) -> Bool {
        guard let lowered = modelID?.lowercased() else { return false }
        return extendedMarkers.contains { lowered.contains($0) }
    }

    /// A model identifier with any extended-context marker removed, lowercased:
    /// "opus[1m]" → "opus", "claude-sonnet-4-5-1m" → "claude-sonnet-4-5".
    private static func baseModelID(_ modelID: String) -> String {
        var base = modelID.lowercased()
        for marker in extendedMarkers {
            base = base.replacingOccurrences(of: marker, with: "")
        }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
    }

    /// Model families, for comparing a selection alias against a resolved ID.
    private static let modelFamilies = ["opus", "sonnet", "haiku", "fable"]

    /// Whether two model identifiers name the same model.
    ///
    /// The two sides are spelled differently: the settings value is an alias
    /// ("opus", "opusplan") and the transcript value is a full resolved ID
    /// ("claude-opus-5"). Comparing families handles the aliases that are not a
    /// substring of the ID at all — `opusplan` is Opus in plan mode, and plain
    /// containment would refuse to widen its window. Containment is the
    /// fallback for a family this build has never heard of, and an empty side
    /// must match nothing rather than everything.
    private static func namesSameModel(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if let lhsFamily = family(lhs), let rhsFamily = family(rhs) {
            return lhsFamily == rhsFamily
        }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }

    private static func family(_ modelID: String) -> String? {
        modelFamilies.first { modelID.contains($0) }
    }
}
