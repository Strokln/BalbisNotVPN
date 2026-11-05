import SwiftUI

enum SiteCategory: String, CaseIterable, Identifiable {
    case all = "Все", ai = "Нейросети", video = "Видео", social = "Соцсети", other = "Другие"
    var id: String { rawValue }
}

struct BuiltInSite: Codable, Equatable, Identifiable {
    let domain: String
    var enabled: Bool
    var id: String { domain }
}

final class BuiltInSitesStore: ObservableObject {
    @Published var text = "" { didSet { if !synchronizingText { textIsDirty = true } } }
    @Published private(set) var sites: [BuiltInSite] = []
    @Published private(set) var textIsDirty = false
    @Published private(set) var isOverridden = false
    @Published private(set) var error = ""
    @Published private(set) var message = ""
    @Published private(set) var lastDeleted: BuiltInSite?
    private let file: URL
    private let stateFile: URL
    private let resources: URL
    private var synchronizingText = false
    private var loadedFile: Data?
    private var loadedStateFile: Data?
    private var savedSites: [BuiltInSite] = []
    private var categories: [String: SiteCategory] = [:]
    private struct EditorState: Codable {
        let sites: [BuiltInSite]
        let enabledDomains: [String]
    }
    var enabledDomains: [String] { sites.filter { $0.enabled }.map { $0.domain } }
    var hasUnsavedChanges: Bool { textIsDirty || sites != savedSites }

