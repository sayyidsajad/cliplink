import Foundation

public enum Format {
    public static func bytes(_ value: Int64) -> String {
        let v = Double(value)
        switch v {
        case ..<1024: return "\(value) B"
        case ..<(1024 * 1024): return String(format: "%.1f KB", v / 1024)
        case ..<(1024 * 1024 * 1024): return String(format: "%.1f MB", v / (1024 * 1024))
        default: return String(format: "%.2f GB", v / (1024 * 1024 * 1024))
        }
    }

    public static func relativeExpiry(expiresAtMillis: Int64, from reference: Date = Date()) -> String {
        let target = Date(timeIntervalSince1970: Double(expiresAtMillis) / 1000)
        let delta = target.timeIntervalSince(reference)
        switch delta {
        case ..<0: return "expired"
        case ..<90: return "expires in ~\(Int(delta.rounded())) seconds"
        case ..<5400: return "expires in ~\(Int((delta / 60).rounded())) minutes"
        case ..<172_800: return "expires in ~\(Int((delta / 3600).rounded())) hours"
        default: return "expires in ~\(Int((delta / 86400).rounded())) days"
        }
    }

    public static func shortDate(_ epochMillis: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(epochMillis) / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

public enum ClipLinkCore {
    public static let appName = "ClipLink"
    public static let version = "0.1.0"
}
