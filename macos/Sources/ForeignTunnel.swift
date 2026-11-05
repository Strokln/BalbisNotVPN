import Foundation
import Darwin

struct ForeignOptions {
    var enabled = false
    var youtube = true
    var region = "AUTO"
}
struct SessionConfig: Codable {
    let resources: String
    let dpiPort: UInt16
    let socksPort: UInt16
    let httpPort: UInt16
    let strategy: Int
    let sessionID: String
    let region: String
    let domainsFile: String
    var excludedFile: String? = nil
    var probeOnly: Bool? = nil
}

func foreignDomains(resources: URL, youtube: Bool, baseDomains: [String]? = nil) throws -> [String] {
    let root = resources.appendingPathComponent("routing")
    var rules = Set(try baseDomains ?? DomainRules.parse(String(contentsOf: root.appendingPathComponent("foreign.txt"), encoding: .utf8)))
    if !youtube {
        let video = DomainRules.parse(try String(contentsOf: root.appendingPathComponent("youtube.txt"), encoding: .utf8))
        rules = Set(rules.filter { host in
            !video.contains { host == $0 || host.hasSuffix("." + $0) }
        })
    }
    return rules.sorted()
}

func tcpReady(port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
}

struct ForeignProbe {
    let country: String
    let aiRegion: String
    static func parseTrace(_ body: String) throws -> String {
        let loc = body.components(separatedBy: .newlines).first { $0.hasPrefix("loc=") }.map { String($0.dropFirst(4)) } ?? ""
        guard loc.utf8.count == 2, loc.utf8.allSatisfy({ (65...90).contains($0) }) else { throw BalbisError("Не удалось определить страну выхода туннеля.") }
        guard !["RU", "BY", "IR", "KP", "SY", "CU"].contains(loc) else { throw BalbisError("Узел туннеля вернул неподходящую страну выхода: \(loc).") }
        return loc
    }
    static func classifyAPI(status: Int, body: String) -> String {
        let lower = body.lowercased()
        if status == 451 || ["unsupported_country", "country, region, or territory", "user location is not supported", "not available in your region", "not available in your country"].contains(where: lower.contains) { return "blocked" }
        if status == 200 || status == 401 { return "ok" }
        return "unknown"
    }
    static func shouldProbeAPI(foreignDomains: [String], directDomains: [String]) -> Bool {
        let host = "api.openai.com"
        func matches(_ domains: [String]) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }
        return matches(foreignDomains) && !matches(directDomains)
    }
    static func verify(httpPort: UInt16, socksPort: UInt16, directDomains: [String] = [], probeAPI: Bool = true) throws -> ForeignProbe {
        // Both probes explicitly use Balbis's local listeners, independent of system VPN/proxies.
        let trace = try command("/usr/bin/curl", ["-q", "--proxy", "http://127.0.0.1:\(httpPort)", "--noproxy", "", "--connect-timeout", "5", "--max-time", "12", "--max-filesize", "65536", "--fail", "--silent", "--show-error", "https://www.cloudflare.com/cdn-cgi/trace"])
        guard trace.status == 0 else { throw BalbisError("Зарубежный туннель не передаёт HTTPS. Попробуйте другой регион. " + String(trace.output.prefix(200))) }
        let country = try parseTrace(trace.output)
        // An explicit exclusion intentionally bypasses the foreign API route. Do not
        // reject that session because a direct request has a different region.
        if !probeAPI || directDomains.contains(where: { "api.openai.com" == $0 || "api.openai.com".hasSuffix("." + $0) }) {
            return ForeignProbe(country: country, aiRegion: "unknown")
        }
        // No API key, account cookies or user data are sent. 401 proves the API is reachable.
        let api = try command("/usr/bin/curl", ["-q", "--proxy", "socks5h://127.0.0.1:\(socksPort)", "--noproxy", "", "--connect-timeout", "5", "--max-time", "10", "--max-filesize", "65536", "--silent", "--show-error", "--write-out", "\n%{http_code}", "https://api.openai.com/v1/models"])
        let lines = api.output.components(separatedBy: .newlines)
        let classification = api.status == 0 ? classifyAPI(status: Int(lines.last ?? "") ?? 0, body: lines.dropLast().joined(separator: "\n")) : "unknown"
        guard classification != "blocked" else { throw BalbisError("Узел \(country) доступен, но OpenAI отклоняет его регион. Попробуйте другой регион.") }
        return ForeignProbe(country: country, aiRegion: classification)
    }
}

