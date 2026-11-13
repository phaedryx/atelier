// ABOUTME: Singleton that owns the ghostty_app_t lifecycle and runtime callbacks.
// ABOUTME: All terminal surfaces are created through this app instance.

import Cocoa
import os
import UserNotifications

private let logger = Logger(subsystem: "atelier", category: "terminal-app")

private func handleTerminalWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let userdataBits = UInt(bitPattern: userdata)
    DispatchQueue.main.async {
        let userdata = UnsafeMutableRawPointer(bitPattern: userdataBits)!
        let app = Unmanaged<TerminalApp>.fromOpaque(userdata).takeUnretainedValue()
        app.tick()
    }
}

private func handleTerminalAction(
    _: UnsafeMutableRawPointer?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_RELOAD_CONFIG:
        let soft = action.action.reload_config.soft
        if soft {
            if target.tag == GHOSTTY_TARGET_APP {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let app = TerminalApp.shared.app,
                              let config = TerminalApp.shared.config else { return }
                        ghostty_app_update_config(app, config)
                    }
                }
            } else if target.tag == GHOSTTY_TARGET_SURFACE {
                // Carry the pointer as bits and re-check liveness on the main
                // actor: a settings respawn or a purge can free this surface
                // between the callback and the hop, and
                // `ghostty_surface_update_config` on freed memory is a crash.
                // The registry is the liveness record, and `destroy()` clears
                // the entry and the view's own `surface` together.
                let surfaceBits = UInt(bitPattern: target.target.surface)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let key = UnsafeMutableRawPointer(bitPattern: surfaceBits),
                              let surface = TerminalView.view(for: key)?.surface,
                              let config = TerminalApp.shared.config else { return }
                        ghostty_surface_update_config(surface, config)
                    }
                }
            }
        }
        return true
    default:
        break
    }

    guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
        guard let cstr = action.action.set_title.title else { return false }
        // The one read that must stay on this thread: libghostty does not
        // promise the title pointer outlives the callback. Everything else —
        // the registry lookup and the view's `workstreamID` — is main-actor
        // state and moves inside the hop.
        let title = String(cString: cstr)
        let surfaceBits = UInt(bitPattern: target.target.surface)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let key = UnsafeMutableRawPointer(bitPattern: surfaceBits),
                      let wsID = TerminalView.view(for: key)?.workstreamID else { return }
                NotificationCenter.default.post(
                    name: .terminalTitleChanged,
                    object: wsID,
                    userInfo: ["title": title]
                )
            }
        }
        // Unconditionally true, where this used to return false for an
        // unregistered surface: the action *was* accepted, and with delivery
        // deferred there is no longer anything to report back. libghostty
        // reads the return as "did the runtime handle this tag", not "did a
        // notification get posted".
        return true
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
        let notification = action.action.desktop_notification
        let title = notification.title.map { String(cString: $0) } ?? AppConstants.appName
        let body = notification.body.map { String(cString: $0) } ?? ""
        sendDesktopNotification(title: title, body: body, suppressWhenActive: false)
        return true
    case GHOSTTY_ACTION_RING_BELL:
        // `NSLocalizedString`, not a bare literal: `body` is a `String` handed
        // to `UNMutableNotificationContent`, which is AppKit-side and has no
        // `LocalizedStringKey` to resolve it — the rule AGENTS.md's
        // Localization section states for every non-SwiftUI API.
        sendDesktopNotification(
            title: AppConstants.appName,
            body: NSLocalizedString("Terminal bell", comment: "Desktop notification body when a terminal rings the bell"),
            suppressWhenActive: true
        )
        return true
    default:
        return false
    }
}

private func readTerminalClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?,
    _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    _ mimesLen: Int,
    _ list: Bool
) -> ghostty_clipboard_read_result_e {
    guard let userdata, let state else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    // Refusing a location is the read callback's job (the write path checks
    // for itself). macOS has no primary selection, and answering a Kitty
    // read of it with the general pasteboard would hand over the clipboard
    // for a request that should get ENOSYS.
    guard location != GHOSTTY_CLIPBOARD_PRIMARY else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

    // libghostty 1.4 asks for specific representations. Atelier serves one,
    // `text/plain`, so a request that wants only something else (a Kitty
    // clipboard read of an image, say) is unavailable rather than answered
    // with text it did not ask for. `list` is a mode 5522 paste event, which
    // wants the available types and no data.
    var wantsText = false
    if let mimes {
        for index in 0 ..< mimesLen {
            guard let mime = mimes[index] else { continue }
            if strcmp(mime, "text/plain") == 0 {
                wantsText = true
                break
            }
        }
    }
    guard wantsText || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

    let userdataBits = UInt(bitPattern: userdata)
    let stateBits = UInt(bitPattern: state)
    if Thread.isMainThread {
        return completeClipboardRead(
            userdataBits: userdataBits, stateBits: stateBits, serveText: wantsText, list: list
        )
    }
    return DispatchQueue.main.sync {
        completeClipboardRead(
            userdataBits: userdataBits, stateBits: stateBits, serveText: wantsText, list: list
        )
    }
}

