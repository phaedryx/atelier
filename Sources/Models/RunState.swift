// ABOUTME: Shared run-state types for atelier-run and the app-side port monitor.
// ABOUTME: Encodes detected localhost ports, selection rules, and state-file persistence.

import Darwin
import Foundation

/// The state of a running dev server: what ports it opened, which one was
/// selected, and how that is persisted for `atelier-run`.
///
/// Declared here rather than in a file of its own because `AtelierRun`
/// compiles only AppConstants.swift, FilePersistence.swift, and this file
/// (`project.yml:179-181`).
enum RunState {}

extension RunState {
    enum Status: String, Codable {
        case starting
        case running
        case stopped
        case crashed
    }
}

extension RunState {
    struct Snapshot: Codable {
        let pid: Int32
        let status: Status
        let detectedPorts: [Int]
        let selectedPort: Int?
        let startedAt: Date
    }
}

extension RunState {
    struct PortSelection {
        let detectedPorts: [Int]
        let selectedPort: Int?
    }
}

extension RunState {
    struct PortSelectionTracker {
        let expectedPort: Int?
        private var lastCandidate: Int?
        private var candidateMatches = 0
        private(set) var selectedPort: Int?

        init(expectedPort: Int?) {
            self.expectedPort = expectedPort
        }

        mutating func update(listeningPorts: Set<Int>) -> PortSelection {
            let currentPorts = Set(listeningPorts.filter { $0 > 0 })

            if let selectedPort, !currentPorts.contains(selectedPort) {
                self.selectedPort = nil
            }

            let candidate = candidatePort(currentPorts: currentPorts)

            if selectedPort == nil,
               let candidate
            {
                if candidate == lastCandidate {
                    candidateMatches += 1
                } else {
                    lastCandidate = candidate
                    candidateMatches = 1
                }
                if candidateMatches >= 2 {
                    selectedPort = candidate
                }
            } else if selectedPort == nil {
                lastCandidate = nil
                candidateMatches = 0
            }

            return PortSelection(
                detectedPorts: orderedPorts(currentPorts, preferredPort: selectedPort ?? candidate),
                selectedPort: selectedPort
            )
        }

        private func candidatePort(currentPorts: Set<Int>) -> Int? {
            if currentPorts.count == 1, let onlyPort = currentPorts.first {
                return onlyPort
            }
            if currentPorts.count > 1,
               let expectedPort,
               currentPorts.contains(expectedPort)
            {
                return expectedPort
            }
            return nil
        }

        private func orderedPorts(_ currentPorts: Set<Int>, preferredPort: Int?) -> [Int] {
            let sortedPorts = currentPorts.sorted()
            guard let preferredPort,
                  currentPorts.contains(preferredPort),
                  currentPorts.count > 1
            else {
                return sortedPorts
            }

            return [preferredPort] + sortedPorts.filter { $0 != preferredPort }
        }
    }
}

extension RunState {
    enum Store {
        static var directoryURL: URL {
            AppConstants.cacheDirectory.appendingPathComponent("run-state", isDirectory: true)
        }

        static func fileURL(for workstreamID: UUID) -> URL {
            directoryURL.appendingPathComponent("\(workstreamID.uuidString.lowercased()).json")
        }

        static func load(for workstreamID: UUID) -> Snapshot? {
            load(from: fileURL(for: workstreamID))
        }

        static func loadValidated(for workstreamID: UUID) -> Snapshot? {
            guard let state = load(for: workstreamID),
                  isProcessRunning(pid: state.pid)
            else {
                return nil
            }
            return state
        }

        static func load(from url: URL) -> Snapshot? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Snapshot.self, from: data)
        }

        static func write(_ state: Snapshot, for workstreamID: UUID) throws {
            let data = try encoder.encode(state)
            try FilePersistence.writeAtomically(data, to: fileURL(for: workstreamID))
        }

        static func remove(for workstreamID: UUID) {
            try? FileManager.default.removeItem(at: fileURL(for: workstreamID))
        }

        static func isProcessRunning(pid: Int32) -> Bool {
            guard pid > 0 else { return false }
            if kill(pid, 0) == 0 {
                return true
            }
            return errno == EPERM
        }

        private static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return encoder
        }()

        private static let decoder: JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }()
    }
}
