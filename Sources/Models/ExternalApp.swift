// ABOUTME: The external editors and terminals a directory can be opened in, and which one is the default.
// ABOUTME: Detection, default resolution and menu grouping are pure; only `open` and `isInstalled` touch AppKit.

import AppKit
import OSLog

private let logger = Logger(subsystem: "atelier", category: "external-app")

/// The one place Atelier hands a directory to another application.
///
/// Installation is decided by LaunchServices through
/// `urlForApplication(withBundleIdentifier:)`, which already knows every
/// bundle in `/Applications`, `~/Applications` (where JetBrains Toolbox puts
/// its IDEs), the `/System` equivalents, and anywhere else the user put one —
/// so there is no directory walk, no `open -Ra` probe, and no child process.
/// Opening goes through `NSWorkspace` for the same reason: the path travels as
/// a `URL`, nothing is spliced into a command line, and no CLI shim on `PATH`
/// is consulted — a GUI app's environment never read the `.zshrc` that puts
/// `code` there.
///
/// Running a *command* in a terminal is a different job with an injection
/// surface of its own, and stays in `ExternalTerminal.run`.
enum ExternalApp {
    enum Kind: String, CaseIterable, Sendable {
        case editor
        case terminal

        /// The `UserDefaults` key holding this kind's chosen bundle id.
        /// `atelier.defaultTerminal` predates this type and is what the
        /// Settings picker has always written, so it keeps its spelling.
        var defaultsKey: String {
            switch self {
            case .editor: "atelier.defaultEditor"
            case .terminal: "atelier.defaultTerminal"
            }
        }
    }

    struct Candidate: Sendable {
        let name: String
        let bundleID: String
        let kind: Kind
    }

    /// Every app Atelier knows how to offer, in the order it is offered.
    ///
    /// Order is load-bearing: with no stored default, the first *installed*
    /// candidate of a kind is the one the plain "Open in External …" action
    /// uses. Apple Terminal ships with macOS, so the terminal kind always
    /// resolves to something; the editor kind may legitimately resolve to
    /// nothing, and every editor affordance is hidden when it does.
    static let catalog: [Candidate] = [
        Candidate(name: "VS Code", bundleID: "com.microsoft.VSCode", kind: .editor),
        Candidate(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", kind: .editor),
        Candidate(name: "Zed", bundleID: "dev.zed.Zed", kind: .editor),
        Candidate(name: "RubyMine", bundleID: "com.jetbrains.rubymine", kind: .editor),
        Candidate(name: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij", kind: .editor),
        Candidate(name: "IntelliJ IDEA CE", bundleID: "com.jetbrains.intellij.ce", kind: .editor),

        Candidate(name: "Ghostty", bundleID: "com.mitchellh.ghostty", kind: .terminal),
        Candidate(name: "iTerm2", bundleID: "com.googlecode.iterm2", kind: .terminal),
        Candidate(name: "Terminal", bundleID: "com.apple.Terminal", kind: .terminal),
        Candidate(name: "Warp", bundleID: "dev.warp.Warp-Stable", kind: .terminal),
        Candidate(name: "WezTerm", bundleID: "com.github.wez.wezterm", kind: .terminal),
        Candidate(name: "Alacritty", bundleID: "org.alacritty", kind: .terminal),
        Candidate(name: "kitty", bundleID: "net.kovidgoyal.kitty", kind: .terminal),
    ]

    // MARK: - Detection

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// The installed apps of `kind`, in catalog order.
    static func detect(_ kind: Kind, isInstalled: (String) -> Bool = isInstalled) -> [AppInfo] {
        catalog
            .filter { $0.kind == kind && isInstalled($0.bundleID) }
            .map { AppInfo(name: $0.name, bundleID: $0.bundleID) }
    }

    // MARK: - Defaults

    /// The stored default if it is still installed, otherwise the first
    /// installed app, otherwise nothing.
    ///
    /// An uninstalled default falls through rather than failing: the user
    /// removed that app, and any installed alternative is a better answer to
    /// "open this" than doing nothing.
    static func resolve(stored: String?, installed: [AppInfo]) -> AppInfo? {
        if let stored, !stored.isEmpty, let match = installed.first(where: { $0.bundleID == stored }) {
            return match
        }
        return installed.first
    }

    static func preferred(_ kind: Kind, installed: [AppInfo], defaults: UserDefaults = .standard) -> AppInfo? {
        resolve(stored: defaults.string(forKey: kind.defaultsKey), installed: installed)
    }

    static func choose(_ app: AppInfo, as kind: Kind, defaults: UserDefaults = .standard) {
        defaults.set(app.bundleID, forKey: kind.defaultsKey)
    }

    // MARK: - Menu

    struct MenuItem: Identifiable {
        let app: AppInfo
        let isDefault: Bool
        var id: String {
            app.bundleID
        }
    }

    struct MenuSection: Identifiable {
        let kind: Kind
        let items: [MenuItem]
        var id: Kind {
            kind
        }
    }

    /// The "Open With" menu: one section per kind with anything installed,
    /// editors first, each kind's effective default marked — the *resolved*
    /// one, so a stale or empty stored value still ticks what a plain open
    /// would actually use.
    ///
    /// Takes the stored ids as values rather than reading `UserDefaults`, so a
    /// view passes its `@AppStorage` copies and redraws the tick when one moves.
    static func menuSections(installed: [Kind: [AppInfo]], stored: [Kind: String]) -> [MenuSection] {
        Kind.allCases.compactMap { kind in
            let apps = installed[kind] ?? []
            guard !apps.isEmpty else { return nil }
            let chosen = resolve(stored: stored[kind], installed: apps)?.bundleID
            return MenuSection(
                kind: kind,
                items: apps.map { MenuItem(app: $0, isDefault: $0.bundleID == chosen) }
            )
        }
    }

    // MARK: - Opening

    /// Opens `directory` in this kind's default app. Resolves against a fresh
    /// detection rather than `AppEnvironment`'s cached lists, so it works
    /// before startup detection has finished — a handful of LaunchServices
    /// lookups, not a child process.
    static func open(directory: String, kind: Kind) {
        guard let app = preferred(kind, installed: detect(kind)) else {
            logger.warning("No \(kind.rawValue, privacy: .public) installed to open \(directory, privacy: .public)")
            return
        }
        open(directory: directory, in: app)
    }

    /// Opens `directory` in `app` and makes it the default for `kind` — the
    /// "Open With" menu's behaviour, where picking is also choosing.
    static func open(directory: String, in app: AppInfo, choosingFor kind: Kind) {
        choose(app, as: kind)
        open(directory: directory, in: app)
    }

    private static func open(directory: String, in app: AppInfo) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            logger.warning("\(app.bundleID, privacy: .public) is no longer installed")
            return
        }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: directory)],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                logger.error("Opening \(directory, privacy: .public) in \(app.bundleID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
