// ABOUTME: Tests the address-identity guard that stands between a deferred C
// ABOUTME: callback and a use-after-free on an already-destroyed surface view.

@testable import Atelier
import Cocoa
import XCTest

final class TerminalLiveObjectTests: XCTestCase {
    func testFindsAnObjectThatIsStillLive() {
        let alive = NSObject()
        let other = NSObject()
        let address = Unmanaged.passUnretained(alive).toOpaque()

        let found = TerminalView.liveObject(at: address, among: [other, alive])

        XCTAssertTrue(found === alive)
    }

    func testReturnsNilForAnObjectNoLongerListed() {
        // Stands in for a view `destroy()` has dropped from the registry: the
        // address is still a valid bit pattern, and the callback must not
        // resurrect an object from it.
        let dropped = NSObject()
        let address = Unmanaged.passUnretained(dropped).toOpaque()

        let found = TerminalView.liveObject(at: address, among: [NSObject(), NSObject()])

        XCTAssertNil(found)
    }

    func testReturnsNilAgainstAnEmptyRegistry() {
        let object = NSObject()
        let address = Unmanaged.passUnretained(object).toOpaque()

        let found = TerminalView.liveObject(at: address, among: [NSObject]())

        XCTAssertNil(found)
    }
}
