// ABOUTME: Tests for stored prompts: persistence and seeding, palette command mapping,
// ABOUTME: registry sync, and the PromptInjector turn-state policy.

@testable import Atelier
import Combine
import XCTest

@MainActor
final class StoredPromptStoreTests: XCTestCase {
    private let suiteName = "StoredPromptStoreTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSeedsDefaultPromptsWhenKeyAbsent() {
        let store = StoredPromptStore(defaults: defaults)
        XCTAssertEqual(store.prompts.map(\.label), StoredPromptStore.defaultPrompts().map(\.label))
        XCTAssertFalse(store.prompts.isEmpty)
    }

    func testSeedIDsAreStableAcrossCalls() {
        // Seeds are returned unpersisted until the first edit, so fresh ids per
        // call would change their palette command id on every launch and reset
        // usage ranking. See StoredPromptStore.defaultPrompts.
        XCTAssertEqual(
            StoredPromptStore.defaultPrompts().map(\.id),
            StoredPromptStore.defaultPrompts().map(\.id)
        )
        XCTAssertEqual(
            StoredPromptStore(defaults: defaults).prompts.map(\.id),
            StoredPromptStore.defaultPrompts().map(\.id)
        )
    }

    func testSeedIDsAreDistinct() {
        let ids = StoredPromptStore.defaultPrompts().map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testDeletingEverySeedStaysEmptyAcrossReload() {
        let store = StoredPromptStore(defaults: defaults)
        for prompt in store.prompts {
            store.remove(id: prompt.id)
        }
        XCTAssertTrue(store.prompts.isEmpty)

        let reloaded = StoredPromptStore(defaults: defaults)
        XCTAssertTrue(reloaded.prompts.isEmpty, "an emptied list must not re-seed the defaults")
    }

    func testAddUpdateRemoveRoundTrip() throws {
        let store = StoredPromptStore(defaults: defaults)
        let prompt = StoredPrompt(label: "Lint", text: "Run the linter and fix what it reports.")
        store.add(prompt)

        var edited = prompt
        edited.text = "Run the linter."
        store.update(edited)
        try store.remove(id: XCTUnwrap(store.prompts.first?.id))

        let reloaded = StoredPromptStore(defaults: defaults)
        XCTAssertEqual(reloaded.prompt(id: prompt.id)?.text, "Run the linter.")
        XCTAssertEqual(reloaded.prompts.count, StoredPromptStore.defaultPrompts().count)
    }

    func testCorruptDataFallsBackToDefaults() {
        defaults.set(Data("not json".utf8), forKey: StoredPromptStore.storageKey)
        let store = StoredPromptStore(defaults: defaults)
        XCTAssertEqual(store.prompts.map(\.label), StoredPromptStore.defaultPrompts().map(\.label))
    }

    // MARK: - One unreadable prompt must not take the rest with it

    /// The list went through a single `try?`, so one prompt the current shape
    /// cannot read discarded all of them — and because the fallback is the seed
    /// list, the user's own prompts were replaced by two they never wrote.
    func testKeepsThePromptsItCanReadWhenOneIsUnreadable() {
        let json = """
        [{ "id": "\(UUID().uuidString)", "label": "Mine", "text": "keep me" },
         { "label": "no id, not a prompt" }]
        """
        defaults.set(Data(json.utf8), forKey: StoredPromptStore.storageKey)

        let store = StoredPromptStore(defaults: defaults)

        XCTAssertEqual(store.prompts.map(\.label), ["Mine"])
    }

    /// The seed fallback is what makes an unreadable blob destructive: the store
    /// hands back two prompts the user never wrote, and the first edit saves
    /// them over the bytes it could not read. Keep those bytes.
    func testKeepsTheOriginalBlobWhenItCouldNotBeReadInFull() {
        let json = "not json"
        defaults.set(Data(json.utf8), forKey: StoredPromptStore.storageKey)

        let store = StoredPromptStore(defaults: defaults)
        store.add(StoredPrompt(label: "New", text: "text"))

        let kept = defaults.data(forKey: StoredPromptStore.storageKey + LossyStore.unreadableKeySuffix)
        XCTAssertEqual(kept.map { String(decoding: $0, as: UTF8.self) }, json)
    }

    /// "The user deleted all their prompts" and "not one of their prompts could
    /// be read" both end up as an empty list, and they must not be treated the
    /// same: the first is a state the store is documented to preserve, the second
    /// is a failed read that should fall back to the seeds like any other.
    /// `testDeletingEverySeedStaysEmptyAcrossReload` pins the other side.
    func testFallsBackToSeedsWhenNoPromptCanBeRead() {
        let json = """
        [{ "label": "no id" }, { "label": "also no id" }]
        """
        defaults.set(Data(json.utf8), forKey: StoredPromptStore.storageKey)

        let store = StoredPromptStore(defaults: defaults)

        XCTAssertEqual(store.prompts.map(\.label), StoredPromptStore.defaultPrompts().map(\.label))
        XCTAssertEqual(
            defaults.data(forKey: StoredPromptStore.storageKey + LossyStore.unreadableKeySuffix)
                .map { String(decoding: $0, as: UTF8.self) },
            json,
            "and the bytes it could not read are still there"
        )
    }

    func testKeepsNoBlobWhenEverythingReads() {
        let store = StoredPromptStore(defaults: defaults)
        store.add(StoredPrompt(label: "One", text: "text"))

        _ = StoredPromptStore(defaults: defaults)

        XCTAssertNil(defaults.data(forKey: StoredPromptStore.storageKey + LossyStore.unreadableKeySuffix))
    }
}

