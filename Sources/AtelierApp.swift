// ABOUTME: Main application entry point.
// ABOUTME: Initializes the ghostty terminal engine and presents the main window.

import os
import SwiftUI
import UserNotifications

private let logger = Logger(subsystem: "atelier", category: "app")

protocol NotificationAuthorizationRequesting {
    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    )
}

extension UNUserNotificationCenter: NotificationAuthorizationRequesting {}

extension Notification.Name {
    static let openDirectory = Notification.Name("atelier.openDirectory")
    static let openSettings = Notification.Name("atelier.openSettings")
    static let openHelp = Notification.Name("atelier.openHelp")
    static let switchToProject = Notification.Name("atelier.switchToProject")
    static let toggleSidebar = Notification.Name("atelier.toggleSidebar")
    static let switchByNumber = Notification.Name("atelier.switchByNumber") // object: Int (1-9)
    static let dismissOverlay = Notification.Name("atelier.dismissOverlay")
    static let openExternalBrowser = Notification.Name("atelier.openExternalBrowser")
    static let clearProjects = Notification.Name("atelier.clearProjects")
    static let openExternalTerminal = Notification.Name("atelier.openExternalTerminal")
    static let nextWorkstream = Notification.Name("atelier.nextWorkstream")
    static let prevWorkstream = Notification.Name("atelier.prevWorkstream")
    static let nextProject = Notification.Name("atelier.nextProject")
    static let prevProject = Notification.Name("atelier.prevProject")
    static let archiveWorkstream = Notification.Name("atelier.archiveWorkstream")
    static let renameWorkstream = Notification.Name("atelier.renameWorkstream")
    static let toggleCommandPalette = Notification.Name("atelier.toggleCommandPalette")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    enum NotificationAuthorizationLogLevel {
        case info
        case warning
    }

