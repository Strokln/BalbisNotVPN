import Foundation
import Darwin

@main struct RuntimeTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        let app = URL(fileURLWithPath: CommandLine.arguments[1])
        let runtime = BalbisRuntime()
        for strategy in Strategy.allCases {
            try runtime.start(strategy: strategy, mode: 0, service: "", resources: app.appendingPathComponent("Contents/Resources"), executable: app.appendingPathComponent("Contents/MacOS/Balbis").path)
            let port = runtime.port
            check(runtime.isRunning && socksReady(port: port), "bundled engine ready for strategy \(strategy.rawValue)")
            let response = try command("/usr/bin/curl", ["-q", "--noproxy", "*", "--fail", "--silent", "--max-time", "5", runtime.pacURL])
            check(response.status == 0 && response.output.contains("FindProxyForURL"), "bundled domain PAC served")
            check(!FileManager.default.fileExists(atPath: journalURL.path), "local mode never installs a system proxy journal")
            try runtime.stop()
            check(!runtime.isRunning && !socksReady(port: port), "supervisor and engine stop before restart")
        }
        // A parent crash closes its only pipe writer; the surviving supervisor must reap tpws.
        let port = try availablePort()
        let helper = Process()
        let input = Pipe()
        helper.executableURL = app.appendingPathComponent("Contents/MacOS/Balbis")
        helper.arguments = ["--supervise", app.appendingPathComponent("Contents/Resources/tpws").path, String(port), "0", UUID().uuidString]
        helper.standardInput = input
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        try input.fileHandleForReading.close()
        for _ in 0..<50 { if socksReady(port: port) { break }; usleep(100_000) }
        check(socksReady(port: port), "supervisor starts on parent pipe")
        try input.fileHandleForWriting.close() // Exactly the EOF produced by an abruptly killed parent.
        helper.waitUntilExit()
        check(!socksReady(port: port), "parent EOF reaps engine without changing networking")
        // A controlled signal to the supervisor also terminates its engine.
        let signaled = Process()
        let input2 = Pipe()
        signaled.executableURL = helper.executableURL
        signaled.arguments = helper.arguments
        signaled.standardInput = input2
        signaled.standardOutput = FileHandle.nullDevice
        signaled.standardError = FileHandle.nullDevice
        try signaled.run()
        try input2.fileHandleForReading.close()
        for _ in 0..<50 { if socksReady(port: port) { break }; usleep(100_000) }
        check(socksReady(port: port), "signaled helper ready")
        kill(signaled.processIdentifier, SIGTERM)
        signaled.waitUntilExit()
        try input2.fileHandleForWriting.close()
        check(!socksReady(port: port), "SIGTERM reaps engine")
        if CommandLine.arguments.contains("--live-foreign") {
            try runtime.start(strategy: .balanced, mode: 0, service: "", resources: app.appendingPathComponent("Contents/Resources"), executable: app.appendingPathComponent("Contents/MacOS/Balbis").path,
                              foreign: ForeignOptions(enabled: true, youtube: true, region: "AUTO"))
            check(!runtime.foreignStatus.isEmpty, "foreign exit verified before marking ready")
            print("LIVE: " + runtime.foreignStatus)
            let native = try command("/usr/bin/curl", ["-q", "--proxy", "http://127.0.0.1:\(runtime.port)", "--noproxy", "", "--connect-timeout", "5", "--max-time", "12", "--silent", "--show-error", "--write-out", "\n%{http_code}", "https://api.openai.com/v1/models"])
            let nativeLines = native.output.components(separatedBy: .newlines)
            let nativeStatus = Int(nativeLines.last ?? "") ?? 0
            check(native.status == 0 && [200, 401].contains(nativeStatus), "native-client HTTP CONNECT path reaches OpenAI without regional block")
            print("LIVE HTTP CONNECT: OpenAI HTTP \(nativeStatus)")
            let routedPort = runtime.port
            // Standard curl SOCKS5 (local DNS / IP-only) must not bypass the foreign policy.
            let forbidden = try command("/usr/bin/curl", ["-q", "--proxy", "socks5://127.0.0.1:\(routedPort)", "--noproxy", "", "--max-time", "5", "--silent", "https://1.1.1.1/"])
            check(forbidden.status != 0, "IP-only requests cannot leak selected services to DPI")
            try runtime.stop()
            check(!socksReady(port: routedPort), "all foreign-session helpers stopped")
            check(!FileManager.default.fileExists(atPath: journalURL.path), "foreign local mode never touched system PAC")
        }
        print("PASS: bundled app lifecycle, three strategies, rapid restarts, parent EOF and SIGTERM; system settings untouched")
    }
}