    init(resources: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL,
         file: URL = supportDirectory.appendingPathComponent("builtin-sites.json")) {
        self.resources = resources
        self.file = file
        self.stateFile = file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-ui.json")
        reload()
    }
    static func validated(_ text: String) throws -> [String] {
        var values = Set<String>()
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let value = line.trimmingCharacters(in: .whitespaces).lowercased()
            if value.isEmpty { continue }
            guard DomainRules.parse(value) == [value], value.contains("."), !value.contains("#"),
                  !value.hasSuffix(".local"), value.range(of: "^[0-9.]+$", options: .regularExpression) == nil else {
                throw BalbisError("Строка %d: нужен домен без ссылки, пути или комментария.", index + 1)
            }
            values.insert(value)
        }
        return values.sorted()
    }
    static func load(file: URL = supportDirectory.appendingPathComponent("builtin-sites.json")) throws -> [String]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try JSONDecoder().decode([String].self, from: Data(contentsOf: file))
        for value in values {
            guard try validated(value) == [value] else { throw BalbisError("Некорректный домен в основном списке сайтов.") }
        }
        return Array(Set(values)).sorted()
    }
    static func bundledDomains(resources: URL) throws -> [String] {
        let included = try DomainRules.load(from: resources.appendingPathComponent("list")).included
        return Array(Set(try included + foreignDomains(resources: resources, youtube: true))).sorted()
    }
    private func bytes(at file: URL) throws -> Data? {
        FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
    }
    private func checkExternalChanges() throws {
        guard try bytes(at: file) == loadedFile, try bytes(at: stateFile) == loadedStateFile else {
            throw BalbisError("Список изменён вне этого редактора. Нажмите «Перезагрузить с диска», чтобы получить актуальную версию.")
        }
    }
    func reload() {
        do {
            let currentFile = try bytes(at: file)
            let currentState = try bytes(at: stateFile)
            let override = try Self.load(file: file)
            let values = try override ?? Self.bundledDomains(resources: resources)
            var rows = values.map { BuiltInSite(domain: $0, enabled: true) }
            if let override = override, let data = currentState,
               let state = try? JSONDecoder().decode(EditorState.self, from: data),
               state.enabledDomains == override,
               Set(state.sites.map { $0.domain }).count == state.sites.count,
               state.sites.allSatisfy({ (try? Self.validated($0.domain)) == [$0.domain] }),
               state.sites.filter({ $0.enabled }).map({ $0.domain }).sorted() == override {
                rows = state.sites.sorted { $0.domain < $1.domain }
            }
            categories = Self.bundledCategories(resources: resources)
            sites = rows
            savedSites = rows
            isOverridden = override != nil
            loadedFile = currentFile
            loadedStateFile = currentState
            lastDeleted = nil
            syncText()
            error = ""
            message = ""
        } catch { self.error = L("Не удалось прочитать основной список сайтов. ") + error.localizedDescription }
    }
    private func syncText() {
        synchronizingText = true
        text = enabledDomains.joined(separator: "\n")
        synchronizingText = false
        textIsDirty = false
    }
    @discardableResult func applyText() -> Bool {
        guard textIsDirty else { return true }
        do {
            let values = Set(try Self.validated(text))
            var updated = sites.map { BuiltInSite(domain: $0.domain, enabled: values.contains($0.domain)) }
            let known = Set(sites.map { $0.domain })
            updated += values.subtracting(known).map { BuiltInSite(domain: $0, enabled: true) }
            sites = updated.sorted { $0.domain < $1.domain }
            syncText()
            error = ""
            message = L("Текст применён к списку. Сохраните изменения.")
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func discardText() { syncText(); error = "" }
    func setEnabled(_ domain: String, _ enabled: Bool) {
        guard applyText(), let index = sites.firstIndex(where: { $0.domain == domain }) else { return }
        sites[index].enabled = enabled
        syncText()
        message = ""
    }
    @discardableResult func add(_ input: String) -> Bool {
        guard applyText() else { return false }
        do {
            let values = try Self.validated(input)
            guard values.count == 1 else { throw BalbisError("Введите один домен, например example.com.") }
            let domain = values[0]
            if let index = sites.firstIndex(where: { $0.domain == domain }) { sites[index].enabled = true }
            else { sites.append(BuiltInSite(domain: domain, enabled: true)); sites.sort { $0.domain < $1.domain } }
            syncText()
            error = ""
            message = ""
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func remove(_ domain: String) {
        guard applyText(), let row = sites.first(where: { $0.domain == domain }) else { return }
        lastDeleted = row
        sites.removeAll { $0.domain == domain }
        syncText()
        message = ""
    }
    func undoDelete() {
        guard applyText(), let row = lastDeleted else { return }
        // A subsequently added copy wins over an old undo entry.
        if !sites.contains(where: { $0.domain == row.domain }) {
            sites.append(row)
            sites.sort { $0.domain < $1.domain }
        }
        lastDeleted = nil
        syncText()
    }
    func category(for domain: String) -> SiteCategory {
        var suffix = domain
        while true {
            if let category = categories[suffix] { return category }
            guard let dot = suffix.firstIndex(of: ".") else { return .other }
            suffix = String(suffix[suffix.index(after: dot)...])
        }
    }
    func filteredSites(search: String, category: SiteCategory) -> [BuiltInSite] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sites.filter { row in
            (query.isEmpty || row.domain.contains(query)) && (category == .all || self.category(for: row.domain) == category)
        }
    }
    private static func bundledCategories(resources: URL) -> [String: SiteCategory] {
        var result: [String: SiteCategory] = [:]
        func add(_ domains: [String], as category: SiteCategory) { for domain in domains { result[domain] = category } }
        // Prefer the dedicated bundled lists; current bundles also group foreign.txt by service.
        for (name, category) in [("ai", SiteCategory.ai), ("youtube", .video), ("discord", .social), ("telegram", .social), ("whatsapp", .social)] {
            let body = (try? String(contentsOf: resources.appendingPathComponent("list/" + name + ".txt"), encoding: .utf8)) ?? ""
            add(DomainRules.parse(body), as: category)
        }
        let body = (try? String(contentsOf: resources.appendingPathComponent("routing/foreign.txt"), encoding: .utf8)) ?? ""
        var section: SiteCategory = .other
        for line in body.components(separatedBy: .newlines) {
            if line.hasPrefix("# ") {
                let heading = String(line.dropFirst(2))
                if ["OpenAI / ChatGPT", "Anthropic / Claude", "Google AI", "Microsoft Copilot", "Other AI services"].contains(heading) { section = .ai }
                else if heading == "YouTube" { section = .video }
                else if ["Meta", "X / Twitter", "Discord"].contains(heading) { section = .social }
                else { section = .other }
            } else { add(DomainRules.parse(line), as: section) }
        }
        // These services share the generic bundled 'Other services' section.
        let youtube = (try? String(contentsOf: resources.appendingPathComponent("routing/youtube.txt"), encoding: .utf8)) ?? ""
        add(DomainRules.parse(youtube), as: .video)
        let known = Set(DomainRules.parse(body))
        add(["netflix.com", "nflxvideo.net", "nflximg.net", "tiktok.com", "tiktokcdn.com"].filter { known.contains($0) }, as: .video)
        add(["linkedin.com", "licdn.com", "signal.org", "viber.com", "quora.com", "medium.com", "patreon.com"].filter { known.contains($0) }, as: .social)
        return result
    }
    private func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func save() {
        guard applyText() else { return }
        do {
            try checkExternalChanges()
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let values = enabledDomains
            // State is accepted on reload only if it agrees with the routing file.
            try write(JSONEncoder().encode(EditorState(sites: sites, enabledDomains: values)), to: stateFile)
            loadedStateFile = try bytes(at: stateFile)
            try write(JSONEncoder().encode(values), to: file)
            loadedFile = try bytes(at: file)
            savedSites = sites
            isOverridden = true
            error = ""
            message = L("Список сохранён. Применится при следующем подключении.")
        } catch { self.error = error.localizedDescription }
    }
    func restoreDefaults() {
        do {
            try checkExternalChanges()
            _ = try Self.bundledDomains(resources: resources)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            if FileManager.default.fileExists(atPath: stateFile.path) { try FileManager.default.removeItem(at: stateFile) }
            reload()
            message = L("Встроенный список восстановлен. Применится при следующем подключении.")
        } catch { self.error = L("Не удалось восстановить встроенный список сайтов. ") + error.localizedDescription }
    }
}

struct BuiltInSitesView: View {
    @StateObject private var store = BuiltInSitesStore()
    @State private var search = ""
    @State private var category: SiteCategory = .all
    @State private var entry = ""
    var body: some View {
        DisclosureGroup(L("Основной список сайтов")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Включённые домены и их поддомены войдут в основной список. Изменения применятся при следующем подключении после сохранения. «Мои сайты» добавляются отдельно. Выключение строки не отменяет правило родительского домена; для прямого маршрута используйте «Исключения»."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(L("Поиск по домену"), text: $search)
                Picker(L("Категория"), selection: $category) {
                    ForEach(SiteCategory.allCases) { Text(L($0.rawValue)).tag($0) }
                }.labelsHidden().accessibilityLabel(L("Категория сайтов"))
                Text(L("Включено %d из %d", store.enabledDomains.count, store.sites.count))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                siteList
                if let deleted = store.lastDeleted {
                    HStack {
                        Text(L("Удалён %@", deleted.domain)).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Button(L("Отменить")) { store.undoDelete() }.disabled(store.textIsDirty)
                    }
                }
                HStack {
                    TextField("example.com", text: $entry)
                    Button(L("Добавить")) { if store.add(entry) { entry = "" } }
                }.disabled(store.textIsDirty)
                DisclosureGroup(L("Дополнительно: полный текст")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Один включённый домен в строке. Удалённые из текста домены останутся в списке выключенными. Примените текст перед изменением переключателей."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        TextEditor(text: $store.text)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 160)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                            .accessibilityLabel(L("Основной список включённых доменов, один домен в строке"))
                        if store.textIsDirty {
                            HStack {
                                Button(L("Применить к списку")) { store.applyText() }
                                Button(L("Отменить текст")) { store.discardText() }
                            }
                        }
                    }.padding(.top, 8)
                }
                Group {
                    Button(L("Сохранить изменения")) { store.save() }
                    Button(L("Восстановить встроенный")) { store.restoreDefaults() }
                    Button(L("Перезагрузить с диска")) { store.reload() }
                    Text(store.hasUnsavedChanges ? L("Есть несохранённые изменения.") : (store.isOverridden ? L("Используется ваш основной список.") : L("Используются встроенные списки.")))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if !store.message.isEmpty { Text(store.message).font(.system(size: 11)).foregroundStyle(.secondary) }
                    if !store.error.isEmpty { Text(store.error).font(.system(size: 11)).foregroundStyle(.orange) }
                }
            }.padding(.top, 10)
        }.font(.system(size: 12))
    }
    private var siteList: some View {
        let rows = store.filteredSites(search: search, category: category)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if rows.isEmpty { Text(L("Сайты не найдены.")).foregroundStyle(.secondary) }
                ForEach(rows) { site in
                    HStack(spacing: 8) {
                        Toggle(site.domain, isOn: Binding(get: {
                            store.sites.first(where: { $0.domain == site.domain })?.enabled ?? false
                        }, set: { store.setEnabled(site.domain, $0) }))
                            .toggleStyle(.checkbox).lineLimit(1)
                        Spacer(minLength: 0)
                        Button { store.remove(site.domain) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).accessibilityLabel(L("Удалить ") + site.domain)
                    }
                }
            }.padding(6)
        }.frame(height: 190).background(Color.primary.opacity(0.04)).cornerRadius(6).disabled(store.textIsDirty)
    }
}