/// Approves whatever libghostty asks to confirm.
///
/// Atelier has never prompted: it completes every read as already confirmed,
/// so for reads this is never called. It exists because 1.4 added the Kitty
/// clipboard protocol, whose *write* path asks for confirmation under
/// `clipboard-write = ask` (a setting read from the user's own ghostty config)
/// with no read Atelier could pre-confirm — and the Zig side holds the
/// callback as a non-optional function pointer, so `nil` is a crash on that
/// path. Approving extends the no-prompt policy to Kitty writes, which is what
/// the OSC 52 write path already does by ignoring its `confirm` flag. The
/// contents are borrowed only for the duration of this call, which is why the
/// completion happens inside it rather than after a hop.
private func confirmTerminalClipboardRead(
    _ userdata: UnsafeMutableRawPointer?,
    _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    _ state: UnsafeMutableRawPointer?,
    _: ghostty_clipboard_request_e
) {
    guard let userdata, let state else { return }
    let userdataBits = UInt(bitPattern: userdata)
    let stateBits = UInt(bitPattern: state)
    let confirmBits = confirm.map { UInt(bitPattern: $0) }
    let approve = {
        let userdata = UnsafeMutableRawPointer(bitPattern: userdataBits)!
        let state = UnsafeMutableRawPointer(bitPattern: stateBits)!
        let surfaceView = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = surfaceView.surface else { return }
        guard let confirmBits,
              let confirm = UnsafePointer<ghostty_clipboard_confirm_s>(bitPattern: confirmBits)
        else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }
        var complete = ghostty_clipboard_complete_s(
            contents: confirm.pointee.contents,
            contents_len: confirm.pointee.contents_len,
            available: confirm.pointee.available,
            available_len: confirm.pointee.available_len,
            confirmed: true,
            remember: false
        )
        ghostty_surface_complete_clipboard_request(surface, &complete, state)
    }
    if Thread.isMainThread {
        approve()
    } else {
        DispatchQueue.main.sync(execute: approve)
    }
}

private func writeTerminalClipboard(
    _: UnsafeMutableRawPointer?,
    _: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _: Bool
) {
    guard let content, len > 0 else { return }
    let entries = (0 ..< len).compactMap { index -> String? in
        let item = content[index]
        guard let mime = item.mime, let data = item.data,
              strcmp(mime, "text/plain") == 0 else { return nil }
        // `data` carries an explicit length since 1.4 and is not promised a
        // terminating NUL, so it is read as bytes, never as a C string.
        return String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
    }
    guard let plainText = entries.first else { return }

    if Thread.isMainThread {
        writeClipboardText(plainText)
    } else {
        DispatchQueue.main.sync {
            writeClipboardText(plainText)
        }
    }
}

private func closeTerminalSurface(
    _ userdata: UnsafeMutableRawPointer?,
    _: Bool
) {
    guard let userdata else { return }
    let userdataBits = UInt(bitPattern: userdata)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            // `takeUnretainedValue` on the raw `userdata` was a use-after-free:
            // the view can be destroyed between this callback and the hop. The
            // registry holds its views strongly, so matching the address
            // against its values proves the object is alive without ever
            // dereferencing the stale pointer.
            //
            // Skipping a view that is no longer registered is the wanted
            // outcome, not a safe fallback: posting `.terminalSurfaceClosed`
            // for an already-replaced view would drive a second respawn.
            guard let userdata = UnsafeMutableRawPointer(bitPattern: userdataBits),
                  let surfaceView = TerminalView.liveObject(
                      at: userdata,
                      among: TerminalView.surfaceRegistry.values
                  ) else { return }
            surfaceView.surfaceClosed()
        }
    }
}

