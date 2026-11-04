import Foundation

private final class FakeLoginItem: LoginItemManaging {
    var state = LoginItemState.disabled
    var reject = false
    var settingsOpened = false
    func setEnabled(_ enabled: Bool) throws {
        if reject { throw BalbisError("Проверка отказа регистрации") }
        state = enabled ? .enabled : .disabled
    }
    func openSettings() { settingsOpened = true }
}

@main
struct StartupSettingsTests {
    static func finish(_ model: PanelModel) {
        let deadline = Date().addingTimeInterval(3)
        while model.loginItemBusy && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(!model.loginItemBusy, "Login-item operation timed out")
    }
    static func main() {
        let login = FakeLoginItem()
        let model = PanelModel(loginItem: login)
        precondition(model.loginItemState == .disabled)
        model.setLaunchAtLogin(true)
        finish(model)
        precondition(model.loginItemState == .enabled)
        login.state = .requiresApproval
        model.refreshLoginItem()
        precondition(model.loginItemState == .requiresApproval, "Pending approval must remain visible")
        model.setLaunchAtLogin(false)
        finish(model)
        precondition(model.loginItemState == .disabled)
        login.reject = true
        model.setLaunchAtLogin(true)
        finish(model)
        precondition(model.loginItemState == .disabled && !model.loginItemMessage.isEmpty)
        model.openLoginSettings()
        precondition(login.settingsOpened)
        model.autoConnect = true
        model.autoConnectChanged()
        precondition(PanelModel(loginItem: login).autoConnect)
        model.autoConnect = false
        model.autoConnectChanged()
        precondition(!PanelModel(loginItem: login).autoConnect)
        let probeGate = DispatchSemaphore(value: 0)
        let health = PanelModel(loginItem: login, connectionProbe: { _, _, _ in
            _ = probeGate.wait(timeout: .now() + 2)
            return "HTTP 403: транспорт отвечает"
        })
        health.connected = true
        health.checkConnection()
        precondition(health.checkingConnection && !health.busy && health.connected,
                     "A background check must not look like a disconnection")
        probeGate.signal()
        let probeDeadline = Date().addingTimeInterval(3)
        while health.checkingConnection && Date() < probeDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(!health.checkingConnection && health.connected && !health.busy)
        precondition(health.checkResult.contains("403"))
        print("PASS: health probe preserves connection status")
        print("PASS: startup preference persists; login registration handles approval, rejection and external changes")
    }
}
