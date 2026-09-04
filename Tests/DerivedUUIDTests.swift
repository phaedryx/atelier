// ABOUTME: Tests for derivedUUID, the deterministic surface-identity derivation.
// ABOUTME: Covers determinism and the collisions the old byte-folding hash produced.

@testable import Atelier
import XCTest

final class DerivedUUIDTests: XCTestCase {
    private let base = UUID(uuidString: "6C1E9B1E-6A1A-4F0E-9F1A-2B3C4D5E6F70")!

    func testTheSameInputsAlwaysDeriveTheSameUUID() {
        XCTAssertEqual(derivedUUID(from: base, salt: "terminal-1"), derivedUUID(from: base, salt: "terminal-1"))
    }

    func testDifferentSaltsDeriveDifferentUUIDs() {
        XCTAssertNotEqual(derivedUUID(from: base, salt: "terminal-1"), derivedUUID(from: base, salt: "terminal-2"))
    }

    func testDifferentBasesDeriveDifferentUUIDs() {
        XCTAssertNotEqual(derivedUUID(from: base, salt: "terminal-1"), derivedUUID(from: UUID(), salt: "terminal-1"))
    }

    /// The old implementation folded input into `bytes[i % 16]`, so two characters
    /// exactly 16 apart swapped places, landing in the same bucket with the same index
    /// contribution and producing a byte-identical UUID.
    func testSwappingTwoCharactersSixteenApartChangesTheUUID() {
        let salt = String(repeating: "a", count: 40)
        var swapped = Array(salt)
        swapped[4] = "x"
        swapped[20] = "y"
        var reversed = Array(salt)
        reversed[4] = "y"
        reversed[20] = "x"

        XCTAssertNotEqual(
            derivedUUID(from: base, salt: String(swapped)),
            derivedUUID(from: base, salt: String(reversed)),
            "A permutation of the salt must not derive the same identity"
        )
    }

    /// The old implementation added `UInt8(i & 0xFF)`, making positions k and k+256
    /// indistinguishable — so a salt long enough wrapped into the same digest.
    func testPositionsTwoHundredFiftySixApartAreDistinguishable() {
        var a = Array(repeating: Character("a"), count: 300)
        var b = a
        a[10] = "z"
        b[266] = "z"
        XCTAssertNotEqual(derivedUUID(from: base, salt: String(a)), derivedUUID(from: base, salt: String(b)))
    }

    /// A separator with no length prefix would let ("ab", "") and ("a", "b") collide
    /// once base and salt are concatenated.
    func testSaltBoundaryIsNotAmbiguous() {
        XCTAssertNotEqual(derivedUUID(from: base, salt: "terminal-11"), derivedUUID(from: base, salt: "terminal-1\u{0}1"))
    }

    func testNoCollisionsAcrossTheSaltsTheAppActuallyUses() {
        var seen: Set<UUID> = []
        for prefix in ["terminal", "browser", "editor", "env-run", "env-setup"] {
            for index in 0 ..< 500 {
                let id = derivedUUID(from: base, salt: "\(prefix)-\(index)")
                XCTAssertTrue(seen.insert(id).inserted, "Collision on \(prefix)-\(index)")
            }
        }
    }

    func testTheUUIDIsWellFormed() {
        let id = derivedUUID(from: base, salt: "terminal-1")
        XCTAssertEqual(id.uuid.6 & 0xF0, 0x80, "Version nibble should be 8 (custom), not the 4 the old comment claimed")
        XCTAssertEqual(id.uuid.8 & 0xC0, 0x80, "Variant bits should be RFC 4122")
    }
}
