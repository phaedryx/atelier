// ABOUTME: The ⌘⇧P command palette: fuzzy search over registered commands, keyboard-driven.
// ABOUTME: Presented as a ContentView overlay; selection state lives here, commands in CommandRegistry.

import AppKit
import SwiftUI

struct CommandPaletteView: View {
    let registry: CommandRegistry
    let context: PaletteContext
    let onDismiss: () -> Void

    /// One row's height. Fixed because `List` has no ideal height of its own,
    /// so it is what the panel's height is counted in; both row layouts are
    /// single-line.
    private static let rowHeight: CGFloat = 31

    @State private var query = ""
    /// The highlighted row's `PaletteCommand.id`. An id rather than an index
    /// because `results` is recomputed on every keystroke.
    @State private var selectedID: String?
    @State private var paletteWindow: NSWindow?
    /// Whoever held the keyboard before the palette opened, restored on dismiss.
    @State private var previousResponder: NSResponder?
    /// Set by `onDisappear`, read by the deferred `WindowReader` callback.
    @State private var didDisappear = false
    @FocusState private var fieldFocused: Bool

    private var results: [PaletteCommand] {
        registry.search(query, context: context)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Type a command…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(12)
                .focused($fieldFocused)
                .onSubmit(runSelected)
                // Focus stays here, so the arrows are read here: the list
                // below is deliberately not a focus candidate.
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    return .handled
                }

            Divider()

            if results.isEmpty {
                Text("No matching commands")
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                FilterResultList(
                    items: results,
                    id: \.id,
                    selection: $selectedID,
                    rowHeight: Self.rowHeight,
                    maxHeight: 320,
                    onActivate: run
                ) { command, _ in
                    row(command)
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(radius: 24, y: 8)
        // The agent tab's Ghostty surface is a plain NSView holding the window's
        // first responder, and SwiftUI's focus system will not pull focus out of
        // a responder it does not own: setting `fieldFocused` from `onAppear`
        // is silently reset to false and every keystroke keeps going to the
        // terminal. Clearing the responder first, one runloop turn later (once
        // the field is installed), is what makes the field take focus. The
        // window comes from `WindowReader` rather than `NSApp.keyWindow`
        // because every open window toggles its own palette on the shared
        // notification, and only this one's responder should be disturbed.
        .background(WindowReader { window in
            // `WindowReader` reports one runloop turn late. A palette dismissed
            // inside that turn — fast Esc, a rapid toggle — has already run
            // `onDisappear` and restored the responder, so taking it now would
            // leave the terminal underneath keyboard-dead with nothing left to
            // hand it back.
            guard !didDisappear, paletteWindow == nil, let window else { return }
            paletteWindow = window
            previousResponder = window.firstResponder
            window.makeFirstResponder(nil)
            fieldFocused = true
        })
        .onDisappear {
            didDisappear = true
            // Hand the keyboard back to whatever had it, or the terminal the
            // palette was opened over stays keyboard-dead until it is clicked.
            // A command that focuses something of its own (New Terminal, say)
            // claims the responder after this runs, so it still wins.
            guard let previousResponder else { return }
            paletteWindow?.makeFirstResponder(previousResponder)
        }
        .onExitCommand(perform: onDismiss)
        .onChange(of: query) {
            selectedID = results.first?.id
        }
        .onAppear {
            selectedID = results.first?.id
        }
    }

    /// One row. A refused command keeps its row and shows why in place of its
    /// category and shortcut — the alternative, dropping it, is what made stored
    /// prompts look like a feature that came and went.
    private func row(_ command: PaletteCommand) -> some View {
        let reason = command.availability(context).reason
        return HStack {
            Text(command.title)
                .foregroundStyle(reason == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            Spacer()
            if let reason {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(command.category)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(.horizontal, 12)
        // The selection fill is `List`'s own now, not a painted background.
        // The row is a real `Button` and stays enabled even when the command is
        // refused, so the reason has to reach VoiceOver as a hint.
        .accessibilityHint(Text(reason ?? ""))
    }

    /// Runs the highlighted command, unless it is a disabled row.
    ///
    /// A disabled row does nothing *and does not dismiss*: the palette stays up
    /// with the reason still on screen, which is the whole point of listing it.
    /// `search` already sorts every disabled row below every runnable one, so
    /// Return lands on one only when the user has deliberately arrowed to it.
    private func runSelected() {
        // The highlighted id may name a row that no longer exists — `results`
        // is recomputed from the live registry — and Return with nothing to run
        // dismisses, as it did when the selection was an out-of-range index.
        guard let selectedID, let command = results.first(where: { $0.id == selectedID }) else {
            onDismiss()
            return
        }
        run(command)
    }

    /// Runs one command, or refuses it. The row itself is never `.disabled()`:
    /// that would risk taking its selectability with it, and arrowing onto a
    /// refused row to read its reason is the whole point of listing it.
    private func run(_ command: PaletteCommand) {
        guard command.isAvailable(context) else { return }
        registry.recordUsage(command.id)
        onDismiss()
        command.action()
    }

    private func moveSelection(_ delta: Int) {
        selectedID = neighbouringSelection(from: selectedID, in: results.map(\.id), delta: delta)
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view. The palette needs its own
/// window rather than `NSApp.keyWindow`, since every open window toggles its
/// palette on the same notification.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view has no window until it is installed, and the callback
        // mutates `@State`, so both reads are deferred past the update pass.
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}
