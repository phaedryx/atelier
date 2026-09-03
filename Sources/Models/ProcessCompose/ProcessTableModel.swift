// ABOUTME: Polls process-compose for process state and drives per-process control.
// ABOUTME: Selection of what `execute` starts is stored per workstream.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "process-table")

@MainActor
final class ProcessTableModel: ObservableObject {
    @Published private(set) var processes: [ProcessComposeProcess] = []
    /// Set when the manager is unreachable for a reason worth showing. Nil while
    /// simply not running, which is the normal state before Start.
    @Published private(set) var error: String?

    private let socketPath: String
    private let client: ProcessComposeControlling
    private var pollTask: Task<Void, Never>?

    /// The refresh currently running, or the last one that ran. Every refresh
    /// chains onto it, which is what keeps two `processes()` calls off the wire
    /// at the same time even when a control action refreshes mid-poll.
    private var refreshChain: Task<Void, Never>?

    /// Bumped whenever the table is cleared. A refresh captures it before it
    /// starts and re-checks it before every published write, so a reply that
    /// arrives after `stopPolling()` is dropped instead of resurrecting the
    /// previous run's rows.
    private var generation = 0

    /// Matches Port.Detector's cadence. The API also offers a push stream, which
    /// is the later optimisation once this is proven.
    private static let pollInterval = Duration.seconds(1)

    /// The client is injected so the polling, the error branches and the
    /// post-stop suppression can be driven by a stub. They are the subtlest
    /// behaviour here and the hardest to reach with a live binary.
    init(socketPath: String, client: ProcessComposeControlling? = nil) {
        self.socketPath = socketPath
        self.client = client ?? ProcessComposeClient(socketPath: socketPath)
    }

    deinit { pollTask?.cancel() }

    /// One request can block for as long as the client's send and receive
    /// timeouts allow, which is longer than the interval between polls — so the
    /// loop awaits each refresh before sleeping. A timer that fired regardless
    /// would stack overlapping requests on a manager that is already slow.
    func startPolling() {
        guard pollTask == nil else { return }
        clear()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        clear()
    }

    /// Empties the table and invalidates anything already on the wire.
    private func clear() {
        generation += 1
        refreshChain = nil
        if !processes.isEmpty {
            processes = []
        }
        if error != nil {
            error = nil
        }
    }

