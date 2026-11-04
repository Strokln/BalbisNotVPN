import Cocoa
import SwiftUI
import CoreServices
import Network

final class PanelModel: ObservableObject {
    @Published var automaticRecovery = UserDefaults.standard.object(forKey: "automaticRecovery") == nil || UserDefaults.standard.bool(forKey: "automaticRecovery")
    @Published var checkResult = ""
    @Published var checkingConnection = false
    private var healthFailures = HealthFailurePolicy()
    private let connectionProbe: (UInt16, UInt16, Bool) throws -> String
    private var reconnectPolicy = ReconnectPolicy()
    private var retryTask: DispatchWorkItem?
    private var healthTask: DispatchWorkItem?
    private var healthTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    @Published var autoConnect = UserDefaults.standard.bool(forKey: "autoConnect")
    @Published var loginItemState = LoginItemState.disabled
    @Published var loginItemBusy = false
    @Published var loginItemMessage = ""
    @Published var waitingForNetwork = false
    private let loginItem: LoginItemManaging
    private let startupConnection = StartupConnection()
    @Published var connected = false
    @Published var busy = false
    @Published var settings = false
    @Published var mode = 1
    @Published var strategy = 0
    @Published var service = ""
    @Published var services: [String] = []
    @Published var foreign = UserDefaults.standard.object(forKey: "foreignEnabled") == nil || UserDefaults.standard.bool(forKey: "foreignEnabled")
    @Published var youtube = UserDefaults.standard.object(forKey: "youtubeTunnel") == nil || UserDefaults.standard.bool(forKey: "youtubeTunnel")
    @Published var region = max(0, min(2, UserDefaults.standard.integer(forKey: "foreignRegion")))
    @Published var message = ""
    @Published var diagnostics = ""
    @Published var recoveryNeeded = FileManager.default.fileExists(atPath: journalURL.path)
    let runtime = BalbisRuntime()
    let queue = DispatchQueue(label: "balbis.lifecycle")
    var pendingExit = false
    var quitting = false
    var stateChanged: (() -> Void)?

