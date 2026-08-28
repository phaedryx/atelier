// ABOUTME: Tests for config-directory resolution across app, debug, and test contexts.
// ABOUTME: Keeps XCTest persistence isolated from the app's real project roster.

@testable import Atelier
import XCTest

final class AppConstantsTests: XCTestCase {
    func testDebugBuildUsesReleaseConfigDirectory() {
        let base = URL(fileURLWithPath: "/tmp/atelier-config")

        let resolved = resolvedConfigDirectory(
            configDirectoryName: "atelier",
            environment: [:],
            defaultConfigBase: base,
            isRunningTests: false
        )

        XCTAssertEqual(resolved, base.appendingPathComponent("atelier"))
    }

    func testTestsUseDedicatedConfigDirectoryWithoutFallback() {
        let base = URL(fileURLWithPath: "/tmp/atelier-config")

        let resolved = resolvedConfigDirectory(
            configDirectoryName: "atelier",
            environment: [:],
            defaultConfigBase: base,
            isRunningTests: true
        )

        XCTAssertEqual(resolved, base.appendingPathComponent("atelier-tests"))
    }

    func testDetectsXCTestEnvironment() {
        XCTAssertTrue(isRunningXCTest(environment: ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"]))
        XCTAssertFalse(isRunningXCTest(environment: [:]))
    }
}
