import Foundation

/// Root dir for all local file reads. The `AI_USAGE_BAR_HOME` env var redirects it
/// wholesale — used for tests and demo screenshots (fake data);
/// `homeDirectoryForCurrentUser` ignores $HOME.
enum AppHome {
    static let url: URL = ProcessInfo.processInfo.environment["AI_USAGE_BAR_HOME"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
}

/// App version, for the menu footer — "which build am I running" shouldn't need a
/// trip to Finder. Read from the bundle's Info.plist; plain `swift run` has no bundle.
enum AppInfo {
    static let version: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
}

/// One quota window (5-hour session / 7-day all-models / 7-day per-model).
struct LimitWindow {
    let kind: String        // session | weekly_all | weekly_scoped
    let label: String       // display name; scoped ones carry the model name
    let percent: Double
    let resetsAt: Date?
    let isActive: Bool

    /// Fixed display order in the menu: shorter windows first, regardless of usage —
    /// a stable order makes glance-to-glance comparison possible.
    var sortRank: Int {
        switch kind {
        case "session": return 0
        case "weekly_all": return 1
        case "weekly_scoped": return 2
        case "window": return 3       // Codex personal; within rank, sort by label (5h < 7d)
        case "budget": return 4
        default: return 5
        }
    }

    /// Menu space is tight; keep names short.
    var displayName: String {
        switch kind {
        case "session": return "5h"
        case "weekly_all": return L("7d 全部", "7d all")
        case "weekly_scoped": return label.isEmpty ? L("7d 单模型", "7d model") : "7d \(label)"
        case "budget": return label.isEmpty ? L("预算", "budget")
            : L("\(label) 预算", "\(label) budget")
        case "window": return label            // Codex personal; label is already 5h / 7d
        default: return kind
        }
    }
}

/// Extra-usage allowance (credits buffer after hitting the limit).
struct ExtraUsage {
    let usedMinor: Int      // minor units x100 (dollars→cents; credits→hundredths)
    let limitMinor: Int     // same; 0 means no buffer
    /// Codex business spend_control is denominated in credits, not dollars; render without $.
    var isCredits: Bool = false
    var used: Double { Double(usedMinor) / 100 }
    var limit: Double { Double(limitMinor) / 100 }
    var hasBuffer: Bool { limitMinor > 0 }
}

/// One account (in Claude Code = one team; other providers may use a different granularity).
struct Account {
    /// Provider identifier, see `UsageProvider.id`.
    let providerID: String
    /// Unique ID within the provider. Claude Code uses the config dir path.
    let localID: String
    /// Short UI name; Claude Code uses the dir name, e.g. `.claude-work`.
    let label: String

    /// Cross-provider unique key, used to route refresh results back.
    var key: String { "\(providerID):\(localID)" }

    /// Claude Code only: whether this is the default dir that changes as the UI switches teams.
    var isDefaultDir = false

    /// claude-swap only: whether this is the slot cswap is currently switched to.
    var isLiveSwapSlot = false

    var isLoggedIn = false
    var org: String?
    /// Org uuid (present in Claude Code's oauthAccount). Names are unreliable when
    /// orgs share a name; match on this instead.
    var orgUuid: String?
    var email: String?
    var seatTier: String?
    var fetchedAt: Date?
    var windows: [LimitWindow] = []
    var extraUsage: ExtraUsage?
    var error: String?

    /// Key for "same org" checks, uuid preferred. Only safe against this account's own
    /// previous value (change detection); for cross-account comparison use `sameOrg(as:)` —
    /// old state files may lack the uuid, and comparing keys directly would misread that
    /// as a different org.
    var orgKey: String? { orgUuid ?? org }

    /// Same org? Compare uuids only when both sides have one; otherwise fall back to names.
    func sameOrg(as other: Account) -> Bool {
        if let a = orgUuid, let b = other.orgUuid { return a == b }
        if let a = org, let b = other.org { return a == b }
        return false
    }

    /// Age of the data; nil when there is none.
    var cacheAge: TimeInterval? {
        guard let fetchedAt else { return nil }
        return Date().timeIntervalSince(fetchedAt)
    }

    /// Data older than this is considered stale (2x the /usage refresh window for slack).
    static let staleAfter: TimeInterval = 10 * 60

    var isStale: Bool {
        guard let age = cacheAge else { return true }
        return age > Account.staleAfter
    }

    /// The account's tightest window — drives the menu bar icon.
    var tightestWindow: LimitWindow? {
        windows.max { $0.percent < $1.percent }
    }
}

// MARK: - Formatting

enum Fmt {
    /// "3分钟前" / "3m ago"
    static func ago(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return L("\(s)秒前", "\(s)s ago") }
        if s < 3600 { return L("\(s / 60)分钟前", "\(s / 60)m ago") }
        if s < 86400 { return L("\(s / 3600)小时前", "\(s / 3600)h ago") }
        return L("\(s / 86400)天前", "\(s / 86400)d ago")
    }

    /// "4小时后" / "in 4h"
    static func until(_ date: Date?) -> String {
        guard let date else { return "—" }
        let d = date.timeIntervalSinceNow
        if d <= 0 { return L("已过", "passed") }
        if d < 3600 { return L("\(Int(d / 60))分钟后", "in \(Int(d / 60))m") }
        if d < 86400 { return L("\(Int(d / 3600))小时后", "in \(Int(d / 3600))h") }
        return L("\(Int(d / 86400))天后", "in \(Int(d / 86400))d")
    }

    /// 12-cell progress bar. Non-zero but under one cell still gets one cell —
    /// otherwise 4% renders fully empty and looks unused.
    static func bar(_ percent: Double, width: Int = 12) -> String {
        let p = min(max(percent, 0), 100)
        var filled = Int((p / 100 * Double(width)).rounded())
        if p > 0 && filled == 0 { filled = 1 }
        return String(repeating: "█", count: filled)
            + String(repeating: "░", count: width - filled)
    }
}
