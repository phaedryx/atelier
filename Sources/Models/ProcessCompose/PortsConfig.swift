// ABOUTME: Parses ports.yaml, which declares the port variables Atelier supplies.
// ABOUTME: Names come from the file; numbers come from PortPlan.

import Foundation
import Yams

/// One declared port variable.
struct PortEntry: Equatable {
    enum Kind: Equatable {
        /// Atelier picks the number, per worktree.
        case assigned
        /// This exact number, always — for values registered outside the machine,
        /// such as an OAuth redirect URI that cannot vary per worktree.
        case fixed(Int)
    }

    let name: String
    let kind: Kind
    /// The port the embedded browser opens. At most one per file.
    let isBrowser: Bool
}

struct PortsConfig: Equatable {
    /// Sorted by name, so allocation order does not depend on YAML dictionary
    /// ordering — an assigned port must not move because a key was reordered.
    let entries: [PortEntry]

    static let fileNames = ["ports.yaml", "ports.yml"]

    enum LoadError: Error, LocalizedError, Equatable {
        case malformed(String)
        case invalidEntry(name: String, reason: String)
        case multipleBrowserPorts([String])

        var errorDescription: String? {
            switch self {
            case let .malformed(detail):
                return String(format: NSLocalizedString("ports.yaml could not be read: %@", comment: ""), detail)
            case let .invalidEntry(name, reason):
                return String(format: NSLocalizedString("ports.yaml: %@ %@", comment: ""), name, reason)
            case let .multipleBrowserPorts(names):
                return String(
                    format: NSLocalizedString("ports.yaml: only one port may set browser: true (%@)", comment: ""),
                    names.sorted().joined(separator: ", ")
                )
            }
        }
    }

    /// The wire shape. Every field is optional so validation can produce a
    /// specific message rather than a decoding failure.
    private struct File: Decodable {
        struct Entry: Decodable {
            let assigned: Bool?
            let fixed: Int?
            let browser: Bool?
        }

        let ports: [String: Entry]
    }

    /// Load `ports.yaml` from a directory. Returns nil when there is no such
    /// file — that is the normal state for a project that does not use ports.
    static func load(from directory: String) throws -> PortsConfig? {
        let url = URL(fileURLWithPath: directory)
        guard let path = fileNames
            .map({ url.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else { return nil }

        let text: String
        do {
            text = try String(contentsOf: path, encoding: .utf8)
        } catch {
            throw LoadError.malformed(error.localizedDescription)
        }

        let file: File
        do {
            file = try YAMLDecoder().decode(File.self, from: text)
        } catch {
            throw LoadError.malformed(error.localizedDescription)
        }

        var entries: [PortEntry] = []
        for name in file.ports.keys.sorted() {
            // Force-unwrap is safe: the key came from this dictionary.
            let entry = file.ports[name]!
            let kind: PortEntry.Kind
            switch (entry.assigned, entry.fixed) {
            case (true, nil):
                kind = .assigned
            case let (nil, .some(port)):
                kind = .fixed(port)
            case (.some, .some):
                throw LoadError.invalidEntry(
                    name: name,
                    reason: NSLocalizedString("sets both assigned and fixed", comment: "")
                )
            case (false, _):
                throw LoadError.invalidEntry(
                    name: name,
                    reason: NSLocalizedString("sets assigned: false, which means nothing; remove the entry instead", comment: "")
                )
            case (nil, nil):
                throw LoadError.invalidEntry(
                    name: name,
                    reason: NSLocalizedString("needs assigned: true or fixed: <port>", comment: "")
                )
            }
            entries.append(PortEntry(name: name, kind: kind, isBrowser: entry.browser == true))
        }

        let browsers = entries.filter(\.isBrowser).map(\.name)
        if browsers.count > 1 {
            throw LoadError.multipleBrowserPorts(browsers)
        }

        return PortsConfig(entries: entries)
    }
}
