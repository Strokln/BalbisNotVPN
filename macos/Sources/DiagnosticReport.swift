import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

struct DiagnosticSnapshot {
    var version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "неизвестно"
    var connected: Bool
    var mode: String
    var region: String
    var automaticRecovery: Bool
    var strategy: String = "неизвестно"
    var foreignEnabled: Bool = false
}

struct DiagnosticMetadata {
    var osVersion: String
    var architecture: String
    var helperInstalled: Bool

    static func current() -> DiagnosticMetadata {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var machine = utsname()
        uname(&machine)
        let capacity = MemoryLayout.size(ofValue: machine.machine)
        let architecture = withUnsafePointer(to: &machine.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
        var info = stat()
        let path = "/Library/PrivilegedHelperTools/local.balbis.proxy/helper"
        let installed = lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == 0 && info.st_mode & 0o022 == 0
        return DiagnosticMetadata(osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture, helperInstalled: installed)
    }
}

enum DiagnosticReport {
    static let byteLimit = 16_384
    static let lineLimit = 100

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z") else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }

    private static func choice(_ value: String, allowed: [String]) -> String {
        allowed.contains(value) ? value : "неизвестно"
    }

    static func sanitizedEvents(_ input: String) -> [String] {
        let events = "(?:user-connect|user-disconnect|session-stop|session-start mode=[0-2] region=(?:AUTO|EU|AM)|supervisor-exit status=-?[0-9]{1,3}|child-exit name=(?:tpws|opera-proxy|balbis-router) status=-?[0-9]{1,3}|transport-probe-failed count=[0-3]|reconnect-reason=consecutive-transport-failures|reconnect-scheduled delay=(?:5|15|30|60)|notification-delivery-failed)"
        let prefix = "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"
        // Bound injected input as well as file input. Reject every unrecognized complete line.
        let tail = Data(input.utf8).suffix(byteLimit)
        let lines = String(decoding: tail, as: UTF8.self).components(separatedBy: .newlines)
        return Array(lines.compactMap { line -> String? in
            guard line.utf8.count <= 256, matches(line, prefix + " pid=[0-9]{1,10} " + events),
                  let pid = line.range(of: " pid="), let event = line[pid.upperBound...].firstIndex(of: " ") else { return nil }
            // PID is unnecessary for troubleshooting and is omitted from the export.
            return String(line[..<pid.lowerBound]) + " " + line[line.index(after: event)...]
        }.suffix(lineLimit))
    }

    static func recentEvents(at file: URL = supportDirectory.appendingPathComponent("connection-events.log")) -> String {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { return "" }
        let count = Int(min(off_t(byteLimit), info.st_size))
        let offset = max(off_t(0), info.st_size - off_t(count))
        var bytes = [UInt8](repeating: 0, count: count)
        let size = pread(fd, &bytes, count, offset)
        guard size > 0 else { return "" }
        var data = Data(bytes.prefix(size))
        if offset > 0 {
            guard let newline = data.firstIndex(of: 10) else { return "" }
            data = Data(data.suffix(from: data.index(after: newline)))
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func generate(snapshot: DiagnosticSnapshot, metadata: DiagnosticMetadata, events: String) -> String {
        let version = matches(snapshot.version, "[0-9]{1,3}(?:\\.[0-9]{1,3}){1,2}") ? snapshot.version : "неизвестно"
        let os = matches(metadata.osVersion, "[0-9]{1,3}(?:\\.[0-9]{1,3}){1,2}") ? metadata.osVersion : "неизвестно"
        let mode = choice(snapshot.mode, allowed: ["0", "1", "2", "Ручная настройка", "Избранное", "Все сайты"])
        let region = choice(snapshot.region, allowed: ["AUTO", "EU", "AM", "Автоматически", "Европа", "США"])
        let strategy = choice(snapshot.strategy, allowed: ["0", "1", "2", "balanced", "split", "tls", "Сегментация TCP + TLS", "Только сегментация TCP", "Только разделение TLS"])
        let architecture = choice(metadata.architecture, allowed: ["x86_64", "arm64", "arm64e"])
        let yesNo: (Bool) -> String = { $0 ? "да" : "нет" }
        var lines = ["Диагностический отчёт Balbis", "", "Версия Balbis: \(version)", "macOS: \(os)", "Архитектура: \(architecture)",
                     "Подключено: \(yesNo(snapshot.connected))", "Режим: \(mode)", "Регион: \(region)", "Стратегия: \(strategy)",
                     "Зарубежное подключение: \(yesNo(snapshot.foreignEnabled))", "Восстановление при обрыве: \(yesNo(snapshot.automaticRecovery))",
                     "Служба установлена: \(yesNo(metadata.helperInstalled)) (проверен только файл)", "", "Последние события"]
        let safeEvents = sanitizedEvents(events)
        lines += safeEvents.isEmpty ? ["Нет подходящих событий."] : safeEvents
        return lines.joined(separator: "\n") + "\n"
    }

    static func save(_ text: String, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".balbis-report-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: "BalbisDiagnostic", code: 1) }
        defer { close(fd); unlink(temporary.path) }
        let data = Data(text.utf8)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let size = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw NSError(domain: "BalbisDiagnostic", code: 2) }
                offset += size
            }
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0, rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: "BalbisDiagnostic", code: 3)
        }
    }
}

struct DiagnosticReportView: View {
    let snapshot: DiagnosticSnapshot
    @State private var preview = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Отчёт создаётся на этом Mac. Проверьте текст перед сохранением. Ничего не отправляется автоматически.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !preview.isEmpty {
                ScrollView {
                    Text(preview).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(height: 180).background(Color.primary.opacity(0.04)).cornerRadius(8)
                Button("Сохранить отчёт…") { savePreview() }
            }
            Button(preview.isEmpty ? "Подготовить отчёт" : "Обновить отчёт") {
                preview = DiagnosticReport.generate(snapshot: snapshot, metadata: .current(), events: DiagnosticReport.recentEvents())
                message = ""
            }
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    private func savePreview() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Balbis-diagnostic.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticReport.save(preview, to: url)
            message = "Отчёт сохранён. Отправить его можно самостоятельно."
        } catch {
            message = "Не удалось сохранить отчёт. Выберите другую папку."
        }
    }
}
