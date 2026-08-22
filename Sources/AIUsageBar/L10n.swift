import Foundation

/// UI language. Follows the system by default; config.json's `"language"`
/// ("auto" / "zh" / "en") can force it.
///
/// No Localizable.strings bundle — the .app is hand-assembled by bundle.sh and the
/// resource-packing step is fragile; strings are written inline in both languages
/// (`L("中文", "English")`). Revisit a resource bundle if more languages are added.
enum L10n {
    private(set) static var isZh: Bool = resolve()

    /// Called after "reload config" so a language change takes effect immediately
    /// (the menu is rebuilt on every open).
    static func reload() { isZh = resolve() }

    private static func resolve() -> Bool {
        switch Settings.shared.language {
        case "zh": return true
        case "en": return false
        default:   return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }
}

/// Inline bilingual copy. User-visible strings only; internal keys/ids don't go
/// through this.
func L(_ zh: String, _ en: String) -> String { L10n.isZh ? zh : en }
