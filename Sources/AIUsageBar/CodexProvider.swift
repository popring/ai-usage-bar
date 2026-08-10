import Foundation

/// Codex（OpenAI）额度。
///
/// 数据来自 `GET https://chatgpt.com/backend-api/wham/usage`，用 `~/.codex/auth.json`
/// 里的 ChatGPT OAuth access token 认证 —— 和 Codex CLI 自己用的是同一个凭证、同一个口。
///
/// **这是未公开接口**，OpenAI 随时可能改。改动只会波及本文件。
///
/// 计划类型决定了额度长在哪：
///   - 个人版（Plus/Pro）：`rate_limit` 里的 primary/secondary 百分比窗口
///   - **business / team：`spend_control.individual_limit` 的美元额度**，
///     `rate_limit` 和 `credits` 都是空的
/// 本地 session rollout 文件只记了 `rate_limits`，所以在 business 计划下看着像没数据，
/// 其实是记错了地方 —— 必须打这个接口才拿得到。
struct CodexProvider: UsageProvider {
    let id = "codex"
    let displayName = "Codex"

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let authFile = home.appendingPathComponent(".codex/auth.json")
    private static let cacheFile = home.appendingPathComponent(".cache/ai-usage-bar/codex.json")
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// 设置面板显示登录状态用。判断标准和 readAccounts 一致：auth.json 存在即算。
    static var isLoggedIn: Bool {
        FileManager.default.fileExists(atPath: authFile.path)
    }

    // MARK: - UsageProvider

    func readAccounts() -> [Account] {
        guard FileManager.default.fileExists(atPath: Self.authFile.path) else { return [] }

        var account = Account(providerID: id, localID: "codex", label: "Codex")
        account.isLoggedIn = true

        guard let data = try? Data(contentsOf: Self.cacheFile),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            account.error = "还没取过，点「立即刷新」"
            return [account]
        }

        let plan = root["plan"] as? String
        account.org = [root["email"] as? String, plan.map { "（\($0)）" }]
            .compactMap { $0 }.joined()
        account.email = root["email"] as? String
        account.seatTier = plan
        account.fetchedAt = (root["fetchedAt"] as? Double).map { Date(timeIntervalSince1970: $0) }

