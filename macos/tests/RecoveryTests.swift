import Foundation

struct RecoveryTests {
    static func run() throws {
        var policy = ReconnectPolicy()
        precondition(policy.nextDelay() == nil)
        policy.wanted = true
        for delay in [5.0, 15, 30, 60, 60] { precondition(policy.nextDelay() == delay) }
        policy.wanted = false
        precondition(policy.nextDelay() == nil, "Manual disconnect must suppress recovery")
        policy.wanted = true
        policy.reset()
        precondition(policy.nextDelay() == 5)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sites.json")
        let store = CustomSitesStore(file: file)
        for bad in ["https://example.com", "example.com/path", "127.0.0.1", "foo..com", "test.local", "com", "localhost", "ru"] {
            store.add(bad)
            precondition(store.domains.isEmpty && !store.error.isEmpty)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(["com", "localhost", "127.0.0.1", "test.local", "safe.example"]).write(to: file)
        precondition(CustomSitesStore(file: file).domains == ["safe.example"], "Old broad or local entries must not reload")
        store.add("EXAMPLE.COM")
        store.add("example.com")
        precondition(store.domains == ["example.com"])
        precondition(CustomSitesStore(file: file).domains == ["example.com"])
        store.remove("example.com")
        precondition(CustomSitesStore(file: file).domains.isEmpty)
        print("PASS: bounded reconnect delay, manual suppression and persistent domain validation")
    }
}
