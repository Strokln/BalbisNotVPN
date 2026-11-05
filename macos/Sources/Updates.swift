import Cocoa
import SwiftUI

struct ReleaseVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(fields.count), fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              fields.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = fields.map { Int($0)! } + Array(repeating: 0, count: 4 - fields.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

final class UpdateChecker: ObservableObject {
    @Published var automatic = UserDefaults.standard.object(forKey: "checkUpdates") == nil || UserDefaults.standard.bool(forKey: "checkUpdates")
    @Published private(set) var checking = false
    @Published private(set) var available = ""
    @Published private(set) var status = ""
    var onAvailable: (() -> Void)?
    private var session: URLSession?
    func check(manual: Bool = false) {
        guard !checking, manual || automatic else { return }
        checking = true
        if manual { status = "Проверяем GitHub…" }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        self.session = session
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Strokln/BalbisNotVPN/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Balbis-macOS", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            var version: String?
            if error == nil, let response = response as? HTTPURLResponse, response.statusCode == 200,
               response.url?.host == "api.github.com", let data = data, data.count < 262144,
               let tag = Self.stableTag(data) { version = tag }
            DispatchQueue.main.async {
                self.checking = false
                guard manual || self.automatic else {
                    session.finishTasksAndInvalidate()
                    self.session = nil
                    return
                }
                let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.0"
                if let tag = version, let remote = ReleaseVersion(tag), let current = ReleaseVersion(local) {
                    self.available = remote > current ? tag : ""
                    self.status = self.available.isEmpty ? "Установлена актуальная версия." : "Доступна версия \(tag)."
                    if !self.available.isEmpty { self.onAvailable?() }
                } else if manual { self.status = "GitHub не ответил. Попробуйте позже." }
                session.finishTasksAndInvalidate()
                self.session = nil
            }
        }.resume()
    }
    static func stableTag(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool == false, json["prerelease"] as? Bool == false,
              let tag = json["tag_name"] as? String, ReleaseVersion(tag) != nil else { return nil }
        return tag
    }
    func openRelease() {
        guard ReleaseVersion(available) != nil else { return }
        NSWorkspace.shared.open(URL(string: "https://github.com/Strokln/BalbisNotVPN/releases/tag/\(available)")!)
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateChecker
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Проверять обновления при запуске", isOn: $updates.automatic)
                .toggleStyle(.switch).controlSize(.small)
                .onChange(of: updates.automatic) { UserDefaults.standard.set($0, forKey: "checkUpdates") }
            Button(updates.checking ? "Проверяем…" : "Проверить обновления") { updates.check(manual: true) }.disabled(updates.checking)
            if !updates.status.isEmpty { Text(updates.status).font(.system(size: 11)).foregroundStyle(.secondary) }
            if !updates.available.isEmpty { Button("Открыть обновление на GitHub", action: updates.openRelease) }
        }
    }
}

struct UpdateBannerView: View {
    @ObservedObject var updates: UpdateChecker
    var body: some View {
        if !updates.available.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Доступен Balbis \(updates.available)").font(.system(size: 13, weight: .semibold))
                Button("Открыть обновление", action: updates.openRelease)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
        }
    }
}
