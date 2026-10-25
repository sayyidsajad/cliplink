import AppKit

/// Replaces clipboard contents with the generated URL(s) and returns the new
/// pasteboard changeCount so the monitor can ignore its own write (FR-05).
public enum ClipboardWriter {
    @discardableResult
    public static func writeLinks(_ urls: [String]) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.joined(separator: "\n"), forType: .string)
        return pasteboard.changeCount
    }

    @discardableResult
    public static func write(_ string: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        return pasteboard.changeCount
    }

    /// Replaces clipboard contents with raw image bytes (PNG) — used for the
    /// per-link QR code. Returns the new pasteboard changeCount.
    @discardableResult
    public static func writeImage(_ pngData: Data) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        return pasteboard.changeCount
    }
}
