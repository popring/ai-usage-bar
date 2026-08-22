import Foundation

/// Reads per-team usage from Claude Code's local state.
///
/// Only reads `.claude.json`; never touches credentials (they live in the macOS Keychain,
/// which this app doesn't need).
enum UsageReader {

    static let home = AppHome.url

    /// Discover all config dirs: `~/.claude` and `~/.claude-*`.
    static func configDirs() -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []

        let defaultDir = home.appendingPathComponent(".claude")
        if isDir(defaultDir) { dirs.append(defaultDir) }

        let contents = (try? fm.contentsOfDirectory(
            at: home, includingPropertiesForKeys: nil, options: [])) ?? []
        dirs += contents
            .filter { $0.lastPathComponent.hasPrefix(".claude-") && isDir($0) }
            // claude-swap's backup dir is not a Claude config dir; don't treat it as a team.
            .filter { $0.lastPathComponent != ".claude-swap-backup" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return dirs
    }

    private static func isDir(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Locate the state file for a config dir.
    ///
    /// Gotcha: for the default dir `~/.claude`, the state file is **`~/.claude.json`**
    /// (in the home dir), not inside the dir; only custom `CLAUDE_CONFIG_DIR` setups
    /// keep it inside. Probe both.
    static func stateFile(for configDir: URL) -> URL? {
        var candidates = [configDir.appendingPathComponent(".claude.json")]
        if configDir.lastPathComponent == ".claude" {
            candidates.append(home.appendingPathComponent(".claude.json"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Read one config dir and produce one account record.
    static func read(_ configDir: URL, providerID: String) -> Account {
        var account = Account(
            providerID: providerID,
            localID: configDir.path,
            label: configDir.lastPathComponent,
            isDefaultDir: configDir.lastPathComponent == ".claude"
        )

        guard let state = stateFile(for: configDir) else {
            account.error = L("未登录", "Not logged in")
            return account
        }
        guard
            let data = try? Data(contentsOf: state),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            account.error = L("状态文件读不出来", "can't read state file")
            return account
        }
        guard let oauth = root["oauthAccount"] as? [String: Any] else {
            account.error = L("未登录", "Not logged in")
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
            account.error = L("还没取过用量", "usage not fetched yet")
        }

        // The `.claude.json` cache only updates via interactive /usage (headless runs
        // broke in CLI >=2.1.228); the primary data comes from Refresher hitting the
        // endpoint directly — whichever side is newer wins.
        if let fresh = Refresher.cached(configDir),
           fresh.fetchedAt > (account.fetchedAt ?? .distantPast) {
            account.fetchedAt = fresh.fetchedAt
            account.windows = parseWindows(fresh.utilization)
            account.extraUsage = parseExtra(fresh.utilization)
            account.error = nil
        }
        return account
    }

    // MARK: - Parsing details

    /// Prefer `limits[]` (includes breakdowns like weekly_scoped); fall back to
    /// five_hour / seven_day when absent.
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

    /// Numbers in the JSON are sometimes Int, sometimes Double; normalize.
    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// `resets_at` looks like "2026-08-10T06:40:00.419888+00:00" — 6 fractional
    /// digits, but ISO8601DateFormatter only accepts 3, so truncate before parsing.
    private static func parseDate(_ any: Any?) -> Date? {
        guard let raw = any as? String else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }

        // Trim .419888 down to .419 and retry.
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
