import Cocoa

if CommandLine.arguments == [CommandLine.arguments[0], "--install-proxy-helper"] {
    do {
        try ProxyHelperClient.ensureInstalled()
        print("Служба подключения Balbis готова.")
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.count == 6 && CommandLine.arguments[1] == "--supervise" {
    guard let raw = Int(CommandLine.arguments[4]), let strategy = Strategy(rawValue: raw),
          let port = UInt16(CommandLine.arguments[3]), port > 0 else { exit(2) }
    exit(runSupervisor(engine: CommandLine.arguments[2], port: String(port), strategy: strategy, sessionID: CommandLine.arguments[5]))
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--tunnel-session" {
    do {
        let config = try JSONDecoder().decode(SessionConfig.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        exit(runTunnelSupervisor(config: config))
    } catch { fputs("Не удалось прочитать конфигурацию туннеля.\n", stderr); exit(2) }
}
// Transfer the previous installation only after its supervisor and GUI have exited.
let previousDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Nova macOS", isDirectory: true)
if FileManager.default.fileExists(atPath: previousDirectory.path) {
    let previousLock = open(previousDirectory.appendingPathComponent("app.lock").path, O_RDWR | O_CLOEXEC)
    if previousLock >= 0 {
        guard flock(previousLock, LOCK_EX | LOCK_NB) == 0 else {
            let alert = NSAlert()
            alert.messageText = "Сначала завершите предыдущую версию"
            alert.informativeText = "Выберите «Завершить» в меню работающего приложения, затем откройте Balbis."
            alert.runModal()
            exit(1)
        }
        defer { close(previousLock) }
        if !FileManager.default.fileExists(atPath: supportDirectory.path) {
            try FileManager.default.moveItem(at: previousDirectory, to: supportDirectory)
        }
    }
}
// A second app instance must not compete for the same recovery journal.
try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let appLockFD = open(supportDirectory.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
guard appLockFD >= 0, flock(appLockFD, LOCK_EX | LOCK_NB) == 0 else {
    fputs("Balbis is already running. Use its menu bar icon.\n", stderr)
    exit(1)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
