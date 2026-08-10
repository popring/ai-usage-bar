import Foundation

/// 用户配置。
///
/// 位置：`~/.config/ai-usage-bar/config.json`。首次运行会写一份带注释说明的模板，
/// 用户改完即可 —— 不需要改代码、不需要重新编译。
///
/// 任何和具体某个人/某家公司相关的东西（网关地址、API key、要看哪些来源）都只
/// 存在这个文件里，**不进仓库**。
struct Settings {

    struct ProviderSettings {
        var enabled: Bool
        var options: [String: String]

        func string(_ key: String) -> String? {
            let v = options[key]
            return (v?.isEmpty ?? true) ? nil : v
        }
    }

    var providers: [String: ProviderSettings]
    var pollMinutes: Int
    var menuBarPrefix: String

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ai-usage-bar/config.json")

    // MARK: - 加载

    /// 当前生效的配置。菜单里的「重新加载配置」会重算它，不需要重启应用。
    static private(set) var shared: Settings = load()

    /// 重新读盘。改完 config.json 后调用即可生效。
    @discardableResult
    static func reload() -> Settings {
        shared = load()
        return shared
    }

    private static func load() -> Settings {
        // 放在这里而不是 app 启动回调里：--dump 这类不起 UI 的路径也要覆盖到。
        tightenPermissionsIfNeeded()

        guard let data = try? Data(contentsOf: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            writeTemplateIfMissing()
            return .defaults
        }

        var providers: [String: ProviderSettings] = [:]
        if let raw = root["providers"] as? [String: Any] {
            for (id, value) in raw {
                guard let dict = value as? [String: Any] else { continue }
                let options = dict
                    .filter { $0.key != "enabled" }
                    .compactMapValues { $0 as? String }
                providers[id] = ProviderSettings(
                    enabled: dict["enabled"] as? Bool ?? true,
                    options: options)
            }
        }

        return Settings(
            providers: providers,
            pollMinutes: max(1, root["pollMinutes"] as? Int ?? defaults.pollMinutes),
            menuBarPrefix: root["menuBarPrefix"] as? String ?? defaults.menuBarPrefix)
    }

    static let defaults = Settings(providers: [:], pollMinutes: 6, menuBarPrefix: "AI")

    /// 某个来源的配置；没写过就按「启用、无选项」处理，保证开箱即用。
    func forProvider(_ id: String) -> ProviderSettings {
        providers[id] ?? ProviderSettings(enabled: true, options: [:])
    }

    // MARK: - 模板

    /// 首次运行写一份模板，用户照着填就行。已存在则不动。
    static func writeTemplateIfMissing() {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        let template = """
        {
          "_说明": "改完重启 AI Usage Bar 生效。删掉某个来源的 enabled 或设为 false 即可隐藏它。",
          "pollMinutes": 6,
          "menuBarPrefix": "AI",

          "providers": {
            "claude-code": {
              "enabled": true,
              "_说明": "自动发现 ~/.claude 和 ~/.claude-* 配置目录，无需额外配置。"
            },
            "codex": {
              "enabled": true,
              "_说明": "读 ~/.codex/auth.json，无需额外配置。个人版看百分比窗口，business/team 看支出额度。"
            },
            "litellm": {
              "enabled": false,
              "baseURL": "",
              "apiKey": "",
              "_说明": "自建 LiteLLM 网关。填上 baseURL 和 apiKey 并把 enabled 改成 true。也可以改用环境变量 LITELLM_BASE_URL / LITELLM_API_KEY。"
            }
          }
        }

        """
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try template.write(to: path, atomically: true, encoding: .utf8)
            // 这个文件是要放 API key 的，别让同机其他用户读到。
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            // 写不了就算了，全部走默认值，不影响使用。
        }
    }

    /// 用户可能手动建配置文件、或从别处拷过来，权限未必对。
    /// 里面存着 API key，启动时收紧一次。
    static func tightenPermissionsIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path.path),
              let perms = attrs[.posixPermissions] as? NSNumber,
              perms.int16Value & 0o077 != 0            // group / other 有任何权限
        else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
