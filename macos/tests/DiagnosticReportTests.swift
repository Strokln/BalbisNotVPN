import Foundation
import Darwin

@main struct DiagnosticReportTests {
    static func main() throws {
        let valid = "2026-11-05T10:00:00Z pid=123 session-start mode=1 region=AUTO"
        let hostile = ["2026-11-05T10:00:00Z pid=123 user-connect token=secret", "2026-11-05T10:00:00Z pid=123 child-exit name=/Users/private/account status=1", "2026-11-05T10:00:00Z pid=123 session-start mode=1 region=example.com", "PAC=http://127.0.0.1:1234/private/proxy.pac", "password=secret", "192.168.1.2", "SSID=private", "/Users/private/home"]
        let snapshot = DiagnosticSnapshot(version: "0.7.1", connected: true, mode: "Избранное", region: "EU", automaticRecovery: true)
        let metadata = DiagnosticMetadata(osVersion: "13.7.8", architecture: "x86_64", helperInstalled: true)
        let report = DiagnosticReport.generate(snapshot: snapshot, metadata: metadata, events: ([valid] + hostile).joined(separator: "\n"))
        precondition(report.contains("session-start mode=1 region=AUTO"))
        for secret in ["secret", "example.com", "/Users", "127.0.0.1", "192.168", "SSID", "pid="] { precondition(!report.contains(secret)) }
        let ipv4Version = DiagnosticReport.generate(snapshot: DiagnosticSnapshot(version: "127.0.0.1", connected: false, mode: "1", region: "EU", automaticRecovery: false), metadata: metadata, events: "")
        precondition(!ipv4Version.contains("127.0.0.1"))
        for event in ["user-connect", "user-disconnect", "session-stop", "supervisor-exit status=9", "child-exit name=opera-proxy status=1", "transport-probe-failed count=3", "reconnect-reason=consecutive-transport-failures", "reconnect-scheduled delay=60", "notification-delivery-failed"] {
            precondition(DiagnosticReport.sanitizedEvents("2026-11-05T10:00:00Z pid=123 " + event).count == 1)
        }
        let injected = DiagnosticSnapshot(version: "0.7.1\npassword=secret", connected: false, mode: "/Users/private", region: "example.com", automaticRecovery: false, strategy: "token=secret")
        let sanitized = DiagnosticReport.generate(snapshot: injected, metadata: DiagnosticMetadata(osVersion: "/Users/private", architecture: "secret", helperInstalled: false), events: "")
        for secret in ["secret", "example.com", "/Users", "password="] { precondition(!sanitized.contains(secret)) }
        precondition(DiagnosticReport.sanitizedEvents(Array(repeating: valid, count: 150).joined(separator: "\n")).count == 100)
        precondition(DiagnosticReport.sanitizedEvents(valid + "\n" + String(repeating: "x", count: 20_000)).isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("balbis-report-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.log")
        try (String(repeating: "private\n", count: 10_000) + valid + "\n").write(to: file, atomically: true, encoding: .utf8)
        let tail = DiagnosticReport.recentEvents(at: file)
        precondition(tail.utf8.count <= DiagnosticReport.byteLimit)
        precondition(DiagnosticReport.sanitizedEvents(tail).count == 1)
        let link = directory.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        precondition(DiagnosticReport.recentEvents(at: link).isEmpty)
        let output = directory.appendingPathComponent("report.txt")
        try DiagnosticReport.save(report, to: output)
        try DiagnosticReport.save(report, to: output)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let saved = try String(contentsOf: output)
        precondition(saved == report)
        print("Diagnostic report tests passed")
    }
}
