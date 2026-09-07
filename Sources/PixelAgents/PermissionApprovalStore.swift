// ABOUTME: Holds the permission requests agents are blocked on, one queue per workstream.
// ABOUTME: Every request that enters here leaves through resolve — by answer, by deadline, or by teardown.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "permission-approval")

/// The permission requests currently blocking agents, keyed by workstream.
///
/// The invariant this type exists to keep: **an agent that is waiting here is
/// stopped**, so every request must be resolved. There are three ways out —
/// the user answers, the hold expires, or the workstream goes away — and all
/// three run the same `finish`, which calls the resolver exactly once and takes
/// the request off the queue. A request that is dropped without being resolved
/// leaves a real agent hanging until Claude Code's own hook timeout fires.
///
/// A queue rather than a single slot: two agents in one workstream (the Coding
/// Agent and a terminal tab) can be asking at the same time, and the second one
/// must not silently displace the first.
@MainActor
final class PermissionApprovalStore: ObservableObject {
    static let shared = PermissionApprovalStore()

    /// Requests waiting on the user, oldest first, per workstream.
    @Published private(set) var pending: [UUID: [PendingPermission]] = [:]

    /// Answers a request. Called with nil for "no decision", which lets Claude
    /// Code fall back to asking in the terminal.
    private var resolvers: [UUID: (PendingPermission.Decision?) -> Void] = [:]
    private var deadlines: [UUID: Timer] = [:]
    /// Which workstream each request belongs to, so `finish` can find its queue
    /// from the request id alone.
    private var owners: [UUID: UUID] = [:]

    /// Called when a request is answered explicitly, so the workstream's row can
    /// stop reporting that it is waiting on the user. Not called on expiry: the
    /// user is still being asked, just in the terminal instead.
    var onAnswered: ((UUID) -> Void)?

    init() {}

    // MARK: - Reading

    /// The request to put in front of the user for this workstream, if any.
    func frontmost(for workstreamID: UUID) -> PendingPermission? {
        pending[workstreamID]?.first
    }

    func count(for workstreamID: UUID) -> Int {
        pending[workstreamID]?.count ?? 0
    }

    // MARK: - Enqueueing

    /// Takes ownership of a request and its resolver.
    ///
    /// The resolver is stored *before* anything that could fail or return early,
    /// and the deadline is armed in the same turn, so there is no window in
    /// which a request is queued with nothing scheduled to answer it.
    func enqueue(
        _ request: PendingPermission,
        in workstreamID: UUID,
        resolve: @escaping (PendingPermission.Decision?) -> Void
    ) {
        resolvers[request.id] = resolve
        owners[request.id] = workstreamID
        pending[workstreamID, default: []].append(request)

        let remaining = max(request.expiresAt.timeIntervalSinceNow, 0)
        let timer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                logger.info("Permission request \(request.id, privacy: .public) expired; Claude Code will ask instead")
                self.finish(request.id, with: nil, answered: false)
            }
        }
        deadlines[request.id] = timer

        logger.info(
            "Holding \(request.toolName, privacy: .public) for \(Int(remaining))s in workstream \(workstreamID, privacy: .public)"
        )
    }

    // MARK: - Resolving

    func answer(_ requestID: UUID, with decision: PendingPermission.Decision) {
        finish(requestID, with: decision, answered: true)
    }

    /// Releases every request in a workstream — the workstream is being archived
    /// or removed, and the app is no longer in a position to answer. Each agent
    /// falls back to Claude Code's own prompt rather than waiting out a deadline
    /// nothing will service.
    func releaseAll(workstreamID: UUID) {
        for request in pending[workstreamID] ?? [] {
            finish(request.id, with: nil, answered: false)
        }
    }

    /// Releases everything, e.g. at termination. An agent blocked on a app that
    /// is going away must be handed back to Claude Code, not left to time out.
    func releaseEverything() {
        for requestID in resolvers.keys {
            finish(requestID, with: nil, answered: false)
        }
    }

    /// The single exit. Idempotent: a deadline that fires while the click is
    /// already in flight finds the resolver gone and does nothing.
    private func finish(_ requestID: UUID, with decision: PendingPermission.Decision?, answered: Bool) {
        deadlines.removeValue(forKey: requestID)?.invalidate()
        guard let resolve = resolvers.removeValue(forKey: requestID) else { return }
        let workstreamID = owners.removeValue(forKey: requestID)

        if let workstreamID {
            pending[workstreamID]?.removeAll { $0.id == requestID }
            if pending[workstreamID]?.isEmpty == true {
                pending.removeValue(forKey: workstreamID)
            }
        }

        resolve(decision)

        if answered, let workstreamID {
            onAnswered?(workstreamID)
        }
    }

    /// Test seam: drops everything without resolving. Only safe where no real
    /// agent is attached to the resolvers.
    func resetForTesting() {
        for timer in deadlines.values {
            timer.invalidate()
        }
        deadlines.removeAll()
        resolvers.removeAll()
        owners.removeAll()
        pending.removeAll()
        onAnswered = nil
    }
}
