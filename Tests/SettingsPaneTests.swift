// ABOUTME: Tests for the SettingsPane enum backing the tabbed Settings view.
// ABOUTME: Covers raw-value persistence stability, tab order, and deep-link parsing.

@testable import Atelier
import XCTest

final class SettingsPaneTests: XCTestCase {
    func testRawValuesAreStable() {
        // Raw values are persisted in UserDefaults (atelier.settingsPane)
        // and carried in .openSettings notifications; renaming one silently
        // resets the user's remembered pane.
        XCTAssertEqual(SettingsPane.environment.rawValue, "environment")
        XCTAssertEqual(SettingsPane.general.rawValue, "general")
        XCTAssertEqual(SettingsPane.codingAgent.rawValue, "codingAgent")
        XCTAssertEqual(SettingsPane.prompts.rawValue, "prompts")
        XCTAssertEqual(SettingsPane.advanced.rawValue, "advanced")
        XCTAssertEqual(SettingsPane.integrations.rawValue, "integrations")
    }

    func testTabOrderStartsWithGeneral() {
        XCTAssertEqual(
            SettingsPane.allCases,
            [.general, .environment, .codingAgent, .prompts, .integrations, .advanced]
        )
    }

    func testIntegrationsIsDeepLinkable() {
        // The Shortcut dialog's "unauthorized" error links straight to the token field.
        let note = Notification(name: .openSettings, object: "integrations")
        XCTAssertEqual(SettingsPane.deepLinkTarget(from: note), .integrations)
    }

    func testEveryPaneHasTitleAndIcon() {
        for pane in SettingsPane.allCases {
            XCTAssertFalse(pane.title.isEmpty, "\(pane) has no title")
            XCTAssertFalse(pane.icon.isEmpty, "\(pane) has no icon")
        }
    }

    func testDeepLinkTargetParsesRawValueObject() {
        let note = Notification(name: .openSettings, object: "codingAgent")
        XCTAssertEqual(SettingsPane.deepLinkTarget(from: note), .codingAgent)
    }

    func testDeepLinkTargetIsNilForPlainOpen() {
        XCTAssertNil(SettingsPane.deepLinkTarget(from: Notification(name: .openSettings)))
    }

    func testDeepLinkTargetIsNilForUnknownOrNonStringObjects() {
        XCTAssertNil(SettingsPane.deepLinkTarget(from: Notification(name: .openSettings, object: "notAPane")))
        XCTAssertNil(SettingsPane.deepLinkTarget(from: Notification(name: .openSettings, object: 42)))
    }
}
