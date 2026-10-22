// ABOUTME: Context-menu items and the "Open With" menu that open a directory in an external editor or terminal.
// ABOUTME: Thin over ExternalApp, which owns detection and the per-kind default.

import SwiftUI

/// "Open in External Editor", "Open in External Terminal", and the "Open With"
/// submenu, for a context menu. The editor item is omitted when no editor is
/// installed, the same choice the menu makes for "Open on GitHub" with no
/// remote; a terminal always exists, because Apple Terminal ships with macOS.
///
/// `installed` is a parameter, not an `@EnvironmentObject` read, because this
/// is built inside `.contextMenu`: a menu is presented outside the row's own
/// hierarchy, and a missing environment object there is a crash rather than an
/// empty menu. The row's owner already holds `AppEnvironment`, so it passes the
/// value down the way it passes `githubURL`.
struct OpenInAppMenuItems: View {
    let directory: String
    let installed: [ExternalApp.Kind: [AppInfo]]

    var body: some View {
        if !(installed[.editor] ?? []).isEmpty {
            Button {
                ExternalApp.open(directory: directory, kind: .editor)
            } label: {
                Label("Open in External Editor", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
        Button {
            ExternalApp.open(directory: directory, kind: .terminal)
        } label: {
            Label("Open in External Terminal", systemImage: "terminal")
        }
        OpenWithMenu(directory: directory, installed: installed)
    }
}

/// Every detected editor and terminal, grouped by kind with each kind's
/// default ticked. Picking one opens `directory` in it and makes it that
/// kind's default, so the menu is both the picker and a way to reach an app
/// once without a trip to Settings.
struct OpenWithMenu<MenuLabel: View>: View {
    let directory: String
    /// A parameter for the reason `OpenInAppMenuItems` gives.
    let installed: [ExternalApp.Kind: [AppInfo]]
    let label: MenuLabel

    // Read here so the ticks redraw when a pick, or Settings, moves a default.
    @AppStorage(ExternalApp.Kind.editor.defaultsKey) private var defaultEditor = ""
    @AppStorage(ExternalApp.Kind.terminal.defaultsKey) private var defaultTerminal = ""

    init(directory: String, installed: [ExternalApp.Kind: [AppInfo]], @ViewBuilder label: () -> MenuLabel) {
        self.directory = directory
        self.installed = installed
        self.label = label()
    }

    var body: some View {
        let sections = ExternalApp.menuSections(
            installed: installed,
            stored: [.editor: defaultEditor, .terminal: defaultTerminal]
        )
        if !sections.isEmpty {
            Menu {
                ForEach(sections) { section in
                    Section(section.kind.sectionTitle) {
                        ForEach(section.items) { item in
                            Toggle(item.app.name, isOn: Binding(
                                get: { item.isDefault },
                                set: { _ in
                                    ExternalApp.open(directory: directory, in: item.app, choosingFor: section.kind)
                                }
                            ))
                        }
                    }
                }
            } label: {
                label
            }
        }
    }
}

extension OpenWithMenu where MenuLabel == Label<Text, Image> {
    init(directory: String, installed: [ExternalApp.Kind: [AppInfo]]) {
        self.init(directory: directory, installed: installed) {
            Label("Open With", systemImage: "arrow.up.forward.app")
        }
    }
}

extension ExternalApp.Kind {
    var sectionTitle: LocalizedStringKey {
        switch self {
        case .editor: "Editors"
        case .terminal: "Terminals"
        }
    }
}
