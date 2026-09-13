// ABOUTME: What a process checklist has stored for one workstream: all, none, or a subset.
// ABOUTME: Three states in one UserDefaults key, so "nothing selected" cannot read as "all".

import Foundation

/// Which processes a checklist has chosen, for `execute` or for `verify`.
///
/// **Three states, because two were not enough.** `ProcessCompose.PhaseRunner`
/// means *all* by an empty name list — `up -n execute` with no names starts the
/// whole namespace — and that is what keeps "all" canonical, so a project that
/// adds a process to its YAML has it included automatically rather than
/// silently excluded. The trap is that "nothing selected" wants the same
/// representation: storing it made unchecking the last box self-contradictory,
/// since the view read empty back as *all*, every checkbox re-checked itself,
/// and Start ran the entire namespace — the opposite of what was asked.
///
/// That used to be handled by refusing the click: the last checked box was
/// disabled, so a selection could never empty. The refusal is gone and this
/// type is what replaces it — the box can be unchecked, the state is stored as
/// itself, and Start is disabled while it holds.
///
/// `.nothing` rather than `.none` deliberately: `ProcessSelection?` would make
/// a bare `.none` mean `Optional.none` at some call sites and this case at
/// others. It also matches `ProcessCompose.RunCommandPlan.nothing`, which is the
/// same answer one layer up.
enum ProcessSelection: Equatable, Sendable {
    /// Every declared process, whatever the config declares now.
    case all
    /// Nothing at all. There is no command to run for this, and the surface
    /// that owns the button must say so rather than fall back to `.all`.
    case nothing
    /// Exactly these names. Sorted, and never empty — an empty subset is
    /// `.nothing` and a complete one is `.all`.
    case only([String])

    /// The names to hand `ProcessCompose.PhaseRunner`, or **nil when there is
    /// nothing to run**.
    ///
    /// The nil is the point. `.all` and `.nothing` are both "no names", and a
    /// `[String]` return would flatten them into one value that the runner
    /// reads as *start everything* — so the distinction has to survive in the
    /// type, where a caller cannot drop it without the compiler saying so.
    var namesToRun: [String]? {
        switch self {
        case .all:
            []
        case .nothing:
            nil
        case let .only(names):
            names
        }
    }

    // MARK: - Storage

    /// Read from `defaults`, where the three states are: **key absent** — all;
    /// **key present holding an empty array** — nothing; **key present holding
    /// names** — that subset.
    ///
    /// No migration was needed for the empty array to take on its meaning:
    /// `setSelected` removed the key for the empty case, so no stored value has
    /// ever been one. `Tests/ProcessTableModelTests` pins that round trip in
    /// both stores, because `UserDefaults` handing back `[]` rather than nil is
    /// the whole of the encoding, and the failure would silently turn a
    /// `.nothing` into an `.all` — a stack the user switched off, starting
    /// itself.
    static func stored(forKey key: String, in defaults: UserDefaults = .standard) -> ProcessSelection {
        guard let names = defaults.stringArray(forKey: key) else { return .all }
        return names.isEmpty ? .nothing : .only(names)
    }

    func store(forKey key: String, in defaults: UserDefaults = .standard) {
        switch self {
        case .all:
            defaults.removeObject(forKey: key)
        case .nothing:
            defaults.set([String](), forKey: key)
        case let .only(names):
            defaults.set(names, forKey: key)
        }
    }
}
