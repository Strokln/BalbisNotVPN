import CFNetwork
import Foundation
import JavaScriptCore
import Darwin

final class MockNetwork: NetworkSettings {
    var outputs: [String: String] = [
        "-getwebproxy": "Enabled: No\n", "-getsecurewebproxy": "Enabled: No\n",
        "-getsocksfirewallproxy": "Enabled: No\n", "-getproxyautodiscovery": "Auto Proxy Discovery: Off\n",
        "-getautoproxyurl": "URL: https://previous.example/proxy.pac\nEnabled: Yes\n"
    ]
    var applied: [[[String]]] = []
    var reject = false
    func read(_ args: [String]) throws -> String { outputs[args[0]] ?? "" }
    func apply(_ commands: [[String]]) throws {
        if reject { throw BalbisError("Authorization cancelled") }
        applied.append(commands)
    }
}
@main struct CoreTests {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        try RecoveryTests.run()
        let parsed = DomainRules.parse(" Example.COM\n# comment\nsub.example.com # comment\nfoo..bar\n-foo.com\nfoo-.com\na/evil\na'quote\n.example\nexample.com\n")
        require(parsed == ["example.com", "sub.example.com"], "domain normalization and untrusted list rejection")
        let rules = DomainRules(included: ["blocked.example", "example.com"], excluded: ["safe.example.com"])
        let context = JSContext()!
        context.evaluateScript("function isPlainHostName(h) { return h.indexOf('.') < 0; }")
        context.evaluateScript(try rules.pac(port: 1088, allSites: false))
        require(context.exception == nil, "generated PAC is executable JavaScript")
        for host in ["example.com", "deep.sub.example.com", "EXAMPLE.COM.", "blocked.example"] {
            let output = context.objectForKeyedSubscript("FindProxyForURL")!.call(withArguments: ["https://\(host)/", host])!.toString()!
            require(output == "SOCKS5 127.0.0.1:1088", "PAC routes \(host)")
        }
        for host in ["notexample.com", "example.com.evil", "safe.example.com", "sub.safe.example.com", "printer.local", "localhost", "127.0.0.1", "10.0.0.1", "[::1]", "outside.example"] {
            let output = context.objectForKeyedSubscript("FindProxyForURL")!.call(withArguments: ["https://\(host)/", host])!.toString()!
            require(output == "DIRECT", "PAC bypasses \(host)")
        }
        context.evaluateScript(try rules.pac(port: 1088, allSites: true))
        require(context.objectForKeyedSubscript("FindProxyForURL")!.call(withArguments: ["https://outside.example/", "outside.example"])!.toString() == "SOCKS5 127.0.0.1:1088", "all-sites mode")
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let overseas = try foreignDomains(resources: resources, youtube: true)
        require(overseas.contains("youtube.com") && overseas.contains("sndcdn.com") && overseas.contains("openai.com"), "user foreign-route list bundled and normalized")
        let withoutVideo = try foreignDomains(resources: resources, youtube: false)
        require(!withoutVideo.contains("youtube.com") && !withoutVideo.contains("googlevideo.com") && withoutVideo.contains("gemini.google.com"), "YouTube can retain working DPI route")
        let foreignPAC = try rules.pac(port: 1088, allSites: false, foreign: overseas)
        context.evaluateScript(foreignPAC)
        let proxies = CFNetworkCopyProxiesForAutoConfigurationScript(foreignPAC as CFString,
            URL(string: "https://chatgpt.com/")! as CFURL, nil)?.takeRetainedValue() as? [[String: Any]]
        require(proxies?.first?[kCFProxyHostNameKey as String] as? String == "127.0.0.1" &&
            proxies?.first?[kCFProxyPortNumberKey as String] as? Int == 1088, "Ventura resolves client HTTPS proxy")
        for host in ["api.openai.com", "sub.claude.ai", "gemini.google.com", "youtube.com", "www.figma.com"] {
            require(context.objectForKeyedSubscript("FindProxyForURL")!.call(withArguments: ["https://\(host)/", host])!.toString() == "PROXY 127.0.0.1:1088", "foreign PAC takes priority for \(host)")
        }
        for host in ["google.com", "www.google.com", "mail.google.com", "maps.google.com", "notopenai.com", "openai.com.evil"] {
            require(context.objectForKeyedSubscript("FindProxyForURL")!.call(withArguments: ["https://\(host)/", host])!.toString() == "DIRECT", "rest of Google and suffix impostors stay outside tunnel: \(host)")
        }
        let detectedCountry = try ForeignProbe.parseTrace("ip=hidden\nloc=NL\n")
        require(detectedCountry == "NL", "country detected without exposing IP")
        do { _ = try ForeignProbe.parseTrace("loc=RU\n"); require(false, "RU exit must not look connected") }
        catch { require(true, "RU exit refused") }
        require(ForeignProbe.classifyAPI(status: 401, body: "missing API key") == "ok", "API 401 validates region reachability")
        require(ForeignProbe.classifyAPI(status: 403, body: "unsupported_country_region_territory") == "blocked", "region ban rejected")
        require(ForeignProbe.classifyAPI(status: 403, body: "Cloudflare challenge") == "unknown", "Cloudflare challenge is not a country diagnosis")
        let mock = MockNetwork()
        let snapshot = try ProxySnapshot.capture(service: "Wi-Fi ' test", balbisURL: "http://127.0.0.1:3333/id/proxy.pac", network: mock)
        require(snapshot.originalEnabled && snapshot.originalURL == "https://previous.example/proxy.pac", "capture preserves old PAC")
        try snapshot.install(network: mock)
        require(mock.applied[0][0] == ["-setautoproxyurl", "Wi-Fi ' test", snapshot.balbisURL], "arguments preserve service name")
        mock.outputs["-getautoproxyurl"] = "URL: \(snapshot.balbisURL)\nEnabled: Yes\n"
        try snapshot.restore(network: mock)
        require(mock.applied.last!.last! == ["-setautoproxystate", snapshot.service, "on"], "enabled PAC is re-enabled")
        require(mock.applied.last![1][2] == snapshot.originalURL, "old PAC URL restored")
        // Regression: macOS rejects -setautoproxyurl with an empty argument.
        let emptyBefore = MockNetwork()
        emptyBefore.outputs["-getautoproxyurl"] = "URL: (null)\nEnabled: No\n"
        let emptySnapshot = try ProxySnapshot.capture(service: "Wi-Fi", balbisURL: snapshot.balbisURL, network: emptyBefore)
        emptyBefore.outputs["-getautoproxyurl"] = "URL: \(snapshot.balbisURL)\nEnabled: Yes\n"
        try emptySnapshot.restore(network: emptyBefore)
        require(emptyBefore.applied == [[["-setautoproxystate", "Wi-Fi", "off"]]], "no prior PAC: disable without an invalid empty-URL command")
        emptyBefore.outputs["-getautoproxyurl"] = "URL: \(snapshot.balbisURL)\nEnabled: No\n"
        emptyBefore.reject = true
        try emptySnapshot.restore(network: emptyBefore)
        require(emptyBefore.applied.count == 1, "retry after partial rollback needs no authorization or network writes")
        let recoveryDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: recoveryDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recoveryDir) }
        let oldJournal = recoveryDir.appendingPathComponent("old-session.json")
        try JSONEncoder().encode(emptySnapshot).write(to: oldJournal)
        try recoverSnapshot(network: emptyBefore, at: oldJournal)
        require(!FileManager.default.fileExists(atPath: oldJournal.path), "old 0.1.0 journal recovers after PAC was already disabled")
        let before = mock.applied.count
        mock.outputs["-getautoproxyurl"] = "URL: https://vpn.example/new.pac\nEnabled: Yes\n"
        try snapshot.restore(network: mock)
        require(mock.applied.count == before, "never overwrite a newer VPN/user PAC")
        for flag in ["-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy", "-getproxyautodiscovery"] {
            let protected = MockNetwork()
            protected.outputs[flag] = flag == "-getproxyautodiscovery" ? "Auto Proxy Discovery: On\n" : "Enabled: Yes\n"
            do { _ = try ProxySnapshot.capture(service: "Wi-Fi", balbisURL: snapshot.balbisURL, network: protected); require(false, "reject existing proxy \(flag)") }
            catch { require(protected.applied.isEmpty, "existing proxy untouched \(flag)") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.json")
        try JSONEncoder().encode(snapshot).write(to: journal)
        mock.outputs["-getautoproxyurl"] = "URL: \(snapshot.balbisURL)\nEnabled: Yes\n"
        try recoverSnapshot(network: mock, expectedID: "other-session", at: journal)
        require(FileManager.default.fileExists(atPath: journal.path), "old supervisor cannot consume a new session")
        mock.reject = true
        do { try recoverSnapshot(network: mock, at: journal); require(false, "failed restoration must throw") }
        catch { require(FileManager.default.fileExists(atPath: journal.path), "cancelled restoration retains journal") }
        mock.reject = false
        try recoverSnapshot(network: mock, expectedID: snapshot.sessionID, at: journal)
        require(!FileManager.default.fileExists(atPath: journal.path), "successful restoration removes journal")
        require(shellQuote("a'b") == "'a'\\''b'", "shell apostrophe escaping")
        require(appleQuote("a\"\\\nb") == "\"a\\\"\\\\\\nb\"", "AppleScript escaping")
        let server = PACServer(script: try rules.pac(port: 1088, allSites: false))
        try server.start()
        require(server.isReady, "loopback PAC listener ready")
        func get(_ path: String) throws -> (Data, HTTPURLResponse) {
            let done = DispatchSemaphore(value: 0)
            var result: (Data, HTTPURLResponse)?
            var failure: Error?
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:] // Never use the machine's VPN proxy for a loopback test.
            let session = URLSession(configuration: config)
            session.dataTask(with: URL(string: "http://127.0.0.1:\(server.port)\(path)")!) { data, response, error in
                if let data = data, let response = response as? HTTPURLResponse { result = (data, response) }
                failure = error
                done.signal()
            }.resume()
            require(done.wait(timeout: .now() + 5) == .success, "PAC HTTP responds")
            session.invalidateAndCancel()
            if let error = failure { throw error }
            return result!
        }
        let (body, response) = try get(server.path)
        require(response.statusCode == 200 && String(decoding: body, as: UTF8.self).contains("FindProxyForURL"), "PAC served over HTTP")
        let (_, wrong) = try get("/unknown")
        require(wrong.statusCode == 404, "no unrelated local resources exposed")
        server.stop()
        require(!server.isReady, "PAC listener stops")
        print("PASS: \(checks) core/PAC checks; no system network settings changed")
    }
}
