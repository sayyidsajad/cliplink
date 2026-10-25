import Foundation

/// Result of verifying a ClipLink Pro license with the backend.
public struct ProLicenseStatus: Codable, Sendable, Equatable {
    public let active: Bool
    public let plan: String?
    public let reason: String?
    public let keyId: String?
}

public enum ProLicenseError: Error, LocalizedError, Sendable {
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

/// Talks to `POST /api/v1/license/verify`. Licenses are one-time purchases —
/// there is no subscription anywhere in this flow; verification simply
/// confirms the key came from the operator's mint.
public final class LicenseClient: @unchecked Sendable {
    public init() {}

    public func verify(backend: URL, installID: String, licenseKey: String) async throws -> ProLicenseStatus {
        var request = URLRequest(url: backend.appendingPathComponent("api/v1/license/verify"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(installID, forHTTPHeaderField: "X-ClipLink-Install")
        request.httpBody = try JSONEncoder().encode(["licenseKey": licenseKey])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProLicenseError.server(status, "license endpoint unavailable")
        }
        do {
            return try JSONDecoder().decode(ProLicenseStatus.self, from: data)
        } catch {
            throw ProLicenseError.invalidResponse("Could not parse the license response.")
        }
    }
}
