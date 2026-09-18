// ABOUTME: Identifies the tabbed panes of the Settings view, in on-screen tab order.
// ABOUTME: Raw values are persisted in UserDefaults and name the remembered pane — do not rename.

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

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .environment: NSLocalizedString("Environment", comment: "Settings pane")
        case .general: NSLocalizedString("General", comment: "Settings pane")
        case .codingAgent: NSLocalizedString("Coding Agent", comment: "Settings pane")
        case .prompts: NSLocalizedString("Prompts", comment: "Settings pane")
        case .integrations: NSLocalizedString("Integrations", comment: "Settings pane")
        case .advanced: NSLocalizedString("Advanced", comment: "Settings pane")
        }
    }

    /// SF Symbol shown above the tab label in the pane strip.
    var icon: String {
        switch self {
        case .environment: "wrench.and.screwdriver"
        case .general: "gearshape"
        case .codingAgent: "sparkles"
        case .prompts: "text.bubble"
        case .integrations: "puzzlepiece.extension"
        case .advanced: "gearshape.2"
        }
    }
}