// One owner for all three children: parent EOF or any child failure stops the session.
func runTunnelSupervisor(config: SessionConfig) -> Int32 {
    guard let strategy = Strategy(rawValue: config.strategy), ["EU", "AM"].contains(config.region),
          config.dpiPort > 0, config.httpPort > 0, config.socksPort > 0 else { return 2 }
    let root = URL(fileURLWithPath: config.resources)
    let finished = DispatchSemaphore(value: 0)
    var children: [Process] = []
    var signals: [DispatchSourceSignal] = []
    let parentGone = DispatchSemaphore(value: 0)
    for number in [SIGTERM, SIGINT, SIGHUP] {
        // A caught no-op handler is reset by exec, unlike SIG_IGN inherited by children.
        signal(number, { _ in })
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { finished.signal() }; source.resume(); signals.append(source)
    }
    DispatchQueue.global().async {
        _ = FileHandle.standardInput.readDataToEndOfFile()
        parentGone.signal()
        finished.signal()
    }
    func checkCancellation() throws {
        if finished.wait(timeout: .now()) == .success { throw BalbisError("Сеанс завершён во время запуска.") }
    }
    func launch(_ name: String, _ arguments: [String], quiet: Bool = false) throws {
        let child = Process()
        child.executableURL = root.appendingPathComponent(name)
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = quiet ? FileHandle.nullDevice : FileHandle.standardError
        child.standardError = quiet ? FileHandle.nullDevice : FileHandle.standardError
        child.terminationHandler = { process in
            if config.probeOnly != true { ConnectionEvents.record("child-exit name=\(name) status=\(process.terminationStatus)") }
            finished.signal()
        }
        try child.run()
        children.append(child)
    }
    do {
        try launch("tpws", ["--bind-addr=127.0.0.1", "--port=\(config.dpiPort)", "--socks"] + strategy.arguments)
        // tpws also shapes the TLS connection to the overseas proxy. No route recursion.
        for _ in 0..<50 {
            try checkCancellation()
            if socksReady(port: config.dpiPort) { break }
            if !children[0].isRunning { throw BalbisError("DPI helper exited") }
            usleep(100_000)
        }
        guard socksReady(port: config.dpiPort) else { throw BalbisError("DPI helper did not start") }
        try checkCancellation()
        try launch("opera-proxy", ["-bind-address", "127.0.0.1:\(config.httpPort)", "-country", config.region,
            "-proxy", "socks5://127.0.0.1:\(config.dpiPort)", "-server-selection", "fastest",
            "-server-selection-timeout", "15s", "-server-selection-test-url", "https://www.cloudflare.com/cdn-cgi/trace",
            "-server-selection-dl-limit", "4096", "-init-retries", "1", "-timeout", "10s", "-verbosity", "50"], quiet: true)
        var routerArguments = ["-listen", "127.0.0.1:\(config.socksPort)", "-dpi", "127.0.0.1:\(config.dpiPort)",
            "-foreign", "127.0.0.1:\(config.httpPort)", "-domains", config.domainsFile]
        if let excludedFile = config.excludedFile { routerArguments += ["-direct-domains", excludedFile] }
        try launch("balbis-router", routerArguments)
        finished.wait()
    } catch { fputs("Не удалось запустить туннель: \(error.localizedDescription)\n", stderr) }
    signals.forEach { $0.cancel() }
    for child in children.reversed() where child.isRunning { child.terminate() }
    for _ in 0..<20 { if children.allSatisfy({ !$0.isRunning }) { break }; usleep(100_000) }
    for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL) }
    children.forEach { $0.waitUntilExit() }
    if parentGone.wait(timeout: .now()) == .success && config.probeOnly != true {
        do { try recoverSnapshot(expectedID: config.sessionID) }
        catch { fputs("Восстановление прокси: \(error.localizedDescription)\n", stderr) }
    }
    return 0
}

