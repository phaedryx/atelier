// ABOUTME: The ⌘⇧P command palette: fuzzy search over registered commands, keyboard-driven.
// ABOUTME: Presented as a ContentView overlay; selection state lives here, commands in CommandRegistry.

import SwiftUI

/// Keeps the highlighted row inside the result list as results change.
func clampedPaletteSelection(_ index: Int, resultCount: Int) -> Int {
    guard resultCount > 0 else { return 0 }
    return min(max(index, 0), resultCount - 1)
}

struct CommandPaletteView: View {
    let registry: CommandRegistry
    let context: PaletteContext
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
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
                .onKeyPress(.downArrow) {
                    selectedIndex = clampedPaletteSelection(selectedIndex + 1, resultCount: results.count)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selectedIndex = clampedPaletteSelection(selectedIndex - 1, resultCount: results.count)
                    return .handled
                }

            Divider()

            if results.isEmpty {
                Text("No matching commands")
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                                row(command, isSelected: index == selectedIndex)
                                    .id(command.id)
                                    .onTapGesture {
                                        selectedIndex = index
                                        runSelected()
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selectedIndex) {
                        guard results.indices.contains(selectedIndex) else { return }
                        proxy.scrollTo(results[selectedIndex].id)
                    }
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(radius: 24, y: 8)
        .onAppear { fieldFocused = true }
        .onExitCommand(perform: onDismiss)
        .onChange(of: query) {
            selectedIndex = 0
        }
    }

    private func row(_ command: PaletteCommand, isSelected: Bool) -> some View {
        HStack {
            Text(command.title)
            Spacer()
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
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
    }

    private func runSelected() {
        let current = results
        let index = clampedPaletteSelection(selectedIndex, resultCount: current.count)
        guard current.indices.contains(index) else {
            onDismiss()
            return
        }
        let command = current[index]
        registry.recordUsage(command.id)
        onDismiss()
        command.action()
    }
}
