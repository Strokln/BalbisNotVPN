import Foundation
import ServiceManagement

enum LoginItemState: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

protocol LoginItemManaging {
    var state: LoginItemState { get }
    func setEnabled(_ enabled: Bool) throws
    func openSettings()
}

struct SystemLoginItem: LoginItemManaging {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .disabled
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
            let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
            let installed = bundle.pathExtension.lowercased() == "app" && roots.contains {
                bundle.path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/")
            }
            guard installed else {
                throw BalbisError("Для запуска при входе переместите Balbis в папку «Программы» (/Applications или ~/Applications) и запустите его оттуда.")
            }
            switch state {
            case .enabled, .requiresApproval: return
            case .disabled, .unavailable: try SMAppService.mainApp.register()
            }
        } else {
            switch state {
            case .enabled, .requiresApproval: try SMAppService.mainApp.unregister()
            case .disabled, .unavailable: return
            }
        }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
