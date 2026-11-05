import Foundation

/// Russian source keys are stable; Bundle selects the user's preferred supported macOS language.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return arguments.isEmpty ? format : String(format: format, locale: Locale.current, arguments: arguments)
}
