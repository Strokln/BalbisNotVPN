import Foundation
import Darwin

struct BalbisError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct UserFacingError: LocalizedError {
    let message: String
    let details: String
    var errorDescription: String? { details }
}

struct CommandResult {
    let status: Int32
    let output: String
}

@discardableResult
func command(_ path: String, _ args: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "LANG": "C"]) { _, new in new }
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleQuote(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
}

protocol NetworkSettings {
    func read(_ args: [String]) throws -> String
    func apply(_ commands: [[String]]) throws
    func installProxy(_ snapshot: ProxySnapshot) throws
    func restoreProxy(_ snapshot: ProxySnapshot) throws
}
extension NetworkSettings {
    func installProxy(_ snapshot: ProxySnapshot) throws {
        try apply([["-setautoproxyurl", snapshot.service, snapshot.balbisURL], ["-setautoproxystate", snapshot.service, "on"]])
    }
    func restoreProxy(_ snapshot: ProxySnapshot) throws { try snapshot.restoreLegacy(network: self) }
}
struct SystemNetworkSettings: NetworkSettings {
    func read(_ args: [String]) throws -> String {
        let result = try command("/usr/sbin/networksetup", args)
        guard result.status == 0, !result.output.contains("Error:") else { throw BalbisError(result.output) }
        return result.output
    }
    func installProxy(_ snapshot: ProxySnapshot) throws { try ProxyHelperClient.install(snapshot) }
    func restoreProxy(_ snapshot: ProxySnapshot) throws {
        if try !ProxyHelperClient.restore(snapshot) {
            // Pre-helper sessions still need their original authorized restoration.
            try snapshot.restoreLegacy(network: self)
        }
    }
    func apply(_ commands: [[String]]) throws {
        // Only fixed networksetup commands and separately shell-quoted arguments enter the script.
        let script = "set -e\n" + commands.map { "/usr/sbin/networksetup " + $0.map(shellQuote).joined(separator: " ") }.joined(separator: "\n")
        let result = try command("/usr/bin/osascript", ["-e", "do shell script " + appleQuote(script) + " with administrator privileges"])
        guard result.status == 0, !result.output.contains("Error:") else { throw BalbisError("Не удалось изменить настройки прокси. " + result.output) }
    }
}

