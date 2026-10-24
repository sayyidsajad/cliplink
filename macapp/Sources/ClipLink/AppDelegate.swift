import AppKit
import ClipLinkCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = Settings()
    let history = LinkStore()
    let notifier = SystemNotifier()

    lazy var pipeline: UploadPipeline = UploadPipeline(settings: settings)
    var monitor: ClipboardMonitor!

    var statusItem: NSStatusItem!
    var statusLine = "Starting…"

    var onboardingWindowController: OnboardingWindowController?
    var preferencesWindowController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        pipeline.progressSink = { [weak self] fraction, filename in
            guard let self else { return }
            self.statusLine = fraction >= 1
                ? "Waiting for server…"
                : "Uploading \(filename) — \(Int((fraction * 100).rounded()))%"
            self.statusItem.button?.toolTip = self.statusLine
        }

        monitor = ClipboardMonitor(
            settings: settings,
            pipeline: pipeline,
            history: history,
            notifier: notifier
        )
        monitor.eventSink = { [weak self] event in
            self?.handleEvent(event)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "link", accessibilityDescription: "ClipLink")
            button.toolTip = statusLine
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        if settings.onboardingDone, settings.monitoringEnabled {
            monitor.start()
            statusLine = "Watching the clipboard"
        } else {
            statusLine = "Not configured yet"
            DispatchQueue.main.async { [weak self] in self?.showOnboarding(initial: true) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }

    // MARK: - menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func menu(_ menu: NSMenu, title: String) {
        let item = NSMenuItem()
        item.title = title
        item.isEnabled = false
        menu.addItem(item)
    }

    private func staticTitle(_ menu: NSMenu, title: String) {
        let item = NSMenuItem()
        item.title = title
        item.isEnabled = false
        menu.addItem(item)
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        staticTitle(menu, title: statusLine)
        if let limits = pipeline.limits {
            staticTitle(menu, title: "Server: ≤ \(Format.bytes(limits.maxFileBytes)) per file · links expire in \(humanHours(limits.expiryHours))")
        } else if let error = pipeline.lastLimitsError {
            staticTitle(menu, title: "Backend unreachable — \(error)")
        } else {
            staticTitle(menu, title: "Server limits: unknown")
        }
        menu.addItem(.separator())

        if monitor?.isRunning == true {
            menu.addItem(action("Pause Clipboard Monitoring", #selector(toggleMonitoring(_:))))
        } else {
            menu.addItem(action("Resume Clipboard Monitoring", #selector(toggleMonitoring(_:))))
        }

        menu.addItem(.separator())
        staticTitle(menu, title: "RECENT LINKS")
        if history.links.isEmpty {
            staticTitle(menu, title: "  Nothing shared yet — copy a file in Finder")
        }
        for link in history.links.prefix(10) {
            let item = NSMenuItem()
            item.title = "\(link.filename) · \(Format.bytes(link.size)) · \(Format.relativeExpiry(expiresAtMillis: link.expiresAt))"
            let sub = NSMenu()
            sub.autoenablesItems = false
            sub.addItem(menuItem("Copy Link", #selector(copyLink(_:)), object: link.url))
            sub.addItem(menuItem("Open Download Page", #selector(openLink(_:)), object: link.url))
            sub.addItem(.separator())
            sub.addItem(menuItem("Revoke (delete hosted file)", #selector(revokeLink(_:)), object: link.token))
            sub.addItem(.separator())
            let note = NSMenuItem()
            note.title = "Uploaded \(Format.shortDate(link.createdAt)) · expires \(Format.shortDate(link.expiresAt))"
            note.isEnabled = false
            sub.addItem(note)
            item.submenu = sub
            menu.addItem(item)
        }
        if !history.links.isEmpty {
            menu.addItem(action("Clear Recent Links", #selector(clearHistory(_:))))
        }

        menu.addItem(.separator())
        let backend = NSMenuItem()
        backend.title = "Backend"
        let backendSub = NSMenu()
        backendSub.autoenablesItems = false
        let whereAmI = NSMenuItem()
        whereAmI.title = "  \(settings.backendURL.absoluteString)"
        whereAmI.isEnabled = false
        backendSub.addItem(whereAmI)
        backendSub.addItem(actionItem("Use Local Development Server (127.0.0.1:8787)", #selector(useLocalDevBackend(_:))))
        backendSub.addItem(actionItem("Use Custom URL…", #selector(changeBackend(_:))))
        backendSub.addItem(actionItem("Check Connection & Limits", #selector(checkLimits(_:))))
        backend.submenu = backendSub
        backendSub.autoenablesItems = false
        menu.addItem(backend)

        let notificationsItem = actionItem("Enable Notifications", #selector(toggleNotifications(_:)))
        notificationsItem.state = settings.notificationsEnabled ? .on : .off
        menu.addItem(notificationsItem)

        menu.addItem(actionItem("Preferences…", #selector(showPreferences(_:))))
        menu.addItem(actionItem("How ClipLink Works…", #selector(showAbout(_:))))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit ClipLink", #selector(NSApplication.terminate(_:))))
    }

    private func menuItem(_ title: String, _ sel: Selector, object: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        item.isEnabled = true
        return item
    }

    private func actionItem(_ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    private func humanHours(_ value: Double) -> String {
        Int(value) == 24 ? "24 h" : "\(String(format: "%.1f", value)) h"
    }

    // MARK: - actions

    @objc func toggleMonitoring(_ sender: Any?) {
        let enabling = !(monitor?.isRunning ?? false)
        settings.monitoringEnabled = enabling
        settings.onboardingDone = true
        if enabling {
            monitor?.start()
            statusLine = "Watching the clipboard"
        } else {
            monitor?.stop()
            statusLine = "Paused"
        }
    }

    @objc func clearHistory(_ sender: Any?) {
        history.removeAll()
        statusLine = "Recent links cleared (hosted files are NOT deleted)"
    }

    @objc func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        ClipboardWriter.write(url)
        statusLine = "Link copied to clipboard"
    }

    @objc func openLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String,
              let parsed = URL(string: url) else { return }
        NSWorkspace.shared.open(parsed)
    }

    @objc func revokeLink(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String,
              let link = history.links.first(where: { $0.token == token }) else { return }
        let alert = NSAlert()
        alert.messageText = "Revoke \(link.filename)?"
        alert.informativeText = "The hosted file is deleted immediately and the public link stops working for everyone."
        alert.addButton(withTitle: "Revoke")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: activeWindow()) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await self.revoke(link) }
        }
    }

    private func revoke(_ link: StoredLink) async {
        var request = URLRequest(
            url: URL(string: link.url.replacingOccurrences(of: "/s/", with: "/api/v1/shares/"))!
        )
        request.httpMethod = "DELETE"
        request.setValue(link.revokeToken, forHTTPHeaderField: "X-ClipLink-Revoke-Token")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                statusLine = "Revoked \(link.filename)"
                notifier.notifySuccess(title: "ClipLink", message: "Revoked and deleted \(link.filename).")
            } else {
                throw URLError(.badServerResponse)
            }
        } catch {
            statusLine = "Revocation failed for \(link.filename)"
            notifier.notifyFailure(title: "ClipLink", message: "Could not revoke \(link.filename). Check connection and try again.")
        }
    }

    @objc func useLocalDevBackend(_ sender: Any?) {
        applyBackend(Settings.defaultBackendString)
    }

    @objc func changeBackend(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "ClipLink backend URL"
        alert.informativeText = "Where files are uploaded. Example: https://cliplink.yourname.workers.dev"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = settings.backendURLString
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: activeWindow()) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.applyBackend(field.stringValue)
        }
        field.becomeFirstResponder()
    }

    private func applyBackend(_ raw: String) {
        settings.backendURLString = raw
        pipeline.resetLimits()
        statusLine = "Backend set to \(settings.backendURL.absoluteString)"
        Task { await pipeline.refreshLimits(force: true) }
    }

    @objc func checkLimits(_ sender: Any?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let limits = try await self.pipeline.client.fetchLimits(backend: self.settings.backendURL)
                await MainActor.run {
                    self.pipeline.storeLimits(limits)
                    self.statusLine = "Backend reachable"
                    let alert = NSAlert()
                    alert.messageText = "Backend is reachable"
                    alert.informativeText = """
                    Max file size: \(Format.bytes(limits.maxFileBytes))
                    Link expiry: \(limits.expiryHours) hours
                    Rate limit: \(limits.rateLimitUploads ?? 0) uploads / \(limits.rateWindowMinutes ?? 0) min
                    """
                    alert.runModal()
                }
            } catch {
                await MainActor.run {
                    self.pipeline.noteLimitsError("\(error)")
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Backend unreachable"
                    alert.informativeText = "\(error)"
                    alert.runModal()
                }
            }
        }
    }

    @objc func toggleNotifications(_ sender: Any?) {
        if settings.notificationsEnabled {
            settings.notificationsEnabled = false
            notifier.isEnabled = false
            statusLine = "Notifications off"
        } else {
            Task { [weak self] in
                guard let self else { return }
                await self.notifier.requestAuthorization()
                await MainActor.run {
                    self.settings.notificationsEnabled = self.notifier.isEnabled
                    self.statusLine = self.settings.notificationsEnabled ? "Notifications on" : "Notifications denied in System Settings"
                }
            }
        }
    }

    @objc func showPreferences(_ sender: Any?) {
        let controller = preferencesWindowController ?? PreferencesWindowController(settings: settings)
        preferencesWindowController = controller
        controller.onSaved = { [weak self] in
            guard let self else { return }
            self.pipeline.resetLimits()
            Task { await self.pipeline.refreshLimits(force: true) }
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAbout(_ sender: Any?) {
        showOnboarding(initial: false)
    }

    func showOnboarding(initial: Bool) {
        let controller = onboardingWindowController ?? OnboardingWindowController()
        onboardingWindowController = controller
        controller.onStart = { [weak self] in
            guard let self else { return }
            Task { await self.notifier.requestAuthorization() }
            self.settings.notificationsEnabled = controller.wantsNotifications && self.notifier.isEnabled
            self.settings.onboardingDone = true
            self.settings.monitoringEnabled = true
            self.monitor?.start()
            self.statusLine = "Watching the clipboard — copy any file in Finder"
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if initial { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - event handling (status line + progress)

    private func handleEvent(_ event: ClipLinkEvent) {
        switch event {
        case .started(let names):
            statusLine = "Uploading \(names.first ?? "file")…"
        case .progress(let fraction, let filename):
            statusLine = "Uploading \(filename) — \(Int((fraction * 100).rounded()))%"
        case .succeeded(let links, let replaced):
            if replaced {
                statusLine = links.count == 1 ? "Link copied to clipboard ✓ (\(links[0].filename))" : "\(links.count) links copied ✓"
            } else {
                statusLine = "Uploaded — link in Recent links"
            }
        case .failed(let message, let names):
            statusLine = "Upload failed ✗ (\(names.first ?? "file"))"
            NSLog("ClipLink upload failed: %@", message)
        case .ineligible(let records):
            if let first = records.first {
                statusLine = "Skipped \(first.name) — \(first.reason)"
            }
        case .superseded(let links):
            statusLine = "Uploaded \(links.count) file(s); clipboard left untouched"
        case .info:
            break
        }
        statusItem.button?.toolTip = statusLine
    }

    func activeWindow() -> NSWindow {
        NSApp.keyWindow
            ?? preferencesWindowController?.window
            ?? onboardingWindowController?.window
            ?? NSWindow()
    }
}

private extension NSMenu {
    func item(title: String) {
        let entry = NSMenuItem()
        entry.title = title
        entry.isEnabled = false
        addItem(entry)
    }
}
