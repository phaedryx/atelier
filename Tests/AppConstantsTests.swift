// ABOUTME: Tests for XCTest-environment detection, which keeps test persistence
// ABOUTME: isolated from the app's real cache and project roster.

@testable import Atelier
import XCTest

final class AppConstantsTests: XCTestCase {
    func testDetectsXCTestEnvironment() {
        XCTAssertTrue(isRunningXCTest(environment: ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"]))
        XCTAssertFalse(isRunningXCTest(environment: [:]))
    }
}
