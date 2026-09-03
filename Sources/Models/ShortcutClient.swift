// ABOUTME: HTTP client for the Shortcut REST API — the app's only networking code.
// ABOUTME: Transport only; DTOs and error mapping live in ShortcutAPI.swift.

import Foundation
import OSLog

private let logger = Logger(subsystem: "atelier", category: "shortcut")

/// Reads stories, workflows, and the token's own member record from Shortcut.
///
/// This is the only thing in Atelier that makes a network request: the update checker
/// was removed in 14e2b3b and telemetry/Sentry in #24. Everything else that needs
/// remote data shells out to a CLI (`gh`, `git`). Written against plain `URLSession`
/// rather than following a house convention, because there is no longer one.
extension Shortcut {
    struct Client {
        static let baseURL = "https://api.app.shortcut.com/api/v3"

        private let session: URLSession
        private let token: @Sendable () -> String?

        init(
            session: URLSession = .shared,
            token: @escaping @Sendable () -> String? = { KeychainTokenStore().read() }
        ) {
            self.session = session
            self.token = token
        }

        func story(id: Int) async throws -> Story {
            try await get("stories/\(id)")
        }

        func workflows() async throws -> [Workflow] {
            try await get("workflows")
        }

        func currentMember() async throws -> Member {
            try await get("member")
        }

        private func get<T: Decodable>(_ path: String) async throws -> T {
            guard let token = token(), !token.isEmpty else { throw Error.noToken }
            guard let url = URL(string: "\(Self.baseURL)/\(path)") else {
                throw Error.transport("Bad URL for \(path)")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue(token, forHTTPHeaderField: "Shortcut-Token")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw Error.transport(error.localizedDescription)
            }

            // An explicit failure rather than skipping the status check: a non-HTTP response
            // would otherwise go straight to decode, so a bad stub in tests reads as success.
            guard let http = response as? HTTPURLResponse else {
                throw Error.transport("Not an HTTP response")
            }
            if let error = Error.forStatus(http.statusCode) {
                throw error
            }

            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                // The DecodingError names the exact missing key or type mismatch. Losing it
                // makes "schema changed", "unusual story", and "a captive portal returned
                // HTML with a 200" all read as one opaque message.
                logger.warning("[Atelier] shortcut: decoding \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                throw Error.decoding
            }
        }
    }
}
