import Foundation
import UserNotifications
import ClipLinkCore

/// Posts local user notifications. Only used when ClipLink runs inside a real
/// app bundle and only after the user opted in (FR-08).
final class SystemNotifier: ClipLinkNotifier {
    private let center: UNUserNotificationCenter?

    init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    var isEnabled = false

    func requestAuthorization() async {
        guard let center else {
            isEnabled = false
            return
        }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        await MainActor.run { isEnabled = granted }
    }

    func notifySuccess(title: String, message: String) {
        self.post(title: title, body: message)
    }

    func notifyFailure(title: String, message: String) {
        post(title: title, body: message)
    }

    private func post(title: String, body: String) {
        guard isEnabled, let center else {
            NSLog("ClipLink: %@ — %@", title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error { NSLog("ClipLink notification failed: %@", error.localizedDescription) }
        }
    }
}
