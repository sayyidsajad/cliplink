import AppKit
import ClipLinkCore

/// First-run explanation (FR-08): before monitoring starts, the user is told
/// exactly what gets uploaded, what never gets uploaded, and how to stop.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    var onStart: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
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

        let startButton = NSButton(title: "Start Monitoring", target: self, action: #selector(startAction(_:)))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
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
        container.addArrangedSubview(checkbox)
        container.addArrangedSubview(buttonRow)

        window.contentView = container
        for edge in [NSLayoutConstraint.Attribute.top, .bottom, .left, .right] {
            NSLayoutConstraint(item: container, attribute: edge, relatedBy: .equal,
                               toItem: window.contentView!, attribute: edge,
                               multiplier: 1, constant: 0).isActive = true
        }
        window.setContentSize(NSSize(width: 560, height: 470))
    }

    private var notificationsCheckbox: NSButton!
    private var startButton_: NSButton!

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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true // closing without starting keeps monitoring off — also a valid choice
    }

    private static func explanation() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 9
        return NSAttributedString(string: """
        When you copy a file in Finder, ClipLink uploads that file to your ClipLink backend and replaces the clipboard contents with a public download link. Anyone you paste the link to can download it in a browser — no app, no account.

        • Only files copied in Finder are uploaded. Text, passwords, screenshots and image data are ignored by design.
        • Files matching sensitive patterns (.env, private keys, wallets, …) are never uploaded.
        • Links expire automatically after 24 hours; the hosted file is deleted, and you can revoke any link from the menu-bar icon.
        • You can pause monitoring at any time from the ClipLink menu-bar icon.
        • The link is unguessable, but anyone who has it can download the file — keep that in mind for confidential documents.
        """, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .paragraphStyle: paragraph,
        ])
    }
}
