// ABOUTME: Tests for stored prompts: persistence and seeding, palette command mapping,
// ABOUTME: registry sync, and the PromptInjector turn-state policy.

@testable import Atelier
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

    func testAddUpdateRemoveRoundTrip() {
        let store = StoredPromptStore(defaults: defaults)
        let prompt = StoredPrompt(label: "Lint", text: "Run the linter and fix what it reports.")
        store.add(prompt)

        var edited = prompt
        edited.text = "Run the linter."
        store.update(edited)
        store.remove(id: store.prompts.first!.id)

        let reloaded = StoredPromptStore(defaults: defaults)
        XCTAssertEqual(reloaded.prompt(id: prompt.id)?.text, "Run the linter.")
        XCTAssertEqual(reloaded.prompts.count, StoredPromptStore.defaultPrompts().count)
    }

    func testCorruptDataFallsBackToDefaults() {
        defaults.set(Data("not json".utf8), forKey: StoredPromptStore.storageKey)
        let store = StoredPromptStore(defaults: defaults)
        XCTAssertEqual(store.prompts.map(\.label), StoredPromptStore.defaultPrompts().map(\.label))
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

    func testEditStoredPromptsCommandDeepLinksToPromptsPane() {
        let command = defaultPaletteCommands().first { $0.id == "app.editPrompts" }
        let editPrompts = try! XCTUnwrap(command)

        let posted = expectation(forNotification: .openSettings, object: nil) { note in
            SettingsPane.deepLinkTarget(from: note) == .prompts
        }
        editPrompts.action()
        wait(for: [posted], timeout: 1)
    }

    func testAvailabilityRequiresWorkstreamAndReceptiveAgent() {
        let command = promptPaletteCommands(for: [StoredPrompt(label: "X", text: "y")])[0]

        XCTAssertTrue(command.isAvailable(
            PaletteContext(workstreamActive: true, editorActive: false, agentCanReceivePrompt: true)))
        XCTAssertFalse(command.isAvailable(
            PaletteContext(workstreamActive: false, editorActive: false, agentCanReceivePrompt: true)))
        XCTAssertFalse(command.isAvailable(
            PaletteContext(workstreamActive: true, editorActive: false, agentCanReceivePrompt: false)))
    }

    func testActionPostsRunStoredPromptWithPromptID() {
        let prompt = StoredPrompt(label: "Commit", text: "Commit the changes.")
        let command = promptPaletteCommands(for: [prompt])[0]

        let posted = expectation(forNotification: .runStoredPrompt, object: nil) { note in
            note.object as? String == prompt.id.uuidString
        }
        command.action()
        wait(for: [posted], timeout: 1)
    }
}

@MainActor
final class CommandRegistrySyncTests: XCTestCase {
    private func command(id: String) -> PaletteCommand {
        PaletteCommand(id: id, title: id, category: "Test", action: {})
    }

    func testSyncReplacesOnlyThePrefixedCommands() {
        let registry = CommandRegistry(
            commands: [command(id: "tab.info"), command(id: "prompt.old")],
            defaults: UserDefaults(suiteName: "CommandRegistrySyncTests")!
        )

        registry.sync(idPrefix: "prompt.", with: [command(id: "prompt.new")])

        let ids = registry.commands.map(\.id)
        XCTAssertTrue(ids.contains("tab.info"))
        XCTAssertTrue(ids.contains("prompt.new"))
        XCTAssertFalse(ids.contains("prompt.old"))
    }

    func testSyncWithEmptyListRemovesAllPrefixed() {
        let registry = CommandRegistry(
            commands: [command(id: "tab.info"), command(id: "prompt.a"), command(id: "prompt.b")],
            defaults: UserDefaults(suiteName: "CommandRegistrySyncTests")!
        )

        registry.sync(idPrefix: "prompt.", with: [])

        XCTAssertEqual(registry.commands.map(\.id), ["tab.info"])
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
        XCTAssertTrue(WorkstreamAgentStateTracker.AgentRunState.idle.turnHasEnded)
        XCTAssertTrue(WorkstreamAgentStateTracker.AgentRunState.needsAttention(.justFinished).turnHasEnded)
        XCTAssertFalse(WorkstreamAgentStateTracker.AgentRunState.working.turnHasEnded)
        XCTAssertFalse(WorkstreamAgentStateTracker.AgentRunState.stalled.turnHasEnded)
        XCTAssertFalse(WorkstreamAgentStateTracker.AgentRunState.needsAttention(.permission).turnHasEnded)
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
