import Foundation

/// A share recorded in the local history (menu > Recent links, incl. revoke).
public struct StoredLink: Codable, Sendable, Hashable {
    public let token: String
    public let url: String
    public let filename: String
    public let size: Int64
    public let createdAt: Int64
    public let expiresAt: Int64
    public let revokeToken: String

    public init(token: String, url: String, filename: String, size: Int64,
                createdAt: Int64, expiresAt: Int64, revokeToken: String) {
        self.token = token
        self.url = url
        self.filename = filename
        self.size = size
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.revokeToken = revokeToken
    }
}

/// Notifications surface upload results to the user (FR-08/FR-09).
public protocol ClipLinkNotifier: AnyObject {
    var isEnabled: Bool { get }
    func notifySuccess(title: String, message: String)
    func notifyFailure(title: String, message: String)
}

public final class SilentNotifier: ClipLinkNotifier {
    public var isEnabled: Bool { false }
    public init() {}
    public func notifySuccess(title: String, message: String) {}
    public func notifyFailure(title: String, message: String) {}
}

public enum ClipLinkEvent: Sendable {
    case started(filenames: [String])
    case progress(fraction: Double, filename: String)
    case succeeded(links: [StoredLink], clipboardReplaced: Bool)
    case failed(message: String, filenames: [String])
    case ineligible(records: [IneligibleFile])
    case superseded(links: [StoredLink])
    case info(text: String)
}
