import Foundation

/// claude-swap（cswap，多账号自动切换工具）里录入的各个 Claude team。
///
/// 直接吃它的产物，不需要在本应用重复登录：
/// - `~/.claude-swap-backup/cache/usage.json`：它自己轮询（默认约 10 分钟）
///   得到的各账号 5h / 7d / 单模型窗口用量
/// - `~/.claude-swap-backup/configs/.claude-config-<槽位>-<邮箱>.json`：
///   各账号的完整 Claude 配置备份，从中取 org 名 / seatTier
///
/// 只读，不碰它的凭证与状态；刷新节奏由 claude-swap 自己控制，
/// 本应用没有可主动刷的口（refresh 返回 notSupported）。
struct ClaudeSwapProvider: UsageProvider {
    let id = "claude-swap"
    let displayName = "Claude Swap"

    private static let root = AppHome.url
        .appendingPathComponent(".claude-swap-backup")

    func readAccounts() -> [Account] {
        let cache = Self.root.appendingPathComponent("cache/usage.json")
        guard let data = try? Data(contentsOf: cache),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let slots = json["accounts"] as? [String: [String: Any]]
        else { return [] }          // 没装 / 没跑过 claude-swap 就整个不显示

        let liveSlot = Self.liveSlot()
        let profiles = Self.configProfiles()

        return slots.keys
            .sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
            .compactMap { slot in
                guard let raw = slots[slot] else { return nil }
                var account = Account(providerID: id, localID: slot, label: "槽位 \(slot)")
                account.isLoggedIn = true
                account.email = raw["email"] as? String
                account.orgUuid = raw["organizationUuid"] as? String
                let profile = account.orgUuid.flatMap { profiles[$0] }
                account.org = profile?.orgName ?? account.email
                account.seatTier = profile?.seatTier
                account.fetchedAt = (raw["fetchedAt"] as? Double)
                    .map { Date(timeIntervalSince1970: $0) }
                if let good = raw["lastGood"] as? [String: Any] {
                    account.windows = Self.parseWindows(good, isLive: slot == liveSlot)
                }
                if let err = raw["lastError"] as? String, !err.isEmpty {
                    account.error = err
                }
                return account
            }
    }

    /// claude-swap 自己轮询，这里没有可主动刷的口。
    func refresh(_ account: Account) -> RefreshResult { .notSupported }

    // MARK: - 解析细节

    /// usage.json 的窗口字段 → 统一的 LimitWindow。
    /// `isLive` = 该槽位是 claude-swap 当前切到的那个，标在 5h 窗上当「在用」记号。
    private static func parseWindows(_ good: [String: Any], isLive: Bool) -> [LimitWindow] {
        var windows: [LimitWindow] = []
        if let w = good["five_hour"] as? [String: Any] {
            windows.append(LimitWindow(
                kind: "session", label: "",
                percent: w["pct"] as? Double ?? 0,
                resetsAt: parseDate(w["resets_at"]),
                isActive: isLive))
        }
        if let w = good["seven_day"] as? [String: Any] {
            windows.append(LimitWindow(
                kind: "weekly_all", label: "",
                percent: w["pct"] as? Double ?? 0,
                resetsAt: parseDate(w["resets_at"]),
                isActive: false))
        }
        for w in good["scoped"] as? [[String: Any]] ?? [] {
            windows.append(LimitWindow(
                kind: "weekly_scoped",
                label: w["name"] as? String ?? "",
                percent: w["pct"] as? Double ?? 0,
                resetsAt: parseDate(w["resets_at"]),
                isActive: false))
        }
        return windows
    }

    /// claude-swap 当前切到的槽位（autoswitch_state.json 的 lastSwitchTo，
    /// 新版本写字符串、老字段是数字，两种都认）。
    private static func liveSlot() -> String? {
        let file = root.appendingPathComponent("autoswitch_state.json")
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let s = json["lastSwitchTo"] as? String { return s }
        if let n = json["lastSwitchTo"] as? Int { return String(n) }
        return nil
    }

    /// 配置备份里的 org 展示信息，按 organizationUuid 索引。
    /// usage.json 里只有 uuid 和邮箱，org 名得从这里补。
    private static func configProfiles() -> [String: (orgName: String?, seatTier: String?)] {
        let dir = root.appendingPathComponent("configs")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        var map: [String: (orgName: String?, seatTier: String?)] = [:]
        for file in files where file.lastPathComponent.hasPrefix(".claude-config-") {
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let oauth = json["oauthAccount"] as? [String: Any],
                  let uuid = oauth["organizationUuid"] as? String else { continue }
            map[uuid] = (oauth["organizationName"] as? String,
                         oauth["seatTier"] as? String)
        }
        return map
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let iso = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }
}
