import Foundation

struct ConnectionProblem {
    enum Action { case retry, settings, network }
    let message: String
    let action: Action
    static func explain(_ error: Error) -> Self {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("another pac") || raw.contains("conflicting proxy") || raw.contains("другой vpn") {
            return Self(message: "Системным прокси управляет другая программа. Проверьте настройки сети или выберите ручной режим Balbis.", action: .network)
        }
        if let error = error as? UserFacingError { return Self(message: error.message, action: .settings) }
        if raw.contains("восстанов") || raw.contains("журнал") {
            return Self(message: "Остались настройки прошлого подключения. Откройте диагностику и восстановите настройки.", action: .settings)
        }
        if raw.contains("служб") || raw.contains("password") || raw.contains("authorized") || raw.contains("canceled") {
            return Self(message: "Служба подключения не готова или разрешение не получено. Проверьте её в диагностике.", action: .settings)
        }
        if raw.contains("регион") || raw.contains("стран") || raw.contains("туннел") || raw.contains("движок") {
            return Self(message: "Зарубежный выход сейчас недоступен. Повторите попытку или выберите другую страну в настройках.", action: .settings)
        }
        return Self(message: "Не удалось передать запрос. Проверьте доступ к интернету и повторите подключение.", action: .retry)
    }
}
