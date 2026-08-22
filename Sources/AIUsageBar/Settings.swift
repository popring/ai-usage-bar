import Foundation

/// User configuration.
///
/// Location: `~/.config/ai-usage-bar/config.json`. First run writes an annotated
/// template the user edits directly — no code changes, no recompiling.
///
/// Anything person- or company-specific (gateway URL, API keys, which sources to
/// show) lives only in this file and **never enters the repo**.
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
    /// UI language: "auto" (follow system) / "zh" / "en".
    var language: String

    /// Respects XDG_CONFIG_HOME (default ~/.config). Note `homeDirectoryForCurrentUser`
    /// ignores the $HOME env var, so tests can only isolate config via XDG_CONFIG_HOME.
    static let path: URL = {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? AppHome.url.appendingPathComponent(".config")
        return base.appendingPathComponent("ai-usage-bar/config.json")
    }()

    // MARK: - Loading

    /// The active configuration. "Reload Config" in the menu recomputes it — no app restart needed.
    static private(set) var shared: Settings = load()

    @discardableResult
    static func reload() -> Settings {
        shared = load()
        L10n.reload()
        return shared
    }

    private static func load() -> Settings {
        // Done here rather than in the app-launch callback so UI-less paths like --dump are covered too.
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
            menuBarPrefix: root["menuBarPrefix"] as? String ?? defaults.menuBarPrefix,
            language: root["language"] as? String ?? defaults.language)
    }

    /// Default poll: 20 min. Opening the menu refreshes anyway, so background polling is a
    /// fallback — but polling too rarely leaves the menu-bar number stale for long stretches.
    static let defaults = Settings(providers: [:], pollMinutes: 20, menuBarPrefix: "AI",
                                   language: "auto")

    // MARK: - Saving (settings panel)

    /// Merge the panel's values back into config.json, then reload immediately.
    ///
    /// Merge rather than rewrite: the user's hand-written `_说明`/`_note` entries and
    /// fields the panel doesn't manage are preserved.
    static func save(providerEnabled: [String: Bool],
                     providerOptions: [String: [String: String]],
                     pollMinutes: Int,
                     menuBarPrefix: String,
                     language: String) throws {
        var root = (try? Data(contentsOf: path))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]

        // Floor of 5: /usage only re-fetches roughly every 5 minutes, so polling more often is wasted.
        root["pollMinutes"] = max(5, pollMinutes)
        root["menuBarPrefix"] = menuBarPrefix
        root["language"] = language

        var providers = root["providers"] as? [String: Any] ?? [:]
        for (id, enabled) in providerEnabled {
            var p = providers[id] as? [String: Any] ?? [:]
            p["enabled"] = enabled
            for (key, value) in providerOptions[id] ?? [:] { p[key] = value }
            providers[id] = p
        }
        root["providers"] = providers

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
        // The atomic write creates a new file, so permissions must be tightened again.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path.path)

        reload()
    }

    /// Settings for one provider; unconfigured providers default to enabled with no options,
    /// so everything works out of the box.
    func forProvider(_ id: String) -> ProviderSettings {
        providers[id] ?? ProviderSettings(enabled: true, options: [:])
    }

    // MARK: - Template

    /// Writes a template on first run for the user to fill in. No-op if the file exists.
    ///
    /// Must not use `L()`: the template is written during `load()`, before `Settings.shared`
    /// finishes initializing, so `L()` reading shared would re-enter static initialization.
    /// No config exists yet anyway — check the system language directly.
    static func writeTemplateIfMissing() {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        let template = zh ? """
        {
          "_说明": "改完重启 AI Usage Bar 生效。删掉某个来源的 enabled 或设为 false 即可隐藏它。language: auto=跟随系统, zh, en。",
          "pollMinutes": 20,
          "menuBarPrefix": "AI",
          "language": "auto",

          "providers": {
            "claude-code": {
              "enabled": true,
              "_说明": "自动发现 ~/.claude 和 ~/.claude-* 配置目录，无需额外配置。"
            },
            "claude-swap": {
              "enabled": true,
              "_说明": "读 claude-swap（cswap）的 ~/.claude-swap-backup 缓存，无需额外登录。和 Claude Code 目录同 org 时自动去重，目录那份优先。"
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

        """ : """
        {
          "_note": "Restart AI Usage Bar after editing. Set a provider's enabled to false (or delete it) to hide it. language: auto = follow system, zh, en.",
          "pollMinutes": 20,
          "menuBarPrefix": "AI",
          "language": "auto",

          "providers": {
            "claude-code": {
              "enabled": true,
              "_note": "Auto-discovers ~/.claude and ~/.claude-* config directories; no setup needed."
            },
            "claude-swap": {
              "enabled": true,
              "_note": "Reads claude-swap (cswap)'s ~/.claude-swap-backup cache; no extra login. Deduplicated with Claude Code directories sharing an org — the directory wins."
            },
            "codex": {
              "enabled": true,
              "_note": "Reads ~/.codex/auth.json; no setup needed. Personal plans show percentage windows, business/team shows spend quota."
            },
            "litellm": {
              "enabled": false,
              "baseURL": "",
              "apiKey": "",
              "_note": "Self-hosted LiteLLM gateway. Fill in baseURL and apiKey, then set enabled to true. Env vars LITELLM_BASE_URL / LITELLM_API_KEY also work."
            }
          }
        }

        """
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try template.write(to: path, atomically: true, encoding: .utf8)
            // This file will hold API keys — keep it unreadable to other users on the machine.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            // If the write fails, fall back to defaults; the app still works.
        }
    }

    /// The user may create the config by hand or copy it from elsewhere, so permissions
    /// may be wrong. It holds API keys — tighten once at startup.
    static func tightenPermissionsIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path.path),
              let perms = attrs[.posixPermissions] as? NSNumber,
              perms.int16Value & 0o077 != 0            // group/other has any permission
        else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
