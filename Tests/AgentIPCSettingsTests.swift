// ABOUTME: Tests the agent-IPC switches and the listener they control.
// ABOUTME: Both default off, and the nudge is meaningless without messaging.

@testable import Atelier
import XCTest

final class AgentIPCSettingsTests: XCTestCase {
    /// These keys live in the app's own defaults domain, and the test host *is*
    /// the app — so a test that simply cleared them would silently turn the
    /// feature off for whoever ran the suite. Save and put back.
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in [IPC.AgentSettings.enabledKey, IPC.AgentSettings.nudgeKey] {
            saved[key] = UserDefaults.standard.object(forKey: key)
        }
        clearSettings()
        try? FileManager.default.removeItem(at: IPC.Endpoint.fileURL)
    }

    override func tearDown() {
        clearSettings()
        for (key, value) in saved {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        saved.removeAll()
        super.tearDown()
    }

    private func clearSettings() {
        UserDefaults.standard.removeObject(forKey: IPC.AgentSettings.enabledKey)
        UserDefaults.standard.removeObject(forKey: IPC.AgentSettings.nudgeKey)
    }

    func test_bothSwitches_defaultOff() {
        XCTAssertFalse(IPC.AgentSettings.isEnabled)
        XCTAssertFalse(IPC.AgentSettings.nudgeEnabled)
    }

    func test_nudge_requiresMessaging() {
        UserDefaults.standard.set(true, forKey: IPC.AgentSettings.nudgeKey)
        XCTAssertFalse(IPC.AgentSettings.nudgeEnabled, "the nudge must stay off while messaging is off")

        UserDefaults.standard.set(true, forKey: IPC.AgentSettings.enabledKey)
        XCTAssertTrue(IPC.AgentSettings.nudgeEnabled)
    }

    func test_apply_startsAndStopsTheListener() throws {
        let server = IPC.Server(service: IPC.Service())
        defer { server.stop() }

        UserDefaults.standard.set(true, forKey: IPC.AgentSettings.enabledKey)
        IPC.AgentSettings.apply(server: server)
        XCTAssertNotNil(try waitForEndpoint(), "enabling must bring the listener up")

        UserDefaults.standard.set(false, forKey: IPC.AgentSettings.enabledKey)
        IPC.AgentSettings.apply(server: server)
        XCTAssertTrue(try waitForNoEndpoint(), "disabling must remove ipc.json, so a helper reports IPC is off")
    }

    private func waitForEndpoint(timeout: TimeInterval = 5) throws -> IPC.Endpoint? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let endpoint = IPC.Endpoint.read() {
                return endpoint
            }
            usleep(20_000)
        }
        return nil
    }

    private func waitForNoEndpoint(timeout: TimeInterval = 5) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if IPC.Endpoint.read() == nil {
                return true
            }
            usleep(20_000)
        }
        return false
    }
}
