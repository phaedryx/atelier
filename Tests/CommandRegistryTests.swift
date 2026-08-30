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
}
