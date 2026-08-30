// ABOUTME: User-defined stored prompts: a label plus prompt text, edited in Settings,
// ABOUTME: surfaced as palette commands and typed into the Coding Agent when run.

import Foundation

struct StoredPrompt: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var text: String
}

/// Owns the user's stored prompts. Prompts are user-owned and global —
/// deliberately not loaded from repository config: repo-provided prompt text
/// typed into an agent would be repository-provided instructions, which is
/// ScriptTrust territory. Keeping the source Settings-only avoids that gate.
@MainActor
final class StoredPromptStore: ObservableObject {
    static let storageKey = "atelier.storedPrompts"
    static let shared = StoredPromptStore()

    @Published private(set) var prompts: [StoredPrompt]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        prompts = Self.load(from: defaults)
    }

    /// Seeded when the storage key is absent (first launch). Deleting a seed
    /// sticks: the key then exists with the smaller list and is never re-seeded.
    ///
    /// The ids are fixed literals, not fresh `UUID()`s. Seeds are returned
    /// unpersisted until the user's first edit, so minting new ids per call
    /// would give the seeds a different palette id (`prompt.<uuid>`) every
    /// launch — resetting their usage ranking and leaving an orphaned
    /// `atelier.paletteUsage` entry behind each time.
    static func defaultPrompts() -> [StoredPrompt] {
        [
            StoredPrompt(
                id: UUID(uuidString: "6E7A1C64-0F2B-4A1E-9C3D-1B5E8A0D7F21")!,
                label: NSLocalizedString("Commit", comment: "Seed stored prompt label"),
                text: "Stage and commit all changes in the working tree with a good commit message based on the changes. Do not push."
            ),
            StoredPrompt(
                id: UUID(uuidString: "C2F5B930-7D48-4E6A-B1F7-3A9C4D2E8B05")!,
                label: NSLocalizedString("Create PR", comment: "Seed stored prompt label"),
                text: "Create a pull request for the current changes. Write a clear title and description based on what we've been working on."
            ),
        ]
    }

    static func load(from defaults: UserDefaults) -> [StoredPrompt] {
        guard let data = defaults.data(forKey: storageKey) else { return defaultPrompts() }
        return (try? JSONDecoder().decode([StoredPrompt].self, from: data)) ?? defaultPrompts()
    }

    func prompt(id: UUID) -> StoredPrompt? {
        prompts.first { $0.id == id }
    }

    func add(_ prompt: StoredPrompt) {
        prompts.append(prompt)
        save()
    }

    func update(_ prompt: StoredPrompt) {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        prompts[index] = prompt
        save()
    }

    func remove(id: UUID) {
        prompts.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(prompts) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
