import Cocoa
import SwiftUI
import UserNotifications

struct RecoveryNoticePolicy {
    private(set) var failures = 0
    private var notified = false
    mutating func recordFailure() -> Bool {
        failures = min(3, failures + 1)
        guard failures == 3, !notified else { return false }
        notified = true
        return true
    }
    mutating func reset() { failures = 0; notified = false }
}

final class ConnectionNotices: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "connectionNotices")
    @Published private(set) var requesting = false
    @Published private(set) var status = ""
    var onRetry: (() -> Void)?
    var onSettings: (() -> Void)?
    private lazy var center = UNUserNotificationCenter.current()
    private var authorizationGeneration = 0
    private let identifier = "balbis.connection.problem"

    func configure() {
        center.delegate = self
        let retry = UNNotificationAction(identifier: "retry", title: L("Повторить"), options: [.foreground])
        let settings = UNNotificationAction(identifier: "settings", title: L("Открыть настройки"), options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "connectionProblem", actions: [retry, settings], intentIdentifiers: [])])
    }

    func refreshAuthorization() {
        guard enabled, !requesting else { return }
        let generation = authorizationGeneration
        center.getNotificationSettings { settings in
            self.finishAuthorization(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
                                     generation: generation)
        }
    }
    func setEnabled(_ value: Bool) {
        guard !requesting || !value else { return }
        authorizationGeneration += 1
        let generation = authorizationGeneration
        if !value {
            clear()
            enabled = false
            requesting = false
            status = ""
            UserDefaults.standard.set(false, forKey: "connectionNotices")
            return
        }
        requesting = true
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                guard generation == self.authorizationGeneration else { return }
                if settings.authorizationStatus == .notDetermined {
                    self.center.requestAuthorization(options: [.alert, .sound]) { allowed, _ in
                        self.finishAuthorization(allowed, generation: generation)
                    }
                } else {
                    self.finishAuthorization(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
                                             generation: generation)
                }
            }
        }
    }
    private func finishAuthorization(_ allowed: Bool, generation: Int) {
        DispatchQueue.main.async {
            guard generation == self.authorizationGeneration else { return }
            self.enabled = allowed
            self.requesting = false
            self.status = allowed ? "" : L("Разрешите уведомления Balbis в системных настройках macOS → Уведомления.")
            UserDefaults.standard.set(allowed, forKey: "connectionNotices")
        }
    }
    func showProblem() {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Balbis не удалось восстановить соединение")
        content.body = L("Несколько попыток не удались. Balbis продолжает восстановление. Можно повторить сейчас или открыть настройки.")
        content.categoryIdentifier = "connectionProblem"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if error != nil { ConnectionEvents.record("notification-delivery-failed") }
        }
    }
    func clear() {
        guard enabled else { return }
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            switch response.actionIdentifier {
            case "retry": self.onRetry?()
            case "settings", UNNotificationDefaultActionIdentifier: self.onSettings?()
            default: break
            }
            completionHandler()
        }
    }
}

struct ConnectionNoticeSettingsView: View {
    @ObservedObject var notices: ConnectionNotices
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("Уведомлять о сбоях"), isOn: Binding(get: { notices.enabled }, set: { notices.setEnabled($0) }))
                .toggleStyle(.switch).controlSize(.small).disabled(notices.requesting)
            Text(L("После нескольких неудачных попыток восстановления. Повторные уведомления появятся только после нового обрыва."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !notices.status.isEmpty { Text(notices.status).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}
