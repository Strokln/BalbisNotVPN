import Foundation

@main
struct HelperClientTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("balbis helper test '" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let launcher = folder.appendingPathComponent("launchctl")
        let script = folder.appendingPathComponent("stop.sh")
        for (printStatus, stopStatus, expected) in [(113, 0, true), (0, 0, true), (0, 5, false), (5, 0, false)] {
            try """
            #!/bin/sh
            if test "$1" = print; then exit \(printStatus); fi
            if test "$1" = bootout; then exit \(stopStatus); fi
            exit 99
            """.write(to: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
            try ("set -eu\n" + ProxyHelperClient.stopServiceScript.replacingOccurrences(of: "/bin/launchctl", with: shellQuote(launcher.path)))
                .write(to: script, atomically: true, encoding: .utf8)
            let result = try command("/bin/sh", [script.path])
            precondition((result.status == 0) == expected, "stop must fail closed")
        }
        try ProxyHelperClient.installationLockScript.write(to: script, atomically: true, encoding: .utf8)
        let syntax = try command("/bin/sh", ["-n", script.path])
        precondition(syntax.status == 0)
        let request = HelperRequest(operation: "restore", service: "Wi-Fi", pacURL: "http://127.0.0.1:1234/a/proxy.pac", sessionID: UUID().uuidString)
        let restored = try JSONDecoder().decode(HelperRequest.self, from: JSONEncoder().encode(request))
        precondition(restored.operation == "restore" && restored.sessionID == request.sessionID)
        print("PASS: stopped-service checks fail closed; quoted paths and protocol round trip")
    }
}
