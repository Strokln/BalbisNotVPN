import Foundation

struct ConnectionHealth {
    // HTTP errors describe the destination's response, not a dead transport.
    static func provesTransport(exitStatus: Int32, httpStatus: Int) -> Bool {
        exitStatus == 0 && (100...599).contains(httpStatus)
    }

    private static func probe(url: String, proxy: String, keepBody: Bool = false) throws -> (alive: Bool, status: Int, body: String) {
        var args = ["-q", "--proxy", proxy, "--noproxy", "", "--connect-timeout", "3", "--max-time", "8", "--max-filesize", "65536", "--silent", "--show-error"]
        if !keepBody { args += ["--output", "/dev/null"] }
        args += ["--write-out", "\n%{http_code}", url]
        let result = try command("/usr/bin/curl", args)
        let lines = result.output.components(separatedBy: .newlines)
        let status = Int((lines.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return (provesTransport(exitStatus: result.status, httpStatus: status), status, lines.dropLast().joined(separator: "\n"))
    }

    static func transportAlive(port: UInt16, foreignPort: UInt16) throws {
        guard socksReady(port: port) else { throw BalbisError("Локальная служба не отвечает.") }
        let proxy = foreignPort == 0 ? "socks5h://127.0.0.1:\(port)" : "http://127.0.0.1:\(foreignPort)"
        for url in ["https://www.cloudflare.com/cdn-cgi/trace", "https://api.openai.com/v1/models"] {
            if let result = try? probe(url: url, proxy: proxy), result.alive { return }
        }
        throw BalbisError("Маршрут не передаёт запросы через локальный прокси.")
    }

    static func check(port: UInt16, foreignPort: UInt16) throws -> String {
        guard socksReady(port: port) else { throw BalbisError("Локальная служба не отвечает.") }
        var route = L("Balbis отвечает · Зарубежный выход выключен")
        var traceAlive = false
        if foreignPort != 0 {
            let trace = try? probe(url: "https://www.cloudflare.com/cdn-cgi/trace", proxy: "http://127.0.0.1:\(foreignPort)", keepBody: true)
            traceAlive = trace?.alive == true
            if let trace = trace, trace.alive, let country = try? ForeignProbe.parseTrace(trace.body) {
                route = L("Balbis отвечает · Страна: %@", country)
            } else {
                route = L("Balbis отвечает · Страну выхода определить не удалось")
            }
        }
        let api = try? probe(url: "https://api.openai.com/v1/models", proxy: "socks5h://127.0.0.1:\(port)")
        guard traceAlive || api?.alive == true else { throw BalbisError("Маршрут не передаёт запросы.") }
        let apiReport: String
        if let api = api, api.alive {
            apiReport = [200, 401].contains(api.status) ? L("OpenAI API: отвечает (HTTP %d)", api.status) : L("OpenAI API: HTTP %d; доступ требует проверки", api.status)
        } else {
            apiReport = L("OpenAI API: запрос не прошёл; маршрут отвечает")
        }
        return route + "\n" + apiReport + "\n" + L("ChatGPT: отдельно не проверялся; проверьте сайт или приложение.")
    }
}

struct HealthFailurePolicy {
    private(set) var failures = 0
    mutating func record(success: Bool) -> Bool {
        failures = success ? 0 : min(3, failures + 1)
        return failures == 3
    }
    mutating func reset() { failures = 0 }
}

struct ReconnectPolicy {
    var wanted = false
    private(set) var failures = 0
    mutating func reset() { failures = 0 }
    mutating func nextDelay() -> TimeInterval? {
        guard wanted else { return nil }
        let delays: [TimeInterval] = [5, 15, 30, 60]
        let delay = delays[min(failures, delays.count - 1)]
        failures += 1
        return delay
    }
}
