import Foundation

/// Codex (OpenAI) quota.
///
/// Data comes from `GET https://chatgpt.com/backend-api/wham/usage`, authenticated with
/// the ChatGPT OAuth access token in `~/.codex/auth.json` — the same credential and
/// endpoint the Codex CLI itself uses.
///
/// **This is an undocumented API** — OpenAI may change it at any time. Breakage stays
/// contained to this file.
///
/// Where the quota lives depends on the plan:
///   - Personal (Plus/Pro): primary/secondary percentage windows under `rate_limit`
///   - **business/team: a credits quota (not dollars) under `spend_control.individual_limit`**,
///     with `rate_limit` and `credits` both empty
/// Local session rollout files only record `rate_limits`, so business plans look like they
/// have no data — it's just recorded in the wrong place; this endpoint is the only way to get it.
struct CodexProvider: UsageProvider {
    let id = "codex"
    let displayName = "Codex"

    private static let home = AppHome.url
    private static let authFile = home.appendingPathComponent(".codex/auth.json")
    private static let cacheFile = home.appendingPathComponent(".cache/ai-usage-bar/codex.json")
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// Login status for the settings panel. Same criterion as readAccounts: auth.json exists.
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
            account.error = L("还没取过，点「立即刷新」", "Not fetched yet — click \"Refresh Now\"")
            return [account]
        }

        let plan = root["plan"] as? String
        account.org = [root["email"] as? String, plan.map { L("（\($0)）", " (\($0))") }]
            .compactMap { $0 }.joined()
        account.email = root["email"] as? String
        account.seatTier = plan
        account.fetchedAt = (root["fetchedAt"] as? Double).map { Date(timeIntervalSince1970: $0) }

        // business/team: credits quota
        if let used = root["spendUsed"] as? Double, let limit = root["spendLimit"] as? Double,
           limit > 0 {
            account.extraUsage = ExtraUsage(usedMinor: Int((used * 100).rounded()),
                                            limitMinor: Int((limit * 100).rounded()),
                                            isCredits: true)
            account.windows = [LimitWindow(
                kind: "budget",
                label: "",          // empty renders as "Budget"; a label would render as "X Budget"

                percent: used / limit * 100,
                resetsAt: (root["spendResetAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
                isActive: true)]
        }

        // Personal (Plus/Pro): percentage windows. Only one plan type ever matches, so appending is fine.
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
            account.error = L("该计划未下发额度数据", "this plan exposes no quota data")
        }
        return [account]
    }

    func refresh(_ account: Account) -> RefreshResult {
        switch fetch() {
        case .success(let json):
            return persist(json)
        case .failure(.unauthorized):
            // Access token expired. `codex doctor` exchanges the refresh_token for a new
            // one and writes it back to auth.json — safer than running the OAuth refresh
            // flow ourselves, and it doesn't touch the user's login state.
            guard refreshToken() else {
                return .failed(L("token 过期，且刷新失败（试试跑一次 codex）",
                                 "token expired, and refresh failed (try running codex once)"))
            }
            switch fetch() {
            case .success(let json): return persist(json)
            case .failure(let e):    return .failed(e.message)
            }
        case .failure(let e):
            return .failed(e.message)
        }
    }

    // MARK: - Details

    private enum FetchError: Error {
        case noAuth, unauthorized, http(Int), transport(String), badPayload

        var message: String {
            switch self {
            case .noAuth:            return L("读不到 ~/.codex/auth.json", "can't read ~/.codex/auth.json")
            case .unauthorized:      return L("token 未授权", "token unauthorized")
            case .http(let code):    return "HTTP \(code)"
            case .transport(let m):  return m
            case .badPayload:        return L("返回看不懂", "unrecognized response")
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
            return .failure(.transport(L("超时", "timed out")))
        }
        if let transportError { return .failure(.transport(transportError)) }
        if status == 401 { return .failure(.unauthorized) }
        guard status == 200 else { return .failure(.http(status)) }
        guard let payload,
              let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        else { return .failure(.badPayload) }
        return .success(root)
    }

    /// JSON numbers may arrive as Int / Double / String; normalize.
    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// Derive a readable name from the window length (300 minutes → 5h, 10080 → 7d),
    /// falling back to primary/secondary when it can't be derived.
    private static func windowLabel(_ window: [String: Any], fallback: String) -> String {
        guard let minutes = number(window["window_minutes"] ?? window["window_size_minutes"]),
              minutes > 0 else { return fallback }
        if minutes < 60 { return "\(Int(minutes))m" }
        if minutes < 1440 { return "\(Int(minutes / 60))h" }
        return "\(Int(minutes / 1440))d"
    }

    /// Run `codex doctor` to get a fresh access token; it writes the result back to auth.json.
    /// Uses a login shell because codex is often installed under fnm/nvm, which a plain
    /// PATH lookup can't resolve.
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

    /// Persist only the fields we use — not the whole response (user_id etc.).
    private func persist(_ json: [String: Any]) -> RefreshResult {
        var slim: [String: Any] = [
            "fetchedAt": Date().timeIntervalSince1970,
            "email": json["email"] as? String as Any,
            "plan": json["plan_type"] as? String as Any,
        ]

        if let spend = json["spend_control"] as? [String: Any],
           let limit = spend["individual_limit"] as? [String: Any] {
            // These values are numbers encoded as strings; convert.
            slim["spendUsed"] = (limit["used"] as? String).flatMap(Double.init)
            slim["spendLimit"] = (limit["limit"] as? String).flatMap(Double.init)
            slim["spendResetAt"] = limit["reset_at"] as? Double
        }

        // Personal (Plus/Pro): primary/secondary percentage windows.
        // This path can't be tested from a business account, so field names and types
        // tolerate several variants; anything missing degrades to not showing — never
        // crash outright over an unexpected shape.
        if let rate = json["rate_limit"] as? [String: Any] {
            let windows: [[String: Any]] = ["primary", "secondary"].compactMap { key in
                guard let w = rate[key] as? [String: Any],
                      let pct = Self.number(w["used_percent"] ?? w["used_percentage"])
                else { return nil }

                var entry: [String: Any] = ["name": Self.windowLabel(w, fallback: key),
                                            "percent": pct]
                // reset may be an absolute timestamp or "seconds remaining"
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
            return .failed(L("缓存写不进去：\(error.localizedDescription)",
                             "can't write cache: \(error.localizedDescription)"))
        }
        return .updated
    }
}
