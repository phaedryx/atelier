// ABOUTME: Editor for a project's environment variable definitions.
// ABOUTME: Rows are a literal value or a port Atelier picks per workstream.

import SwiftUI

/// Edits the variables injected into a project's run command.
///
/// Definitions belong to the project, values belong to the workstream: the
/// resolved column shows what *this* worktree will receive, which is the only
/// way to tell a computed port apart from the definition that produced it.
///
/// The section's title and its Add button live in the parent, so this is only
/// the rows.
struct EnvVarsEditor: View {
    @Binding var definitions: [EnvVarDefinition]
    /// The values these definitions produce in the current worktree.
    let resolved: [String: String]

    private static let columnSpacing: CGFloat = 6
    private static let nameWidth: CGFloat = 150
    private static let kindWidth: CGFloat = 80
    /// Where the value column starts, so the expansion hint lines up under it
    /// instead of under a number someone guessed.
    private static let valueColumnInset = nameWidth + columnSpacing + kindWidth + columnSpacing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if definitions.isEmpty {
                Text("Variables defined here are exported to the run command for every workstream in this project. A port variable gets its own value per worktree.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach($definitions) { $definition in
                    row(for: $definition)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func row(for definition: Binding<EnvVarDefinition>) -> some View {
        HStack(spacing: Self.columnSpacing) {
            TextField("NAME", text: definition.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: Self.nameWidth)
                // A name with a space or an `=` would not become a broken
                // variable, it would become a different word in the command —
                // so say so here rather than letting it reach a shell.
                .foregroundStyle(definition.wrappedValue.hasValidName ? Color.primary : Color.red)
                .help(definition.wrappedValue.hasValidName
                    ? ""
                    : NSLocalizedString("Names may use letters, digits and _, and cannot start with a digit.", comment: ""))

            Picker("", selection: definition.kind) {
                Text("Value").tag(EnvVarDefinition.Kind.literal)
                Text("Port").tag(EnvVarDefinition.Kind.computedPort)
            }
            .labelsHidden()
            .frame(width: Self.kindWidth)

            switch definition.wrappedValue.kind {
            case .literal:
                TextField("value or ${OTHER_VAR}", text: definition.value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            case .computedPort:
                Text(resolvedValue(for: definition.wrappedValue) ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                definitions.removeAll { $0.id == definition.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Remove", comment: ""))
        }

        // A literal that references another variable reads very differently
        // before and after expansion, so show the expansion rather than making
        // the user hold the substitution in their head.
        if definition.wrappedValue.kind == .literal,
           definition.wrappedValue.value.contains("${"),
           let expanded = resolvedValue(for: definition.wrappedValue),
           expanded != definition.wrappedValue.value
        {
            Text(expanded)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.leading, Self.valueColumnInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func resolvedValue(for definition: EnvVarDefinition) -> String? {
        let name = definition.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return resolved[name]
    }
}