func fields(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in text.components(separatedBy: .newlines) {
        if let separator = line.firstIndex(of: ":") {
            result[String(line[..<separator])] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
    }
    return result
}

struct ProxySnapshot: Codable {
    let sessionID: String
    let service: String
    let originalURL: String
    let originalEnabled: Bool
    let balbisURL: String
    enum CodingKeys: String, CodingKey {
        case sessionID, service, originalURL, originalEnabled
        case balbisURL = "novaURL" // Compatibility with existing recovery journals.
    }

    static func capture(service: String, balbisURL: String, sessionID: String = UUID().uuidString, network: NetworkSettings) throws -> ProxySnapshot {
        guard !service.isEmpty else { throw BalbisError("Выберите сетевую службу.") }
        for flag in ["-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy", "-getproxyautodiscovery"] {
            let info = try network.read([flag, service])
            if fields(info)["Enabled"] == "Yes" || info.contains("Auto Proxy Discovery: On") {
                throw UserFacingError(message: "Подключением управляет другой VPN. Отключите его перед подключением Balbis.",
                                      details: "В службе «\(service)» уже включён прокси или автообнаружение. Для работы вместе с VPN доступен режим ручной настройки.")
            }
        }
        let before = fields(try network.read(["-getautoproxyurl", service]))
        guard let url = before["URL"], let enabled = before["Enabled"], ["Yes", "No"].contains(enabled) else {
            throw BalbisError("Не удалось прочитать текущие настройки PAC.")
        }
        return ProxySnapshot(sessionID: sessionID, service: service, originalURL: url == "(null)" ? "" : url,
                             originalEnabled: enabled == "Yes", balbisURL: balbisURL)
    }
    func install(network: NetworkSettings) throws {
        try network.installProxy(self)
    }
    func restore(network: NetworkSettings) throws { try network.restoreProxy(self) }
    func restoreLegacy(network: NetworkSettings) throws {
        let current = fields(try network.read(["-getautoproxyurl", service]))
        guard current["URL"] == balbisURL else { return } // A newer user/VPN configuration owns the setting now.
        guard let enabled = current["Enabled"], ["Yes", "No"].contains(enabled) else {
            throw BalbisError("Не удалось прочитать состояние PAC для восстановления.")
        }
        // networksetup rejects an empty URL. If no PAC was configured before Balbis,
        // restoring the disabled state is sufficient; leave the inactive URL alone.
        guard !originalEnabled || !originalURL.isEmpty else {
            throw BalbisError("В журнале восстановления отсутствует адрес ранее включённого PAC.")
        }
        var operations: [[String]] = []
        if enabled == "Yes" { operations.append(["-setautoproxystate", service, "off"]) }
        if !originalURL.isEmpty { operations.append(["-setautoproxyurl", service, originalURL]) }
        if originalEnabled { operations.append(["-setautoproxystate", service, "on"]) }
        if !operations.isEmpty { try network.apply(operations) }
    }
}

struct DomainRules {
    let included: [String]
    let excluded: [String]
    static func parse(_ text: String) -> [String] {
        var domains = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            let value = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty, value.count <= 253, !value.hasPrefix("."), !value.hasSuffix("."), !value.contains(".."),
                  value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
                  value.split(separator: ".").allSatisfy({ !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.count <= 63 }) else { continue }
            domains.insert(value)
        }
        return domains.sorted()
    }
    static func load(from directory: URL) throws -> DomainRules {
        let names = ["main", "youtube", "ai", "discord", "telegram", "whatsapp", "cloudflare", "second", "rkn"]
        var all: [String] = []
        for name in names {
            all += parse(try String(contentsOf: directory.appendingPathComponent(name + ".txt"), encoding: .utf8))
        }
        return DomainRules(included: Array(Set(all)).sorted(), excluded: parse(try String(contentsOf: directory.appendingPathComponent("exclude.txt"), encoding: .utf8)))
    }
    func pac(port: UInt16, allSites: Bool, foreign: [String] = []) throws -> String {
        let allow = String(decoding: try JSONEncoder().encode(included), as: UTF8.self)
        let foreignJSON = String(decoding: try JSONEncoder().encode(foreign.sorted()), as: UTF8.self)
        let bypass = String(decoding: try JSONEncoder().encode(excluded), as: UTF8.self)
        return """
        var balbisDomains = \(allow), balbisExclude = \(bypass), balbisForeign = \(foreignJSON);
        function balbisMatch(host, domains) {
            var parts = host.split('.');
            for (var i = 0; i < parts.length; i++) {
                var name = parts.slice(i).join('.'), lo = 0, hi = domains.length - 1;
                while (lo <= hi) {
                    var mid = (lo + hi) >> 1;
                    if (domains[mid] === name) return true;
                    if (domains[mid] < name) lo = mid + 1; else hi = mid - 1;
                }
            }
            return false;
        }
        function FindProxyForURL(url, host) {
            host = host.toLowerCase().replace(/\\.$/, '');
            // Do not resolve DNS in PAC: this would leak queries and block browser requests.
            if (isPlainHostName(host) || host === 'localhost' || /\\.local$/.test(host) ||
                host.indexOf(':') >= 0 || /^[0-9.]+$/.test(host)) return 'DIRECT';
            // CFNetwork on Ventura ignores SOCKS5 PAC entries. The foreign router
            // also accepts HTTP CONNECT for encrypted traffic on the same port.
            var proxy = (\(foreign.isEmpty ? "false" : "true") && /^(https|wss):/i.test(url)
                ? 'PROXY' : 'SOCKS5') + ' 127.0.0.1:\(port)';
            if (balbisMatch(host, balbisForeign)) return proxy;
            if (balbisMatch(host, balbisExclude)) return 'DIRECT';
            if (\(allSites ? "true" : "false") || balbisMatch(host, balbisDomains)) return proxy;
            return 'DIRECT';
        }
        """
    }
}

let supportDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Balbis macOS", isDirectory: true)
let journalURL = supportDirectory.appendingPathComponent("proxy-session.json")

func saveSnapshot(_ snapshot: ProxySnapshot) throws {
    try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(snapshot).write(to: journalURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
}
func recoverSnapshot(network: NetworkSettings = SystemNetworkSettings(), expectedID: String? = nil, at url: URL = journalURL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let lockFD = open(directory.appendingPathComponent("recovery.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard lockFD >= 0 else { throw BalbisError("Не удалось заблокировать журнал восстановления.") }
    defer { close(lockFD) }
    guard flock(lockFD, LOCK_EX) == 0 else { throw BalbisError("Журнал восстановления занят.") }
    defer { flock(lockFD, LOCK_UN) }
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let snapshot = try JSONDecoder().decode(ProxySnapshot.self, from: Data(contentsOf: url))
    if let expected = expectedID, snapshot.sessionID != expected { return }
    try snapshot.restore(network: network)
    try FileManager.default.removeItem(at: url)
}
