import Foundation
import JavaScriptCore

struct BuiltInSitesTests {
    static func run(resources sourceResources: URL) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = directory.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let bundledList = sourceResources.deletingLastPathComponent().appendingPathComponent("list")
        try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent("list"), withDestinationURL: bundledList)
        try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent("routing"), withDestinationURL: sourceResources.appendingPathComponent("routing"))
        let file = directory.appendingPathComponent("builtin-sites.json")
        let absent = try BuiltInSitesStore.load(file: file)
        precondition(absent == nil)
        let store = BuiltInSitesStore(resources: resources, file: file)
        precondition(store.error.isEmpty && !store.isOverridden && store.text.contains("openai.com"))
        let defaults = store.text
        let validatedDefaults = try BuiltInSitesStore.validated(defaults)
        precondition(!validatedDefaults.isEmpty, "All bundled entries must be editable and saveable")
        for invalid in ["https://example.com", "example.com/path", "127.0.0.1", "::1", "test.local", "localhost", "foo..com", "example.com # comment", "*.example.com"] {
            store.text = "valid.example\n" + invalid
            store.save()
            precondition(!store.error.isEmpty && !FileManager.default.fileExists(atPath: file.path), "Invalid line must not partially save")
        }
        store.text = " Example.COM \n\napi.example.com\nexample.com"
        store.save()
        precondition(store.error.isEmpty && store.isOverridden)
        let saved = try BuiltInSitesStore.load(file: file)
        precondition(saved == ["api.example.com", "example.com"])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)
        let original = try DomainRules.load(from: resources.appendingPathComponent("list"))
        let edited = try DomainRules.load(from: resources.appendingPathComponent("list"), baseDomains: saved)
        let abroad = try foreignDomains(resources: resources, youtube: true, baseDomains: saved)
        precondition(edited.included == saved && abroad == saved && original.excluded == edited.excluded)
        precondition(!abroad.contains("openai.com"), "Deleted built-in site must not reappear in foreign routes")
        precondition(!ForeignProbe.shouldProbeAPI(foreignDomains: abroad, directDomains: []))
        precondition(ForeignProbe.shouldProbeAPI(foreignDomains: ["openai.com"], directDomains: []))
        precondition(!ForeignProbe.shouldProbeAPI(foreignDomains: ["openai.com"], directDomains: ["api.openai.com"]))
        precondition(!ForeignProbe.shouldProbeAPI(foreignDomains: ["notopenai.com", "openai.com.evil"], directDomains: []))
        let filtered = try foreignDomains(resources: resources, youtube: false, baseDomains: ["youtube.com", "openai.com"])
        precondition(filtered == ["openai.com"], "YouTube toggle still filters overridden foreign list")
        let context = JSContext()!
        context.evaluateScript("function isPlainHostName(h) { return h.indexOf('.') < 0; }")
        context.evaluateScript(try edited.pac(port: 1088, allSites: false, foreign: abroad, useHTTPProxy: true))
        func route(_ host: String) -> String {
            context.objectForKeyedSubscript("FindProxyForURL")!.call(withArguments: ["https://\(host)/", host])!.toString()!
        }
        precondition(route("api.openai.com") == "DIRECT" && route("example.com") == "PROXY 127.0.0.1:1088")
        store.text = "\n \n"
        store.save()
        let empty = try BuiltInSitesStore.load(file: file)
        precondition(empty == [] && store.isOverridden && store.text.isEmpty)
        precondition(BuiltInSitesStore(resources: resources, file: file).isOverridden)
        let emptySelected = try DomainRules.load(from: resources.appendingPathComponent("list"), baseDomains: empty)
        let emptyForeign = try foreignDomains(resources: resources, youtube: true, baseDomains: empty)
        precondition(emptySelected.included.isEmpty && emptyForeign.isEmpty)
        context.evaluateScript(try emptySelected.pac(port: 1088, allSites: true, foreign: emptyForeign, useHTTPProxy: true))
        precondition(route("api.openai.com") == "PROXY 127.0.0.1:1088", "Empty foreign list must retain router HTTP frontend in all-sites mode")
        context.evaluateScript(try emptySelected.pac(port: 1088, allSites: false, foreign: emptyForeign, useHTTPProxy: true))
        precondition(route("api.openai.com") == "DIRECT", "Empty selected list must remain empty")
        store.restoreDefaults()
        let restored = try BuiltInSitesStore.load(file: file)
        precondition(restored == nil && !store.isOverridden && store.text == defaults)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("[\"example.com\\nother.com\"]".utf8).write(to: file)
        do { _ = try BuiltInSitesStore.load(file: file); preconditionFailure("Malformed JSON domain entry accepted") } catch { }
        print("PASS: editable built-in list, empty override, defaults restoration, route removal and API probe decision")
    }
}