    init(loginItem: LoginItemManaging = SystemLoginItem(),
         connectionProbe: @escaping (UInt16, UInt16, Bool) throws -> String = { port, foreignPort, background in
             if background {
                 try ConnectionHealth.transportAlive(port: port, foreignPort: foreignPort)
                 return "Маршрут отвечает."
             }
             return try ConnectionHealth.check(port: port, foreignPort: foreignPort)
         }) {
        self.connectionProbe = connectionProbe
        self.loginItem = loginItem
        loginItemState = loginItem.state
        let defaults = UserDefaults.standard
        if let savedMode = defaults.object(forKey: "connectionMode") as? Int, (0...2).contains(savedMode) {
            mode = savedMode
        }
        if let savedStrategy = defaults.object(forKey: "connectionStrategy") as? Int,
           Strategy(rawValue: savedStrategy) != nil {
            strategy = savedStrategy
        }
        do {
            let output = try SystemNetworkSettings().read(["-listallnetworkservices"])
            services = output.components(separatedBy: .newlines).dropFirst().filter { !$0.isEmpty && !$0.hasPrefix("*") }
            if let savedService = defaults.string(forKey: "networkService"), services.contains(savedService) {
                service = savedService
            } else {
                service = services.contains("Wi-Fi") ? "Wi-Fi" : services.first ?? ""
            }
        } catch { diagnostics = error.localizedDescription }
        if recoveryNeeded { message = "Нужно восстановить настройки предыдущего подключения." }
        runtime.onProgress = { [weak self] _ in
            DispatchQueue.main.async { self?.message = "Подбираем доступное подключение…" }
        }
        runtime.onUnexpectedExit = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.busy { self.pendingExit = true; return }
                guard !self.runtime.isAlive else { return }
                self.perform {
                    try self.runtime.stop()
                } completion: {
                    self.message = "Соединение прервалось."
                    self.scheduleReconnect()
                }
            }
        }
    }
    func persist() {
        UserDefaults.standard.set(mode, forKey: "connectionMode")
        UserDefaults.standard.set(strategy, forKey: "connectionStrategy")
        UserDefaults.standard.set(service, forKey: "networkService")
        UserDefaults.standard.set(foreign, forKey: "foreignEnabled")
        UserDefaults.standard.set(youtube, forKey: "youtubeTunnel")
        UserDefaults.standard.set(region, forKey: "foreignRegion")
    }
    func refreshLoginItem() { loginItemState = loginItem.state }
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !loginItemBusy else { return }
        loginItemBusy = true
        loginItemMessage = ""
        queue.async {
            var failure: Error?
            do { try self.loginItem.setEnabled(enabled) } catch { failure = error }
            let state = self.loginItem.state
            DispatchQueue.main.async {
                self.loginItemBusy = false
                self.loginItemState = state
                if let error = failure { self.loginItemMessage = error.localizedDescription }
            }
        }
    }
    func openLoginSettings() { loginItem.openSettings() }
    func autoConnectChanged() {
        UserDefaults.standard.set(autoConnect, forKey: "autoConnect")
        if !autoConnect { cancelStartupConnection() }
    }
    func beginStartupConnection() {
        guard autoConnect, !busy, !connected else { return }
        waitingForNetwork = true
        startupConnection.waitForNetwork { [weak self] in
            guard let self = self else { return }
            self.waitingForNetwork = false
            guard self.autoConnect, !self.connected, !self.busy else { return }
            self.reconnectPolicy.wanted = true
            self.changeConnection(automatically: true)
        }
    }
    func cancelStartupConnection() {
        startupConnection.cancel()
        waitingForNetwork = false
    }
    func toggle() {
        reconnectPolicy.wanted = !connected && !waitingForNetwork
        retryTask?.cancel()
        retryTask = nil
        healthTask?.cancel()
        if waitingForNetwork {
            cancelStartupConnection()
            return
        }
        ConnectionEvents.record(reconnectPolicy.wanted ? "user-connect" : "user-disconnect")
        changeConnection(automatically: false)
    }
    private func changeConnection(automatically: Bool) {
        guard !busy else { return }
        persist()
        let stopping = connected
        let selectedMode = mode
        let selectedService = service
        let selectedStrategy = Strategy(rawValue: strategy) ?? .balanced
        let options = ForeignOptions(enabled: foreign, youtube: youtube, region: ["AUTO", "EU", "AM"][region])
        message = stopping ? "Завершаем подключение…" : "Подбираем доступное подключение…"
        perform {
            if stopping { try self.runtime.stop() }
            else {
                if automatically {
                    let needsRecovery = FileManager.default.fileExists(atPath: journalURL.path)
                    if (selectedMode != 0 || needsRecovery) && !ProxyHelperClient.isReady() {
                        throw UserFacingError(message: "Откройте Balbis и подключитесь вручную один раз, чтобы завершить настройку.",
                                              details: "Для автоматического подключения служба должна быть установлена и готова.")
                    }
                    if needsRecovery { try recoverSnapshot() }
                }
                guard let resources = Bundle.main.resourceURL, let executable = Bundle.main.executablePath else {
                    throw BalbisError("Повреждён пакет приложения.")
                }
                try self.runtime.start(strategy: selectedStrategy, mode: selectedMode, service: selectedService,
                                       resources: resources, executable: executable, foreign: options)
            }
        } completion: {
            self.message = ""
            self.checkResult = ""
            self.reconnectPolicy.reset()
            self.healthFailures.reset()
            self.diagnostics = self.connected
                ? "SOCKS5: 127.0.0.1:\(self.runtime.port)\nPAC: \(self.runtime.pacURL)\n\(self.runtime.foreignStatus)"
                : ""
        }
    }
    private func perform(_ operation: @escaping () throws -> Void, completion: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        stateChanged?()
        queue.async {
            var failure: Error?
            do { try operation() } catch { failure = error }
            DispatchQueue.main.async {
                self.busy = false
                self.connected = self.runtime.isRunning
                self.recoveryNeeded = FileManager.default.fileExists(atPath: journalURL.path)
                if let error = failure {
                    self.message = (error as? UserFacingError)?.message
                        ?? "Не удалось подключиться. Проверьте сеть или выберите другую страну в настройках."
                    self.diagnostics = error.localizedDescription
                    if !(error is UserFacingError) { self.scheduleReconnect() }
                } else { completion() }
                self.stateChanged?()
                if self.pendingExit {
                    self.pendingExit = false
                    if self.runtime.isRunning && !self.runtime.isAlive { self.runtime.onUnexpectedExit?() }
                }
            }
        }
    }
    func observeConnection() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleHealthCheck() }
        }
        monitor.start(queue: DispatchQueue(label: "balbis.recovery.network"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleHealthCheck()
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.scheduleHealthCheck() }
    }
    func recoveryChanged() {
        UserDefaults.standard.set(automaticRecovery, forKey: "automaticRecovery")
        if !automaticRecovery, retryTask != nil {
            retryTask?.cancel()
            retryTask = nil
            waitingForNetwork = false
        }
    }
    private func scheduleHealthCheck() {
        guard automaticRecovery, reconnectPolicy.wanted else { return }
        healthTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.checkConnection(repair: true) }
        healthTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }
    func checkConnection(repair: Bool = false) {
        guard !waitingForNetwork, !checkingConnection else { return }
        guard !busy, connected else {
            if repair && !busy { scheduleReconnect() }
            return
        }
        let port = runtime.port
        let foreignPort = runtime.foreignHTTPPort
        checkingConnection = true
        if !repair { checkResult = "Проверяем маршрут…" }
        queue.async {
            var result = ""
            var failure: Error?
            do { result = try self.connectionProbe(port, foreignPort, repair) }
            catch { failure = error }
            DispatchQueue.main.async {
                self.checkingConnection = false
                // Ignore a probe from the preceding connection or a user-requested transition.
                guard !self.busy, self.connected, self.runtime.port == port else { return }
                if !repair {
                    self.checkResult = failure == nil ? result : "Проверка не удалась. Подробности доступны в диагностике."
                }
                if let error = failure { self.diagnostics = error.localizedDescription }
                if self.pendingExit {
                    self.pendingExit = false
                    if !self.runtime.isAlive { self.runtime.onUnexpectedExit?() }
                    return
                }
                if repair {
                    let shouldRecover = self.healthFailures.record(success: failure == nil)
                    if failure != nil { ConnectionEvents.record("transport-probe-failed count=\(self.healthFailures.failures)") }
                    if shouldRecover && self.automaticRecovery && self.reconnectPolicy.wanted {
                        self.healthFailures.reset()
                        ConnectionEvents.record("reconnect-reason=consecutive-transport-failures")
                        self.reconnect()
                    }
                }
            }
        }
    }
    private func scheduleReconnect() {
        guard automaticRecovery, !quitting, retryTask == nil, let delay = reconnectPolicy.nextDelay() else { return }
        retryTask?.cancel()
        waitingForNetwork = true
        message = "Повторим подключение через \(Int(delay)) сек."
        let task = DispatchWorkItem { [weak self] in
            guard let self = self, self.reconnectPolicy.wanted, self.automaticRecovery, !self.quitting else { return }
            self.retryTask = nil
            self.waitingForNetwork = false
            if self.busy { self.scheduleReconnect(); return }
            self.reconnect()
        }
        retryTask = task
        ConnectionEvents.record("reconnect-scheduled delay=\(Int(delay))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    private func reconnect() {
        guard !busy, reconnectPolicy.wanted else { return }
        if !connected { changeConnection(automatically: true); return }
        let selectedMode = mode
        let selectedService = service
        let selectedStrategy = Strategy(rawValue: strategy) ?? .balanced
        let options = ForeignOptions(enabled: foreign, youtube: youtube, region: ["AUTO", "EU", "AM"][region])
        message = "Восстанавливаем подключение…"
        perform {
            try self.runtime.stop()
            guard let resources = Bundle.main.resourceURL, let executable = Bundle.main.executablePath else { throw BalbisError("Повреждён пакет приложения.") }
            try self.runtime.start(strategy: selectedStrategy, mode: selectedMode, service: selectedService, resources: resources, executable: executable, foreign: options)
        } completion: {
            self.message = "Соединение восстановлено."
            self.reconnectPolicy.reset()
        }
    }
    func changeRegion(_ next: Int) {
        guard (0...2).contains(next), !busy, next != region else { return }
        let previous = region
        if !connected { region = next; persist(); return }
        retryTask?.cancel()
        retryTask = nil
        waitingForNetwork = false
        let selectedMode = mode
        let selectedService = service
        let selectedStrategy = Strategy(rawValue: strategy) ?? .balanced
        let video = youtube
        let useForeign = foreign
        message = "Меняем страну…"
        perform {
            guard let resources = Bundle.main.resourceURL, let executable = Bundle.main.executablePath else { throw BalbisError("Повреждён пакет приложения.") }
            try self.runtime.stop()
            do {
                try self.runtime.start(strategy: selectedStrategy, mode: selectedMode, service: selectedService, resources: resources, executable: executable, foreign: ForeignOptions(enabled: useForeign, youtube: video, region: ["AUTO", "EU", "AM"][next]))
                DispatchQueue.main.async { self.region = next; self.persist() }
            } catch {
                let failure = error
                try self.runtime.stop()
                try self.runtime.start(strategy: selectedStrategy, mode: selectedMode, service: selectedService, resources: resources, executable: executable, foreign: ForeignOptions(enabled: useForeign, youtube: video, region: ["AUTO", "EU", "AM"][previous]))
                throw UserFacingError(message: "Новая страна недоступна. Прежнее подключение восстановлено.", details: failure.localizedDescription)
            }
        } completion: { self.message = "Страна изменена."; self.reconnectPolicy.reset() }
    }
    func prepareToQuit() {
        reconnectPolicy.wanted = false
        retryTask?.cancel()
        healthTask?.cancel()
        healthTimer?.invalidate()
        pathMonitor?.cancel()
        if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        cancelStartupConnection()
    }
    func recover() {
        message = "Восстанавливаем настройки…"
        perform { try recoverSnapshot() } completion: {
            self.message = "Настройки восстановлены. Можно подключаться."
        }
    }
    func removeHelper() {
        message = "Удаляем службу подключения…"
        perform { try ProxyHelperClient.uninstall() } completion: {
            self.message = "Служба удалена. При следующем подключении потребуется разрешение."
        }
    }
    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }
    func openLog() { NSWorkspace.shared.open(supportDirectory.appendingPathComponent("engine.log")) }
    func openHelp() {
        if let url = Bundle.main.url(forResource: "README-macOS", withExtension: "txt") { NSWorkspace.shared.open(url) }
    }
}

private struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.10)))
    }
}

struct BalbisPanel: View {
    @ObservedObject var model: PanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let blue = Color(red: 0.34, green: 0.65, blue: 1)
    private let mint = Color(red: 0.40, green: 0.90, blue: 0.74)
    private var accent: Color { model.connected ? mint : blue }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.settings {
                settingsPage
            } else {
                ScrollView { homePage.padding(.bottom, 2) }.scrollIndicators(.hidden)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 360, height: 560)
        .background {
            ZStack(alignment: .topTrailing) {
                GlassBackground()
                LinearGradient(colors: [Color(red: 0.06, green: 0.12, blue: 0.24).opacity(0.65), .black.opacity(0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }.allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.13)))
        .preferredColorScheme(.dark)
        .tint(blue)
        .onChange(of: model.automaticRecovery) { _ in model.recoveryChanged() }
        .onChange(of: model.autoConnect) { _ in model.autoConnectChanged() }
        .onChange(of: model.mode) { _ in model.persist() }
        .onChange(of: model.strategy) { _ in model.persist() }
        .onChange(of: model.service) { _ in model.persist() }
        .onChange(of: model.foreign) { _ in model.persist() }
        .onChange(of: model.youtube) { _ in model.persist() }
        .onChange(of: model.region) { _ in model.persist() }
    }
    private var header: some View {
        HStack(spacing: 10) {
            if let url = Bundle.main.url(forResource: "Balbis", withExtension: "icns"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().frame(width: 35, height: 35).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Balbis").font(.system(size: 19, weight: .semibold, design: .rounded))
                Text(model.settings ? "Настройки" : "Свободнее в сети").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { model.settings.toggle() }
            } label: {
                Image(systemName: model.settings ? "xmark" : "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium)).frame(width: 32, height: 32)
                    .background(.white.opacity(0.08), in: Circle())
            }.buttonStyle(.plain).help(model.settings ? "Назад" : "Настройки")
                .accessibilityLabel(model.settings ? "Вернуться к подключению" : "Настройки")
        }.padding(.bottom, 22)
    }
    private var homePage: some View {
        VStack(spacing: 18) {
            VStack(spacing: 13) {
                powerButton
                HStack(spacing: 6) {
                    Circle().fill(model.busy ? Color.orange : accent).frame(width: 5, height: 5)
                    Text(model.waitingForNetwork ? "Ждём подключения к сети" : model.busy ? "Подождите немного" : model.connected ? "Подключено" : "Готов к подключению")
                        .font(.system(size: 14, weight: .medium))
                        .accessibilityIdentifier("balbis.connection.status")
                }
                Text(model.waitingForNetwork ? "Balbis подключится, когда сеть будет готова" : model.connected ? "Можно открывать любимые сервисы" : "Любимые сервисы — в одном нажатии")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.vertical, 6)

            if !model.busy && !model.waitingForNetwork && (!model.message.isEmpty || (model.recoveryNeeded && !model.connected)) {
                notice
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 3) {
                    routeButton("Избранное", value: 1)
                    routeButton("Все сайты", value: 2)
                    if model.mode == 0 { routeButton("Вручную", value: 0) }
                }.padding(3).background(.black.opacity(0.14), in: Capsule())
                Text(model.mode == 2 ? "Все сайты используют подключение Balbis." :
                     model.mode == 0 ? "Для приложений с ручной настройкой подключения." :
                     "Нейросети, YouTube и другие сервисы из списка.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.modifier(GlassCard()).disabled(model.busy || model.connected)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("YouTube через Balbis").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Toggle("YouTube через Balbis", isOn: $model.youtube).labelsHidden()
                        .toggleStyle(.switch).controlSize(.small)
                }
                Text("Включите, если видео не загружаются.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.modifier(GlassCard()).disabled(model.busy || model.connected || !model.foreign)

        }
    }
    private func routeButton(_ title: String, value: Int) -> some View {
        Button { model.mode = value } label: {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.mode == value ? Color.white : Color.white.opacity(0.55))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(.white.opacity(model.mode == value ? 0.14 : 0), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(model.mode == value ? 0.15 : 0)))
                .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityValue(model.mode == value ? "Выбрано" : "")
    }
    private var powerButton: some View {
        Button(action: model.toggle) {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [accent.opacity(0.26), accent.opacity(0.04)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.5), accent.opacity(0.14)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    if model.busy || model.waitingForNetwork {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: "power").font(.system(size: 34, weight: .light)).foregroundStyle(accent)
                    }
                }.frame(width: 102, height: 102)
                    .shadow(color: accent.opacity(0.16), radius: 24, y: 6)
                Text(model.waitingForNetwork ? "Отменить" : model.busy ? "Подождите…" : model.connected ? "Отключить" : "Подключить")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.busy)
            .accessibilityLabel(model.waitingForNetwork ? "Отменить автоматическое подключение" : model.connected ? "Отключить Balbis" : "Подключить Balbis")
    }
    private var notice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.message.isEmpty ? "Восстановите настройки предыдущего подключения." : model.message)
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if model.recoveryNeeded && !model.connected {
                Button("Восстановить подключение", action: model.recover).disabled(model.busy)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).modifier(GlassCard())
    }
    private var startupSettings: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("При запуске").font(.system(size: 13, weight: .semibold))
            Toggle("Запускать вместе с macOS", isOn: Binding(
                get: { model.loginItemState == .enabled || model.loginItemState == .requiresApproval },
                set: { model.setLaunchAtLogin($0) }
            )).toggleStyle(.switch).controlSize(.small).disabled(model.loginItemBusy)
            if model.loginItemState == .requiresApproval {
                Text("Разрешите автозапуск в настройках macOS.").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Открыть настройки macOS", action: model.openLoginSettings).buttonStyle(.link)
            }
            if !model.loginItemMessage.isEmpty {
                Text(model.loginItemMessage).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider().opacity(0.35)
            Toggle("Подключаться автоматически", isOn: $model.autoConnect).toggleStyle(.switch).controlSize(.small)
            Text("При открытии Balbis, когда появится сеть.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.font(.system(size: 12)).modifier(GlassCard())
    }
    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                startupSettings
                VStack(alignment: .leading, spacing: 12) {
                    Button(model.checkingConnection ? "Проверяем…" : "Проверить подключение") { model.checkConnection() }.disabled(model.busy || model.checkingConnection || !model.connected)
                    if !model.checkResult.isEmpty { Text(model.checkResult).font(.system(size: 11)).textSelection(.enabled) }
                    Toggle("Восстанавливать при обрыве", isOn: $model.automaticRecovery).toggleStyle(.switch).controlSize(.small)
                }.modifier(GlassCard())
                CustomSitesView().modifier(GlassCard())
                VStack(alignment: .leading, spacing: 12) {
                    Text("Подключение").font(.system(size: 13, weight: .semibold))
                    Picker("Страна", selection: Binding(get: { model.region }, set: { model.changeRegion($0) })) {
                        Text("Автоматически").tag(0)
                        Text("Европа").tag(1)
                        Text("США").tag(2)
                    }
                    .disabled(model.busy)
                    Toggle("Зарубежное подключение", isOn: $model.foreign).toggleStyle(.switch).controlSize(.small).disabled(model.busy || model.connected)
                    Text("Нужно для сервисов, недоступных в вашей стране.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if model.connected { Text("Страну можно менять с автоматическим переподключением.").font(.system(size: 11)).foregroundStyle(.secondary) }
                }.modifier(GlassCard())

                DisclosureGroup("Дополнительно") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Режим", selection: $model.mode) {
                            Text("Избранные сервисы").tag(1)
                            Text("Все сайты").tag(2)
                            Text("Ручная настройка").tag(0)
                        }
                        Picker("Способ обхода", selection: $model.strategy) {
                            Text("Универсальный").tag(0)
                            Text("Альтернативный").tag(1)
                            Text("Для защищённых сайтов").tag(2)
                        }
                        Text("Попробуйте другой способ, если сайты не открываются.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker("Сеть", selection: $model.service) {
                            ForEach(model.services, id: \.self) { Text($0).tag($0) }
                        }.disabled(model.mode == 0)
                    }.padding(.top, 12).disabled(model.busy || model.connected)
                }.font(.system(size: 12)).modifier(GlassCard())

                DisclosureGroup("Диагностика") {
                    VStack(alignment: .leading, spacing: 10) {
                        if !model.diagnostics.isEmpty {
                            Text(model.diagnostics).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        }
                        Button("Скопировать сведения", action: model.copyDiagnostics).disabled(model.diagnostics.isEmpty)
                        Button("Открыть журнал", action: model.openLog)
                        Button("Причины переподключений") {
                            NSWorkspace.shared.open(supportDirectory.appendingPathComponent("connection-events.log"))
                        }
                        Button("Удалить службу подключения", action: model.removeHelper)
                            .disabled(model.busy || model.connected || model.recoveryNeeded)
                        Button("Восстановить настройки", action: model.recover).disabled(model.busy || model.connected || !model.recoveryNeeded)
                    }.padding(.top, 10)
                }.font(.system(size: 12)).modifier(GlassCard())
                Button("Открыть инструкцию", action: model.openHelp).buttonStyle(.link).font(.system(size: 12))
            }
        }.frame(maxHeight: .infinity)
    }
    private var footer: some View {
        HStack {
            Text("Balbis by Strokin").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            Spacer()
            if model.settings {
                Text("0.7.1").font(.system(size: 10)).foregroundStyle(.tertiary)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").font(.system(size: 12)) }
                    .buttonStyle(.plain).help("Завершить Balbis").disabled(model.busy)
            } else {
                Image(systemName: "lock.shield").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(.top, 20)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = PanelModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.setAccessibilityLabel("Balbis")
        let controller = NSHostingController(rootView: BalbisPanel(model: model))
        controller.view.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 360, height: 560)
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        model.stateChanged = { [weak self] in self?.updateStatus() }
        updateStatus()
        model.observeConnection()
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if model.autoConnect { model.beginStartupConnection() }
        else if !loginLaunch { showPanel() }
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshLoginItem() }
    private func updateStatus() {
        let symbol = model.connected ? "shield.lefthalf.filled" : "shield"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Balbis")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = model.connected ? "Balbis · Подключено" : "Balbis · Отключено"
    }
    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }
    private func showPanel() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.quitting else { return .terminateLater }
        guard !model.busy else { NSSound.beep(); return .terminateCancel }
        model.prepareToQuit()
        model.quitting = true
        model.busy = true
        model.queue.async {
            var failure: Error?
            do { try self.model.runtime.stop() } catch { failure = error }
            DispatchQueue.main.async {
                if let error = failure {
                    self.model.quitting = false
                    self.model.busy = false
                    self.model.diagnostics = error.localizedDescription
                    self.model.message = "Не удалось восстановить настройки. Повторите выход."
                    self.showPanel()
                    sender.reply(toApplicationShouldTerminate: false)
                } else { sender.reply(toApplicationShouldTerminate: true) }
            }
        }
        return .terminateLater
    }
}
