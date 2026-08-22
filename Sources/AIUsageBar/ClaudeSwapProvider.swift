import Foundation

/// Claude teams registered in claude-swap (cswap, a multi-account auto-switcher).
///
/// Consumes its output directly — no need to log in again in this app:
/// - `~/.claude-swap-backup/cache/usage.json`: 5h / 7d / per-model window usage
///   per account, written by cswap's collector (which `refresh` below triggers)
/// - `~/.claude-swap-backup/configs/.claude-config-<slot>-<email>.json`:
///   full Claude config backup per account, source of org name / seatTier
///
/// Read-only; never touches its credentials or state. Refresh drives cswap's own
/// collector (`cswap list`) rather than fetching anything itself.
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
        else { return [] }          // claude-swap not installed / never run: hide entirely

        let liveSlot = Self.liveSlot()
        let profiles = Self.configProfiles()

        return slots.keys
            .sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
            .compactMap { slot in
                guard let raw = slots[slot] else { return nil }
                var account = Account(providerID: id, localID: slot,
                                      label: L("槽位 \(slot)", "Slot \(slot)"))
                account.isLoggedIn = true
                account.isLiveSwapSlot = slot == liveSlot
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

    /// cswap has no daemon: `cache/usage.json` is only rewritten while its CLI runs
    /// (a slot switch, `cswap auto`, the TUI). Read passively, this source silently
    /// freezes for hours between switches — so drive it instead. `cswap list` re-fetches
    /// every slot and rewrites the cache; it only reads, and never switches slots.
    func refresh(_ account: Account) -> RefreshResult { Self.collect() }

    /// One `cswap list` covers every slot, so the per-account calls of a refresh batch
    /// collapse into a single run; the rest read the cache it just wrote.
    private static let gate = NSLock()
    private static var lastCollectAt = Date.distantPast
    private static let collectWindow: TimeInterval = 60

    private static func collect() -> RefreshResult {
        gate.lock()
        defer { gate.unlock() }
        let age = Date().timeIntervalSince(lastCollectAt)
        if age < collectWindow { return .notYet(age: age) }
        guard CLI.run(["cswap", "list"], timeout: 60) else {
            return .failed(L("cswap 跑不起来", "can't run cswap"))
        }
        lastCollectAt = Date()
        return .updated
    }

    // MARK: - Parsing details

    /// usage.json window fields → unified LimitWindow.
    /// `isLive` = this slot is the one claude-swap is currently on; marked on the
    /// 5h window as the "in use" indicator.
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

    /// cswap's switch-state file. Exposed because the follow logic needs to watch it
    /// and compare its timestamp.
    static var autoswitchStateFile: URL { root.appendingPathComponent("autoswitch_state.json") }

    /// When the last switch happened; compared against Desktop's org-switch signal
    /// to decide which is newer.
    static var lastSwitchAt: Date? {
        guard let data = try? Data(contentsOf: autoswitchStateFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ts = json["lastSwitchAt"] as? Double else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    /// The slot claude-swap is currently on (autoswitch_state.json's lastSwitchTo;
    /// new versions write a string, the old field was a number — accept both).
    private static func liveSlot() -> String? {
        guard let data = try? Data(contentsOf: autoswitchStateFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let s = json["lastSwitchTo"] as? String { return s }
        if let n = json["lastSwitchTo"] as? Int { return String(n) }
        return nil
    }

    /// Org display info from the config backups, keyed by organizationUuid.
    /// usage.json only has the uuid and email; org names must be filled from here.
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