// AUTO compares verified region routes before the user session changes any PAC settings.
struct ExitCandidateScore: Equatable {
    let region: String
    let seconds: Double
    let downloadedBytes: Int
    var bytesPerSecond: Double? = nil
    var estimatedCost: Double {
        // Compare a verified request plus the estimated transfer time of 128 KiB.
        // An unavailable download is not evidence of a dead region.
        guard let rate = bytesPerSecond, rate.isFinite, rate > 0 else { return seconds + 1 }
        return seconds + 131_072 / rate
    }
}

enum ExitSelectionPolicy {
    static func orderedRegions(_ scores: [ExitCandidateScore]) -> [String] {
        let valid = scores.filter {
            ["EU", "AM"].contains($0.region) && $0.seconds.isFinite && $0.seconds > 0 &&
                (1...4096).contains($0.downloadedBytes)
        }
        let sorted = valid.sorted {
            if $0.estimatedCost == $1.estimatedCost { return $0.region == "EU" && $1.region != "EU" }
            return $0.estimatedCost < $1.estimatedCost
        }
        var result: [String] = []
        for region in sorted.map(\.region) + ["EU", "AM"] where !result.contains(region) { result.append(region) }
        return result
    }
}

// Every candidate owns its children, including a partially started candidate.
// No command shell is used and the cleanup deadline does not depend on child cooperation.
final class ExitCandidateProcesses {
    private(set) var children: [Process] = []
    private var lifelines: [Pipe] = []
    @discardableResult func launch(_ executable: URL, _ arguments: [String], lifeline: Bool = false) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = lifeline ? Pipe() : nil
        process.standardInput = pipe ?? FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        children.append(process)
        if let pipe = pipe {
            try? pipe.fileHandleForReading.close()
            lifelines.append(pipe)
        }
        return process
    }
    func stop() {
        lifelines.forEach { try? $0.fileHandleForWriting.close() }
        lifelines.removeAll()
        for child in children.reversed() where child.isRunning { child.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while children.contains(where: \.isRunning) && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
        for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL) }
        children.forEach { $0.waitUntilExit() }
        children.removeAll()
    }
    deinit { stop() }
}

private final class ExitCandidateResults {
    private let lock = NSLock()
    private var scores: [ExitCandidateScore] = []
    func append(_ value: ExitCandidateScore) { lock.lock(); defer { lock.unlock() }; scores.append(value) }
    func orderedRegions() -> [String] { lock.lock(); defer { lock.unlock() }; return ExitSelectionPolicy.orderedRegions(scores) }
}