@MainActor
final class PromptPaletteCommandTests: XCTestCase {
    func testMapsPromptsToPrefixedCommands() {
        let prompt = StoredPrompt(label: "Commit", text: "Commit the changes.")
        let commands = promptPaletteCommands(for: [prompt])

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].id, "\(storedPromptCommandPrefix)\(prompt.id.uuidString.lowercased())")
        XCTAssertEqual(commands[0].title, "Commit")
    }

    func testNoBuiltInCommandSitsUnderTheStoredPromptPrefix() {
        // sync() replaces this prefix wholesale, so a built-in named under it
        // would be silently dropped on the store's first emission.
        let builtIns = defaultPaletteCommands().map(\.id)
        XCTAssertTrue(builtIns.allSatisfy { !$0.hasPrefix(storedPromptCommandPrefix) })
    }

    func testEditStoredPromptsCommandDeepLinksToPromptsPane() throws {
        let command = defaultPaletteCommands().first { $0.id == "app.editPrompts" }
        let editPrompts = try XCTUnwrap(command)

        let posted = expectation(forNotification: .openSettings, object: nil) { note in
            SettingsPane.deepLinkTarget(from: note) == .prompts
        }
        editPrompts.action()
        wait(for: [posted], timeout: 1)
    }

    func testAvailabilityRequiresWorkstreamAndReceptiveAgent() {
        let command = promptPaletteCommands(for: [StoredPrompt(label: "X", text: "y")])[0]

        XCTAssertTrue(command.isAvailable(
            PaletteContext(workstreamActive: true, editorActive: false, agentCanReceivePrompt: true)
        ))
        XCTAssertFalse(command.isAvailable(
            PaletteContext(workstreamActive: false, editorActive: false, agentCanReceivePrompt: true)
        ))
        XCTAssertFalse(command.isAvailable(
            PaletteContext(workstreamActive: true, editorActive: false, agentCanReceivePrompt: false)
        ))
    }

    func testActionPostsRunStoredPromptWithPromptID() {
        let prompt = StoredPrompt(label: "Commit", text: "Commit the changes.")
        let command = promptPaletteCommands(for: [prompt])[0]

        // The payload is the same string as the id's suffix. It used to be the
        // uppercase `uuidString` against a lowercased id, which only survived
        // because the sole receiver reparses it as a case-insensitive `UUID`.
        let posted = expectation(forNotification: .runStoredPrompt, object: nil) { note in
            note.object as? String == storedPromptCommandKey(prompt.id)
        }
        command.action()
        wait(for: [posted], timeout: 1)

        XCTAssertEqual(
            command.id,
            storedPromptCommandPrefix + storedPromptCommandKey(prompt.id)
        )
        XCTAssertEqual(
            command.id.dropFirst(storedPromptCommandPrefix.count),
            Substring(storedPromptCommandKey(prompt.id)),
            "a posted payload must be correlatable back to its command id by string"
        )
    }
}

@MainActor
final class CommandRegistrySyncTests: XCTestCase {
    private func command(id: String) -> PaletteCommand {
        PaletteCommand(id: id, title: id, category: "Test", action: {})
    }

    func testSyncReplacesOnlyThePrefixedCommands() throws {
        let registry = try CommandRegistry(
            commands: [command(id: "tab.info"), command(id: "prompt.old")],
            defaults: XCTUnwrap(UserDefaults(suiteName: "CommandRegistrySyncTests"))
        )

        registry.sync(idPrefix: "prompt.", with: [command(id: "prompt.new")])

        let ids = registry.commands.map(\.id)
        XCTAssertTrue(ids.contains("tab.info"))
        XCTAssertTrue(ids.contains("prompt.new"))
        XCTAssertFalse(ids.contains("prompt.old"))
    }

