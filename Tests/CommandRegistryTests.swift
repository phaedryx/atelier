// ABOUTME: Tests for the palette's command registry: search, availability, usage ranking.
// ABOUTME: Uses an isolated UserDefaults suite so frequency persistence never leaks.

@testable import Atelier
import XCTest

@MainActor
final class CommandRegistryTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "atelier.tests.commandRegistry"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func command(
        _ id: String, title: String, category: String = "Test",
        available: @escaping @MainActor @Sendable (PaletteContext) -> Bool = { _ in true }
    ) -> PaletteCommand {
        PaletteCommand(id: id, title: title, category: category, shortcut: nil,
                       isAvailable: available, action: {})
    }

    private let anyContext = PaletteContext(workstreamActive: true, editorActive: false)

    func testSearchFiltersUnavailableCommands() {
        let registry = CommandRegistry(commands: [
            command("a", title: "Alpha"),
            command("b", title: "Alpha Editor", available: { $0.editorActive }),
        ], defaults: defaults)

        let results = registry.search("alpha", context: anyContext)

        XCTAssertEqual(results.map(\.id), ["a"])
    }

    func testSearchOrdersByScore() {
        let registry = CommandRegistry(commands: [
            command("interior", title: "Renew Terminal"),
            command("prefix", title: "New Terminal"),
        ], defaults: defaults)

        let results = registry.search("new", context: anyContext)

        XCTAssertEqual(results.map(\.id), ["prefix", "interior"])
    }

    func testEmptyQueryReturnsAllAvailableSortedByUsageThenTitle() {
        let registry = CommandRegistry(commands: [
            command("b", title: "Bravo"),
            command("a", title: "Alpha"),
            command("c", title: "Charlie"),
        ], defaults: defaults)
        registry.recordUsage("c")
        registry.recordUsage("c")

        let results = registry.search("", context: anyContext)

        XCTAssertEqual(results.map(\.id), ["c", "a", "b"])
    }

    func testUsageSurvivesANewRegistryInstance() {
        let first = CommandRegistry(commands: [command("x", title: "X-Ray")], defaults: defaults)
        first.recordUsage("x")
        first.recordUsage("x")

        let second = CommandRegistry(commands: [
            command("x", title: "X-Ray"),
            command("y", title: "X-Ray Yankee"),
        ], defaults: defaults)

        let results = second.search("", context: anyContext)
        XCTAssertEqual(results.first?.id, "x")
    }

    func testDuplicateIDsAreRejected() {
        let registry = CommandRegistry(commands: [
            command("dup", title: "First"),
            command("dup", title: "Second"),
        ], defaults: defaults)

        XCTAssertEqual(registry.commands.count, 1)
        XCTAssertEqual(registry.commands.first?.title, "First")
    }

    private func disabledCommand(_ id: String, title: String, reason: String) -> PaletteCommand {
        PaletteCommand(id: id, title: title, category: "Test", shortcut: nil,
                       availability: { _ in .disabled(reason) }, action: {})
    }

    /// A disabled command is listed — it is there to explain itself — but it
    /// never outranks a runnable one, however well it scores. Return lands on a
    /// disabled row only when the user has deliberately arrowed to it.
    func testDisabledCommandsSortBelowRunnableOnes() {
        let registry = CommandRegistry(commands: [
            disabledCommand("d", title: "Alpha", reason: "The Coding Agent is mid-turn."),
            command("a", title: "Alpha Later Words"),
        ], defaults: defaults)

        XCTAssertEqual(registry.search("alpha", context: anyContext).map(\.id), ["a", "d"])
        XCTAssertEqual(registry.search("", context: anyContext).map(\.id), ["a", "d"])
    }

    /// Usage ranking must not lift a disabled row over a runnable one: the
    /// frequently-used prompt is exactly the one most likely to be mid-turn.
    func testUsageCannotLiftADisabledCommandAboveARunnableOne() {
        let registry = CommandRegistry(commands: [
            disabledCommand("d", title: "Alpha", reason: "busy"),
            command("a", title: "Alpha"),
        ], defaults: defaults)
        for _ in 0 ..< 10 {
            registry.recordUsage("d")
        }

        XCTAssertEqual(registry.search("alpha", context: anyContext).first?.id, "a")
        XCTAssertEqual(registry.search("", context: anyContext).first?.id, "a")
    }

    /// `.hidden` still means gone, which is what every command using the
    /// `isAvailable:` initializer gets.
    func testHiddenCommandsAreStillDropped() {
        let registry = CommandRegistry(commands: [
            command("a", title: "Alpha", available: { _ in false }),
        ], defaults: defaults)

        XCTAssertTrue(registry.search("alpha", context: anyContext).isEmpty)
        XCTAssertTrue(registry.search("", context: anyContext).isEmpty)
    }

    /// Replaces `clampedPaletteSelection`, which clamped an *index*. Selection
    /// is an id now — both the palette and the editor's file finder rebuild
    /// their result array on every keystroke — so what has to be pinned is that
    /// moving past either end stays put rather than wrapping, and that a
    /// selection naming a row that is gone is treated as no selection.
    func testNeighbouringSelectionClampsAtBothEnds() {
        let ids = ["a", "b", "c"]

        XCTAssertEqual(neighbouringSelection(from: "a", in: ids, delta: 1), "b")
        XCTAssertEqual(neighbouringSelection(from: "b", in: ids, delta: -1), "a")
        XCTAssertEqual(neighbouringSelection(from: "c", in: ids, delta: 1), "c")
        XCTAssertEqual(neighbouringSelection(from: "a", in: ids, delta: -1), "a")
    }

    func testNeighbouringSelectionEntersTheListFromEitherEnd() {
        let ids = ["a", "b", "c"]

        XCTAssertEqual(neighbouringSelection(from: nil, in: ids, delta: 1), "a")
        XCTAssertEqual(neighbouringSelection(from: nil, in: ids, delta: -1), "c")
        // An id the results no longer contain names a row that is gone, so it
        // is worth exactly as much as no selection at all.
        XCTAssertEqual(neighbouringSelection(from: "gone", in: ids, delta: 1), "a")
    }

    func testNeighbouringSelectionOfAnEmptyListIsNothing() {
        XCTAssertNil(neighbouringSelection(from: nil, in: [String](), delta: 1))
        XCTAssertNil(neighbouringSelection(from: "a", in: [String](), delta: -1))
    }
}
