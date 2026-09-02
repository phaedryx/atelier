// ABOUTME: Removes the OpenCode plugin earlier builds installed into
// ABOUTME: ~/.config/opencode/plugins, now that Atelier is Claude Code only.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "opencode-plugin-remover")

/// Counterpart to the installer that shipped while Atelier supported OpenCode.
///
/// That installer wrote a plugin into the user's *global* OpenCode plugin
/// directory, so it keeps loading on every `opencode` run whether or not
/// Atelier is involved — uninstalling Atelier would not reach it. The plugin
/// also splices `.atelier-state/instructions.md` into each turn's system
/// prompt, and nothing writes that file any more, so it must not be left
/// behind to inject a snapshot no code can update.
enum OpencodePluginRemover {
    /// First-line marker the installer stamped onto every plugin it wrote.
    /// A file without it is someone else's plugin and is never touched.
    static let marker = "ATELIER_OPENCODE_PLUGIN"

    static var installedPluginPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugins/atelier.js").path
    }

    /// Whether the file's contents identify it as a plugin Atelier installed.
    static func isAtelierPlugin(contents: String) -> Bool {
        contents.contains(marker)
    }

    /// Deletes the installed plugin, if it is one Atelier wrote.
    ///
    /// Idempotent and safe to call on every launch: the common case is a
    /// missing file, which costs one failed read. Deliberately not gated on a
    /// UserDefaults flag — a flag would skip anyone who had already launched a
    /// build before the removal shipped.
    static func uninstall(at path: String = installedPluginPath) {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        guard isAtelierPlugin(contents: contents) else {
            logger.info("Leaving unrecognized opencode plugin in place at \(path, privacy: .public)")
            return
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            logger.info("Removed the retired Atelier opencode plugin")
        } catch {
            logger.error("Failed to remove opencode plugin: \(error.localizedDescription)")
        }
    }
}
