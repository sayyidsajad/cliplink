import Foundation

/// Limits advertised by the backend (`GET /api/v1/limits`).
public struct ShareLimits: Codable, Sendable, Equatable {
    public let maxFileBytes: Int64
    public let maxFileMB: Int
    public let expiryHours: Double
    public let rateLimitUploads: Int?
    public let rateWindowMinutes: Int?
    /// v0.4+ BYO storage: "drive" | "mock" | "supabase" (older backends omit).
    public let storageProvider: String?
    public let driveConfigured: Bool?
}

/// Successful upload response (`POST /api/v1/shares`).
public struct ShareCreation: Codable, Sendable, Equatable {
    public let url: String
    public let token: String
    public let filename: String?
    public let size: Int64?
    public let expiresAt: Int64
    public let revokeToken: String
}

public enum ClipLinkAPIError: Error, LocalizedError, Sendable {
    case badBackendURL(String)
    case network(String, retriable: Bool)
    case tooLarge(limitBytes: Int64)
    case rateLimited(retrySeconds: Int)
    case httpsRequired
    case driveNotConnected
    case invalidResponse(String)
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .badBackendURL(let url):
            return "Backend URL '\(url)' is invalid."
        case .network(let message, _):
            return "Network problem: \(message)"
        case .tooLarge(let limit):
            return limit > 0
                ? "The file exceeds the server's \(Format.bytes(limit)) size limit."
                : "The file exceeds the server's size limit."
        case .rateLimited:
            return "Upload rate limit reached on the server. Try again later."
        case .httpsRequired:
            return "The server requires HTTPS uploads in production."
        case .driveNotConnected:
            return "No Google Drive is connected yet. Open the ClipLink menu-bar icon → Connect Google Drive…"
        case .invalidResponse(let detail):
            return "Unexpected response from the backend. \(detail)"
        case .server(let status, let message):
            return "Server error (\(status)). \(message)"
        }
    }

    var isRetriable: Bool {
        switch self {
        case .network(_, let retriable): return retriable
        case .server(let status, _): return (500...599).contains(status)
        default: return false
        }
    }
}

struct APIErrorBody: Codable {
    struct Detail: Codable { let code: String?; let message: String }
    let error: Detail
}

extension CharacterSet {
    /// RFC 3986 `unreserved` characters — safe inside a header value.
    static let urlAllowedForHeader = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

/// Uploads files to the ClipLink backend via the raw-body endpoint.
/// Streams straight from disk with `uploadTask(fromFile:)` (the file is never
/// loaded into memory), reports upload progress, and retries transient
/// failures with exponential backoff (FR-03).
public final class UploadClient: NSObject, @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (Double) -> Void

    private struct PendingUpload {
        let continuation: CheckedContinuation<(Data, URLResponse?), Error>
        let progressHandler: ProgressHandler?
        var response: URLResponse?
        var buffer = Data()
    }

    private let lock = NSLock()
    private var pending: [Int: PendingUpload] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    public override init() {
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: public API

    public func fetchLimits(backend: URL) async throws -> ShareLimits {
        guard backend.scheme == "http" || backend.scheme == "https" else {
            throw ClipLinkAPIError.badBackendURL(backend.absoluteString)
        }
        let (data, response) = try await session.data(from: backend.appendingPathComponent("api/v1/limits"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClipLinkAPIError.server(status: status, message: "limits endpoint unavailable")
        }
        do {
            return try JSONDecoder().decode(ShareLimits.self, from: data)
        } catch {
            throw ClipLinkAPIError.invalidResponse("Could not parse limits JSON.")
        }
    }

    public func upload(
        fileURL: URL,
        backend: URL,
        filename: String,
        installID: String,
        maxAttempts: Int = 3,
        onProgress: ProgressHandler? = nil
    ) async throws -> ShareCreation {
        var request = URLRequest(url: backend.appendingPathComponent("api/v1/shares"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(
            filename.addingPercentEncoding(withAllowedCharacters: .urlAllowedForHeader) ?? "file",
            forHTTPHeaderField: "X-ClipLink-Filename"
        )
        request.setValue(installID, forHTTPHeaderField: "X-ClipLink-Install")

        var lastError: ClipLinkAPIError?
        var delay: TimeInterval = 1.5
        for attempt in 1...max(1, maxAttempts) {
            do {
                return try await performUpload(request: request, fileURL: fileURL, onProgress: onProgress)
            } catch let error as ClipLinkAPIError {
                lastError = error
                guard attempt < maxAttempts, error.isRetriable else { throw error }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay *= 2.5
            }
        }
        throw lastError ?? ClipLinkAPIError.invalidResponse("Upload failed for an unknown reason.")
    }

    // MARK: internals

    private func performUpload(
        request: URLRequest,
        fileURL: URL,
        onProgress: ProgressHandler?
    ) async throws -> ShareCreation {
        let (data, response) = try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: fileURL)
            lock.lock()
            pending[task.taskIdentifier] = PendingUpload(
                continuation: continuation,
                progressHandler: onProgress
            )
            lock.unlock()
            task.resume()
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw mapFailure(status: status, data: data)
        }
        do {
            return try JSONDecoder().decode(ShareCreation.self, from: data)
        } catch {
            throw ClipLinkAPIError.invalidResponse("Could not parse the upload response.")
        }
    }

    private func mapFailure(status: Int, data: Data) -> ClipLinkAPIError {
        let body = try? JSONDecoder().decode(APIErrorBody.self, from: data)
        let message = body?.error.message ?? ""
        switch status {
        case 413: return .tooLarge(limitBytes: 0)
        case 429: return .rateLimited(retrySeconds: 60)
        case 403 where body?.error.code == "drive_not_connected" || message.contains("Connect Google Drive"):
            return .driveNotConnected
        case 403 where message.contains("HTTPS"): return .httpsRequired
        default: return .server(status: status, message: message)
        }
    }
}

// MARK: - URLSession delegate plumbing

extension UploadClient: URLSessionDataDelegate {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        lock.lock()
        let handler = pending[task.taskIdentifier]?.progressHandler
        lock.unlock()
        guard let handler, totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        handler(fraction)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @Sendable @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        if var entry = pending[dataTask.taskIdentifier] {
            entry.response = response
            pending[dataTask.taskIdentifier] = entry
        }
        lock.unlock()
        completionHandler(.allow)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        var entry = pending[dataTask.taskIdentifier]
        entry?.buffer.append(data)
        if let entry { pending[dataTask.taskIdentifier] = entry }
        lock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let entry else { return } // not an upload we track (e.g. data(from:))
        if let error = error {
            entry.continuation.resume(throwing: networkingError(from: error))
        } else {
            entry.continuation.resume(returning: (entry.buffer, entry.response))
        }
    }

    private func networkingError(from error: Error) -> Error {
        let urlError = error as? URLError
        let message = urlError?.localizedDescription ?? error.localizedDescription
        let retriable = urlError.map { Self.retriableCodes.contains($0.code) } ?? false
        return ClipLinkAPIError.network(message, retriable: retriable)
    }

    static let retriableCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet,
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]
}
