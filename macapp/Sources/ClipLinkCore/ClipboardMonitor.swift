import AppKit
import Foundation

/// Background clipboard watcher (FR-01/FR-02).
///
/// Design points that keep this safe:
///  - Polls only `changeCount`; content is read solely when the pasteboard
///    actually changed, so polling is cheap and privacy-friendly.
///  - Every processed state marks `lastHandledChangeCount`, so the same state
///    is never processed twice.
///  - Own writes are registered in `lastWrittenChangeCount`; as a second line
///    of defence our written URLs are plain text, which the file detector
///    ignores anyway — no upload loop (FR-05).
///  - Before replacing the clipboard it re-verifies the changeCount, so a
///    newer copy made by the user mid-upload is never clobbered.
///  - Pausable, sequential processing: newer copies queue up until the
///    current upload finishes. All mutations happen on the main thread.
public final class ClipboardMonitor: @unchecked Sendable {
    private let pasteboard = NSPasteboard.general
    private let settings: Settings
    private let pipeline: UploadPipeline
    private let history: LinkStore
    private let notifier: ClipLinkNotifier

    private var timer: Timer?
    public private(set) var lastHandledChangeCount = -1
    private var lastWrittenChangeCount = -1
    private var pendingCopy: ClipboardFileCopy?
    private var draining = false

    public var replaceClipboardOnSuccess = true
    public var eventSink: ((_ event: ClipLinkEvent) -> Void)?

    public var isRunning: Bool { timer != nil }

    public init(
        settings: Settings,
        pipeline: UploadPipeline,
        history: LinkStore,
        notifier: ClipLinkNotifier,
        replaceClipboardOnSuccess: Bool = true
    ) {
        self.settings = settings
        self.pipeline = pipeline
        self.history = history
        self.notifier = notifier
        self.replaceClipboardOnSuccess = replaceClipboardOnSuccess
    }

    // MARK: lifecycle

    public func start(pollInterval: TimeInterval = 1.0) {
        guard timer == nil else { return }
        lastHandledChangeCount = pasteboard.changeCount // ignore everything already there
        lastWrittenChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: pollInterval, repeats: true, block: { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        })
        self.timer = timer
        RunLoop.main.add(timer, forMode: RunLoop.Mode.common) // keeps working while menus are open
        emit(.info(text: "monitor-started"))
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        emit(.info(text: "monitor-stopped"))
    }

    // MARK: detection

    private func tick() {
        let changeCount = pasteboard.changeCount
        if changeCount <= max(lastHandledChangeCount, lastWrittenChangeCount) {
            return
        }
        if !settings.monitoringEnabled {
            // Paused: remember the state without reading its contents at all.
            lastHandledChangeCount = changeCount
            return
        }
        guard let copy = ClipboardFiles.readCurrentCopy(from: pasteboard) else {
            // Not a file copy (text, images, unsupported): do nothing (FR-08).
            lastHandledChangeCount = changeCount
            return
        }
        lastHandledChangeCount = changeCount
        pendingCopy = copy
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard !draining else { return }
        draining = true
        Task { @MainActor [weak self] in
            guard let selfRef = self else { return }
            selfRef.draining = false
            while let copy = selfRef.pendingCopy {
                selfRef.pendingCopy = nil
                await selfRef.run(copy)
            }
        }
    }

    // MARK: processing one copied-file event

    private func run(_ copy: ClipboardFileCopy) async {
        emit(.started(filenames: copy.files.map(\.name)))
        let outcome = await pipeline.uploadCopiedFiles(copy.files)

        if !outcome.ineligible.isEmpty {
            emit(.ineligible(records: outcome.ineligible))
            for record in outcome.ineligible {
                notifier.notifyFailure(
                    title: "File not shared",
                    message: "\(record.name) — \(record.reason)."
                )
            }
        }

        guard outcome.failureMessage == nil, !outcome.links.isEmpty else {
            let message = outcome.failureMessage ?? "Nothing was shared."
            emit(.failed(message: message, filenames: copy.files.map(\.name)))
            notifier.notifyFailure(title: "ClipLink upload failed", message: message)
            return // clipboard untouched: the original file reference stays put
        }

        for link in outcome.links {
            history.add(link)
        }

        var replaced = false
        if replaceClipboardOnSuccess,
           settings.monitoringEnabled,
           pasteboard.changeCount == copy.changeCount {
            noteClipboardWritten(ClipboardWriter.writeLinks(outcome.links.map(\.url)))
            replaced = true
        }

        let summary = outcome.links.count == 1
            ? "Download link copied to clipboard for \(outcome.links[0].filename). \(Format.relativeExpiry(expiresAtMillis: outcome.links[0].expiresAt))."
            : "\(outcome.links.count) download links copied to clipboard."

        if replaced {
            emit(.succeeded(links: outcome.links, clipboardReplaced: true))
            notifier.notifySuccess(title: "ClipLink shared your file", message: summary)
        } else if pasteboard.changeCount != copy.changeCount {
            // The user copied something new while uploading; leave it alone.
            emit(.superseded(links: outcome.links))
            notifier.notifySuccess(title: "ClipLink uploaded your file",
                                   message: summary + " (clipboard left untouched)")
        } else {
            emit(.succeeded(links: outcome.links, clipboardReplaced: false))
        }
    }

    private func noteClipboardWritten(_ changeCount: Int) {
        lastWrittenChangeCount = changeCount
    }

    private func emit(_ event: ClipLinkEvent) {
        eventSink?(event)
    }
}