    func testSyncWithEmptyListRemovesAllPrefixed() throws {
        let registry = try CommandRegistry(
            commands: [command(id: "tab.info"), command(id: "prompt.a"), command(id: "prompt.b")],
            defaults: XCTUnwrap(UserDefaults(suiteName: "CommandRegistrySyncTests"))
        )

        registry.sync(idPrefix: "prompt.", with: [])

        XCTAssertEqual(registry.commands.map(\.id), ["tab.info"])
    }

    /// `hasPrefix("")` is true for every id, so an empty prefix used to clear the
    /// entire registry — every built-in command included, with no way back.
    func testSyncWithAnEmptyPrefixIsRefused() throws {
        let registry = try CommandRegistry(
            commands: [command(id: "tab.info"), command(id: "prompt.a")],
            defaults: XCTUnwrap(UserDefaults(suiteName: "CommandRegistrySyncTests"))
        )

        registry.sync(idPrefix: "", with: [])

        XCTAssertEqual(registry.commands.map(\.id).sorted(), ["prompt.a", "tab.info"])
    }

    /// The registry declares `ObservableObject` and `ContentView` holds it as a
    /// `@StateObject`, but nothing was `@Published`, so a rebuilt prompt family
    /// never redrew an open palette.
    func testSyncNotifiesObservers() throws {
        let registry = try CommandRegistry(
            commands: [command(id: "prompt.old")],
            defaults: XCTUnwrap(UserDefaults(suiteName: "CommandRegistrySyncTests"))
        )
        // Counted rather than fulfilled once: `sync` mutates `commands` more than
        // once (the removal, then each registration), and every mutation of an
        // `@Published` property publishes. What matters is that it publishes at
        // all — before the fix it published nothing.
        var notifications = 0
        let token = registry.objectWillChange.sink { _ in notifications += 1 }

        registry.sync(idPrefix: "prompt.", with: [command(id: "prompt.new")])
        token.cancel()

        XCTAssertGreaterThan(notifications, 0, "an ObservableObject that publishes nothing cannot redraw the palette")
    }
}

final class PromptInjectorPolicyTests: XCTestCase {
    func testAllowsIdleFinishedAndUnreportedStates() {
        XCTAssertTrue(PromptInjector.canInject(state: nil))
        XCTAssertTrue(PromptInjector.canInject(state: .idle))
        XCTAssertTrue(PromptInjector.canInject(state: .needsAttention(.justFinished)))
    }

    func testBlocksMidTurnStates() {
        XCTAssertFalse(PromptInjector.canInject(state: .working))
        XCTAssertFalse(PromptInjector.canInject(state: .stalled))
        XCTAssertFalse(PromptInjector.canInject(state: .needsAttention(.permission)))
    }

    /// Both typing paths classify through this one property; the nil policy is
    /// what differs between them (injector allows, nudge refuses).
    func testTurnHasEndedPartitionsTheStates() {
        XCTAssertTrue(Workstream.AgentStateTracker.AgentRunState.idle.turnHasEnded)
        XCTAssertTrue(Workstream.AgentStateTracker.AgentRunState.needsAttention(.justFinished).turnHasEnded)
        XCTAssertFalse(Workstream.AgentStateTracker.AgentRunState.working.turnHasEnded)
        XCTAssertFalse(Workstream.AgentStateTracker.AgentRunState.stalled.turnHasEnded)
        XCTAssertFalse(Workstream.AgentStateTracker.AgentRunState.needsAttention(.permission).turnHasEnded)
    }
}

/// The nudge shares `turnHasEnded` with the injector now; these pin that the
/// shared classifier did not change nudge behavior.
@MainActor
final class AgentNudgePolicyTests: XCTestCase {
    func testNudgeGatesOnSurfaceAndTurnState() {
        XCTAssertFalse(AgentNudge.shouldNudge(
            state: .idle, hasSurface: false, nudgeEnabled: true, lastNudge: nil
        ))
        XCTAssertTrue(AgentNudge.shouldNudge(
            state: .idle, hasSurface: true, nudgeEnabled: true, lastNudge: nil
        ))
        XCTAssertFalse(AgentNudge.shouldNudge(
            state: .working, hasSurface: true, nudgeEnabled: true, lastNudge: nil
        ))
        XCTAssertFalse(AgentNudge.shouldNudge(
            state: .needsAttention(.permission), hasSurface: true, nudgeEnabled: true, lastNudge: nil
        ))
    }
}
