// ABOUTME: Identifies the tabbed panes of the Settings view, in on-screen tab order.
// ABOUTME: Raw values are persisted and carried by .openSettings deep-links — do not rename.

import Foundation

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case environment
    case codingAgent
    case prompts
    case integrations
    case advanced

    /// UserDefaults key remembering the last-selected pane.
    static let storageKey = "atelier.settingsPane"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .environment: return NSLocalizedString("Environment", comment: "Settings pane")
        case .general: return NSLocalizedString("General", comment: "Settings pane")
        case .codingAgent: return NSLocalizedString("Coding Agent", comment: "Settings pane")
        case .prompts: return NSLocalizedString("Prompts", comment: "Settings pane")
        case .integrations: return NSLocalizedString("Integrations", comment: "Settings pane")
        case .advanced: return NSLocalizedString("Advanced", comment: "Settings pane")
        }
    }

    /// SF Symbol shown above the tab label in the pane strip.
    var icon: String {
        switch self {
        case .environment: return "wrench.and.screwdriver"
        case .general: return "gearshape"
        case .codingAgent: return "sparkles"
        case .prompts: return "text.bubble"
        case .integrations: return "puzzlepiece.extension"
        case .advanced: return "gearshape.2"
        }
    }

    /// The pane an `.openSettings` notification targets, if any. Posters pass
    /// the pane's raw value as the notification object, so they don't need
    /// this type; a plain open (nil object) targets no particular pane.
    static func deepLinkTarget(from notification: Notification) -> SettingsPane? {
        (notification.object as? String).flatMap(SettingsPane.init(rawValue:))
    }
}
