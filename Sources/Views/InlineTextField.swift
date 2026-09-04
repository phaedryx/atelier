// ABOUTME: A reusable inline text field for renaming items in place.
// ABOUTME: Wraps NSTextField with click-outside-to-commit and Enter/Escape handling.

import SwiftUI

struct InlineTextField: NSViewRepresentable {
    let initialText: String
    let accessibilityID: String
    var fontSize: CGFloat = 11
    var fontWeight: NSFont.Weight = .regular
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.cell?.isScrollable = true
        textField.cell?.lineBreakMode = .byTruncatingTail
        textField.stringValue = initialText
        textField.delegate = context.coordinator
        textField.setAccessibilityIdentifier(accessibilityID)
        textField.font = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)

        context.coordinator.textField = textField

        DispatchQueue.main.async {
            textField.selectText(nil)
        }
        // Deferred so the click that started editing doesn't immediately
        // commit through the outside-click monitor.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            context.coordinator.installClickMonitor()
        }

        return textField
    }

    func updateNSView(_: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        weak var textField: NSTextField?
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        private var clickMonitor: Any?
        private var didEnd = false

        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        /// Whether an outside-click monitor is currently installed. Internal so a
        /// test can check the deferred install did not land after editing ended.
        var hasClickMonitor: Bool {
            clickMonitor != nil
        }

        func installClickMonitor() {
            // The install is deferred 0.3s so the click that started editing does
            // not immediately commit through it. Committing with Enter or Esc
            // inside that window ran `finish`, whose `removeClickMonitor()` had
            // nothing to remove — and this then installed one anyway, leaking an
            // NSEvent monitor per rename for the life of the process.
            guard !didEnd else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self, !self.didEnd else { return event }
                if let textField,
                   let eventWindow = event.window,
                   eventWindow == textField.window
                {
                    let point = textField.convert(event.locationInWindow, from: nil)
                    if textField.bounds.contains(point) {
                        return event
                    }
                    if let editor = textField.currentEditor() {
                        let editorPoint = editor.convert(event.locationInWindow, from: nil)
                        if editor.bounds.contains(editorPoint) {
                            return event
                        }
                    }
                }
                finish(commit: true)
                return event
            }
        }

        private func finish(commit: Bool) {
            guard !didEnd else { return }
            didEnd = true
            removeClickMonitor()
            if commit {
                onCommit(textField?.stringValue ?? "")
            } else {
                onCancel()
            }
        }

        private func removeClickMonitor() {
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
                clickMonitor = nil
            }
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finish(commit: true)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(commit: false)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_: Notification) {
            finish(commit: true)
        }

        deinit {
            removeClickMonitor()
        }
    }
}
