import Foundation

public enum FileEligibility: Equatable {
    case eligible
    case directory
    case missing
    case unreadable
    case zeroSize
    case tooLarge(limitBytes: Int64)
    case blocked(pattern: String)

    public var isEligible: Bool {
        if case .eligible = self { return true }
        return false
    }

    public var reason: String {
        switch self {
        case .eligible: return ""
        case .directory: return "folders are not supported yet"
        case .missing: return "file is missing or was moved"
        case .unreadable: return "file is not readable"
        case .zeroSize: return "file is empty"
        case .tooLarge(let limit): return "file exceeds the \(Format.bytes(limit)) size limit"
        case .blocked(let pattern): return "matches the blocked pattern '\(pattern)'"
        }
    }
}

public struct IneligibleFile: Sendable, Equatable {
    public let name: String
    public let reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

public struct EligibilityPolicy {
    public var maxBytes: Int64
    public var blockedPatterns: [String]

    public init(maxBytes: Int64, blockedPatterns: [String]) {
        self.maxBytes = maxBytes
        self.blockedPatterns = blockedPatterns
    }

    /// Heuristic blocklist for files that should never end up on a public URL.
    public static let defaultBlockedPatterns: [String] = [
        ".DS_Store", "Thumbs.db", "desktop.ini",
        ".env", ".env.*", "*.env",
        "credentials*", "*credentials*",
        "*.pem", "*.key", "*.p12", "*.pfx", "*.jks", "*.keystore", "*.mobileprovision",
        "id_rsa*", "id_dsa*", "id_ecdsa*", "id_ed25519", "ed25519",
        "known_hosts", "authorized_keys", "*.ppk",
        "*.kdbx", "*.kwallet", "wallet.dat", "*.wallet",
        ".npmrc", ".netrc", ".npm-auth*", "*netrc*",
        "*.token", "*.secret", "*secrets*", "*apikey*", "*api-key*",
        "service-account*.json", "*.htpasswd",
        ".git-credentials", "*htpasswd*",
    ]

    public func evaluate(_ file: CopiedFile, fileManager: FileManager = .default) -> FileEligibility {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            return .missing
        }
        if isDirectory.boolValue { return .directory }
        guard fileManager.isReadableFile(atPath: file.path) else { return .unreadable }
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path) else {
            return .unreadable
        }
        guard let number = attributes[.size] as? NSNumber else { return .unreadable }
        let bytes = number.int64Value
        if bytes == 0 { return .zeroSize }
        if bytes > maxBytes { return .tooLarge(limitBytes: maxBytes) }
        let name = file.name.lowercased()
        for pattern in blockedPatterns {
            if Self.globMatches(pattern.lowercased(), name) {
                return .blocked(pattern: pattern)
            }
        }
        return .eligible
    }

    /// Small dependency-free wildcard matcher supporting `*` and `?`
    /// (case-insensitive) — enough for filename patterns.
    public static func globMatches(_ pattern: String, _ text: String) -> Bool {
        if pattern.isEmpty { return text.isEmpty }
        let p = Array(pattern.lowercased())
        let t = Array(text.lowercased())
        var pi = 0
        var ti = 0
        var starPi = -1
        var starTi = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || (p[pi] != "*" && p[pi] == t[ti]) {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                starPi = pi
                starTi = ti
                pi += 1
            } else if starPi >= 0 {
                pi = starPi + 1
                starTi += 1
                ti = starTi
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
