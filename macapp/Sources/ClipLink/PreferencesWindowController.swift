import AppKit
import ClipLinkCore

/// Small preferences window: backend URL, upload cap, notifications toggle and
/// the blocked-file pattern list (privacy controls, FR-08).
final class PreferencesWindowController: NSWindowController {
    private(set) var settings: Settings!
    var onSaved: (() -> Void)?

    // force-unwrapped `settings!` is assigned in the convenience initializer

    private var backendField: NSTextField!
    private var maxUploadPopup: NSPopUpButton!
    private var blockedEditor: NSTextView!
    private var notificationsBox: NSButton!
    private var statusLabel: NSTextField!
    private var form: NSGridView!

    // Pro rows
    private var lifetimePopup: NSPopUpButton!
    private var protectionBox: NSButton!
    private var passwordField: NSSecureTextField!
    private var licenseField: NSTextField!
    private var proStatusLabel: NSTextField!

    convenience init(settings: Settings, notifier: (ClipLinkNotifier & Sendable)? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipLink Preferences"
        self.init(window: window)
        self.settings = settings
        buildContent(window: window)
        window.center()
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesWindowClosed(_:)),
            name: NSWindow.willCloseNotification, object: window
        )
    }

    @objc private func preferencesWindowClosed(_ note: Notification) {
        save()
        onSaved?()
        NotificationCenter.default.removeObserver(self)
    }

    private func buildContent(window: NSWindow) {
        form = NSGridView(views: [
            [label("Backend URL"), backendField_()],
            [label("Max upload size"), prevMaxUploadPopup()],
            [label("Notifications"), prevNotificationsCheckbox()],
            [label("Link lifetime (Pro)"), lifetimePopup_()],
            [label("Password-protect (Pro)"), protectionRow()],
            [label("ClipLink Pro license"), proLicenseRow()],
            [label("Blocked filename patterns"), prevBlockedEditor()],
        ])
        form.rowSpacing = 14
        form.columnSpacing = 14
        form.column(at: 0).width = 300
        form.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(closeWindow(_:)))
        cancelButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(form)
        container.addSubview(buttonRow)
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            form.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            form.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -22),
            buttonRow.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            statusLabel.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
        ])
        window.contentView = container
        window.setContentSize(NSSize(width: 580, height: 620))
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private func backendField_() -> NSView {
        let field = NSTextField(string: settings.backendURLString)
        field.placeholderString = "https://cliplink.yourname.workers.dev"
        backendField = field
        return field
    }

    private func prevMaxUploadPopup() -> NSView {
        let popup = NSPopUpButton()
        for option in ["Automatic (server default)", "10 MB", "50 MB", "100 MB"] {
            popup.addItem(withTitle: option)
        }
        switch settings.maxUploadMB {
        case 10: popup.selectItem(at: 1)
        case 50: popup.selectItem(at: 2)
        case 100: popup.selectItem(at: 3)
        default: popup.selectItem(at: 0)
        }
        maxUploadPopup = popup
        return popup
    }

    private func prevNotificationsCheckbox() -> NSView {
        let box = NSButton(checkboxWithTitle: "Upload finished / failures", target: nil, action: nil)
        box.state = settings.notificationsEnabled ? .on : .off
        notificationsBox = box
        return box
    }

    private func prevBlockedEditor() -> NSView {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 150))
        editor.isRichText = false
        if settings.isUsingDefaultBlockedPatterns {
            editor.string = "(default patterns in use)\n" + EligibilityPolicy.defaultBlockedPatterns.joined(separator: "\n")
        } else {
            editor.string = settings.blockedPatterns.joined(separator: "\n")
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 160))
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        blockedEditor = editor
        return scroll
    }

    // MARK: ClipLink Pro (one-time purchase)

    private func lifetimePopup_() -> NSView {
        let popup = NSPopUpButton()
        popup.addItem(withTitle: "Server default (24 h)")
        popup.addItem(withTitle: "1 week — Pro")
        popup.addItem(withTitle: "30 days — Pro")
        switch settings.linkExpiresHours {
        case 168: popup.selectItem(at: 1)
        case 720: popup.selectItem(at: 2)
        default: popup.selectItem(at: 0)
        }
        popup.target = self
        popup.action = #selector(proPreferenceChanged(_:))
        lifetimePopup = popup
        return popup
    }

    private func protectionRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let box = NSButton(checkboxWithTitle: "Ask for a password to download", target: self, action: #selector(proPreferenceChanged(_:)))
        box.state = settings.protectionEnabled ? .on : .off
        box.isEnabled = settings.isProEligible
        let field = NSSecureTextField(string: settings.linkPassword)
        field.placeholderString = "password"
        field.widthAnchor.constraint(equalToConstant: 140).isActive = true
        field.isEnabled = settings.isProEligible
        field.target = self
        field.action = #selector(proPreferenceChanged(_:))
        row.addArrangedSubview(box)
        row.addArrangedSubview(field)
        protectionBox = box
        passwordField = field
        return row
    }

    private func proLicenseRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let field = NSTextField(string: settings.licenseKey)
        field.placeholderString = "CLPRO-XXXX-XXXX-XXXX-XXXX"
        field.widthAnchor.constraint(equalToConstant: 215).isActive = true
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let save = NSButton(title: "Activate", target: self, action: #selector(activatePro(_:)))
        save.bezelStyle = .rounded
        row.addArrangedSubview(field)
        row.addArrangedSubview(save)
        let status = NSTextField(labelWithString: proStatusText())
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = settings.isProEligible ? NSColor.systemGreen : NSColor.secondaryLabelColor
        row.addArrangedSubview(status)
        licenseField = field
        proStatusLabel = status
        return row
    }

    private func proStatusText() -> String {
        settings.isProEligible
            ? "Pro active ✓ (password links + long expiry unlocked)"
            : "Free — Enter your Pro license key for password links & long expiry"
    }

    @objc private func proPreferenceChanged(_ sender: Any?) {
        // Double the row's enabled state unless Pro is already active.
        protectionBox?.isEnabled = settings.isProEligible
        passwordField?.isEnabled = settings.isProEligible
    }

    /// Asks the backend whether the typed key is a genuine ClipLink Pro key
    /// (mint-only; a wrong/garbled key is rejected without any penalty).
    @objc private func activatePro(_ sender: Any?) {
        let entered = licenseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else {
            proStatusLabel.stringValue = "Paste your license key first."
            proStatusLabel.textColor = NSColor.systemOrange
            return
        }
        settings.licenseKey = entered
        proStatusLabel.stringValue = "Verifying…"
        proStatusLabel.textColor = NSColor.secondaryLabelColor
        let client = LicenseClient()
        let backend = settings.backendURL
        let install = settings.installID
        let settingsRef: Settings = settings
        Task { @MainActor [weak self] in
            do {
                let result = try await client.verify(backend: backend, installID: install, licenseKey: entered)
                settingsRef.proActive = result.active
                self?.proStatusLabel.textColor = result.active ? NSColor.systemGreen : NSColor.systemRed
                var text = self?.proStatusText() ?? ""
                if !result.active {
                    text = result.reason == "install_limit"
                        ? "License already in use on too many Macs (5 max)"
                        : "This key is not valid — check for typos or contact support"
                }
                self?.proStatusLabel.stringValue = text
            } catch {
                self?.proStatusLabel.textColor = NSColor.systemOrange
                self?.proStatusLabel.stringValue = "Could not reach the server — try Activate again later"
            }
        }
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.close()
    }

    @objc private func save(_ sender: Any?) {
        save()
        onSaved?()
    }

    private func save() {
        settings.backendURLString = backendField.stringValue
        switch maxUploadPopup.indexOfSelectedItem {
        case 1: settings.maxUploadMB = 10
        case 2: settings.maxUploadMB = 50
        case 3: settings.maxUploadMB = 100
        default: settings.maxUploadMB = 0
        }
        settings.notificationsEnabled = notificationsBox.state == .on
        switch lifetimePopup?.indexOfSelectedItem {
        case 1: settings.linkExpiresHours = 168
        case 2: settings.linkExpiresHours = 720
        default: settings.linkExpiresHours = 0
        }
        if let protectionBox, let passwordField {
            settings.protectionEnabled = protectionBox.state == .on && settings.isProEligible
            settings.linkPassword = passwordField.stringValue
        }
        // License activation has its own button (server round-trip);
        // a silently edited field is kept but not trusted until Activate.
        if let licenseField, settings.licenseKey != licenseField.stringValue {
            settings.licenseKey = licenseField.stringValue
            settings.proActive = false // changed key needs re-verification
        }
        let raw = blockedEditor.string
        if raw.hasPrefix("(default patterns in use)") {
            // untouched — keep defaults
        } else {
            settings.blockedPatterns = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }
}
