// ABOUTME: Tests the agent-IPC switches and the listener they control.
// ABOUTME: Both default off, and the nudge is meaningless without messaging.

@testable import Atelier
import XCTest

final class AgentIPCSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearSettings()
        try? FileManager.default.removeItem(at: IPCEndpoint.fileURL)
    }

    override func tearDown() {
        clearSettings()
        super.tearDown()
    }

    private func clearSettings() {
        UserDefaults.standard.removeObject(forKey: AgentIPCSettings.enabledKey)
        UserDefaults.standard.removeObject(forKey: AgentIPCSettings.nudgeKey)
    }

    func test_bothSwitches_defaultOff() {
        XCTAssertFalse(AgentIPCSettings.isEnabled)
        XCTAssertFalse(AgentIPCSettings.nudgeEnabled)
    }

    func test_nudge_requiresMessaging() {
        UserDefaults.standard.set(true, forKey: AgentIPCSettings.nudgeKey)
        XCTAssertFalse(AgentIPCSettings.nudgeEnabled, "the nudge must stay off while messaging is off")

        UserDefaults.standard.set(true, forKey: AgentIPCSettings.enabledKey)
        XCTAssertTrue(AgentIPCSettings.nudgeEnabled)
    }

    func test_apply_startsAndStopsTheListener() throws {
        let server = IPCServer(service: IPCService())
        defer { server.stop() }

        UserDefaults.standard.set(true, forKey: AgentIPCSettings.enabledKey)
        AgentIPCSettings.apply(server: server)
        XCTAssertNotNil(try waitForEndpoint(), "enabling must bring the listener up")

        UserDefaults.standard.set(false, forKey: AgentIPCSettings.enabledKey)
        AgentIPCSettings.apply(server: server)
        XCTAssertTrue(try waitForNoEndpoint(), "disabling must remove ipc.json, so a helper reports IPC is off")
    }

    private func waitForEndpoint(timeout: TimeInterval = 5) throws -> IPCEndpoint? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let endpoint = IPCEndpoint.read() { return endpoint }
            usleep(20_000)
        }
        return nil
    }

    private func waitForNoEndpoint(timeout: TimeInterval = 5) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if IPCEndpoint.read() == nil { return true }
            usleep(20_000)
        }
        return false
    }
}
