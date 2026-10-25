import Foundation

/// User-configurable state, backed by UserDefaults.
/// Nothing in here is ever a secret: the backend URL is public configuration
/// and the install id is only a rate-limiting hint (PRD §7).
public final class Settings: @unchecked Sendable {
    public static let defaultBackendString = "https://api.cliplink.workers.dev"

    private let d: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.d = defaults
    }

    private enum Key {
        static let onboardingDone = "cliplink.onboardingDone"
        static let monitoringEnabled = "cliplink.monitoringEnabled"
        static let backendURL = "cliplink.backendURL"
        static let installID = "cliplink.installID"
        static let notifications = "cliplink.notificationsEnabled"
        static let maxUploadMB = "cliplink.maxUploadMB"
        static let blockedPatterns = "cliplink.blockedPatterns"
        static let driveConnectionID = "cliplink.driveConnectionID"
        static let driveEmail = "cliplink.driveEmail"
        static let licenseKey = "cliplink.licenseKey"
        static let proActive = "cliplink.proActive"
        static let linkExpiresHours = "cliplink.linkExpiresHours"
        static let protectionEnabled = "cliplink.protectionEnabled"
        static let linkPassword = "cliplink.linkPassword"
    }

    /// Monitoring only turns on after first-run onboarding (FR-08).
    public var onboardingDone: Bool {
        get { d.bool(forKey: Key.onboardingDone) }
        set { d.set(newValue, forKey: Key.onboardingDone) }
    }

    public var monitoringEnabled: Bool {
        get { d.bool(forKey: Key.monitoringEnabled) }
        set { d.set(newValue, forKey: Key.monitoringEnabled) }
    }

    public var notificationsEnabled: Bool {
        get { d.bool(forKey: Key.notifications) }
        set { d.set(newValue, forKey: Key.notifications) }
    }

    /// 0 means "follow the server's advertised limit".
    public var maxUploadMB: Int {
        get { d.object(forKey: Key.maxUploadMB) == nil ? 0 : d.integer(forKey: Key.maxUploadMB) }
        set { d.set(newValue, forKey: Key.maxUploadMB) }
    }

    public var backendURLString: String {
        get { d.string(forKey: Key.backendURL) ?? Self.defaultBackendString }
        set {
            d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.backendURL)
        }
    }

    public var backendURL: URL {
        let raw = backendURLString
        if let url = URL(string: raw),
           let host = url.host, !host.isEmpty,
           url.scheme == "http" || url.scheme == "https" {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.path = ""
            comps?.fragment = nil
            comps?.query = nil
            return comps?.url ?? url
        }
        backendURLString = Self.defaultBackendString
        return URL(string: Self.defaultBackendString)!
    }

    /// Random per-installation identifier. NOT authentication — sent as a
    /// rate-limit key only; the server treats anonymous traffic the same.
    public var installID: String {
        if let existing = d.string(forKey: Key.installID), existing.count >= 32 {
            return existing
        }
        let fresh = UUID().uuidString
        d.set(fresh, forKey: Key.installID)
        return fresh
    }

    public var blockedPatterns: [String] {
        get {
            guard let raw = d.string(forKey: Key.blockedPatterns) else {
                return EligibilityPolicy.defaultBlockedPatterns
            }
            return raw.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set { d.set(newValue.joined(separator: "\n"), forKey: Key.blockedPatterns) }
    }

    public var isUsingDefaultBlockedPatterns: Bool {
        d.string(forKey: Key.blockedPatterns) == nil
    }

    /// BYO storage (v0.4+): the connection id the backend handed to us after
    /// the Google consent flow. Not a secret — it only names which row holds
    /// the (server-side, sealed) refresh token for this install's uploads.
    /// An empty string means "no Drive connected yet".
    public var driveConnectionID: String {
        get { d.string(forKey: Key.driveConnectionID) ?? "" }
        set { d.set(newValue, forKey: Key.driveConnectionID) }
    }

    /// Display-only label of the connected Drive account (decrypted by the
    /// backend for the owner app alone).
    public var driveEmail: String {
        get { d.string(forKey: Key.driveEmail) ?? "" }
        set { d.set(newValue, forKey: Key.driveEmail) }
    }

    public var isDriveConnected: Bool { !driveConnectionID.isEmpty }

    // MARK: ClipLink Pro (one-time license) + per-link upgrades

    /// The presented Pro license key (not a cloud secret — a purchase token).
    public var licenseKey: String {
        get { d.string(forKey: Key.licenseKey) ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), forKey: Key.licenseKey) }
    }

    /// True after the backend verified the key at least once.
    public var proActive: Bool {
        get { d.bool(forKey: Key.proActive) }
        set { d.set(newValue, forKey: Key.proActive) }
    }

    /// Per-link expiry override in hours (0 = server default, 168 = 1 week,
    /// 720 = 30 days). Pro feature — enforced server-side.
    public var linkExpiresHours: Int {
        get { d.object(forKey: Key.linkExpiresHours) == nil ? 0 : d.integer(forKey: Key.linkExpiresHours) }
        set { d.set(newValue, forKey: Key.linkExpiresHours) }
    }

    /// Whether new uploads are password-protected, and with what. The
    /// password lives here for convenience (it is not a cloud secret); the
    /// server stores only a PBKDF2 hash.
    public var protectionEnabled: Bool {
        get { d.bool(forKey: Key.protectionEnabled) }
        set { d.set(newValue, forKey: Key.protectionEnabled) }
    }

    public var linkPassword: String {
        get { d.string(forKey: Key.linkPassword) ?? "" }
        set { d.set(newValue, forKey: Key.linkPassword) }
    }

    public var isProEligible: Bool { proActive && !licenseKey.isEmpty }
}
