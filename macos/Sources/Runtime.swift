import Foundation
import Darwin

enum Strategy: Int, CaseIterable {
    case balanced, split, tls
    var name: String {
        switch self { case .balanced: return "Сегментация TCP + TLS"; case .split: return "Только сегментация TCP"; case .tls: return "Только разделение TLS" }
    }
    var arguments: [String] {
        switch self {
        case .balanced: return ["--split-pos=1,midsld", "--tlsrec=sniext+1"]
        case .split: return ["--split-pos=1,midsld"]
        case .tls: return ["--tlsrec=sniext+1"]
        }
    }
}

func availablePort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BalbisError("Не удалось создать сокет.") }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard bound == 0 else { throw BalbisError("Не удалось выбрать локальный порт.") }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
    guard result == 0 else { throw BalbisError("Не удалось определить локальный порт.") }
    return UInt16(bigEndian: address.sin_port)
}
func socksReady(port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard result == 0 else { return false }
    let greeting: [UInt8] = [5, 1, 0]
    guard greeting.withUnsafeBytes({ send(fd, $0.baseAddress, 3, 0) }) == 3 else { return false }
    var reply: [UInt8] = [0, 0]
    let count = reply.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 2, MSG_WAITALL) }
    return count == 2 && reply == [5, 0]
}

func runSupervisor(engine: String, port: String, strategy: Strategy, sessionID: String) -> Int32 {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: engine)
    child.arguments = ["--bind-addr=127.0.0.1", "--port=\(port)", "--socks"] + strategy.arguments
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.standardError
    child.standardError = FileHandle.standardError
    let finished = DispatchSemaphore(value: 0)
    child.terminationHandler = { _ in finished.signal() }
    do { try child.run() }
    catch { fputs("\(error)\n", stderr); return 1 }
    var sources: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { finished.signal() }
        source.resume()
        sources.append(source)
    }
    // Recover only on parent EOF. A spontaneous engine/helper exit is handled by the
    // GUI, avoiding simultaneous privileged rollback while the GUI installs PAC.
    DispatchQueue.global().async {
        _ = FileHandle.standardInput.readDataToEndOfFile()
        do { try recoverSnapshot(expectedID: sessionID) }
        catch { fputs("Восстановление прокси: \(error.localizedDescription)\n", stderr) }
        finished.signal()
    }
    finished.wait()
    sources.forEach { $0.cancel() }
    if child.isRunning {
        child.terminate()
        for _ in 0..<20 { if !child.isRunning { break }; usleep(100_000) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }
    child.waitUntilExit()
    return 0
}

final class BalbisRuntime {
    private var sessionID = UUID().uuidString
    private var supervisor: Process?
    private var lifeline: Pipe?
    private var pacServer: PACServer?
    private var logHandle: FileHandle?
    private var sessionDirectory: URL?
    private(set) var port: UInt16 = 0
    private(set) var pacURL: String = ""
    private(set) var foreignHTTPPort: UInt16 = 0
    private(set) var foreignStatus: String = ""
    var onUnexpectedExit: (() -> Void)?
    var onProgress: ((String) -> Void)?