enum AutomaticExitSelection {
    static func rankedRegions(resources: URL, strategy: Strategy, executable: String) -> [String] {
        let group = DispatchGroup()
        let results = ExitCandidateResults()
        // Independent candidates run concurrently on worker threads, never the GUI thread.
        for region in ["EU", "AM"] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                if let score = try? measure(region: region, resources: resources, strategy: strategy, executable: executable) { results.append(score) }
            }
        }
        group.wait()
        // Unmeasurable regions remain as last-resort fallbacks. Final session verification
        // still decides whether an actual connection may be reported as established.
        return results.orderedRegions()
    }

    private static func measure(region: String, resources: URL, strategy: Strategy, executable: String) throws -> ExitCandidateScore {
        let owned = ExitCandidateProcesses()
        defer { owned.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("balbis-exit-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { owned.stop(); try? FileManager.default.removeItem(at: directory) }
        var ports = Set<UInt16>()
        while ports.count < 3 { ports.insert(try availablePort()) }
        let selected = ports.sorted()
        let httpPort = selected[2]
        let domains = directory.appendingPathComponent("domains.txt")
        try Data().write(to: domains)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: domains.path)
        let config = SessionConfig(resources: resources.path, dpiPort: selected[0], socksPort: selected[1], httpPort: httpPort,
            strategy: strategy.rawValue, sessionID: UUID().uuidString, region: region, domainsFile: domains.path, excludedFile: nil, probeOnly: true)
        let file = directory.appendingPathComponent("session.json")
        try JSONEncoder().encode(config).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // Reuse the existing EOF-supervised child tree. If the app itself is killed,
        // the pipe closes and this supervisor still cleans up Opera, tpws and router.
        let supervisor = try owned.launch(URL(fileURLWithPath: executable), ["--tunnel-session", file.path], lifeline: true)
        let startupDeadline = ProcessInfo.processInfo.systemUptime + 27
        while supervisor.isRunning && ProcessInfo.processInfo.systemUptime < startupDeadline {
            if tcpReady(port: httpPort) && socksReady(port: selected[1]) { break }
            usleep(50_000)
        }
        guard supervisor.isRunning, tcpReady(port: httpPort), socksReady(port: selected[1]) else { throw BalbisError("Кандидат зарубежного выхода не готов.") }
        let result = try command("/usr/bin/curl", ["-q", "--proxy", "http://127.0.0.1:\(httpPort)", "--noproxy", "",
            "--connect-timeout", "3", "--max-time", "6", "--max-filesize", "4096", "--silent", "--show-error",
            "--write-out", "\nBALBIS_METRICS:%{http_code}:%{time_total}:%{size_download}", "https://www.cloudflare.com/cdn-cgi/trace"])
        guard result.status == 0, supervisor.isRunning,
              let marker = result.output.range(of: "\nBALBIS_METRICS:", options: .backwards) else {
            throw BalbisError("Кандидат не передаёт проверочный запрос.")
        }
        let body = String(result.output[..<marker.lowerBound])
        _ = try ForeignProbe.parseTrace(body)
        let metrics = result.output[marker.upperBound...].split(separator: ":")
        guard metrics.count == 3, metrics[0] == "200", let seconds = Double(metrics[1]), seconds.isFinite, seconds > 0,
              let bytes = Double(metrics[2]), bytes.isFinite, bytes >= 1, bytes <= 4096 else {
            throw BalbisError("Некорректный результат проверки кандидата.")
        }
        // This URL is the vendored backend's own default benchmark URL.
        // A denied/failed benchmark leaves the verified trace candidate eligible.
        var rate: Double?
        if let download = try? command("/usr/bin/curl", ["-q", "--proxy", "http://127.0.0.1:\(httpPort)", "--noproxy", "",
            "--connect-timeout", "2", "--max-time", "5", "--max-filesize", "262144", "--range", "0-262143",
            "--silent", "--show-error", "--output", "/dev/null", "--write-out", "\nBALBIS_SPEED:%{http_code}:%{time_total}:%{size_download}",
            "https://ajax.googleapis.com/ajax/libs/angularjs/1.8.2/angular.min.js"]), download.status == 0,
           let speedMarker = download.output.range(of: "\nBALBIS_SPEED:", options: .backwards) {
            let sample = download.output[speedMarker.upperBound...].split(separator: ":")
            if sample.count == 3, ["200", "206"].contains(String(sample[0])),
               let elapsed = Double(sample[1]), elapsed.isFinite, elapsed > 0,
               let count = Double(sample[2]), count.isFinite, (1024...262144).contains(count) {
                rate = count / elapsed
            }
        }
        guard supervisor.isRunning else { throw BalbisError("Кандидат завершился во время проверки.") }
        return ExitCandidateScore(region: region, seconds: seconds, downloadedBytes: Int(bytes), bytesPerSecond: rate)
    }
}
