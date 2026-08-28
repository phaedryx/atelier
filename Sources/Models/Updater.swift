// ABOUTME: Placeholder auto-update controller; Atelier ships no Sparkle feed.
// ABOUTME: Reports itself unconfigured so the UI falls back to UpdateChecker's Homebrew path.

import Combine

/// Auto-updates are not wired up in Atelier.
///
/// The upstream project used Sparkle with a signing key and appcast feed this
/// fork does not control. Rather than ship an update channel pointing at someone
/// else's builds, the fork drops Sparkle entirely; `UpdateChecker` still surfaces
/// new releases for Homebrew users. Restoring in-app updates means generating a
/// new Ed25519 key pair, hosting an appcast, and reinstating the Sparkle package.
@MainActor
final class Updater: ObservableObject {
    var canCheckForUpdates: Bool { false }

    /// Always false: no update feed is configured.
    var isConfigured: Bool { false }

    func checkForUpdates() {}
}
