import AppKit

/// A single file referenced by a Finder copy operation.
public struct CopiedFile: Equatable, Hashable, Sendable {
    public let url: URL
    public var path: String { url.path }
    public var name: String { url.lastPathComponent }

    public init(url: URL) {
        self.url = url
    }
}

/// A detected "copy files" clipboard state.
public struct ClipboardFileCopy: Sendable, Equatable {
    public let changeCount: Int
    public let files: [CopiedFile]

    public init(changeCount: Int, files: [CopiedFile]) {
        self.changeCount = changeCount
        self.files = files
    }
}

public enum ClipboardFiles {
    /// Legacy Finder multi-file copy type (still what Finder writes, even for one file).
    static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    /// Reads the pasteboard and returns a file copy if — and only if — the
    /// content is structured file references that still resolve to readable
    /// files on disk. Plain text (even text that looks like a path) is never
    /// treated as a file (FR-02).
    public static func readCurrentCopy(from pasteboard: NSPasteboard = .general) -> ClipboardFileCopy? {
        guard let types = pasteboard.types else { return nil }
        var paths: [String] = []

        if types.contains(legacyFilenamesType) {
            if let array = pasteboard.propertyList(forType: legacyFilenamesType) as? [String] {
                paths = array
            }
        }
        if paths.isEmpty, types.contains(.fileURL) {
            if let string = pasteboard.string(forType: .fileURL),
               let url = URL(string: string), url.isFileURL {
                paths = [url.path]
            }
        }
        guard !paths.isEmpty else { return nil }

        let fm = FileManager.default
        var files: [CopiedFile] = []
        var seen = Set<String>()
        for path in paths.prefix(10) {
            let url = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
            guard fm.fileExists(atPath: url.path),
                  fm.isReadableFile(atPath: url.path),
                  seen.insert(url.path).inserted else { continue }
            files.append(CopiedFile(url: url))
        }
        guard !files.isEmpty else { return nil }
        return ClipboardFileCopy(changeCount: pasteboard.changeCount, files: files)
    }

    /// Debug/CLI helper describing the current pasteboard.
    public static func describe(from pasteboard: NSPasteboard = .general)
        -> (changeCount: Int, types: [String], files: [CopiedFile]) {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let copy = readCurrentCopy(from: pasteboard)
        return (pasteboard.changeCount, types, copy?.files ?? [])
    }
}
