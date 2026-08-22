import Foundation

/// 所有本地文件读取的根目录。`AI_USAGE_BAR_HOME` 环境变量可整体重定向，
/// 用于测试和截 demo 图（喂假数据）；`homeDirectoryForCurrentUser` 不认 $HOME。
enum AppHome {
    static let url: URL = ProcessInfo.processInfo.environment["AI_USAGE_BAR_HOME"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
}

/// 一个额度窗口（5 小时会话窗 / 7 天全模型窗 / 7 天单模型窗）。
struct LimitWindow {
    let kind: String        // session | weekly_all | weekly_scoped
    let label: String       // 展示名，scoped 的会带模型名
    let percent: Double
    let resetsAt: Date?
    let isActive: Bool

    /// 菜单里的固定展示顺序：短周期在前，与用量无关 —— 顺序稳定才好逐次对比。
    var sortRank: Int {
        switch kind {
        case "session": return 0
        case "weekly_all": return 1
        case "weekly_scoped": return 2
        case "window": return 3       // Codex 个人版，同 rank 内按 label（5h < 7d）
        case "budget": return 4
        default: return 5
        }
    }

    /// 菜单里空间紧张，名字要短。
    var displayName: String {
        switch kind {
        case "session": return "5h"
        case "weekly_all": return L("7d 全部", "7d all")
        case "weekly_scoped": return label.isEmpty ? L("7d 单模型", "7d model") : "7d \(label)"
        case "budget": return label.isEmpty ? L("预算", "budget")
            : L("\(label) 预算", "\(label) budget")
        case "window": return label            // Codex 个人版，label 已经是 5h / 7d
        default: return kind
        }
    }
}

/// 额外用量额度（撞到限额之后的 credits 兜底）。
struct ExtraUsage {
    let usedMinor: Int      // 最小单位 ×100（美元→分；credits→百分之一 credit）
    let limitMinor: Int     // 同上，0 表示没有兜底
    /// Codex business 的 spend_control 单位是 credits，不是美元；显示时不带 $。
    var isCredits: Bool = false
    var used: Double { Double(usedMinor) / 100 }
    var limit: Double { Double(limitMinor) / 100 }
    var hasBuffer: Bool { limitMinor > 0 }
}

/// 一个账号（Claude Code 里 = 一个 team；其他来源可能是别的粒度）。
struct Account {
    /// 来源标识，见 `UsageProvider.id`。
    let providerID: String
    /// 来源内唯一的标识。Claude Code 用配置目录路径。
    let localID: String
    /// 界面上的短名，Claude Code 用目录名，如 `.claude-work`。
    let label: String

    /// 跨来源唯一键，用于回传刷新结果。
    var key: String { "\(providerID):\(localID)" }

    /// Claude Code 专用：这是不是那个会跟着界面切 team 而变的默认目录。
    var isDefaultDir = false

    var isLoggedIn = false
    var org: String?
    /// org 的 uuid（Claude Code 的 oauthAccount 里有）。重名 org 时名字不可靠，匹配用它。
    var orgUuid: String?
    var email: String?
    var seatTier: String?
    var fetchedAt: Date?
    var windows: [LimitWindow] = []
    var extraUsage: ExtraUsage?
    var error: String?

    /// 判断两个账号是不是同一个 org 用的键，uuid 优先。只适合和自己旧值比（探测变化）；
    /// 跨账号比较用 `sameOrg(as:)` —— 老状态文件可能缺 uuid，直接比键会误判成不同 org。
    var orgKey: String? { orgUuid ?? org }

    /// 是否同一个 org：两边都有 uuid 才比 uuid，否则退回名字。
    func sameOrg(as other: Account) -> Bool {
        if let a = orgUuid, let b = other.orgUuid { return a == b }
        if let a = org, let b = other.org { return a == b }
        return false
    }

    /// 数据年龄。没有数据时为 nil。
    var cacheAge: TimeInterval? {
        guard let fetchedAt else { return nil }
        return Date().timeIntervalSince(fetchedAt)
    }

    /// 超过这个时长就认为数据过期（和 /usage 的刷新窗口对齐留一倍余量）。
    static let staleAfter: TimeInterval = 10 * 60

    var isStale: Bool {
        guard let age = cacheAge else { return true }
        return age > Account.staleAfter
    }

    /// 该账号最紧张的窗口 —— 菜单栏图标用它。
    var tightestWindow: LimitWindow? {
        windows.max { $0.percent < $1.percent }
    }
}

// MARK: - 格式化

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

    /// 12 格进度条。非零但不足一格时也给一格 —— 否则 4% 会显示成全空，看着像没用。
    static func bar(_ percent: Double, width: Int = 12) -> String {
        let p = min(max(percent, 0), 100)
        var filled = Int((p / 100 * Double(width)).rounded())
        if p > 0 && filled == 0 { filled = 1 }
        return String(repeating: "█", count: filled)
            + String(repeating: "░", count: width - filled)
    }
}
