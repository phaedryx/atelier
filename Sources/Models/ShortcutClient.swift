// ABOUTME: HTTP client for the Shortcut REST API — the app's only networking code.
// ABOUTME: Transport only; DTOs and error mapping live in ShortcutAPI.swift.

import Foundation

/// Reads stories, workflows, and the token's own member record from Shortcut.
///
/// This is the only thing in Atelier that makes a network request: the update checker
/// was removed in 14e2b3b and telemetry/Sentry in #24. Everything else that needs
/// remote data shells out to a CLI (`gh`, `git`). Written against plain `URLSession`
/// rather than following a house convention, because there is no longer one.
struct ShortcutClient: Sendable {
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

    func story(id: Int) async throws -> ShortcutStory {
        try await get("stories/\(id)")
    }

    func workflows() async throws -> [ShortcutWorkflow] {
        try await get("workflows")
    }

    func currentMember() async throws -> ShortcutMember {
        try await get("member")
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let token = token(), !token.isEmpty else { throw ShortcutError.noToken }
        guard let url = URL(string: "\(Self.baseURL)/\(path)") else {
            throw ShortcutError.transport("Bad URL for \(path)")
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
            throw ShortcutError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, let error = ShortcutError.forStatus(http.statusCode) {
            throw error
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ShortcutError.decoding
        }
    }
}
