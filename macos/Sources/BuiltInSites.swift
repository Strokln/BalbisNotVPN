import SwiftUI

final class BuiltInSitesStore: ObservableObject {
    @Published var text = ""
    @Published private(set) var isOverridden = false
    @Published private(set) var error = ""
    private let file: URL
    private let resources: URL

    init(resources: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL, file: URL = supportDirectory.appendingPathComponent("builtin-sites.json")) {
        self.resources = resources
        self.file = file
        do {
            let override = try Self.load(file: file)
            let values = try override ?? Self.bundledDomains(resources: resources)
            text = values.joined(separator: "\n")
            isOverridden = override != nil
        } catch { self.error = "Не удалось прочитать основной список сайтов." }
    }
    static func validated(_ text: String) throws -> [String] {
        var values = Set<String>()
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let value = line.trimmingCharacters(in: .whitespaces).lowercased()
            if value.isEmpty { continue }
            guard DomainRules.parse(value) == [value], value.contains("."), !value.contains("#"),
                  !value.hasSuffix(".local"), value.range(of: "^[0-9.]+$", options: .regularExpression) == nil else {
                throw BalbisError("Строка \(index + 1): нужен домен без ссылки, пути или комментария.")
            }
            values.insert(value)
        }
        return values.sorted()
    }
    static func load(file: URL = supportDirectory.appendingPathComponent("builtin-sites.json")) throws -> [String]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try JSONDecoder().decode([String].self, from: Data(contentsOf: file))
        // Validate each stored entry separately: a JSON entry cannot hide extra lines.
        for value in values {
            guard try validated(value) == [value] else { throw BalbisError("Некорректный домен в основном списке сайтов.") }
        }
        return Array(Set(values)).sorted()
    }
    static func bundledDomains(resources: URL) throws -> [String] {
        let included = try DomainRules.load(from: resources.appendingPathComponent("list")).included
        return Array(Set(try included + foreignDomains(resources: resources, youtube: true))).sorted()
    }
    func save() {
        do {
            let values = try Self.validated(text)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(values).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            text = values.joined(separator: "\n")
            isOverridden = true
            error = ""
        } catch { self.error = error.localizedDescription }
    }
    func restoreDefaults() {
        do {
            let defaults = try Self.bundledDomains(resources: resources)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            text = defaults.joined(separator: "\n")
            isOverridden = false
            error = ""
        } catch { self.error = "Не удалось восстановить встроенный список сайтов." }
    }
}

struct BuiltInSitesView: View {
    @StateObject private var store = BuiltInSitesStore()
    var body: some View {
        DisclosureGroup("Основной список сайтов") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Полный список: один домен в строке, вместе с поддоменами. Можно добавить или удалить любой сайт, а также сохранить пустой список. Сохранённый список используется для выбранных сайтов и зарубежного выхода; переключатель YouTube и исключения сохраняют приоритет. Изменения применятся при следующем подключении.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text: $store.text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 160, maxHeight: 240)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    .accessibilityLabel("Основной список доменов, один домен в строке")
                HStack {
                    Button("Сохранить список") { store.save() }
                    Button("Восстановить встроенный") { store.restoreDefaults() }
                }
                Text(store.isOverridden ? "Используется ваш основной список." : "Используются встроенные списки.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !store.error.isEmpty { Text(store.error).font(.system(size: 11)).foregroundStyle(.orange) }
            }.padding(.top, 10)
        }.font(.system(size: 12))
    }
}
