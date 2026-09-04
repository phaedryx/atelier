// ABOUTME: Holds the palette's commands; searches by fuzzy score plus persisted usage frequency.
// ABOUTME: Frequency lives in UserDefaults so ranking survives relaunch.

import Foundation

@MainActor
final class CommandRegistry: ObservableObject {
    private static let usageKey = "atelier.paletteUsage"

    /// `@Published`, not a plain property: `ContentView` holds the registry as a
    /// `@StateObject` and the palette renders from `search`, so a `sync` that
    /// rebuilt the stored-prompt family while the palette was open changed the
    /// results with nothing to redraw them. The `ObservableObject` conformance
    /// was declared and published nothing.
    @Published private(set) var commands: [PaletteCommand] = []
    private var usage: [String: Int]
    private let defaults: UserDefaults

    init(commands: [PaletteCommand], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.usageKey),
           let saved = try? JSONDecoder().decode([String: Int].self, from: data)
        {
            usage = saved
        } else {
            usage = [:]
        }
        for command in commands {
            register(command)
        }
    }

    /// Adds a command. On a duplicate id the first registration wins, so the
    /// palette never shows two rows for one action. Silently ignoring (rather
    /// than asserting) keeps the rule testable — an `assertionFailure` here
    /// would crash the debug test build instead of letting the duplicate test
    /// observe the behavior.
    func register(_ command: PaletteCommand) {
        guard !commands.contains(where: { $0.id == command.id }) else { return }
        commands.append(command)
    }

    /// Replaces every command whose id begins with `idPrefix` with `newCommands`,
    /// leaving all others untouched. Used for dynamic command families (stored
    /// prompts) that are rebuilt whenever their source of truth changes; usage
    /// frequency survives because it is keyed by id, and a prompt's id is
    /// stable across edits.
    ///
    /// An empty prefix is refused: `hasPrefix("")` is true for every id, so it
    /// would clear the whole registry — static commands included — and `sync`
    /// has no way to put those back. A family is identified by its prefix.
    func sync(idPrefix: String, with newCommands: [PaletteCommand]) {
        guard !idPrefix.isEmpty else { return }
        commands.removeAll { $0.id.hasPrefix(idPrefix) }
        for command in newCommands {
            register(command)
        }
    }

    /// Available commands matching `query`, best first. An empty query lists
    /// everything available, most-used first, then alphabetically.
    func search(_ query: String, context: PaletteContext) -> [PaletteCommand] {
        let available = commands.filter { $0.isAvailable(context) }
        if query.isEmpty {
            return available.sorted {
                let (ua, ub) = (usage[$0.id, default: 0], usage[$1.id, default: 0])
                return ua == ub ? $0.title < $1.title : ua > ub
            }
        }
        return available
            .compactMap { command -> (PaletteCommand, Int)? in
                let score = FuzzyMatcher.score(query: query, candidate: command.title)
                guard score > 0 else { return nil }
                return (command, score + usage[command.id, default: 0])
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    func recordUsage(_ commandID: String) {
        usage[commandID, default: 0] += 1
        guard let data = try? JSONEncoder().encode(usage) else { return }
        defaults.set(data, forKey: Self.usageKey)
    }
}
