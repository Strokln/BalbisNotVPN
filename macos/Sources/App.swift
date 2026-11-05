import Cocoa
import SwiftUI
import CoreServices
import Network

final class PanelModel: ObservableObject {
    let notices = ConnectionNotices()
    let updates = UpdateChecker()
    @Published var shortcutAvailable = false
    @Published var problem: ConnectionProblem?
    private var recoveryNoticePolicy = RecoveryNoticePolicy()
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
                 return L("Маршрут отвечает.")
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
        if recoveryNeeded { message = L("Нужно восстановить настройки предыдущего подключения.") }
        runtime.onProgress = { [weak self] _ in
            DispatchQueue.main.async { self?.message = L("Подбираем доступное подключение…") }
        }
        runtime.onUnexpectedExit = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.busy { self.pendingExit = true; return }
                guard !self.runtime.isAlive else { return }
                self.perform(recoveryOperation: true) {
                    try self.runtime.stop()
                } completion: {
                    self.message = L("Соединение прервалось.")
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
        recoveryNoticePolicy.reset()
        reconnectPolicy.reset()
        notices.clear()
        reconnectPolicy.wanted = !connected && !waitingForNetwork
        retryTask?.cancel()
        retryTask = nil
        healthTask?.cancel()
        if waitingForNetwork {
            cancelStartupConnection()
            if !connected { return }
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
        problem = nil
        message = stopping ? L("Завершаем подключение…") : L("Подбираем доступное подключение…")
        perform(recoveryOperation: true) {
            if stopping { try self.runtime.stop() }
            else {
                if automatically {
                    let needsRecovery = FileManager.default.fileExists(atPath: journalURL.path)
                    if (selectedMode != 0 || needsRecovery) && !ProxyHelperClient.isReady() {
                        throw UserFacingError(message: L("Откройте Balbis и подключитесь вручную один раз, чтобы завершить настройку."),
                                              details: L("Для автоматического подключения служба должна быть установлена и готова."))
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
            self.connectionRecovered()
            self.diagnostics = self.connected
                ? "SOCKS5: 127.0.0.1:\(self.runtime.port)\nPAC: \(self.runtime.pacURL)\n\(self.runtime.foreignStatus)"
                : ""
        }
    }
    private func perform(recoveryOperation: Bool = false, _ operation: @escaping () throws -> Void, completion: @escaping () -> Void) {
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
                    if error is UserFacingError && self.connected && self.runtime.isAlive {
                        self.connectionRecovered()
                    }
                    let problem = ConnectionProblem.explain(error)
                    self.problem = problem
                    self.message = problem.message
                    self.diagnostics = error.localizedDescription
                    if recoveryOperation && !(error is UserFacingError) {
                        if self.automaticRecovery && self.reconnectPolicy.wanted && self.notices.enabled && self.recoveryNoticePolicy.recordFailure() {
                            self.notices.showProblem()
                        }
                        self.scheduleReconnect()
                    }
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
        if !repair { checkResult = L("Проверяем маршрут…") }
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
                    self.checkResult = failure == nil ? result : L("Проверка не удалась. Подробности доступны в диагностике.")
                    if failure == nil { self.recoveryNoticePolicy.reset(); self.notices.clear() }
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
        message = L("Повторим подключение через %d сек.", Int(delay))
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
        message = L("Восстанавливаем подключение…")
        perform(recoveryOperation: true) {
            try self.runtime.stop()
            guard let resources = Bundle.main.resourceURL, let executable = Bundle.main.executablePath else { throw BalbisError("Повреждён пакет приложения.") }
            try self.runtime.start(strategy: selectedStrategy, mode: selectedMode, service: selectedService, resources: resources, executable: executable, foreign: options)
        } completion: {
            self.message = L("Соединение восстановлено.")
            self.connectionRecovered()
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
        message = L("Меняем страну…")
        perform(recoveryOperation: true) {
            guard let resources = Bundle.main.resourceURL, let executable = Bundle.main.executablePath else { throw BalbisError("Повреждён пакет приложения.") }
            try self.runtime.stop()
            do {
                try self.runtime.start(strategy: selectedStrategy, mode: selectedMode, service: selectedService, resources: resources, executable: executable, foreign: ForeignOptions(enabled: useForeign, youtube: video, region: ["AUTO", "EU", "AM"][next]))
                DispatchQueue.main.async { self.region = next; self.persist() }
            } catch {
                let failure = error
                try self.runtime.stop()
                try self.runtime.start(strategy: selectedStrategy, mode: selectedMode, service: selectedService, resources: resources, executable: executable, foreign: ForeignOptions(enabled: useForeign, youtube: video, region: ["AUTO", "EU", "AM"][previous]))
                throw UserFacingError(message: L("Новая страна недоступна. Прежнее подключение восстановлено."), details: failure.localizedDescription)
            }
        } completion: { self.message = L("Страна изменена."); self.connectionRecovered() }
    }
    private func connectionRecovered() {
        problem = nil
        reconnectPolicy.reset()
        healthFailures.reset()
        recoveryNoticePolicy.reset()
        notices.clear()
    }
    func retryNow() {
        if busy { return }
        if connected && runtime.isAlive { checkConnection(); return }
        retryTask?.cancel()
        retryTask = nil
        cancelStartupConnection()
        reconnectPolicy.wanted = true
        reconnectPolicy.reset()
        if connected { reconnect() } else { changeConnection(automatically: false) }
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
        message = L("Восстанавливаем настройки…")
        perform { try recoverSnapshot() } completion: {
            self.message = L("Настройки восстановлены. Можно подключаться.")
        }
    }
    func removeHelper() {
        message = L("Удаляем службу подключения…")
        perform { try ProxyHelperClient.uninstall() } completion: {
            self.message = L("Служба удалена. При следующем подключении потребуется разрешение.")
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

// A narrow material veil softens the scroll viewport while leaving controls above it clickable.
private struct GlassScrollEdges: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if !reduceTransparency {
                    Rectangle().fill(.ultraThinMaterial)
                        .frame(height: 28)
                        .mask(LinearGradient(colors: [.clear, .white.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom).frame(height: 10)
                    Color.white
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom).frame(height: 22)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            header.layoutPriority(1)
            if model.settings {
                settingsPage
            } else {
                ViewThatFits(in: .vertical) {
                    homePage.padding(.top, 10).fixedSize(horizontal: false, vertical: true)
                    ScrollView { homePage.padding(.top, 10).padding(.bottom, 24) }
                        .scrollIndicators(.hidden).modifier(GlassScrollEdges())
                }.frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            }
            Spacer(minLength: 0)
            footer.layoutPriority(1)
        }
        .padding(20)
        .frame(width: 360, height: 640)
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
                Text(model.settings ? L("Настройки") : L("Свободнее в сети")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { model.settings.toggle() }
            } label: {
                Image(systemName: model.settings ? "xmark" : "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium)).frame(width: 32, height: 32)
                    .background(.white.opacity(0.08), in: Circle())
            }.buttonStyle(.plain).keyboardShortcut(",", modifiers: .command).help(model.settings ? L("Назад") : L("Настройки"))
                .accessibilityLabel(model.settings ? L("Вернуться к подключению") : L("Настройки"))
        }.frame(height: 38).padding(.bottom, 22)
    }
    private var homePage: some View {
        VStack(spacing: 18) {
            UpdateBannerView(updates: model.updates)
            VStack(spacing: 13) {
                powerButton
                HStack(spacing: 6) {
                    Circle().fill(model.busy ? Color.orange : accent).frame(width: 5, height: 5)
                    Text(model.waitingForNetwork ? L("Ждём подключения к сети") : model.busy ? L("Подождите немного") : model.connected ? L("Подключено") : L("Готов к подключению"))
                        .font(.system(size: 14, weight: .medium))
                        .accessibilityIdentifier("balbis.connection.status")
                }
                Text(model.waitingForNetwork ? L("Balbis подключится, когда сеть будет готова") : model.connected ? L("Можно открывать любимые сервисы") : L("Любимые сервисы — в одном нажатии"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.vertical, 6)

            if !model.busy && !model.waitingForNetwork && (!model.message.isEmpty || (model.recoveryNeeded && !model.connected)) {
                notice
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 3) {
                    routeButton(L("Избранное"), value: 1)
                    routeButton(L("Все сайты"), value: 2)
                    if model.mode == 0 { routeButton(L("Вручную"), value: 0) }
                }.padding(3).background(.black.opacity(0.14), in: Capsule())
                Text(model.mode == 2 ? L("Все сайты используют подключение Balbis.") :
                     model.mode == 0 ? L("Для приложений с ручной настройкой подключения.") :
                     L("Нейросети, YouTube и другие сервисы из списка."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.modifier(GlassCard()).disabled(model.busy || model.connected)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(L("YouTube через Balbis")).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Toggle(L("YouTube через Balbis"), isOn: $model.youtube).labelsHidden()
                        .toggleStyle(.switch).controlSize(.small)
                }
                Text(L("Включите, если видео не загружаются."))
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
        }.buttonStyle(.plain).accessibilityValue(model.mode == value ? L("Выбрано") : "")
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
                Text(model.waitingForNetwork ? L("Отменить") : model.busy ? L("Подождите…") : model.connected ? L("Отключить") : L("Подключить"))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.busy)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(model.waitingForNetwork ? L("Отменить автоматическое подключение") : model.connected ? L("Отключить Balbis") : L("Подключить Balbis"))
    }
    private var notice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.message.isEmpty ? L("Восстановите настройки предыдущего подключения.") : model.message)
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if let problem = model.problem {
                switch problem.action {
                case .retry: Button(L("Повторить"), action: model.retryNow).disabled(model.busy)
                case .settings: Button(L("Открыть настройки")) { model.settings = true }
                case .network: Button(L("Открыть настройки сети")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.network")!) }
                }
            }
            if model.recoveryNeeded && !model.connected {
                Button(L("Восстановить подключение"), action: model.recover).disabled(model.busy)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).modifier(GlassCard())
    }
    private var startupSettings: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(L("При запуске")).font(.system(size: 13, weight: .semibold))
            Toggle(L("Запускать вместе с macOS"), isOn: Binding(
                get: { model.loginItemState == .enabled || model.loginItemState == .requiresApproval },
                set: { model.setLaunchAtLogin($0) }
            )).toggleStyle(.switch).controlSize(.small).disabled(model.loginItemBusy)
            if model.loginItemState == .requiresApproval {
                Text(L("Разрешите автозапуск в настройках macOS.")).font(.system(size: 11)).foregroundStyle(.secondary)
                Button(L("Открыть настройки macOS"), action: model.openLoginSettings).buttonStyle(.link)
            }
            if !model.loginItemMessage.isEmpty {
                Text(model.loginItemMessage).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider().opacity(0.35)
            Toggle(L("Подключаться автоматически"), isOn: $model.autoConnect).toggleStyle(.switch).controlSize(.small)
            Text(L("При открытии Balbis, когда появится сеть."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.font(.system(size: 12)).modifier(GlassCard())
    }
    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                startupSettings
                DisclosureGroup(L("Обновления и клавиатура")) {
                VStack(alignment: .leading, spacing: 12) {
                UpdateSettingsView(updates: model.updates)
                Divider().opacity(0.35)
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("Клавиатура")).font(.system(size: 13, weight: .semibold))
                    Text(model.shortcutAvailable ? L("⇧⌘B — открыть Balbis из любого приложения") : L("⇧⌘B недоступно: сочетание занято другой программой."))
                    Text(L("⌘Return — подключить или отключить · ⌘, — настройки · Esc — назад или закрыть"))
                    Text(L("Для перехода по всем элементам включите навигацию клавиатурой в настройках macOS.")).foregroundStyle(.secondary)
                }.font(.system(size: 11))
                }.padding(.top, 10)
                }.font(.system(size: 12)).modifier(GlassCard())
                }
                VStack(alignment: .leading, spacing: 12) {
                    Button(model.checkingConnection ? L("Проверяем…") : L("Проверить подключение")) { model.checkConnection() }.disabled(model.busy || model.checkingConnection || !model.connected)
                    if !model.checkResult.isEmpty { Text(model.checkResult).font(.system(size: 11)).textSelection(.enabled) }
                    Toggle(L("Восстанавливать при обрыве"), isOn: $model.automaticRecovery).toggleStyle(.switch).controlSize(.small)
                }.modifier(GlassCard())
                ConnectionNoticeSettingsView(notices: model.notices).modifier(GlassCard())
                CustomSitesView().modifier(GlassCard())
                ExcludedSitesView().modifier(GlassCard())
                BuiltInSitesView().modifier(GlassCard())
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Подключение")).font(.system(size: 13, weight: .semibold))
                    Picker(L("Страна"), selection: Binding(get: { model.region }, set: { model.changeRegion($0) })) {
                        Text(L("Автоматически")).tag(0)
                        Text(L("Европа")).tag(1)
                        Text(L("США")).tag(2)
                    }
                    .disabled(model.busy)
                    Toggle(L("Зарубежное подключение"), isOn: $model.foreign).toggleStyle(.switch).controlSize(.small).disabled(model.busy || model.connected)
                    Text(L("Нужно для сервисов, недоступных в вашей стране."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if model.connected { Text(L("Страну можно менять с автоматическим переподключением.")).font(.system(size: 11)).foregroundStyle(.secondary) }
                }.modifier(GlassCard())

                DisclosureGroup(L("Дополнительно")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(L("Режим"), selection: $model.mode) {
                            Text(L("Избранные сервисы")).tag(1)
                            Text(L("Все сайты")).tag(2)
                            Text(L("Ручная настройка")).tag(0)
                        }
                        Picker(L("Способ обхода"), selection: $model.strategy) {
                            Text(L("Универсальный")).tag(0)
                            Text(L("Альтернативный")).tag(1)
                            Text(L("Для защищённых сайтов")).tag(2)
                        }
                        Text(L("Попробуйте другой способ, если сайты не открываются."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker(L("Сеть"), selection: $model.service) {
                            ForEach(model.services, id: \.self) { Text($0).tag($0) }
                        }.disabled(model.mode == 0)
                    }.padding(.top, 12).disabled(model.busy || model.connected)
                }.font(.system(size: 12)).modifier(GlassCard())

                DisclosureGroup(L("Диагностика")) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !model.diagnostics.isEmpty {
                            Text(model.diagnostics).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        }
                        Button(L("Скопировать сведения"), action: model.copyDiagnostics).disabled(model.diagnostics.isEmpty)
                        Button(L("Открыть журнал"), action: model.openLog)
                        Button(L("Причины переподключений")) {
                            NSWorkspace.shared.open(supportDirectory.appendingPathComponent("connection-events.log"))
                        }
                        Button(L("Удалить службу подключения"), action: model.removeHelper)
                            .disabled(model.busy || model.connected || model.recoveryNeeded)
                        Button(L("Восстановить настройки"), action: model.recover).disabled(model.busy || model.connected || !model.recoveryNeeded)
                        DiagnosticReportView(snapshot: DiagnosticSnapshot(
                            connected: model.connected,
                            mode: ["Ручная настройка", "Избранное", "Все сайты"][max(0, min(2, model.mode))],
                            region: ["AUTO", "EU", "AM"][model.region],
                            automaticRecovery: model.automaticRecovery,
                            strategy: String(model.strategy),
                            foreignEnabled: model.foreign
                        ))
                    }.padding(.top, 10)
                }.font(.system(size: 12)).modifier(GlassCard())
                Button(L("Открыть инструкцию"), action: model.openHelp).buttonStyle(.link).font(.system(size: 12))
            }.padding(.top, 10).padding(.bottom, 24)
        }.frame(minHeight: 0, maxHeight: .infinity).modifier(GlassScrollEdges())
    }
    private var footer: some View {
        HStack {
            Text("Balbis by Strokin").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            Spacer()
            if model.settings {
                Text("0.10.0").font(.system(size: 10)).foregroundStyle(.tertiary)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").font(.system(size: 12)) }
                    .buttonStyle(.plain).help(L("Завершить Balbis")).disabled(model.busy)
            } else {
                Image(systemName: "lock.shield").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(.top, 20)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = PanelModel()
    private let popover = NSPopover()
    private let shortcut = PanelShortcut()
    private var keyMonitor: Any?
    private var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.setAccessibilityLabel("Balbis")
        let controller = NSHostingController(rootView: BalbisPanel(model: model))
        controller.view.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 360, height: 640)
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        model.stateChanged = { [weak self] in self?.updateStatus() }
        updateStatus()
        model.notices.onRetry = { [weak self] in self?.showPanel(); self?.model.retryNow() }
        model.notices.onSettings = { [weak self] in self?.model.settings = true; self?.showPanel() }
        model.notices.configure()
        model.updates.onAvailable = { [weak self] in self?.showPanel() }
        model.updates.check()
        shortcut.onOpen = { [weak self] in self?.togglePanel() }
        model.shortcutAvailable = shortcut.register()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.popover.isShown, event.keyCode == 53 else { return event }
            if self.popover.contentViewController?.view.window?.firstResponder is NSTextView {
                self.popover.contentViewController?.view.window?.makeFirstResponder(nil)
            } else if self.model.settings { self.model.settings = false } else { self.popover.performClose(nil) }
            return nil
        }
        model.observeConnection()
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if model.autoConnect { model.beginStartupConnection() }
        else if !loginLaunch { showPanel() }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshLoginItem()
        model.notices.refreshAuthorization()
    }
    private func updateStatus() {
        let symbol = model.connected ? "shield.lefthalf.filled" : "shield"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Balbis")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = model.connected ? L("Balbis · Подключено") : L("Balbis · Отключено")
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
                    self.model.message = L("Не удалось восстановить настройки. Повторите выход.")
                    self.showPanel()
                    sender.reply(toApplicationShouldTerminate: false)
                } else { sender.reply(toApplicationShouldTerminate: true) }
            }
        }
        return .terminateLater
    }
}
