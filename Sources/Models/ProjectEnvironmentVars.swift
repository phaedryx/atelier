// ABOUTME: Per-project environment variable definitions injected into run commands.
// ABOUTME: A definition is a literal (with ${NAME} templating) or a computed port.

import Foundation

/// One user-defined environment variable for a project.
///
/// Definitions live at the project level because the interesting ones — the port
/// a service binds, the URL another service proxies to — are the same *shape*
/// for every workstream. Only the values differ, and a computed definition
/// produces its own value per worktree.
struct EnvVarDefinition: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        /// Literal text, with `${NAME}` references to other definitions expanded.
        case literal
        /// A port derived from the worktree path and this variable's name, then
        /// nudged forward if something already holds it.
        case computedPort
    }

    var id: UUID
    var name: String
    var kind: Kind
    var value: String

    init(id: UUID = UUID(), name: String, kind: Kind = .literal, value: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.value = value
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    /// Whether this name can survive the trip into a shell.
    ///
    /// The value is interpolated into a command line, so a name with a space or
    /// a `=` in it does not become a broken variable — it becomes a different
    /// word in the command. An empty name is not *invalid*, just unfinished: a
    /// row the user has only just added should not turn red before it has been
    /// typed into.
    var hasValidName: Bool {
        let name = trimmedName
        guard !name.isEmpty else { return true }
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    var isUsable: Bool {
        !trimmedName.isEmpty && hasValidName
    }
}

extension Notification.Name {
    /// Posted when a project's definitions change, so workstreams already open
    /// on that project pick the edit up instead of showing stale rows until
    /// they are reopened. The object is the project directory.
    static let projectEnvVarsChanged = Notification.Name("atelier.projectEnvVarsChanged")
}

enum ProjectEnvironmentVars {
    private static let userDefaultsKey = "atelier.projectEnvVars"

    /// How many times template expansion sweeps the literals. A literal may
    /// reference a literal defined after it, so one pass is not enough; the cap
    /// stops a cycle (`A=${B}`, `B=${A}`) from spinning.
    private static let expansionPasses = 5

    // MARK: - Storage

    static func definitions(for projectDirectory: String) -> [EnvVarDefinition] {
        stored()[projectDirectory] ?? []
    }

    static func save(_ definitions: [EnvVarDefinition], for projectDirectory: String) {
        var current = stored()
        if definitions.isEmpty {
            current.removeValue(forKey: projectDirectory)
        } else {
            current[projectDirectory] = definitions
        }
        guard let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
        NotificationCenter.default.post(name: .projectEnvVarsChanged, object: projectDirectory)
    }

    private static func stored() -> [String: [EnvVarDefinition]] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: [EnvVarDefinition]].self, from: data)
        else { return [:] }
        return decoded
    }

    // MARK: - Resolution

    /// Turn definitions into the variables a workstream's run command receives.
    ///
    /// Ports resolve first so a literal can reference one, and each computed port
    /// is kept out of the pool the next one draws from — two variables in the
    /// same project must never land on the same number.
    ///
    /// A `${NAME}` that matches nothing is left verbatim rather than blanked, so
    /// a typo shows up in the command instead of silently becoming an empty
    /// string that a service then treats as a default.
    static func resolve(
        _ definitions: [EnvVarDefinition],
        workingDirectory: String,
        isFree: (Int) -> Bool = PortAllocator.isPortFree
    ) -> [String: String] {
        var resolved: [String: String] = [:]
        var claimed: Set<Int> = []

        for definition in definitions where definition.kind == .computedPort {
            guard definition.isUsable else { continue }
            let name = definition.trimmedName
            let port = PortAllocator.availablePort(
                for: workingDirectory,
                salt: name,
                claimed: claimed,
                isFree: isFree
            )
            claimed.insert(port)
            resolved[name] = "\(port)"
        }

        for definition in definitions where definition.kind == .literal {
            guard definition.isUsable else { continue }
            resolved[definition.trimmedName] = definition.value
        }

        for _ in 0 ..< expansionPasses {
            var changed = false
            for (name, value) in resolved {
                let expanded = expand(value, using: resolved)
                if expanded != value {
                    resolved[name] = expanded
                    changed = true
                }
            }
            if !changed { break }
        }

        return resolved
    }

    /// Replace every `${NAME}` in `text` with its value, leaving unknown names
    /// and self-references in place.
    static func expand(_ text: String, using values: [String: String]) -> String {
        guard text.contains("${") else { return text }
        var result = ""
        var remainder = Substring(text)

        while let open = remainder.range(of: "${") {
            result += remainder[remainder.startIndex ..< open.lowerBound]
            guard let close = remainder[open.upperBound...].firstIndex(of: "}") else {
                result += remainder[open.lowerBound...]
                return result
            }
            let name = String(remainder[open.upperBound ..< close])
            // A value containing its own reference would expand forever.
            if let value = values[name], !value.contains("${\(name)}") {
                result += value
            } else {
                result += "${\(name)}"
            }
            remainder = remainder[remainder.index(after: close)...]
        }

        return result + remainder
    }
}
