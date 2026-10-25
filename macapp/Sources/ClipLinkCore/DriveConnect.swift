import Foundation

/// Client for ClipLink's BYO-storage connect flow (Google Drive, v1).
///
/// The app never sees the OAuth tokens: `start` asks the backend for a Google
/// consent URL + a secret state; the backend completes the OAuth exchange and
/// stores the refresh token sealed. The app simply opens the consent URL in
/// the user's browser, then polls until the backend confirms the connection.
public struct DriveConnectStart: Codable, Sendable, Equatable {
    public let provider: String?
    public let authorizeUrl: String
    public let state: String
    public let expiresInMs: Int?
}

/// One poll response from `GET /api/v1/providers/drive/poll?state=…`.
public struct DriveConnectPoll: Codable, Sendable, Equatable {
    public let connected: Bool
    public let expired: Bool?
    public let connectionId: String?
    public let email: String?

    /// Debatable states come back as `true`/`false` booleans in the backend
    /// JSON — plain `Bool` decoding covers both.
    enum CodingKeys: String, CodingKey {
        case connected, expired, connectionId, email
    }
}

public enum DriveConnectError: Error, LocalizedError, Sendable {
    case invalidResponse(String)
    case server(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail):
            return "Unexpected response from the backend. \(detail)"
        case .server(let status, let message):
            return "Server error (\(status)). \(message)"
        }
    }
}

public final class DriveConnectClient: @unchecked Sendable {
    public init() {}

    private func url(_ backend: URL, _ path: String, query: [URLQueryItem]? = nil) -> URL {
        var comps = URLComponents(url: backend.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let query { comps.queryItems = query }
        return comps.url!
    }

    /// Asks the backend to start a connect session. Returns the Google consent
    /// URL the app should open in the browser, plus the secret `state` used
    /// for subsequent polls. Install header required: the connection is bound
    /// to the uploading install id (rate-limit weighting only, never auth).
    public func start(backend: URL, installID: String) async throws -> DriveConnectStart {
        var request = URLRequest(url: url(backend, "api/v1/providers/drive/authorize"))
        request.setValue(installID, forHTTPHeaderField: "X-ClipLink-Install")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder()
                .decode(APIErrorBody.self, from: data))?.error.message ?? ""
            throw DriveConnectError.server(status, message.isEmpty ? "authorize endpoint unavailable" : message)
        }
        do {
            return try JSONDecoder().decode(DriveConnectStart.self, from: data)
        } catch {
            throw DriveConnectError.invalidResponse("Could not parse the connect-start response.")
        }
    }

    /// A single poll — returns the current connection state.
    public func pollOnce(backend: URL, installID: String, state: String) async throws -> DriveConnectPoll {
        var request = URLRequest(url: url(
            backend, "api/v1/providers/drive/poll",
            query: [URLQueryItem(name: "state", value: state)]
        ))
        request.setValue(installID, forHTTPHeaderField: "X-ClipLink-Install")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DriveConnectError.server(status, "poll endpoint unavailable")
        }
        do {
            return try JSONDecoder().decode(DriveConnectPoll.self, from: data)
        } catch {
            throw DriveConnectError.invalidResponse("Could not parse the connect-poll response.")
        }
    }

    /// Polls every ~2 seconds until connected, expired, or the deadline hits
    /// (backend connect sessions live 15 minutes). Returns the poll payload
    /// on success, nil if the window closed before the user finished.
    public func pollUntilConnected(
        backend: URL,
        installID: String,
        state: String,
        everySeconds: Double = 2,
        deadline: Date = Date().addingTimeInterval(15 * 60)
    ) async throws -> DriveConnectPoll? {
        var lastDelay = everySeconds
        while Date() < deadline {
            let poll = try await pollOnce(backend: backend, installID: installID, state: state)
            if poll.connected { return poll }
            if poll.expired == true { return nil }
            try? await Task.sleep(nanoseconds: UInt64(lastDelay * 1_000_000_000))
            lastDelay = min(lastDelay * 1.25, 5) // gentle backoff while tab stays open
        }
        return nil
    }
}
