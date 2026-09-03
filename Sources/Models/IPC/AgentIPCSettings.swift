// ABOUTME: The on/off switches for agent IPC, and the one place that starts or stops the listener.
// ABOUTME: Both default off: cross-agent messaging is opt-in, and terminal injection is a second opt-in.

import Foundation

extension IPC {
    /// Reads the agent-IPC settings and keeps `IPC.Server` in step with them.
    ///
    /// `ScriptTrust` deliberately isn't involved. Its API fingerprints the
    /// process-compose files a repository ships, and the `AGENTS.md` invariant it
    /// backs is about *repository-provided commands*. Turning on IPC is neither, so
    /// it gets its own switch and its own warning copy rather than a fabricated
    /// config to approve.
    enum AgentSettings {
        static let enabledKey = "atelier.agentIPC"
        static let nudgeKey = "atelier.agentIPCNudge"

        /// Whether agents may see and message each other at all. Off unless the
        /// user turns it on.
        static var isEnabled: Bool {
            UserDefaults.standard.bool(forKey: enabledKey)
        }

        /// Whether Atelier may type an arrival notice into an idle agent's
        /// terminal. Messaging on its own is inert; this is the capability with
        /// teeth, so it is separately switchable and useless without the first.
        static var nudgeEnabled: Bool {
            isEnabled && UserDefaults.standard.bool(forKey: nudgeKey)
        }

        /// Brings the listener in line with the setting. Stopping removes
        /// `ipc.json`, so a helper launched afterwards reports that IPC is off
        /// rather than dialling a stale port.
        static func apply(server: Server = .shared) {
            if isEnabled {
                server.start()
            } else {
                server.stop()
            }
        }
    }
}
