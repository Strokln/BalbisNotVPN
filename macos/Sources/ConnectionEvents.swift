import Foundation
import Darwin

enum ConnectionEvents {
    private static let lock = NSLock()
    static func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        let folder = supportDirectory
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("connection-events.log")
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 131072 {
                let previous = folder.appendingPathComponent("connection-events.previous.log")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: file, to: previous)
            }
            let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = Data("\(stamp) pid=\(getpid()) \(event.prefix(400).replacingOccurrences(of: "\n", with: " "))\n".utf8)
            line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        } catch { /* Diagnostics must never interfere with the connection. */ }
    }
}