private func completeClipboardRead(
    userdataBits: UInt,
    stateBits: UInt,
    serveText: Bool,
    list: Bool
) -> ghostty_clipboard_read_result_e {
    let pasteboard = NSPasteboard.general
    // A listing only asks whether text exists; reading it is for `serveText`.
    let hasText = pasteboard.availableType(from: [.string]) != nil
    let text = serveText ? pasteboard.string(forType: .string) : nil
    // A read with nothing to serve cannot start. A listing can: an empty
    // pasteboard is a valid answer to "what types are available".
    guard text != nil || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

    let userdata = UnsafeMutableRawPointer(bitPattern: userdataBits)!
    let state = UnsafeMutableRawPointer(bitPattern: stateBits)!
    let surfaceView = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
    guard let surface = surfaceView.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

    let available: [String] = list && hasText ? ["text/plain"] : []
    withTextPlainMime { mimeStr in
        withOptionalBytes(text) { servedBytes in
            var contents: [ghostty_clipboard_content_s] = []
            if let servedBytes {
                contents.append(ghostty_clipboard_content_s(
                    mime: mimeStr, data: servedBytes.baseAddress, len: servedBytes.count
                ))
            }
            let availablePointers: [UnsafePointer<CChar>?] = available.map { _ in UnsafePointer(mimeStr) }
            contents.withUnsafeBufferPointer { contentsBuffer in
                availablePointers.withUnsafeBufferPointer { availableBuffer in
                    // `confirmed` is Atelier's standing policy, not a shortcut:
                    // pastes are never held for a prompt. See
                    // `confirmTerminalClipboardRead`.
                    var complete = ghostty_clipboard_complete_s(
                        contents: contentsBuffer.baseAddress,
                        contents_len: contentsBuffer.count,
                        available: availableBuffer.baseAddress,
                        available_len: availableBuffer.count,
                        confirmed: true,
                        remember: false
                    )
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }
    }
    return GHOSTTY_CLIPBOARD_READ_STARTED
}

private func withTextPlainMime<R>(_ body: (UnsafePointer<CChar>) -> R) -> R {
    "text/plain".withCString(body)
}

/// Runs `body` with `text`'s UTF-8 bytes, or with `nil` when there is no text.
///
/// Bytes, not a C string: the 1.4 content struct carries a length, so text
/// with an embedded NUL goes across whole instead of stopping at it.
private func withOptionalBytes<R>(
    _ text: String?,
    _ body: (UnsafeBufferPointer<CChar>?) -> R
) -> R {
    guard let text else { return body(nil) }
    // A trailing byte the count excludes, so the buffer is never empty: an
    // empty Array may hand out a nil base address, and the Zig side declares
    // `data` as a non-optional pointer even when `len` is zero.
    var bytes = Array(text.utf8)
    let count = bytes.count
    bytes.append(0)
    return bytes.withUnsafeBufferPointer { buffer in
        buffer.withMemoryRebound(to: CChar.self) { chars in
            body(UnsafeBufferPointer(rebasing: chars[0 ..< count]))
        }
    }
}

private func writeClipboardText(_ plainText: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(plainText, forType: .string)
}

private func sendDesktopNotification(title: String, body: String, suppressWhenActive: Bool) {
    DispatchQueue.main.async {
        if suppressWhenActive, NSApp.isActive {
            return
        }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound(named: UNNotificationSoundName("notification.wav"))
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        addDesktopNotification(request, using: center)
    }
}

private func addDesktopNotification(
    _ request: UNNotificationRequest,
    using center: NotificationRequestAdding
) {
    center.add(request) { error in
        guard let error else { return }
        if Thread.isMainThread {
            logger.warning("Failed to deliver notification: \(error.localizedDescription)")
            return
        }

        Task { @MainActor in
            logger.warning("Failed to deliver notification: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class TerminalApp {
    static let shared = TerminalApp()

    private(set) nonisolated(unsafe) var app: ghostty_app_t?
    private(set) nonisolated(unsafe) var config: ghostty_config_t?
    private var appearanceObserver: NSKeyValueObservation?

    private init() {
        // Create config
        guard let config = ghostty_config_new() else {
            logger.error("ghostty_config_new failed")
            return
        }
        ghostty_config_load_default_files(config)

        // Enable left Option as Alt so Option+Backspace deletes words in terminal
        let appConfigStr = "macos-option-as-alt = left\n"
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("atelier-ghostty.conf")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data(appConfigStr.utf8))
        ghostty_config_load_file(config, tmpFile.path)
        try? FileManager.default.removeItem(at: tmpFile)

        ghostty_config_finalize(config)

        // Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: handleTerminalWakeup,
            action_cb: handleTerminalAction,
            read_clipboard_cb: readTerminalClipboard,
            confirm_read_clipboard_cb: confirmTerminalClipboardRead,
            write_clipboard_cb: writeTerminalClipboard,
            close_surface_cb: closeTerminalSurface
        )

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            logger.error("ghostty_app_new failed")
            ghostty_config_free(config)
            return
        }
        self.app = app
        self.config = config

        // Defer focus setup until NSApp exists
        DispatchQueue.main.async { [weak self] in
            guard let self, let app = self.app else { return }
            if let nsApp = NSApp {
                ghostty_app_set_focus(app, nsApp.isActive)
            }
        }

        // Sync terminal color scheme with system appearance so conditional
        // themes (e.g. "light:X,dark:Y") switch automatically.
        appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new, .initial]
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let app = self?.app else { return }
                    let scheme: ghostty_color_scheme_e = NSApplication.shared.effectiveAppearance.isDark
                        ? GHOSTTY_COLOR_SCHEME_DARK
                        : GHOSTTY_COLOR_SCHEME_LIGHT
                    ghostty_app_set_color_scheme(app, scheme)
                    for (ptr, _) in TerminalView.surfaceRegistry {
                        ghostty_surface_set_color_scheme(ptr, scheme)
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        }
    }

    fileprivate func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    deinit {
        if let app {
            ghostty_app_free(app)
        }
        if let config {
            ghostty_config_free(config)
        }
    }
}
