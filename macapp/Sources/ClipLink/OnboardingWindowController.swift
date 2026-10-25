import AppKit
import ClipLinkCore

/// First-run explanation (FR-08): before monitoring starts, the user is told
/// exactly what gets uploaded, what never gets uploaded, and how to stop.
/// Since v0.3.2 the user must consent to the Terms & Privacy Policy, and
/// since v0.4 the app also walks through a "Connect Google Drive" step when
/// the backend advertises BYO storage (`storageProvider == "drive"`): the
/// user consents in the browser, the backend stores the refresh token
/// sealed, and monitoring can only start once that gate is satisfied.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    var onStart: (() -> Void)?

    static let termsURL = URL(string: "https://sayyidsajad.github.io/cliplink-website/terms.html")!
    static let privacyURL = URL(string: "https://sayyidsajad.github.io/cliplink-website/privacy.html")!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to ClipLink"
        self.init(window: window)
        window.delegate = self
        buildContent(window: window)
        window.center()
    }

    private func buildContent(window: NSWindow) {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 16
        container.edgeInsets = NSEdgeInsets(top: 24, left: 26, bottom: 22, right: 26)
        container.translatesAutoresizingMaskIntoConstraints = false

        let headline = NSTextField(labelWithString: "Share files by copying them.")
        headline.font = NSFont.systemFont(ofSize: 20, weight: .semibold)

        let body = NSTextField(labelWithString: "")
        body.isSelectable = true
        body.lineBreakMode = .byWordWrapping
        body.preferredMaxLayoutWidth = 505
        body.attributedStringValue = OnboardingWindowController.explanation()

        let checkbox = NSButton(
            checkboxWithTitle: "Notify me when uploads finish (optional)",
            target: self,
            action: #selector(persistNotificationsChoice(_:))
        )
        self.notificationsCheckbox = checkbox

        // BYO storage (v0.4+): before monitoring can start, the user connects
        // their own Google Drive — files then live in THEIR Drive and the
        // backend keeps only the short-link metadata.
        let driveRow = NSStackView(views: [
            connectDriveButton,
            driveStatusLabel,
        ])
        driveRow.orientation = .horizontal
        driveRow.spacing = 10
        driveRow.alignment = .firstBaseline
        self.driveRowHolder = driveRow
        self.driveStatusLabel.stringValue = "Not connected"

        let driveNote = NSTextField(labelWithString: "")
        driveNote.font = NSFont.systemFont(ofSize: 11)
        driveNote.textColor = NSColor.secondaryLabelColor
        driveNote.lineBreakMode = .byWordWrapping
        driveNote.preferredMaxLayoutWidth = 505
        driveNote.attributedStringValue = OnboardingWindowController.driveExplanation()
        self.driveNoteLabel = driveNote

        // Terms/Privacy consent (v0.3.2): Start stays disabled until the user
        // agrees. This surfaces the hosted-service legal terms at first run,
        // before anything is ever uploaded.
        let consent = NSButton(
            checkboxWithTitle: "I'm 18 or older and I accept the Terms & Privacy Policy",
            target: self,
            action: #selector(legalConsentChanged(_:))
        )
        consent.font = NSFont.systemFont(ofSize: 13)
        consent.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.legalCheckbox_ = consent

        let legalLinksRow = NSStackView(views: [
            NSView(), // leading spacer, keeps links visually under the text
            legalButton("Read Terms", url: OnboardingWindowController.termsURL),
            legalButton("Read Privacy Policy", url: OnboardingWindowController.privacyURL),
        ])
        legalLinksRow.orientation = .horizontal
        legalLinksRow.spacing = 12
        legalLinksRow.alignment = .firstBaseline

        let startButton = NSButton(title: "Start Monitoring", target: self, action: #selector(startAction(_:)))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.isEnabled = false
        self.startButton_ = startButton

        let quitButton = NSButton(title: "Quit", target: NSApp.self, action: #selector(NSApplication.terminate(_:)))
        quitButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [quitButton, startButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.alignment = .firstBaseline

        let stretch = NSView()
        stretch.setContentHuggingPriority(.init(1), for: .horizontal)
        buttonRow.addArrangedSubview(stretch)
        buttonRow.setContentHuggingPriority(.defaultLow, for: .horizontal)

        container.addArrangedSubview(headline)
        container.addArrangedSubview(body)
        container.addArrangedSubview(driveRowHolder)
        container.addArrangedSubview(driveNote)
        container.addArrangedSubview(checkbox)
        container.addArrangedSubview(consent)
        container.addArrangedSubview(legalLinksRow)
        container.addArrangedSubview(buttonRow)

        window.contentView = container
        for edge in [NSLayoutConstraint.Attribute.top, .bottom, .left, .right] {
            NSLayoutConstraint(item: container, attribute: edge, relatedBy: .equal,
                               toItem: window.contentView!, attribute: edge,
                               multiplier: 1, constant: 0).isActive = true
        }
        window.setContentSize(NSSize(width: 560, height: 556))
    }

    private var notificationsCheckbox: NSButton!
    private var legalCheckbox_: NSButton!
    private var startButton_: NSButton!

    // MARK: Drive gate (BYO storage v0.4+)

    var onConnectDrive: (() -> Void)?

    /// Server state limits (v0.4+): whether Drive is required at all.
    private var driveRequired = false
    private var driveConnected = false
    private var driveBusy = false

    private lazy var connectDriveButton: NSButton = NSButton(
        title: "Connect Google Drive…",
        target: self,
        action: #selector(connectDriveAction(_:))
    )
    private lazy var driveStatusLabel: NSTextField = NSTextField(labelWithString: "Not connected")
    private var driveRowHolder: NSStackView!
    private var driveNoteLabel: NSTextField!

    @objc private func connectDriveAction(_ sender: Any?) {
        onConnectDrive?()
    }

    /// Pure UI state plumbing used by AppDelegate: `required` reflects the
    /// backend's advertised storageProvider, `connected` our stored state.
    func applyDriveState(required: Bool, connected: Bool) {
        driveRequired = required
        driveConnected = connected
        if connected && driveStatusLabel.stringValue == "Not connected" {
            driveStatusLabel.stringValue = "Connected ✓"
            driveStatusLabel.textColor = NSColor.systemGreen
        }
        refreshDriveUI()
    }

    func setDriveBusy(_ busy: Bool) {
        driveBusy = busy
        refreshDriveUI()
    }

    func setDriveConnected(_ email: String?) {
        driveConnected = true
        driveStatusLabel.stringValue = "Connected ✓ \(email ?? "your account")"
        driveStatusLabel.textColor = NSColor.systemGreen
        refreshDriveUI()
    }

    func setDriveTimedOut() {
        driveConnected = false
        driveStatusLabel.stringValue = "Connect window closed — click Connect to try again"
        driveStatusLabel.textColor = NSColor.systemOrange
        refreshDriveUI()
    }

    func setDriveError(_ detail: String) {
        driveStatusLabel.stringValue = "Couldn't connect: \(detail)"
        driveStatusLabel.textColor = NSColor.systemRed
        refreshDriveUI()
    }

    private func refreshDriveUI() {
        connectDriveButton.isEnabled = !driveBusy
        if driveRequired && !driveConnected {
            // Drive is the storage backend: Start monitoring needs a connection
            // (uploads would 403 drive_not_connected without it).
            startButton_?.isEnabled = legalCheckbox_?.state == .on && driveConnected && !driveBusy
        } else {
            startButton_?.isEnabled = legalCheckbox_?.state == .on
        }
    }

    private static func driveExplanation() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 4
        return NSAttributedString(string:
        "⚠️ Your files are uploaded into YOUR OWN Google Drive — ClipLink's servers store only the short link's metadata, never the file. You can disconnect at any time from Google (myaccount.google.com → Security → Third-party apps).",
        attributes: [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: paragraph])
    }

    private func legalButton(_ title: String, url: URL) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(openLegalPage(_:)))
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 12)
        button.setAccessibilityIdentifier(url.absoluteString)
        button.setAccessibilityURL(url)
        associatedURLs[ObjectIdentifier(button)] = url
        return button
    }

    private var associatedURLs: [ObjectIdentifier: URL] = [:]

    @objc private func legalConsentChanged(_ sender: Any?) {
        refreshDriveUI() // Start's enablement = consent ∧ (Drive connected when required)
    }

    @objc private func openLegalPage(_ sender: Any?) {
        guard let button = sender as? NSButton,
              let url = associatedURLs[ObjectIdentifier(button)] else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func persistNotificationsChoice(_ sender: Any?) {
        // The AppDelegate reads the checkbox state when Start is pressed.
    }

    @objc private func startAction(_ sender: Any?) {
        window?.orderOut(nil)
        onStart?()
    }

    /// Whether the user ticked the notifications checkbox.
    var wantsNotifications: Bool {
        notificationsCheckbox?.state == .on
    }

    /// Whether the user consented to the Terms & Privacy Policy.
    var hasLegalConsent: Bool {
        legalCheckbox_?.state == .on
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true // closing without starting keeps monitoring off — also a valid choice
    }

    private static func explanation() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 9
        return NSAttributedString(string: """
        When you copy a file in Finder, ClipLink uploads that file into YOUR OWN Google Drive and replaces the clipboard contents with a public download link. Anyone you paste the link to can download it in a browser — no app, no account.

        • Your file bytes live in your Google Drive. ClipLink's servers store only the short link's metadata, never the file itself.
        • Only files copied in Finder are uploaded. Text, passwords, screenshots and image data are ignored by design.
        • Files matching sensitive patterns (.env, private keys, wallets, …) are never uploaded.
        • Links expire automatically after 24 hours; the copy in your Drive is deleted, and you can revoke any link from the menu-bar icon.
        • You can pause monitoring at any time from the ClipLink menu-bar icon.
        • The link is unguessable, but anyone who has it can download the file — keep that in mind for confidential documents.
        """, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .paragraphStyle: paragraph,
        ])
    }
}