    func applicationDidFinishLaunching(_: Notification) {
        guard !isRunningXCTest() else { return }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Self.requestNotificationAuthorization(using: center)

        // Contextual shortcuts via key monitor (avoids cluttering the menu bar)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let chars = event.charactersIgnoringModifiers
            else { return event }
            if let digit = chars.first?.wholeNumberValue, (1 ... 9).contains(digit) {
                NotificationCenter.default.post(name: .switchByNumber, object: digit)
                return nil
            }
            if chars == "l" {
                NotificationCenter.default.post(name: .focusAddressBar, object: nil)
                return nil
            }
            return event
        }
    }

    nonisolated static func handleNotificationAuthorizationResult(
        granted: Bool,
        error: (any Error)?,
        log: @escaping @Sendable (String, NotificationAuthorizationLogLevel) -> Void = { message, level in
            switch level {
            case .info:
                logger.info("\(message, privacy: .public)")
            case .warning:
                logger.warning("\(message, privacy: .public)")
            }
        }
    ) {
        if Thread.isMainThread {
            if let error {
                log("Notification permission error: \(error.localizedDescription)", .warning)
            } else if !granted {
                log("Notification permission denied by user", .info)
            }
            return
        }

        Task { @MainActor in
            if let error {
                log("Notification permission error: \(error.localizedDescription)", .warning)
            } else if !granted {
                log("Notification permission denied by user", .info)
            }
        }
    }

    nonisolated static func requestNotificationAuthorization(
        using center: NotificationAuthorizationRequesting,
        log: @escaping @Sendable (String, NotificationAuthorizationLogLevel) -> Void = { message, level in
            switch level {
            case .info:
                logger.info("\(message, privacy: .public)")
            case .warning:
                logger.warning("\(message, privacy: .public)")
            }
        }
    ) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            handleNotificationAuthorizationResult(granted: granted, error: error, log: log)
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func applicationWillTerminate(_: Notification) {
        guard !isRunningXCTest() else { return }
        HookEventReceiver.shared.stop()
        // `ToolStatus.detect()` would do — but it spawns five probes including
        // `gh auth status`, which reaches the network, and this runs on the main
        // thread as the app is quitting. All that is wanted is one path lookup.
        let tmuxPath = CommandLineTools.path(for: "tmux")
        if let tmuxPath {
            TmuxSession.killAllSessions(tmuxPath: tmuxPath)
        }
        // `up --keep-project` servers outlive their processes deliberately, so
        // without this a quit mid-run leaves one per phase holding the
        // worktree's ports until its own deadline.
        if let composeBinary = ProcessCompose.Settings.resolveBinary() {
            ProcessCompose.PhaseExecutor.stopAllServers(binary: composeBinary)
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        let confirmQuit = UserDefaults.standard.object(forKey: "atelier.confirmQuit") as? Bool ?? true
        guard confirmQuit else { return .terminateNow }
        let projects = ProjectStore.load()
        let hasWorkstreams = projects.contains { !$0.workstreams.isEmpty }
        guard hasWorkstreams else { return .terminateNow }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Quit Atelier?", comment: "")
        alert.informativeText = NSLocalizedString("Active workstreams will be stopped.", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        alert.beginSheetModal(for: window) { response in
            NSApp.reply(toApplicationShouldTerminate: response == .alertFirstButtonReturn)
        }
        return .terminateLater
    }
}

@main
struct AtelierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("atelier.editorTabActive") private var isEditorActive = false
    @AppStorage("atelier.editorFileDirty") private var isEditorDirty = false
    @State private var pendingURLDirectory: String?

    init() {
        guard !isRunningXCTest() else { return }

        UserDefaults.standard.set(200, forKey: "NSInitialToolTipDelay") // 200ms vs system ~700-1000ms

        // Start the hook event receiver and wire it to the router and the
        // sidebar agent-state tracker. `onEvent` is invoked on the main queue.
        HookEventReceiver.shared.onEvent = { projectDir, event in
            HookEventRouter.shared.route(projectDir: projectDir, event: event)
            MainActor.assumeIsolated {
                Workstream.AgentStateTracker.shared.handle(projectDir: projectDir, event: event)
            }
        }
        HookEventReceiver.shared.start()

        // Agent IPC listens only when the user has enabled it; SettingsView
        // calls apply() again whenever the switch moves.
        IPC.AgentSettings.apply()

        // Install atelier-hook into ~/.claude/settings.json so Claude Code forwards events
        if let hookURL = Bundle.main.url(forResource: "atelier-hook", withExtension: nil, subdirectory: "Scripts") {
            HookInstaller.install(hookScriptPath: hookURL.path)
        } else if let hookURL = Bundle.main.url(forResource: "atelier-hook", withExtension: nil) {
            HookInstaller.install(hookScriptPath: hookURL.path)
        }

        // Earlier builds installed an OpenCode plugin into the user's global
        // plugin directory; it outlives Atelier unless we take it back out.
        OpencodePluginRemover.uninstall()

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Atelier cannot start", comment: "")
            alert.informativeText = NSLocalizedString(
                "The terminal engine (Ghostty) failed to initialize. This may indicate a system compatibility issue.",
                comment: ""
            )
            alert.alertStyle = .critical
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
            alert.runModal()
            exit(1)
        }
    }

    /// Resolve the directory from CLI arguments.
    /// Only returns a path when an explicit argument is provided.
    /// Returns nil if no argument, or the path doesn't exist or isn't a directory.
    private static var launchDirectory: String? {
        guard CommandLine.arguments.count > 1 else { return nil }

        let resolved = NSString(string: CommandLine.arguments[1]).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return resolved
    }

    var body: some Scene {
        Window(AppConstants.appName, id: "main") {
            if isRunningXCTest() {
                EmptyView()
            } else {
                ContentView()
                    .onAppear {
                        if let dir = Self.launchDirectory {
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: .openDirectory, object: dir)
                            }
                        }
                    }
                    .onOpenURL { url in
                        guard url.scheme == AppConstants.urlScheme else { return }
                        let path = url.path
                        guard !path.isEmpty else { return }
                        var isDir: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
                        pendingURLDirectory = path
                    }
                    .alert(
                        Text("Open Directory"),
                        isPresented: Binding(
                            get: { pendingURLDirectory != nil },
                            set: {
                                if !$0 {
                                    pendingURLDirectory = nil
                                }
                            }
                        )
                    ) {
                        Button("Allow") {
                            if let path = pendingURLDirectory {
                                NotificationCenter.default.post(name: .openDirectory, object: path)
                            }
                            pendingURLDirectory = nil
                        }
                        Button("Cancel", role: .cancel) {
                            pendingURLDirectory = nil
                        }
                    } message: {
                        Text("An external application wants to open \(pendingURLDirectory ?? "") in \(AppConstants.appName).")
                    }
            }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Remove the default Help menu so Cmd+Shift+/ doesn't open it
            CommandGroup(replacing: .help) {}

            // Feed the stock About panel our own credits.
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppConstants.appName)") {
                    AboutPanel.show()
                }
            }

            CommandGroup(replacing: .newItem) {
                // Cmd+N: context-sensitive (add project if none selected, else add workstream)
                Button("New") {
                    NotificationCenter.default.post(name: .addNew, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                // Cmd+Shift+N: always add project
                Button("New Project") {
                    NotificationCenter.default.post(name: .addProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                if isEditorActive {
                    Button("Save") {
                        NotificationCenter.default.post(name: .saveEditor, object: nil)
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isEditorDirty)

                    Button("Save As...") {
                        NotificationCenter.default.post(name: .saveEditorAs, object: nil)
                    }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                }
            }
            // Cmd+,: toggle settings
            CommandGroup(after: .appSettings) {
                Button("Settings") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)

                Button("Help") {
                    NotificationCenter.default.post(name: .openHelp, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
            }
            // View menu
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Command Palette…") {
                    NotificationCenter.default.post(name: .toggleCommandPalette, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            // Tabs
            CommandGroup(after: .toolbar) {
                Button("Info") {
                    NotificationCenter.default.post(name: .toggleInfo, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Coding Agent") {
                    NotificationCenter.default.post(name: .focusAgent, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)

                if isEditorActive {
                    Button("Find File") {
                        NotificationCenter.default.post(name: .toggleFileFinder, object: nil)
                    }
                    .keyboardShortcut("p", modifiers: .command)
                }

                Button("Start/Rerun") {
                    NotificationCenter.default.post(name: .rerunScript, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])

                Divider()

                Button("Next Tab") {
                    NotificationCenter.default.post(name: .nextTab, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

                Button("Previous Tab") {
                    NotificationCenter.default.post(name: .prevTab, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

                Button("Back to Project") {
                    NotificationCenter.default.post(name: .switchToProject, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button("Next Workstream") {
                    NotificationCenter.default.post(name: .nextWorkstream, object: nil)
                }
                .keyboardShortcut("]", modifiers: .command)

                Button("Previous Workstream") {
                    NotificationCenter.default.post(name: .prevWorkstream, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Next Project") {
                    NotificationCenter.default.post(name: .nextProject, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Button("Previous Project") {
                    NotificationCenter.default.post(name: .prevProject, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Divider()

                Button("Open in External Browser") {
                    NotificationCenter.default.post(name: .openExternalBrowser, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .option])

                Button("Open in External Terminal") {
                    NotificationCenter.default.post(name: .openExternalTerminal, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

                Divider()

                Button("Rename Workstream") {
                    NotificationCenter.default.post(name: .renameWorkstream, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Archive Workstream") {
                    NotificationCenter.default.post(name: .archiveWorkstream, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
    }
}
