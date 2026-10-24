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

    convenience init(settings: Settings, notifier: (ClipLinkNotifier & Sendable)? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
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
        let form = NSGridView(views: [
            [label("Backend URL"), backendField_()],
            [label("Max upload size"), prevMaxUploadPopup()],
            [label("Notifications"), prevNotificationsCheckbox()],
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
        window.setContentSize(NSSize(width: 540, height: 500))
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
