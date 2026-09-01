// ABOUTME: Tests for per-project environment variable definitions and resolution.
// ABOUTME: Covers computed ports, ${NAME} expansion, and the cycle guard.

@testable import Atelier
import XCTest

final class ProjectEnvironmentVarsTests: XCTestCase {
    private let worktree = "/tmp/atelier-test/worktree-a"

    /// Every port is free, so a computed row lands on its hashed value.
    private let allFree: (Int) -> Bool = { _ in true }

    // MARK: - Computed ports

    func testComputedPortMatchesSaltedHash() {
        let vars = ProjectEnvironmentVars.resolve(
            [EnvVarDefinition(name: "BFF_PORT", kind: .computedPort)],
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertEqual(vars["BFF_PORT"], "\(PortAllocator.port(for: worktree, salt: "BFF_PORT"))")
    }

    func testComputedPortsDifferPerVariable() {
        let vars = ProjectEnvironmentVars.resolve(
            [
                EnvVarDefinition(name: "BFF_PORT", kind: .computedPort),
                EnvVarDefinition(name: "RAILS_PORT", kind: .computedPort),
            ],
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertNotEqual(vars["BFF_PORT"], vars["RAILS_PORT"])
    }

    func testComputedPortsDifferPerWorktree() {
        let definitions = [EnvVarDefinition(name: "BFF_PORT", kind: .computedPort)]

        let a = ProjectEnvironmentVars.resolve(definitions, workingDirectory: worktree, isFree: allFree)
        let b = ProjectEnvironmentVars.resolve(
            definitions,
            workingDirectory: "/tmp/atelier-test/worktree-b",
            isFree: allFree
        )

        XCTAssertNotEqual(a["BFF_PORT"], b["BFF_PORT"])
    }

    /// The same worktree must produce the same port every run, or a bookmark or
    /// an OAuth redirect saved against it breaks on the next start.
    func testComputedPortIsStableAcrossResolutions() {
        let definitions = [EnvVarDefinition(name: "BFF_PORT", kind: .computedPort)]

        let first = ProjectEnvironmentVars.resolve(definitions, workingDirectory: worktree, isFree: allFree)
        let second = ProjectEnvironmentVars.resolve(definitions, workingDirectory: worktree, isFree: allFree)

        XCTAssertEqual(first["BFF_PORT"], second["BFF_PORT"])
    }

    func testComputedPortSkipsPortsInUse() {
        let hashed = PortAllocator.port(for: worktree, salt: "BFF_PORT")

        let vars = ProjectEnvironmentVars.resolve(
            [EnvVarDefinition(name: "BFF_PORT", kind: .computedPort)],
            workingDirectory: worktree,
            isFree: { $0 != hashed }
        )

        XCTAssertEqual(vars["BFF_PORT"], "\(hashed + 1)")
    }

    /// Two variables whose hashes collide must not both take the same port.
    func testComputedPortsNeverCollideWithEachOther() {
        // Pin every probe to "free" so only the claimed-set logic can separate them.
        let vars = ProjectEnvironmentVars.resolve(
            (1 ... 20).map { EnvVarDefinition(name: "PORT_\($0)", kind: .computedPort) },
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertEqual(Set(vars.values).count, vars.count)
    }

    // MARK: - Literals and templating

    func testLiteralPassesThroughUntouched() {
        let vars = ProjectEnvironmentVars.resolve(
            [EnvVarDefinition(name: "NODE_ENV", value: "development")],
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertEqual(vars["NODE_ENV"], "development")
    }

    func testLiteralExpandsComputedPort() {
        let vars = ProjectEnvironmentVars.resolve(
            [
                EnvVarDefinition(name: "RAILS_PORT", kind: .computedPort),
                EnvVarDefinition(name: "PROXY_API_URL", value: "http://localhost:${RAILS_PORT}"),
            ],
            workingDirectory: worktree,
            isFree: allFree
        )

        let port = try? XCTUnwrap(vars["RAILS_PORT"])
        XCTAssertEqual(vars["PROXY_API_URL"], "http://localhost:\(port ?? "")")
    }

    /// A literal may reference one declared after it.
    func testLiteralExpandsForwardReference() {
        let vars = ProjectEnvironmentVars.resolve(
            [
                EnvVarDefinition(name: "URL", value: "${SCHEME}://localhost"),
                EnvVarDefinition(name: "SCHEME", value: "https"),
            ],
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertEqual(vars["URL"], "https://localhost")
    }

    /// An unknown name stays visible rather than becoming an empty string a
    /// service would silently treat as a default.
    func testUnknownReferenceIsLeftVerbatim() {
        let vars = ProjectEnvironmentVars.resolve(
            [EnvVarDefinition(name: "URL", value: "http://localhost:${NOPE}")],
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertEqual(vars["URL"], "http://localhost:${NOPE}")
    }

    func testCycleDoesNotHang() {
        let vars = ProjectEnvironmentVars.resolve(
            [
                EnvVarDefinition(name: "A", value: "${B}"),
                EnvVarDefinition(name: "B", value: "${A}"),
            ],
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertNotNil(vars["A"])
        XCTAssertNotNil(vars["B"])
    }

    // MARK: - Name validation

    func testAcceptsOrdinaryNames() {
        for name in ["PORT", "_private", "BFF_PORT", "a1"] {
            XCTAssertTrue(EnvVarDefinition(name: name).hasValidName, name)
        }
    }

    func testRejectsNamesAShellWouldMisread() {
        for name in ["FOO BAR", "FOO=BAR", "1PORT", "FOO-BAR", "FOO;rm", "$FOO"] {
            XCTAssertFalse(EnvVarDefinition(name: name).hasValidName, name)
        }
    }

    /// A freshly added row is unfinished, not wrong — it must not turn red
    /// before it has been typed into.
    func testEmptyNameIsNotMarkedInvalid() {
        XCTAssertTrue(EnvVarDefinition(name: "").hasValidName)
        XCTAssertFalse(EnvVarDefinition(name: "").isUsable)
    }

    func testInvalidNamesAreNotExported() {
        let vars = ProjectEnvironmentVars.resolve(
            [
                EnvVarDefinition(name: "FOO BAR", value: "x"),
                EnvVarDefinition(name: "1PORT", kind: .computedPort),
                EnvVarDefinition(name: "GOOD", value: "y"),
            ],
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertEqual(vars, ["GOOD": "y"])
    }

    func testUnnamedDefinitionsAreDropped() {
        let vars = ProjectEnvironmentVars.resolve(
            [
                EnvVarDefinition(name: "  ", value: "orphan"),
                EnvVarDefinition(name: "", kind: .computedPort),
            ],
            workingDirectory: worktree,
            isFree: allFree
        )

        XCTAssertTrue(vars.isEmpty)
    }

    func testUnterminatedReferenceIsLeftVerbatim() {
        XCTAssertEqual(ProjectEnvironmentVars.expand("http://x:${PORT", using: ["PORT": "1"]), "http://x:${PORT")
    }

    // MARK: - Storage

    func testDefinitionsRoundTrip() {
        let project = "/tmp/atelier-test/project-\(UUID().uuidString)"
        defer { ProjectEnvironmentVars.save([], for: project) }
        let definitions = [
            EnvVarDefinition(name: "BFF_PORT", kind: .computedPort),
            EnvVarDefinition(name: "NODE_ENV", value: "development"),
        ]

        ProjectEnvironmentVars.save(definitions, for: project)

        XCTAssertEqual(ProjectEnvironmentVars.definitions(for: project), definitions)
    }

    func testSavingEmptyClearsTheProject() {
        let project = "/tmp/atelier-test/project-\(UUID().uuidString)"
        ProjectEnvironmentVars.save([EnvVarDefinition(name: "A", value: "1")], for: project)

        ProjectEnvironmentVars.save([], for: project)

        XCTAssertTrue(ProjectEnvironmentVars.definitions(for: project).isEmpty)
    }
}
