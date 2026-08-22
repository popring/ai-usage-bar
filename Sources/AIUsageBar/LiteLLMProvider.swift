import Foundation

/// Budget balance for a LiteLLM gateway (self-hosted, OpenAI-compatible AI gateway).
///
/// Data comes from LiteLLM's `GET /key/info`, which returns `spend` / `max_budget` /
/// `budget_duration` / `budget_reset_at`. This is the gateway's public API, not a
/// private endpoint.
///
/// Unlike the Claude Code provider, **reading here is a network request**, so
/// `refresh()` fetches once and writes a local cache while `readAccounts()` only reads
/// the cache — opening the menu never blocks on the network.
struct LiteLLMProvider: UsageProvider {
    let id = "litellm"
    let displayName = "LiteLLM"

    private static let cacheFile = AppHome.url
        .appendingPathComponent(".cache/ai-usage-bar/litellm.json")

    // MARK: - Configuration

    /// Sources for the base URL and API key, in priority order.
    ///
    /// An .app launched from Finder **gets no shell environment variables**, so we must
    /// be able to fish the two exports out of `~/.zshrc` — otherwise the packaged app
    /// would show no data.
    struct Config {
        let baseURL: String
        let apiKey: String
        /// Where the values came from — the settings panel surfaces this to the user.
        let source: Source

        enum Source {
            case configFile, environment, zshrc
            var label: String {
                switch self {
                case .configFile: return L("配置文件", "config file")
                case .environment: return L("环境变量", "environment variable")
                case .zshrc: return "~/.zshrc"
                }
            }
        }
    }

    static func resolveConfig() -> Config? {
        // 1) Config file first — the proper entry point for regular users
        let settings = Settings.shared.forProvider("litellm")
        if let base = settings.string("baseURL"), let key = settings.string("apiKey") {
            return Config(baseURL: base, apiKey: key, source: .configFile)
        }

        // 2) Environment variables
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
            guard !s.hasPrefix("#") else { continue }          // skip commented-out lines
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
        guard Self.resolveConfig() != nil else { return nil }   // unconfigured: hide entirely

        var account = Account(providerID: id, localID: "key", label: L("网关", "Gateway"))
        account.isLoggedIn = true

        guard let data = try? Data(contentsOf: Self.cacheFile),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            account.error = L("还没取过，点「立即刷新」", "Not fetched yet — click \"Refresh Now\"")
            return account
        }

        account.org = root["alias"] as? String ?? L("AI 网关", "AI Gateway")
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
            // With no budget cap there's only spend — no percentage to compute.
            account.extraUsage = ExtraUsage(usedMinor: Int((spend * 100).rounded()), limitMinor: 0)
            account.error = String(
                format: L("已花 $%.2f（未设预算上限）", "spent $%.2f (no budget cap set)"), spend)
        }

        return account
    }

    func refresh(_ account: Account) -> RefreshResult {
        guard let cfg = Self.resolveConfig() else {
            return .failed(L("没配 LITELLM_BASE_URL / LITELLM_API_KEY",
                             "LITELLM_BASE_URL / LITELLM_API_KEY not set"))
        }
        let base = cfg.baseURL.hasSuffix("/") ? String(cfg.baseURL.dropLast()) : cfg.baseURL
        guard let url = URL(string: "\(base)/key/info") else {
            return .failed(L("LITELLM_BASE_URL 不是合法 URL", "LITELLM_BASE_URL is not a valid URL"))
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
            return .failed(L("网关超时", "gateway timed out"))
        }
        if let failure { return .failed(failure) }
        guard status == 200 else {
            return .failed(L("网关返回 HTTP \(status)", "gateway returned HTTP \(status)"))
        }
        guard let payload,
              let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let info = root["info"] as? [String: Any]
        else { return .failed(L("网关返回看不懂", "unrecognized gateway response")) }

        // Persist only the fields we use — not the whole response (permissions, internal ids).
        let slim: [String: Any] = [
            "fetchedAt": Date().timeIntervalSince1970,
            "alias": info["key_alias"] as? String ?? L("AI 网关", "AI Gateway"),
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
            return .failed(L("缓存写不进去：\(error.localizedDescription)",
                             "can't write cache: \(error.localizedDescription)"))
        }
        return .updated
    }
}
