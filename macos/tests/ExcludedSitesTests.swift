import Foundation
import JavaScriptCore

struct ExcludedSitesTests {
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("excluded-sites.json")
        let absent = try ExcludedSitesStore.load(file: file)
        precondition(absent.isEmpty)
        let store = ExcludedSitesStore(file: file)
        for invalid in ["https://example.com", "example.com/path", "127.0.0.1", "::1", "test.local", "localhost", "foo..com", "example.com # comment", "*.example.com", ".example.com", "example.com."] {
            store.add(invalid)
            precondition(store.domains.isEmpty && !store.error.isEmpty, "Accepted invalid exclusion: " + invalid)
        }
        store.add(" EXAMPLE.COM ")
        store.add("example.com")
        precondition(store.domains == ["example.com"] && store.error.isEmpty)
        let persisted = try ExcludedSitesStore.load(file: file)
        precondition(persisted == ["example.com"])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)
        let reloaded = ExcludedSitesStore(file: file)
        reloaded.remove("example.com")
        precondition(reloaded.domains.isEmpty)
        let removed = try ExcludedSitesStore.load(file: file)
        precondition(removed.isEmpty)
        try Data("[\"https://bad.example\"]".utf8).write(to: file)
        do { _ = try ExcludedSitesStore.load(file: file); preconditionFailure("Invalid persisted exclusion accepted") }
        catch { }

        let rules = DomainRules(included: ["example.com"], excluded: ["legacy.example"])
        for allSites in [false, true] {
            let context = JSContext()!
            context.evaluateScript("function isPlainHostName(h) { return h.indexOf('.') < 0; }")
            context.evaluateScript(try rules.pac(port: 1088, allSites: allSites, foreign: ["example.com", "legacy.example"], directDomains: persisted))
            precondition(context.exception == nil)
            func route(_ host: String) -> String {
                context.objectForKeyedSubscript("FindProxyForURL")!.call(withArguments: ["https://\(host)/", host])!.toString()!
            }
            for host in ["example.com", "deep.sub.example.com", "EXAMPLE.COM."] {
                precondition(route(host) == "DIRECT", "User exclusion must override foreign/custom/all-sites")
            }
            precondition(route("legacy.example") == "PROXY 127.0.0.1:1088", "Legacy base exclusions must retain foreign precedence")
            for host in ["notexample.com", "example.com.evil"] {
                precondition(route(host) == (allSites ? "PROXY 127.0.0.1:1088" : "DIRECT"), "Exclusion suffix boundary")
            }
        }
        let dpiContext = JSContext()!
        dpiContext.evaluateScript("function isPlainHostName(h) { return h.indexOf('.') < 0; }")
        dpiContext.evaluateScript(try rules.pac(port: 1088, allSites: true, directDomains: persisted))
        precondition(dpiContext.objectForKeyedSubscript("FindProxyForURL")!.call(withArguments: ["https://sub.example.com/", "sub.example.com"])!.toString() == "DIRECT", "DPI-only system PAC must honor exclusions")
        let oldConfig = Data("{\"resources\":\"/tmp\",\"dpiPort\":1,\"socksPort\":2,\"httpPort\":3,\"strategy\":0,\"sessionID\":\"old\",\"region\":\"EU\",\"domainsFile\":\"/tmp/foreign.txt\"}".utf8)
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: oldConfig)
        precondition(decoded.excludedFile == nil, "Old sessions must remain decodable")
        print("PASS: persistent exclusions, strict validation, PAC precedence and old session compatibility")
    }
}
