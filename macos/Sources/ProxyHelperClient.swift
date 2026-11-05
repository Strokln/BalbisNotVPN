import Foundation
import Darwin
import CryptoKit

enum ProxyHelperClient {
    static let directory = "/Library/PrivilegedHelperTools/local.balbis.proxy"
    static let executable = directory + "/helper"
    static let daemon = "/Library/LaunchDaemons/local.balbis.proxy.plist"
    static let socketPath = "/var/run/local.balbis.proxy.sock"

    // Both installation and removal take this root-owned, crash-recoverable lock.
    static let installationLockScript = """
    /usr/bin/shlock -f /var/run/local.balbis.proxy.install.lock -p $$ || { echo 'Установка службы уже выполняется.' >&2; exit 1; }
    """
    static let stopServiceScript = """
    if /bin/launchctl print system/local.balbis.proxy >/dev/null 2>&1; then
        /bin/launchctl bootout system '\(daemon)'
    else
        launch_status=$?
        if test "$launch_status" -ne 113; then echo 'Не удалось проверить состояние службы.' >&2; exit 1; fi
    fi
    """

    static func exchange(_ request: HelperRequest) throws -> HelperResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BalbisError("Не удалось открыть связь со службой подключения.") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw BalbisError("Служба подключения недоступна. Повторите попытку.") }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else {
            throw BalbisError("Не удалось проверить службу подключения.")
        }
        var payload = try JSONEncoder().encode(request)
        payload.append(10)
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BalbisError("Связь со службой подключения прервалась.") }
                offset += count
            }
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < 16_384 {
            let count = recv(fd, &buffer, min(buffer.count, 16_384 - data.count), 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BalbisError("Служба подключения не ответила вовремя.") }
            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 10) {
                let response = try JSONDecoder().decode(HelperResponse.self, from: data.prefix(upTo: newline))
                if !response.success {
                    switch response.message {
                    case "Another PAC is enabled":
                        throw UserFacingError(message: "В macOS уже включено другое подключение. Завершите его или восстановите настройки.",
                                              details: response.message)
                    case "Conflicting proxy configuration":
                        throw UserFacingError(message: "Подключением управляет другой VPN. Отключите его перед подключением Balbis.",
                                              details: response.message)
                    default: throw BalbisError(response.message)
                    }
                }
                return response
            }
        }
        throw BalbisError("Некорректный ответ службы подключения.")
    }

    static func isReady() -> Bool {
        guard let response = try? exchange(HelperRequest(operation: "ping", service: "", pacURL: "", sessionID: "")) else { return false }
        return response.message == String(helperProtocolVersion)
    }

    private static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func ensureInstalled() throws {
        if isReady() { return }
        // A launchd restart should not turn a transient disconnect into another password prompt.
        if FileManager.default.fileExists(atPath: executable) {
            for _ in 0..<15 {
                usleep(200_000)
                if isReady() { return }
            }
        }
        guard let source = Bundle.main.url(forResource: "balbis-proxy-helper", withExtension: nil) else {
            throw BalbisError("В приложении отсутствует служба подключения. Установите полную сборку Balbis.")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("balbis-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let config = staging.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: ["uid": Int(getuid())]).write(to: config, options: .atomic)
        let plist = staging.appendingPathComponent("daemon.plist")
        let properties: [String: Any] = [
            "Label": "local.balbis.proxy",
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 3,
            "ProcessType": "Background"
        ]
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: plist, options: .atomic)
        let rootStage = "/Library/PrivilegedHelperTools/.balbis-install-" + UUID().uuidString
        // Copy into a root-only staging directory and verify all bytes before launchd uses them.
        // No user-writable executable or launchd property list is ever run as the installed service.
        var lines = [
            "set -eu",
            installationLockScript,
            "trap " + shellQuote("/bin/rm -f /var/run/local.balbis.proxy.install.lock; /bin/rm -rf " + shellQuote(rootStage)) + " EXIT",
            "test ! -L " + shellQuote(directory),
            "if test -e " + shellQuote(directory + "/journal.json") + "; then echo 'Сначала восстановите прежнее подключение Balbis.' >&2; exit 1; fi",
            "/usr/bin/install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools",
            "/usr/bin/install -d -o root -g wheel -m 0700 " + shellQuote(rootStage)
        ]
        for (input, name, mode) in [(source, "helper", "0755"), (config, "config.json", "0600"), (plist, "daemon.plist", "0644")] {
            let output = rootStage + "/" + name
            lines.append("/usr/bin/install -o root -g wheel -m " + mode + " " + shellQuote(input.path) + " " + shellQuote(output))
            lines.append("test \"$(/usr/bin/shasum -a 256 " + shellQuote(output) + " | /usr/bin/awk '{print $1}')\" = " + shellQuote(try digest(input)))
        }
        lines += [
            "/usr/bin/codesign --verify --strict " + shellQuote(rootStage + "/helper"),
            stopServiceScript,
            shellQuote(rootStage + "/helper") + " --check-stopped",
            "if test -e " + shellQuote(directory + "/journal.json") + "; then /bin/launchctl bootstrap system " + shellQuote(daemon) + " >/dev/null 2>&1 || true; echo 'Сначала восстановите прежнее подключение Balbis.' >&2; exit 1; fi",
            "/usr/bin/install -d -o root -g wheel -m 0755 " + shellQuote(directory),
            "/bin/mv -f " + shellQuote(rootStage + "/helper") + " " + shellQuote(executable),
            "/bin/mv -f " + shellQuote(rootStage + "/config.json") + " " + shellQuote(directory + "/config.json"),
            "/bin/mv -f " + shellQuote(rootStage + "/daemon.plist") + " " + shellQuote(daemon),
            "/bin/launchctl bootstrap system " + shellQuote(daemon)
        ]
        let script = "do shell script " + appleQuote(lines.joined(separator: "\n")) + " with administrator privileges"
        let result = try command("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else {
            throw BalbisError("Не удалось установить службу подключения. %@", result.output)
        }
        for _ in 0..<25 {
            if isReady() { return }
            usleep(200_000)
        }
        throw BalbisError("Служба установлена, но ещё не готова. Повторите подключение.")
    }

    static func install(_ snapshot: ProxySnapshot) throws {
        try ensureInstalled()
        _ = try exchange(HelperRequest(operation: "install", service: snapshot.service, pacURL: snapshot.balbisURL, sessionID: snapshot.sessionID))
    }

    static func restore(_ snapshot: ProxySnapshot) throws -> Bool {
        if !FileManager.default.fileExists(atPath: executable) { return false }
        for _ in 0..<15 {
            if isReady() { break }
            usleep(200_000)
        }
        let response = try exchange(HelperRequest(operation: "restore", service: snapshot.service, pacURL: snapshot.balbisURL, sessionID: snapshot.sessionID))
        return response.message != "no-session"
    }

    static func uninstall() throws {
        guard !FileManager.default.fileExists(atPath: journalURL.path) else {
            throw BalbisError("Сначала отключите Balbis или восстановите настройки подключения.")
        }
        let script = """
        set -eu
        \(installationLockScript)
        trap '/bin/rm -f /var/run/local.balbis.proxy.install.lock' EXIT
        if test -e '\(directory)/journal.json'; then echo 'Сначала восстановите подключение Balbis.' >&2; exit 1; fi
        \(stopServiceScript)
        '\(executable)' --check-stopped
        if test -e '\(directory)/journal.json'; then /bin/launchctl bootstrap system '\(daemon)' >/dev/null 2>&1 || true; echo 'Сначала восстановите подключение Balbis.' >&2; exit 1; fi
        /bin/rm -f '\(daemon)' '\(executable)' '\(directory)/config.json' '\(directory)/daemon.lock' '\(socketPath)'
        /bin/rmdir '\(directory)' 2>/dev/null || true
        """
        let result = try command("/usr/bin/osascript", ["-e", "do shell script " + appleQuote(script) + " with administrator privileges"])
        guard result.status == 0 else { throw BalbisError("Не удалось удалить службу подключения. %@", result.output) }
    }
}
