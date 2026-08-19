import Foundation

/// 从 Claude Code 的本地状态里读出各 team 的用量。
///
/// 只读 `.claude.json`，不碰任何凭证（凭证在 macOS Keychain 里，本程序不需要）。
enum UsageReader {

    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// 发现所有配置目录：`~/.claude` 和 `~/.claude-*`。
    static func configDirs() -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []

        let defaultDir = home.appendingPathComponent(".claude")
        if isDir(defaultDir) { dirs.append(defaultDir) }

        let contents = (try? fm.contentsOfDirectory(
            at: home, includingPropertiesForKeys: nil, options: [])) ?? []
        dirs += contents
            .filter { $0.lastPathComponent.hasPrefix(".claude-") && isDir($0) }
            // claude-swap 的备份目录不是 Claude 配置目录，别当成一个 team。
            .filter { $0.lastPathComponent != ".claude-swap-backup" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return dirs
    }

    private static func isDir(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// 定位某个配置目录对应的状态文件。
    ///
    /// 坑：默认目录 `~/.claude` 的状态文件在 **`~/.claude.json`**（家目录下），
    /// 不在目录内部；自定义 `CLAUDE_CONFIG_DIR` 的才在目录里。两处都探。
    static func stateFile(for configDir: URL) -> URL? {
        var candidates = [configDir.appendingPathComponent(".claude.json")]
        if configDir.lastPathComponent == ".claude" {
            candidates.append(home.appendingPathComponent(".claude.json"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 读一个配置目录，产出一条账号记录。
    static func read(_ configDir: URL, providerID: String) -> Account {
        var account = Account(
            providerID: providerID,
            localID: configDir.path,
            label: configDir.lastPathComponent,
            isDefaultDir: configDir.lastPathComponent == ".claude"
        )

        guard let state = stateFile(for: configDir) else {
            account.error = "未登录"
            return account
        }
        guard
            let data = try? Data(contentsOf: state),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            account.error = "状态文件读不出来"
            return account
        }
        guard let oauth = root["oauthAccount"] as? [String: Any] else {
            account.error = "未登录"
            return account
        }

        account.isLoggedIn = true
        account.org = oauth["organizationName"] as? String
        account.orgUuid = oauth["organizationUuid"] as? String
        account.email = oauth["emailAddress"] as? String
        account.seatTier = oauth["seatTier"] as? String

        if let cached = root["cachedUsageUtilization"] as? [String: Any],
           let fetchedMs = cached["fetchedAtMs"] as? Double {
            account.fetchedAt = Date(timeIntervalSince1970: fetchedMs / 1000)
            let util = cached["utilization"] as? [String: Any] ?? [:]
            account.windows = parseWindows(util)
            account.extraUsage = parseExtra(util)
        } else {
            account.error = "还没取过用量"
        }

        // `.claude.json` 的缓存只有交互式 /usage 才更新（CLI ≥2.1.228 无头跑不动了），
        // 主力数据来自 Refresher 直连端点的结果 —— 两边谁新用谁。
        if let fresh = Refresher.cached(configDir),
           fresh.fetchedAt > (account.fetchedAt ?? .distantPast) {
            account.fetchedAt = fresh.fetchedAt
            account.windows = parseWindows(fresh.utilization)
            account.extraUsage = parseExtra(fresh.utilization)
            account.error = nil
        }
        return account
    }

    // MARK: - 解析细节

    /// 优先用 `limits[]`（含 weekly_scoped 之类的细分），没有再回落到 five_hour / seven_day。
    private static func parseWindows(_ util: [String: Any]) -> [LimitWindow] {
        if let limits = util["limits"] as? [[String: Any]], !limits.isEmpty {
            return limits.compactMap { item in
                guard let kind = item["kind"] as? String else { return nil }
                let scope = item["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                return LimitWindow(
                    kind: kind,
                    label: model ?? "",
                    percent: number(item["percent"]) ?? 0,
                    resetsAt: parseDate(item["resets_at"]),
                    isActive: item["is_active"] as? Bool ?? false
                )
            }
        }

        var fallback: [LimitWindow] = []
        for (kind, key) in [("session", "five_hour"), ("weekly_all", "seven_day")] {
            guard let w = util[key] as? [String: Any] else { continue }
            fallback.append(LimitWindow(
                kind: kind,
                label: "",
                percent: number(w["utilization"]) ?? 0,
                resetsAt: parseDate(w["resets_at"]),
                isActive: false
            ))
        }
        return fallback
    }

    private static func parseExtra(_ util: [String: Any]) -> ExtraUsage? {
        guard let extra = util["extra_usage"] as? [String: Any],
              extra["is_enabled"] as? Bool == true else { return nil }
        return ExtraUsage(
            usedMinor: Int(number(extra["used_credits"]) ?? 0),
            limitMinor: Int(number(extra["monthly_limit"]) ?? 0)
        )
    }

    /// JSON 里数字有时是 Int 有时是 Double，统一取。
    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// `resets_at` 形如 "2026-08-10T06:40:00.419888+00:00"，
    /// 小数位有 6 位，ISO8601DateFormatter 只吃 3 位，所以先截断再解析。
    private static func parseDate(_ any: Any?) -> Date? {
        guard let raw = any as? String else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }

        // 把 .419888 压成 .419 再试
        if let dot = raw.firstIndex(of: "."),
           let tzStart = raw[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let frac = raw[raw.index(after: dot)..<tzStart]
            if frac.count > 3 {
                let trimmed = raw[..<dot] + "." + frac.prefix(3) + raw[tzStart...]
                if let d = iso.date(from: String(trimmed)) { return d }
            }
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
