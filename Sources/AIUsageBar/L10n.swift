import Foundation

/// 界面语言。默认跟随系统，config.json 的 `"language"`（"auto" / "zh" / "en"）可强制指定。
///
/// 不走 Localizable.strings 资源包 —— .app 是 bundle.sh 手工拼的，资源打包一环容易脆；
/// 文案就地写两种语言（`L("中文", "English")`），加语言时再考虑上资源包。
enum L10n {
    private(set) static var isZh: Bool = resolve()

    /// 「重新加载配置」后调用，语言改动即时生效（菜单每次打开都重建）。
    static func reload() { isZh = resolve() }

    private static func resolve() -> Bool {
        switch Settings.shared.language {
        case "zh": return true
        case "en": return false
        default:   return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }
}

/// 内联双语文案。只包用户可见的字符串，内部 key / id 不走这里。
func L(_ zh: String, _ en: String) -> String { L10n.isZh ? zh : en }
