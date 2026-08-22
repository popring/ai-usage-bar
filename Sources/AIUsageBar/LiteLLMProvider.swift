import Foundation

/// LiteLLM 网关（OpenAI 兼容的自建 AI 网关）的预算余额。
///
/// 数据来自 LiteLLM 的 `GET /key/info`，返回 `spend` / `max_budget` /
/// `budget_duration` / `budget_reset_at`。这是网关自己的公开接口，不是私有口。
///
/// 与 Claude Code 那条不同：这里 **读是网络请求**，所以 `refresh()` 拉一次并写本地
/// 缓存，`readAccounts()` 只读缓存 —— 保证菜单打开时不卡在网络上。
struct LiteLLMProvider: UsageProvider {
    let id = "litellm"
    let displayName = "LiteLLM"

    private static let cacheFile = AppHome.url
        .appendingPathComponent(".cache/ai-usage-bar/litellm.json")

    // MARK: - 配置

    /// base URL 与 API key 的来源，按优先级。
    ///
    /// 从 Finder 启动的 .app **拿不到 shell 环境变量**，所以必须能从 `~/.zshrc`
    /// 里把那两个 export 捞出来，否则装成 app 之后就没数据了。
    struct Config {
        let baseURL: String
        let apiKey: String
        /// 值是从哪读到的 —— 设置面板要据此提示用户。
        let source: Source

        enum Source {
            case configFile, environment, zshrc
            var label: String {
                switch self {
                case .configFile: return "配置文件"
                case .environment: return "环境变量"
                case .zshrc: return "~/.zshrc"
                }
            }
        }
    }

    static func resolveConfig() -> Config? {
        // 1) 配置文件优先 —— 这是给普通用户的正经入口
        let settings = Settings.shared.forProvider("litellm")
        if let base = settings.string("baseURL"), let key = settings.string("apiKey") {
            return Config(baseURL: base, apiKey: key, source: .configFile)
        }

        // 2) 环境变量
        let env = ProcessInfo.processInfo.environment
        if let base = env["LITELLM_BASE_URL"], let key = env["LITELLM_API_KEY"],
           !base.isEmpty, !key.isEmpty {
            return Config(baseURL: base, apiKey: key, source: .environment)
        }

        let zshrc = AppHome.url
            .appendingPathComponent(".zshrc")
        guard let text = try? String(contentsOf: zshrc, encoding: .utf8) else { return nil }

        var found: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.hasPrefix("#") else { continue }          // 注释掉的不算
            for name in ["LITELLM_BASE_URL", "LITELLM_API_KEY"] where found[name] == nil {
                guard let r = s.range(of: "\(name)=") else { continue }
                var value = String(s[r.upperBound...])
                if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
                value = value.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty { found[name] = value }
            }
        }
        guard let base = found["LITELLM_BASE_URL"], let key = found["LITELLM_API_KEY"] else {
            return nil
        }
        return Config(baseURL: base, apiKey: key, source: .zshrc)
    }

    // MARK: - UsageProvider

    func readAccounts() -> [Account] {
        [readAccount()].compactMap { $0 }
    }

    private func readAccount() -> Account? {
        guard Self.resolveConfig() != nil else { return nil }   // 没配就整个不显示

        var account = Account(providerID: id, localID: "key", label: "网关")
        account.isLoggedIn = true

        guard let data = try? Data(contentsOf: Self.cacheFile),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            account.error = "还没取过，点「立即刷新」"
            return account
        }

        account.org = root["alias"] as? String ?? "AI 网关"
        account.fetchedAt = (root["fetchedAt"] as? Double).map { Date(timeIntervalSince1970: $0) }

        let spend = root["spend"] as? Double ?? 0
        let maxBudget = root["maxBudget"] as? Double

        if let maxBudget, maxBudget > 0 {
            account.extraUsage = ExtraUsage(
                usedMinor: Int((spend * 100).rounded()),
                limitMinor: Int((maxBudget * 100).rounded()))
            var resets: Date?
            if let iso = root["resetAt"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                resets = f.date(from: iso) ?? {
                    let g = ISO8601DateFormatter()
                    g.formatOptions = [.withInternetDateTime]
                    return g.date(from: iso)
                }()
            }
            account.windows = [LimitWindow(
                kind: "budget",
                label: root["duration"] as? String ?? "",
                percent: spend / maxBudget * 100,
                resetsAt: resets,
                isActive: true)]
        } else {
            // 没有预算上限时，只有花费没有百分比可言。
            account.extraUsage = ExtraUsage(usedMinor: Int((spend * 100).rounded()), limitMinor: 0)
            account.error = String(format: "已花 $%.2f（未设预算上限）", spend)
        }

        return account
    }

    func refresh(_ account: Account) -> RefreshResult {
        guard let cfg = Self.resolveConfig() else {
            return .failed("没配 LITELLM_BASE_URL / LITELLM_API_KEY")
        }
        let base = cfg.baseURL.hasSuffix("/") ? String(cfg.baseURL.dropLast()) : cfg.baseURL
        guard let url = URL(string: "\(base)/key/info") else {
            return .failed("LITELLM_BASE_URL 不是合法 URL")
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")

        var payload: Data?
        var status = 0
        var failure: String?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            payload = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            failure = error?.localizedDescription
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 25) == .success else {
            return .failed("网关超时")
        }
        if let failure { return .failed(failure) }
        guard status == 200 else { return .failed("网关返回 HTTP \(status)") }
        guard let payload,
              let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let info = root["info"] as? [String: Any]
        else { return .failed("网关返回看不懂") }

        // 只留要用的字段落盘，别把整个响应（含权限、内部 id）写进缓存。
        let slim: [String: Any] = [
            "fetchedAt": Date().timeIntervalSince1970,
            "alias": info["key_alias"] as? String ?? "AI 网关",
            "spend": info["spend"] as? Double ?? 0,
            "maxBudget": info["max_budget"] as? Double as Any,
            "duration": info["budget_duration"] as? String as Any,
            "resetAt": info["budget_reset_at"] as? String as Any,
        ].compactMapValues { $0 is NSNull ? nil : $0 }

        do {
            try FileManager.default.createDirectory(
                at: Self.cacheFile.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: slim).write(to: Self.cacheFile)
        } catch {
            return .failed("缓存写不进去：\(error.localizedDescription)")
        }
        return .updated
    }
}
