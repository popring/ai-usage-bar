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

    /// cswap's live-state file: `activeAccountNumber` here is rewritten by **every**
    /// switch, manual or automatic. Exposed because the follow logic watches it.
    ///
    /// Do not use `autoswitch_state.json` for this — it only records the automatic
    /// at-limit rotation. Read alone it goes stale the moment you `cswap switch` by hand,
    /// and the menu bar then follows a slot you left hours ago.
    static var liveStateFile: URL { root.appendingPathComponent("sequence.json") }

    private static var autoswitchStateFile: URL {
        root.appendingPathComponent("autoswitch_state.json")
    }

    /// When the active slot last changed; compared against Desktop's org-switch signal
    /// to decide which is newer. Either file can be the more recent record of a switch
    /// (only auto rotations touch autoswitch_state), so take the later of the two.
    static var lastSwitchAt: Date? {
        let fromSequence = (json(liveStateFile)?["lastUpdated"] as? String).flatMap(parseDate)
        let fromAutoswitch = (json(autoswitchStateFile)?["lastSwitchAt"] as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        return [fromSequence, fromAutoswitch].compactMap { $0 }.max()
    }

    /// The slot claude-swap is currently on. Slot numbers are ints in the JSON but
    /// strings as account IDs here; older layouts had no sequence.json, so keep the
    /// autoswitch record as a fallback.
    private static func liveSlot() -> String? {
        if let active = json(liveStateFile)?["activeAccountNumber"] {
            if let n = active as? Int { return String(n) }
            if let s = active as? String { return s }
        }
        guard let fallback = json(autoswitchStateFile)?["lastSwitchTo"] else { return nil }
        if let s = fallback as? String { return s }
        if let n = fallback as? Int { return String(n) }
        return nil
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
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