    /// Re-reads the process list, never concurrently with another refresh.
    ///
    /// Each call chains onto the one before it rather than skipping: a control
    /// action still gets a genuinely fresh read, and the reads stay ordered, so
    /// an older reply cannot land after a newer one and overwrite it.
    func refresh() async {
        let predecessor = refreshChain
        let token = generation
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            await self?.performRefresh(token: token)
        }
        refreshChain = task
        await task.value
    }

    private func performRefresh(token: Int) async {
        do {
            let latest = try await client.processes()
            guard token == generation else { return }
            // Every assignment here is guarded, because this runs once a second
            // for the life of the run session, beside a live terminal surface.
            // `@Published` fires `objectWillChange` from `willSet` with no
            // equality check of its own, so an unguarded `error = nil` would
            // invalidate the whole Environment tab at 1Hz even when nothing
            // changed — guarding only `processes` would achieve nothing.
            if processes != latest {
                processes = latest
            }
            if error != nil {
                error = nil
            }
        } catch ProcessComposeClient.ClientError.notRunning {
            // Expected before Start and after Stop; not worth surfacing.
            guard token == generation else { return }
            if !processes.isEmpty {
                processes = []
            }
            if error != nil {
                error = nil
            }
        } catch {
            guard token == generation else { return }
            // A manager that is gone is not a fault, whatever shape the failure
            // took. Stopping the last process ends the whole project, and the
            // teardown races the request: the connection can drop mid-response,
            // so `body(of:)` finds no header separator and throws
            // `.malformedResponse` rather than `.notRunning`. Keying the
            // suppression on the socket rather than on the error case covers
            // both, and every other way that race can surface.
            guard FileManager.default.fileExists(atPath: socketPath) else {
                if !processes.isEmpty {
                    processes = []
                }
                if self.error != nil {
                    self.error = nil
                }
                return
            }
            logger.debug("poll failed: \(error.localizedDescription, privacy: .public)")
            // Guarded for the same reason as the success path: a manager failing
            // the same way every second must not republish the same message.
            let description = error.localizedDescription
            if self.error != description {
                self.error = description
            }
        }
    }

    func start(_ name: String) async {
        await control { try await client.start(name) }
    }

    func stop(_ name: String) async {
        await control { try await client.stop(name) }
    }

    func restart(_ name: String) async {
        await control { try await client.restart(name) }
    }

    /// Runs one control call and re-reads the table.
    ///
    /// Stopping the last running process ends the whole project: process-compose
    /// exits and removes its socket, so the call that did it — or the response
    /// to it — can fail simply because the manager went away. That is the
    /// expected outcome of a stop, not something to flash at the user, so a
    /// failure is only reported when the socket is still there to have one.
    private func control(_ action: () async throws -> Void) async {
        // Captured for the same reason `performRefresh` captures it: this method
        // publishes after two awaits, and `stopPolling()` can land in either of
        // them. Without the token the refresh's writes would be dropped but this
        // method's own error write would not — leaving a sticky banner over an
        // empty table that nothing is left polling to clear.
        let token = generation
        var failure: String?
        do {
            try await action()
        } catch ProcessComposeClient.ClientError.notRunning {
            // Already gone; the refresh below reports the truth.
        } catch {
            failure = error.localizedDescription
        }
        guard token == generation else { return }
        await refresh()
        guard token == generation else { return }
        guard let failure, FileManager.default.fileExists(atPath: socketPath) else { return }
        if error != failure {
            error = failure
        }
    }

    // MARK: - Selection

    private nonisolated static let selectionKeyPrefix = "atelier.processSelection."

    nonisolated static func selectionKey(for workstreamID: UUID) -> String {
        selectionKeyPrefix + workstreamID.uuidString.lowercased()
    }

    /// Which processes `execute` should start. Empty means all of them —
    /// process-compose starts everything in the namespace when given no names.
    nonisolated static func selected(for workstreamID: UUID) -> [String] {
        UserDefaults.standard.stringArray(forKey: selectionKey(for: workstreamID)) ?? []
    }

    nonisolated static func setSelected(_ names: [String], for workstreamID: UUID) {
        if names.isEmpty {
            UserDefaults.standard.removeObject(forKey: selectionKey(for: workstreamID))
        } else {
            UserDefaults.standard.set(names, forKey: selectionKey(for: workstreamID))
        }
    }

    // MARK: - Ports

    /// The port a process owns, correlated by name.
    ///
    /// process-compose reports pids, and the port plan holds variable names, and
    /// nothing joins the two — a pid-to-port scan is a separate mechanism that
    /// this column deliberately does not reach for. So the join is the name:
    /// `bff` takes `BFF_PORT`, `html-to-json` takes `HTML_TO_JSON_PORT`.
    /// Separators and case are ignored on both sides, and the `PORT` suffix is
    /// optional on the variable. The suffix is added to the *process* name to
    /// look up rather than stripped from the variable, so a variable named only
    /// `PORT` cannot normalize to nothing and match every process.
    /// A name nothing matches gets no port; that is cosmetic, not wrong.
    nonisolated static func port(for process: String, in ports: [String: String]) -> String? {
        let wanted = normalized(process)
        guard !wanted.isEmpty else { return nil }
        let byName = normalizedPorts(ports)
        return byName[wanted] ?? byName[wanted + "port"]
    }

    /// Ports keyed by normalized variable name. Two variables can normalize to
    /// the same key, in which case the lowest variable name wins — arbitrary,
    /// but stable across renders, which is the property that matters.
    private nonisolated static func normalizedPorts(_ ports: [String: String]) -> [String: String] {
        var byName: [String: String] = [:]
        for name in ports.keys.sorted() {
            let key = normalized(name)
            guard !key.isEmpty, byName[key] == nil else { continue }
            byName[key] = ports[name]
        }
        return byName
    }

    private nonisolated static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0 != "-" && $0 != "_" }
    }
}
