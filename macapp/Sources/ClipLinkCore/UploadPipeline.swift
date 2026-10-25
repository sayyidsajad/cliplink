import Foundation

/// Turns a detected clipboard copy into uploaded public links.
/// All state mutations happen on the main thread (timers, UI callbacks);
/// awaits inside the upload loop keep everything responsive (FR-03).
public final class UploadPipeline {
    public static let defaultMaxBytes: Int64 = 100 * 1024 * 1024

    private let settings: Settings
    public let client: UploadClient
    public private(set) var limits: ShareLimits?
    public private(set) var lastLimitsError: String?
    private var limitsFetchedAt: Date?

    /// Called from inside the upload loop (already on the main actor).
    public var progressSink: ((_ fraction: Double, _ filename: String) -> Void)?

    public init(settings: Settings, client: UploadClient = UploadClient()) {
        self.settings = settings
        self.client = client
    }

    /// Local cap: min(user preference, server limit). Advisory — the server
    /// always re-checks (413).
    public func effectiveMaxBytes() -> Int64 {
        let serverLimit = limits?.maxFileBytes ?? Self.defaultMaxBytes
        let userMB = settings.maxUploadMB
        if userMB > 0 {
            return min(Int64(userMB) * 1024 * 1024, serverLimit)
        }
        return serverLimit
    }

    public func refreshLimits(force: Bool = false) async {
        if !force, limits != nil, let fetchedAt = limitsFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 600 {
            return
        }
        do {
            limits = try await client.fetchLimits(backend: settings.backendURL)
            lastLimitsError = nil
            limitsFetchedAt = Date()
        } catch {
            lastLimitsError = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            limitsFetchedAt = nil // retry next time
        }
    }

    /// Drops cached limits so the next upload refreshes them (e.g. after the
    /// user changes the backend URL or preferences).
    public func resetLimits() {
        limits = nil
        lastLimitsError = nil
        limitsFetchedAt = nil
    }

    /// Publishes externally fetched limits (UI "Check connection" action).
    public func storeLimits(_ new: ShareLimits) {
        limits = new
        lastLimitsError = nil
        limitsFetchedAt = Date()
    }

    /// Records a limits-fetch failure for display in the menu.
    public func noteLimitsError(_ message: String) {
        lastLimitsError = message
    }

    /// Uploads files sequentially. Returns successful links plus a failure
    /// message when any upload failed (then the clipboard must not be touched).
    public func uploadCopiedFiles(_ files: [CopiedFile]) async
        -> (links: [StoredLink], failureMessage: String?, ineligible: [IneligibleFile]) {
        await refreshLimits()

        let policy = EligibilityPolicy(
            maxBytes: effectiveMaxBytes(),
            blockedPatterns: settings.blockedPatterns
        )

        var ineligibleRecords: [IneligibleFile] = []
        var eligible: [CopiedFile] = []
        for file in files {
            let verdict = policy.evaluate(file)
            if verdict.isEligible {
                eligible.append(file)
            } else {
                ineligibleRecords.append(IneligibleFile(name: file.name, reason: verdict.reason))
            }
        }

        guard !eligible.isEmpty else {
            return ([], nil, ineligibleRecords)
        }

        var links: [StoredLink] = []
        var errors: [String] = []
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        for file in eligible {
            do {
                links.append(try await uploadOne(file, now: now))
            } catch {
                let apiError = error as? ClipLinkAPIError
                let message = apiError?.errorDescription ?? String(describing: error)
                if case .rateLimited = apiError {
                    if errors.isEmpty { errors.append("\(file.name): \(message)") }
                    break
                }
                errors.append("\(file.name): \(message)")
            }
        }

        return (links, errors.isEmpty ? nil : errors.joined(separator: "; "), ineligibleRecords)
    }

    private func uploadOne(_ file: CopiedFile, now: Int64) async throws -> StoredLink {
        let creation: ShareCreation
        do {
            creation = try await client.upload(
                fileURL: file.url,
                backend: settings.backendURL,
                filename: file.name,
                installID: settings.installID,
                licenseKey: settings.isProEligible ? settings.licenseKey : nil,
                expiryHours: settings.isProEligible ? settings.linkExpiresHours : nil,
                linkPassword: settings.isProEligible && settings.protectionEnabled
                    ? settings.linkPassword : nil
            ) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.progressSink?(fraction, file.name)
                }
            }
        } catch let error as ClipLinkAPIError {
            if case .proLicenseInvalid = error {
                // Auto-downgrade: the key stopped verifying (limit/revocation).
                settings.proActive = false
            }
            throw error
        }
        return StoredLink(
            token: creation.token,
            url: creation.url,
            filename: creation.filename ?? file.name,
            size: creation.size ?? 0,
            createdAt: now,
            expiresAt: creation.expiresAt,
            revokeToken: creation.revokeToken,
            protected: creation.protected ?? false
        )
    }
}