    func start(strategy: Strategy, mode: Int, service: String, resources: URL, executable: String, foreign: ForeignOptions = ForeignOptions()) throws {
        guard supervisor == nil else { throw BalbisError("Balbis уже работает.") }
        guard !FileManager.default.fileExists(atPath: journalURL.path) else {
            throw BalbisError("Остались настройки предыдущего сеанса. Сначала нажмите «Восстановить прокси».")
        }
        sessionID = UUID().uuidString
        ConnectionEvents.record("session-start mode=\(mode) region=\(foreign.region)")
        foreignStatus = ""
        var ports = Set<UInt16>()
        while ports.count < 3 { ports.insert(try availablePort()) }
        let selectedPorts = ports.sorted()
        port = selectedPorts[0]
        let dpiPort = selectedPorts[1], httpPort = selectedPorts[2]
        let baseDomains = try BuiltInSitesStore.load()
        let excludedDomains = try ExcludedSitesStore.load()
        let domains = foreign.enabled ? Array(Set(try foreignDomains(resources: resources, youtube: foreign.youtube, baseDomains: baseDomains) + CustomSitesStore.load())).sorted() : []
        foreignHTTPPort = foreign.enabled ? httpPort : 0
        let rules = try DomainRules.load(from: resources.appendingPathComponent("list"), baseDomains: baseDomains)
        let server = PACServer(script: try rules.pac(port: port, allSites: mode == 2, foreign: domains, directDomains: excludedDomains, useHTTPProxy: foreign.enabled))
        try server.start()
        server.onFailure = { [weak self] in self?.onUnexpectedExit?() }
        pacServer = server
        pacURL = "http://127.0.0.1:\(server.port)\(server.path)"
        do {
            let snapshot = mode == 0 ? nil : try ProxySnapshot.capture(service: service, balbisURL: pacURL, sessionID: sessionID, network: SystemNetworkSettings())
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let log = supportDirectory.appendingPathComponent("engine.log")
            try Data().write(to: log, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
            logHandle = try FileHandle(forWritingTo: log)
            let regions = foreign.enabled ? (foreign.region == "AUTO" ? ["EU", "AM"] : [foreign.region]) : [""]
            var started = false
            var lastError: Error = BalbisError("Туннель не запустился.")
            for region in regions {
                do {
                    var args = ["--supervise", resources.appendingPathComponent("tpws").path, String(port), String(strategy.rawValue), sessionID]
                    if foreign.enabled {
                        onProgress?("Подключение зарубежного выхода: \(region == "EU" ? "Европа" : "США")…")
                        let directory = supportDirectory.appendingPathComponent("sessions/" + UUID().uuidString)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        sessionDirectory = directory
                        let domainsFile = directory.appendingPathComponent("foreign.txt")
                        try domains.joined(separator: "\n").write(to: domainsFile, atomically: true, encoding: .utf8)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: domainsFile.path)
                        let excludedFile = directory.appendingPathComponent("direct.txt")
                        try excludedDomains.joined(separator: "\n").write(to: excludedFile, atomically: true, encoding: .utf8)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: excludedFile.path)
                        let config = SessionConfig(resources: resources.path, dpiPort: dpiPort, socksPort: port, httpPort: httpPort, strategy: strategy.rawValue, sessionID: sessionID, region: region, domainsFile: domainsFile.path, excludedFile: excludedFile.path)
                        let file = directory.appendingPathComponent("session.json")
                        try JSONEncoder().encode(config).write(to: file, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                        args = ["--tunnel-session", file.path]
                    }
                    try launchHelper(executable: executable, arguments: args)
                    guard let process = supervisor else { throw BalbisError("Не удалось запустить процесс Balbis.") }
                    var ready = false
                    for _ in 0..<(foreign.enabled ? 400 : 50) {
                        if !process.isRunning { throw BalbisError("Движок завершился при запуске. Проверьте доступность зарубежного сервиса или выберите другой регион.") }
                        if socksReady(port: port) && (!foreign.enabled || tcpReady(port: httpPort)) { ready = true; break }
                        usleep(100_000)
                    }
                    guard ready else { throw BalbisError("Не удалось дождаться готовности туннеля. Попробуйте другой регион.") }
                    if foreign.enabled {
                        onProgress?("Проверка зарубежного IP и маршрута нейросетей…")
                        let probe = try ForeignProbe.verify(httpPort: httpPort, socksPort: port, directDomains: excludedDomains, probeAPI: ForeignProbe.shouldProbeAPI(foreignDomains: domains, directDomains: excludedDomains))
                        foreignStatus = "Выход: \(probe.country) · OpenAI: \(probe.aiRegion == "ok" ? "регион доступен" : "требует проверки в браузере")"
                    }
                    guard process.isRunning && socksReady(port: port) else { throw BalbisError("Маршрутизатор остановился во время проверки.") }
                    started = true
                    break
                } catch {
                    lastError = error
                    stopHelper()
                }
            }
            guard started else { throw lastError }
            if let snapshot = snapshot {
                try saveSnapshot(snapshot)
                try snapshot.install(network: SystemNetworkSettings())
            }
            supervisor?.terminationHandler = { [weak self] process in
                ConnectionEvents.record("supervisor-exit status=\(process.terminationStatus)")
                self?.onUnexpectedExit?()
            }
            guard supervisor?.isRunning == true && socksReady(port: port) && server.isReady else {
                throw BalbisError("Движок или PAC-сервер остановился во время подключения.")
            }
        } catch {
            do { try recoverSnapshot(expectedID: sessionID) }
            catch { throw BalbisError("Не удалось восстановить прокси: \(error.localizedDescription). Повторите отключение или восстановление.") }
            cleanup()
            throw error
        }
    }
    private func launchHelper(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        try? pipe.fileHandleForReading.close()
        supervisor = process
        lifeline = pipe
    }
    func stop() throws {
        ConnectionEvents.record("session-stop")
        try recoverSnapshot(expectedID: sessionID)
        cleanup()
    }
    private func stopHelper() {
        supervisor?.terminationHandler = nil
        try? lifeline?.fileHandleForWriting.close()
        lifeline = nil
        supervisor?.waitUntilExit()
        supervisor = nil
        if let directory = sessionDirectory { try? FileManager.default.removeItem(at: directory) }
        sessionDirectory = nil
    }
    private func cleanup() {
        stopHelper()
        pacServer?.stop()
        pacServer = nil
        try? logHandle?.close()
        logHandle = nil
        port = 0
        foreignHTTPPort = 0
        pacURL = ""
        foreignStatus = ""
    }
    var isAlive: Bool { supervisor?.isRunning == true && pacServer?.isReady == true }
    var isRunning: Bool { supervisor != nil }
}