        // business / team：美元额度
        if let used = root["spendUsed"] as? Double, let limit = root["spendLimit"] as? Double,
           limit > 0 {
            account.extraUsage = ExtraUsage(usedMinor: Int((used * 100).rounded()),
                                            limitMinor: Int((limit * 100).rounded()))
            account.windows = [LimitWindow(
                kind: "budget",
                label: "",          // 留空，显示成「预算」；带 label 会变成「X 预算」

                percent: used / limit * 100,
                resetsAt: (root["spendResetAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
                isActive: true)]
        }

        // 个人版（Plus/Pro）：百分比窗口。两种计划只会命中一种，直接追加即可。
        if let windows = root["windows"] as? [[String: Any]] {
            account.windows += windows.compactMap { w in
                guard let name = w["name"] as? String, let pct = w["percent"] as? Double
                else { return nil }
                return LimitWindow(
                    kind: "window",
                    label: name,
                    percent: pct,
                    resetsAt: (w["resetAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
                    isActive: false)
            }
        }

        if account.windows.isEmpty && account.extraUsage == nil {
            account.error = "该计划未下发额度数据"
        }
        return [account]
    }

    func refresh(_ account: Account) -> RefreshResult {
        switch fetch() {
        case .success(let json):
            return persist(json)
        case .failure(.unauthorized):
            // access token 过期了。`codex doctor` 会用 refresh_token 换一个新的
            // 并写回 auth.json —— 比自己走 OAuth 刷新流程安全，也不动用户的登录态。
            guard refreshToken() else { return .failed("token 过期，且刷新失败（试试跑一次 codex）") }
            switch fetch() {
            case .success(let json): return persist(json)
            case .failure(let e):    return .failed(e.message)
            }
        case .failure(let e):
            return .failed(e.message)
        }
    }

    // MARK: - 细节

    private enum FetchError: Error {
        case noAuth, unauthorized, http(Int), transport(String), badPayload

        var message: String {
            switch self {
            case .noAuth:            return "读不到 ~/.codex/auth.json"
            case .unauthorized:      return "token 未授权"
            case .http(let code):    return "HTTP \(code)"
            case .transport(let m):  return m
            case .badPayload:        return "返回看不懂"
            }
        }
    }

    private func fetch() -> Result<[String: Any], FetchError> {
        guard let authData = try? Data(contentsOf: Self.authFile),
              let auth = (try? JSONSerialization.jsonObject(with: authData)) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String
        else { return .failure(.noAuth) }

        var request = URLRequest(url: Self.usageURL, timeoutInterval: 20)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = tokens["account_id"] as? String {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.setValue("ai-usage-bar", forHTTPHeaderField: "User-Agent")

        var payload: Data?
        var status = 0
        var transportError: String?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            payload = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            transportError = error?.localizedDescription
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 25) == .success else {
            return .failure(.transport("超时"))
        }
        if let transportError { return .failure(.transport(transportError)) }
        if status == 401 { return .failure(.unauthorized) }
        guard status == 200 else { return .failure(.http(status)) }
        guard let payload,
              let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        else { return .failure(.badPayload) }
        return .success(root)
    }

    /// JSON 里数字可能是 Int / Double / 字符串，统一取。
    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// 用窗口时长推一个好读的名字（300 分钟 → 5h，10080 → 7d），
    /// 推不出来就退回 primary / secondary。
    private static func windowLabel(_ window: [String: Any], fallback: String) -> String {
        guard let minutes = number(window["window_minutes"] ?? window["window_size_minutes"]),
              minutes > 0 else { return fallback }
        if minutes < 60 { return "\(Int(minutes))m" }
        if minutes < 1440 { return "\(Int(minutes / 60))h" }
        return "\(Int(minutes / 1440))d"
    }

    /// 跑 `codex doctor` 换一个新 access token。它会把结果写回 auth.json。
    /// 走登录 shell，因为 codex 常装在 fnm/nvm 下，PATH 不走 shell 解析不出来。
    private func refreshToken() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "codex doctor"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }

        let deadline = Date().addingTimeInterval(60)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if proc.isRunning { proc.terminate(); return false }
        return proc.terminationStatus == 0
    }

    /// 只落用得上的字段，不把整个响应（含 user_id 等）写进缓存。
    private func persist(_ json: [String: Any]) -> RefreshResult {
        var slim: [String: Any] = [
            "fetchedAt": Date().timeIntervalSince1970,
            "email": json["email"] as? String as Any,
            "plan": json["plan_type"] as? String as Any,
        ]

        if let spend = json["spend_control"] as? [String: Any],
           let limit = spend["individual_limit"] as? [String: Any] {
            // 这几个值是字符串形式的数字，得转。
            slim["spendUsed"] = (limit["used"] as? String).flatMap(Double.init)
            slim["spendLimit"] = (limit["limit"] as? String).flatMap(Double.init)
            slim["spendResetAt"] = limit["reset_at"] as? Double
        }

        // 个人版（Plus/Pro）：primary / secondary 百分比窗口。
        // 这条路径无法在 business 账号上实测，所以字段名和类型都兼容几种可能，
        // 缺哪个就退化成不显示，绝不因为形状不对而整个崩掉。
        if let rate = json["rate_limit"] as? [String: Any] {
            let windows: [[String: Any]] = ["primary", "secondary"].compactMap { key in
                guard let w = rate[key] as? [String: Any],
                      let pct = Self.number(w["used_percent"] ?? w["used_percentage"])
                else { return nil }

                var entry: [String: Any] = ["name": Self.windowLabel(w, fallback: key),
                                            "percent": pct]
                // reset 可能给绝对时间戳，也可能给"还剩多少秒"
                if let at = Self.number(w["reset_at"] ?? w["resets_at"]) {
                    entry["resetAt"] = at
                } else if let after = Self.number(w["resets_in_seconds"] ?? w["reset_after_seconds"]) {
                    entry["resetAt"] = Date().timeIntervalSince1970 + after
                }
                return entry
            }
            if !windows.isEmpty { slim["windows"] = windows }
        }

        slim = slim.compactMapValues { $0 is NSNull ? nil : $0 }

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
