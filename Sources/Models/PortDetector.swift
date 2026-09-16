// ABOUTME: Watches atelier-run state files and publishes the selected port for a workstream.
// ABOUTME: Uses filesystem events instead of polling so browser targets update immediately.

import Foundation

/// Localhost port infrastructure shared across the app: allocating one,
/// detecting what is listening, and reporting liveness.
///
/// The process-compose port *config* types (ProcessCompose.PortPlan, ProcessCompose.PortEntry,
/// ProcessCompose.PortsConfig) are deliberately not here — they are that subsystem's
/// schema and live under `ProcessCompose`.
enum Port {}

extension Port {
    /// Lifecycle of the atelier-run session for a workstream.
    enum Status: Equatable {
        /// No atelier-run session is alive (server not running).
        case none
        /// A session is running but no port has been selected yet.
        case starting
        /// A listening port has been selected; the server is reachable.
        case running
    }
}

extension Port {
    /// Whether the browser pane should keep showing "Starting dev server…"
    /// rather than navigating (or falling through to a connection-error retry).
    ///
    /// A declared `browser: true` port is known from `ports.yaml`, ahead of any
    /// detection. `RunState.PortSelectionTracker` can only ever resolve
    /// `selectedPort` when exactly one process is listening, or the port the
    /// launcher expected (`ATELIER_PORT`) is among them — never true for a stack
    /// that declares several named ports, so `status` stays `.starting` forever
    /// and a caller waiting on it would too. A known browser port instead checks
    /// its own liveness — whether it is among the ports atelier-run has actually
    /// observed listening — rather than the tracker's guess at which one to show.
    static func isWaitingForServer(
        browserPort: Int?,
        status: Status,
        detectedPorts: [Int],
        browserStartPending: Bool
    ) -> Bool {
        guard let browserPort else {
            return status == .starting || (status == .none && browserStartPending)
        }
        if status == .none {
            return browserStartPending
        }
        return !detectedPorts.contains(browserPort)
    }
}

extension Port {
    final class Detector: ObservableObject, @unchecked Sendable {
        @Published private(set) var selectedPort: Int?
        @Published private(set) var status: Port.Status = .none
        /// Every port atelier-run currently observes listening, not just the one
        /// `status`/`selectedPort` resolved to. A declared `browser: true` port is
        /// known ahead of detection, so a caller with one in hand can check its own
        /// liveness here instead of waiting on the single-port selection heuristic
        /// below, which never resolves for a stack with several named ports.
        @Published private(set) var detectedPorts: [Int] = []

        private let workstreamID: UUID
        private let queue: DispatchQueue
        private var directorySource: DispatchSourceFileSystemObject?
        private var fileSource: DispatchSourceFileSystemObject?

        init(workstreamID: UUID) {
            self.workstreamID = workstreamID
            queue = DispatchQueue(label: "atelier.port-detector.\(workstreamID.uuidString.lowercased())")
            start()
        }

        deinit {
            stop()
        }

        private func start() {
            try? FileManager.default.createDirectory(at: RunState.Store.directoryURL, withIntermediateDirectories: true)
            attachDirectoryWatcher()
            refreshState()
        }

        private func stop() {
            fileSource?.cancel()
            fileSource = nil
            directorySource?.cancel()
            directorySource = nil
        }

        private func attachDirectoryWatcher() {
            let directoryPath = RunState.Store.directoryURL.path
            let descriptor = open(directoryPath, O_EVTONLY)
            guard descriptor >= 0 else { return }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.attrib, .delete, .extend, .rename, .write],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.attachFileWatcherIfNeeded()
                self?.refreshState()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            directorySource = source
            source.resume()

            attachFileWatcherIfNeeded()
        }

        private func attachFileWatcherIfNeeded() {
            let statePath = RunState.Store.fileURL(for: workstreamID).path
            guard FileManager.default.fileExists(atPath: statePath) else {
                fileSource?.cancel()
                fileSource = nil
                return
            }
            guard fileSource == nil else { return }

            let descriptor = open(statePath, O_EVTONLY)
            guard descriptor >= 0 else { return }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.attrib, .delete, .extend, .rename, .write],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                // Every `RunState.Store.write` is a `writeAtomically`, i.e.
                // `replaceItemAt` → rename, so the path we opened is a dead inode the
                // moment the first write lands. Without dropping the source here it
                // stays attached to that inode forever and never fires again;
                // `refreshState` alone won't re-attach, because it only does so when
                // the state file is *missing*. Detection kept working only because the
                // directory watcher happened to cover it.
                let data = fileSource?.data ?? []
                if data.contains(.rename) || data.contains(.delete) {
                    fileSource?.cancel()
                    fileSource = nil
                    attachFileWatcherIfNeeded()
                }
                refreshState()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            fileSource = source
            source.resume()
        }

        /// The inode the file watcher currently holds open, for tests. A watcher left
        /// on a replaced inode still looks attached — only the inode shows the drift.
        func _testWatchedInode() -> UInt64? {
            queue.sync {
                guard let descriptor = fileSource?.handle else { return nil }
                var info = stat()
                guard fstat(descriptor, &info) == 0 else { return nil }
                return UInt64(info.st_ino)
            }
        }

        private func refreshState() {
            let state = RunState.Store.loadValidated(for: workstreamID)
            if state == nil {
                attachFileWatcherIfNeeded()
            }

            let nextPort = state?.selectedPort
            let nextStatus: Port.Status = state == nil ? .none : (state?.selectedPort != nil ? .running : .starting)
            let nextDetectedPorts = state?.detectedPorts ?? []
            DispatchQueue.main.async { [weak self] in
                self?.selectedPort = nextPort
                self?.status = nextStatus
                self?.detectedPorts = nextDetectedPorts
            }
        }
    }
}
