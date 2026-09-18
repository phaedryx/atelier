// ABOUTME: The app-level commands menus and the palette send, and the channel carrying them.
// ABOUTME: Replaces the one-poster/one-receiver Notification.Name pairs ContentView received.

import Combine
import Foundation

/// One thing the user asked the application to do.
///
/// Each case replaces a `Notification.Name` that had exactly one poster family
/// and exactly one receiver — a function call spelled as a broadcast. Tracing
/// one cost three files: the post in `AtelierApp`, the name declared in some
/// view, the `.onReceive` in a third. Worse, an observer installed in a
/// `@ViewBuilder` branch exists only while that branch is mounted, so a
/// producer elsewhere could reach nothing at all, silently. A value the
/// compiler checks makes both failures impossible: `ContentView.handle` has no
/// `default:`, so a case nothing handles does not build.
///
/// **Only commands `ContentView` receives live here**, because `ContentView` is
/// the always-mounted root — it is the mount guarantee, not the notification,
/// that makes a single receiver safe. Commands received in `ProjectSidebar`
/// (`.addNew`, `.addProject`, `.renameWorkstream`, `.openDirectory`) and in
/// `TerminalContainerView` (the tab family) stay on `NotificationCenter` until
/// they get channels of their own; anything with more than one receiver, or a
/// genuinely broadcast meaning, stays there permanently.
///
/// Top-level rather than under one of the model namespaces for the reason
/// `ProcessRunner` and `AppEnvironment` are: the obvious enclosing name, `App`,
/// collides with SwiftUI's own protocol.
enum AppCommand: Equatable, Sendable {
    // MARK: - Application

    case toggleSidebar
    case toggleCommandPalette
    case openHelp
    /// `pane` nil is the plain ⌘, toggle, which opens or closes Settings on
    /// whichever pane was last shown. A named pane is a deep link: it always
    /// opens, never toggles closed, and is remembered for next time. The pane
    /// travelled as a raw `String` while this was a notification; it is typed
    /// now, so a misspelling is a compile error rather than a silent plain open.
    case openSettings(pane: SettingsPane?)
    case openExternalTerminal
    case clearProjects

    // MARK: - Navigation

    /// Go up one level: the project the selected workstream belongs to. Carries
    /// no payload and can mean nothing else, which is why a *named* jump needs
    /// `focusProject` instead.
    case switchToProject
    case focusWorkstream(UUID)
    case focusProject(UUID)
    case nextWorkstream
    case prevWorkstream
    case nextProject
    case prevProject

    // MARK: - Workstream lifecycle

    /// The ⌘⇧W / "Archive Workstream" path, which lands on `Archiver.remove`
    /// and leaves the files on disk. See CLAUDE.md's "Remove vs purge".
    case archiveWorkstream
    /// A nil id means "the selected workstream", which is what the palette
    /// sends — a command closure is built once and never learns which
    /// workstream is active. Either way this lands on `ContentView.confirmPurge`,
    /// so `purgeWarning` and `destroyableWorktreePath` still stand in front of
    /// the delete.
    case purgeWorkstream(UUID?)

    // MARK: - Actions on the selected workstream

    // Each is the sidebar context menu's item aimed at the *selected*
    // workstream rather than the hovered row. They no-op when there is no
    // target, which is the state the palette hides the rows in — the receiver
    // checks anyway, because nothing stops a command arriving between a body
    // evaluation and a click.
    case revealInFinder
    case openOnGitHub
    case openPullRequest
    case openInShortcut
    case copyBranchName
    case copyWorktreePath
}

/// Carries `AppCommand`s from wherever the user pressed something to the one
/// view that acts on them.
///
/// A `PassthroughSubject` and deliberately not a `@Published` value: a command
/// is an event, and a current-value publisher would replay the last one on
/// every new subscription — re-firing a purge confirmation on a body
/// evaluation. Nothing is buffered, so a command sent while `ContentView` is
/// not subscribed is dropped exactly the way a notification with no observer
/// was.
///
/// `shared` is what senders use: menu builders in `AtelierApp` and the palette's
/// command closures in `DefaultCommands` are built once, outside any view, so
/// there is nothing to inject into them. Tests construct their own instance, or
/// subscribe to `shared` for the closures that cannot take one.
@MainActor
final class AppCommandChannel: ObservableObject {
    static let shared = AppCommandChannel()

    private let subject = PassthroughSubject<AppCommand, Never>()

    /// Every command sent from this point on. Subscribing replays nothing.
    var publisher: AnyPublisher<AppCommand, Never> {
        subject.eraseToAnyPublisher()
    }

    func send(_ command: AppCommand) {
        subject.send(command)
    }
}
