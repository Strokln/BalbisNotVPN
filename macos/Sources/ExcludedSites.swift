import SwiftUI

final class ExcludedSitesStore: ObservableObject {
    @Published private(set) var domains: [String] = []
    @Published var error = ""
    private let file: URL
    init(file: URL = supportDirectory.appendingPathComponent("excluded-sites.json")) {
        self.file = file
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                domains = try Self.read(file: file)
            }
        } catch { self.error = L("Не удалось прочитать список сайтов.") }
    }
    func add(_ input: String) {
        let domain = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard DomainRules.parse(domain) == [domain], !domain.contains("#"),
              domain.range(of: "^[0-9.]+$", options: .regularExpression) == nil,
              !domain.hasSuffix(".local"), domain.contains(".") else {
            error = L("Введите домен, например example.com, без ссылки и пути.")
            return
        }
        save(Array(Set(domains + [domain])).sorted())
    }
    func remove(_ domain: String) { save(domains.filter { $0 != domain }) }
    private func save(_ values: [String]) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(values).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            domains = values
            error = ""
        } catch { self.error = L("Не удалось сохранить список сайтов.") }
    }
    static func load(file: URL = supportDirectory.appendingPathComponent("excluded-sites.json")) throws -> [String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try read(file: file)
    }
    private static func read(file: URL) throws -> [String] {
        let values = try JSONDecoder().decode([String].self, from: Data(contentsOf: file))
        guard values.allSatisfy({ domain in
            DomainRules.parse(domain) == [domain] && !domain.contains("#") && domain.contains(".") &&
            domain.range(of: "^[0-9.]+$", options: .regularExpression) == nil && !domain.hasSuffix(".local")
        }) else { throw BalbisError("Некорректный домен в списке исключений.") }
        return Array(Set(values)).sorted()
    }

}

struct ExcludedSitesView: View {
    @StateObject private var store = ExcludedSitesStore()
    @State private var entry = ""
    var body: some View {
        DisclosureGroup(L("Исключения")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Эти домены и их поддомены идут напрямую, с приоритетом над всеми списками и режимом «Все сайты». Изменения применятся при следующем подключении."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    TextField("example.com", text: $entry)
                    Button(L("Добавить")) { store.add(entry); if store.error.isEmpty { entry = "" } }
                }
                ForEach(store.domains, id: \.self) { domain in
                    HStack {
                        Text(domain).lineLimit(1)
                        Spacer()
                        Button { store.remove(domain) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).accessibilityLabel(L("Удалить ") + domain)
                    }
                }
                if !store.error.isEmpty { Text(store.error).font(.system(size: 11)).foregroundStyle(.orange) }
            }.padding(.top, 10)
        }.font(.system(size: 12))
    }
}
