import Foundation
import AppKit
import ClipLinkCore

/// Headless CLI for driving and testing the ClipLink pipeline without GUI:
///
///   ClipLinkCLI types                            show current pasteboard types
///   ClipLinkCLI limits  --backend URL            show advertised server limits
///   ClipLinkCLI upload FILE --backend URL        upload one file, print JSON
///   ClipLinkCLI watch --backend URL [--once]     run the clipboard monitor headless
///
@main
struct ClipLinkCLI {
    static var stdoutHandle: FileHandle { .standardOutput }
    static var stderrHandle: FileHandle { .standardError }

    private static func note(_ text: String) {
        let data = Data((text + "\n").utf8)
        stderrHandle.write(data)
    }

    private static func say(_ text: String) {
        let data = Data((text + "\n").utf8)
        stdoutHandle.write(data)
    }

    static func flag(_ name: String, in args: [String]) -> String? {
        if let index = args.firstIndex(of: "--\(name)"), args.indices.contains(index + 1) {
            return args[index + 1]
        }
        return nil
    }

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let settings = Settings(defaults: UserDefaults(suiteName: "ClipLinkCLI")!)
        settings.monitoringEnabled = true
        if let backend = flag("backend", in: args) {
            settings.backendURLString = backend
        }

        let command = args.first ?? "--help"
        let exitCode: Int32
        switch command {
        case "types":
            let info = ClipboardFiles.describe()
            note("changeCount: \(info.changeCount)")
            note("types: \(info.types.joined(separator: ", "))")
            note("detectedFiles: \(info.files.map(\.path).joined(separator: " | "))")
            exitCode = 0
        case "limits":
            exitCode = await runLimits(settings: settings)
        case "upload":
            exitCode = await runUpload(settings: settings, args: Array(args.dropFirst()))
        case "watch":
            exitCode = runWatch(settings: settings, args: Array(args.dropFirst()))
        default:
            printUsage()
            exitCode = command == "--help" || command == "-h" ? 0 : 2
        }
        exit(exitCode)
    }

    static func printUsage() {
        say("""
        ClipLink CLI
          types                       print current pasteboard types
          limits --backend URL        fetch advertised limits from a backend
          upload FILE --backend URL   upload one file, print the share JSON
          watch --backend URL [--once] [--no-replace] [--timeout SECONDS]
                                      run the clipboard monitor headless
        """)
    }

    static func runLimits(settings: Settings) async -> Int32 {
        let client = UploadClient()
        do {
            let limits = try await client.fetchLimits(backend: settings.backendURL)
            note("backend: \(settings.backendURL)")
            note("maxFileBytes: \(limits.maxFileBytes)")
            note("maxFileMB: \(limits.maxFileMB)")
            note("expiryHours: \(limits.expiryHours)")
            note("rateLimitUploads: \(limits.rateLimitUploads.map(String.init) ?? "-")")
            return 0
        } catch {
            note("ERROR: \(error)")
            return 1
        }
    }

    static func runUpload(settings: Settings, args: [String]) async -> Int32 {
        guard let pathArg = args.first(where: { !$0.hasPrefix("--") }), !pathArg.isEmpty else {
            note("ERROR: upload requires a file path")
            return 2
        }
        let fileURL = URL(fileURLWithPath: pathArg).standardizedFileURL
        let pipeline = UploadPipeline(settings: settings)
        let copy = ClipboardFileCopy(changeCount: -1, files: [CopiedFile(url: fileURL)])
        let result = await pipeline.uploadCopiedFiles(copy.files)
        for record in result.ineligible {
            note("skipped: \(record.name) — \(record.reason)")
        }
        if let failure = result.failureMessage {
            note("ERROR: \(failure)")
            return 1
        }
        guard let link = result.links.first else {
            note("ERROR: no link produced")
            return 1
        }
        let payload = """
        {"url":"\(link.url)","token":"\(link.token)","filename":"\(link.filename)","size":\(link.size),"expiresAt":\(link.expiresAt),"revokeToken":"\(link.revokeToken)"}
        """
        say(payload)
        return 0
    }

    static func runWatch(settings: Settings, args: [String]) -> Int32 {
        let replaceClipboard = !args.contains("--no-replace")
        let pollInterval = TimeInterval(Double(flag("interval", in: args) ?? "1") ?? 1.0)
        let timeoutSeconds = TimeInterval(Double(flag("timeout", in: args) ?? "0") ?? 0)

        let pipeline = UploadPipeline(settings: settings)
        let monitor = ClipboardMonitor(
            settings: settings,
            pipeline: pipeline,
            history: LinkStore(defaults: UserDefaults(suiteName: "ClipLinkCLIHistory")!),
            notifier: PrintNotifier(),
            replaceClipboardOnSuccess: replaceClipboard
        )
        monitor.eventSink = { event in
            switch event {
            case .started(let names):
                note("event=started files=\(names.joined(separator: ","))")
            case .progress(let fraction, let filename):
                note("event=progress file=\(filename) fraction=\(String(format: "%.2f", fraction))")
            case .succeeded(let links, let replaced):
                for link in links {
                    note("event=success token=\(link.token) revoke=\(link.revokeToken) url=\(link.url)")
                }
                note("event=clipboard_replaced value=\(replaced)")
            case .failed(let message, let names):
                note("event=failed files=\(names.joined(separator: ",")) message=\(message)")
            case .ineligible(let records):
                for record in records {
                    note("event=skipped file=\(record.name) reason=\(record.reason)")
                }
            case .superseded(let links):
                note("event=superseded links=\(links.count)")
            case .info(let text):
                note("event=info text=\(text)")
            }
        }
        monitor.start(pollInterval: pollInterval)
        pipeline.progressSink = { fraction, filename in
            note("event=progress file=\(filename) fraction=\(String(format: "%.2f", fraction))")
        }

        if timeoutSeconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                note("event=timeout")
                exit(3)
            }
        }
        if args.contains("--once") {
            note("event=waiting-for-one-copy")
        }
        RunLoop.main.run()
        return 0
    }
}

final class PrintNotifier: ClipLinkNotifier {
    var isEnabled: Bool { true }
    func notifySuccess(title: String, message: String) {
        let data = Data("[notify][success] \(title): \(message)\n".utf8)
        FileHandle.standardError.write(data)
    }
    func notifyFailure(title: String, message: String) {
        let data = Data("[notify][failure] \(title): \(message)\n".utf8)
        FileHandle.standardError.write(data)
    }
}
