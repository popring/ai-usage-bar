import Foundation

/// 一个额度窗口（5 小时会话窗 / 7 天全模型窗 / 7 天单模型窗）。
struct LimitWindow {
    let kind: String        // session | weekly_all | weekly_scoped
    let label: String       // 展示名，scoped 的会带模型名
    let percent: Double
    let resetsAt: Date?
    let isActive: Bool

    /// 菜单里空间紧张，名字要短。
    var displayName: String {
        switch kind {
        case "session": return "5h"
        case "weekly_all": return "7d 全部"
        case "weekly_scoped": return label.isEmpty ? "7d 单模型" : "7d \(label)"
        case "budget": return label.isEmpty ? "预算" : "\(label) 预算"
        case "window": return label            // Codex 个人版，label 已经是 5h / 7d
        default: return kind
        }
    }
}

/// 额外用量额度（撞到限额之后的 credits 兜底）。
struct ExtraUsage {
    let usedMinor: Int      // 分
    let limitMinor: Int     // 分，0 表示没有兜底
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
    var email: String?
    var seatTier: String?
    var fetchedAt: Date?
    var windows: [LimitWindow] = []
    var extraUsage: ExtraUsage?
    var error: String?

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
    /// "3分钟前" / "2小时前"
    static func ago(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)秒前" }
        if s < 3600 { return "\(s / 60)分钟前" }
        if s < 86400 { return "\(s / 3600)小时前" }
        return "\(s / 86400)天前"
    }

    /// "4小时后" / "5天后"
    static func until(_ date: Date?) -> String {
        guard let date else { return "—" }
        let d = date.timeIntervalSinceNow
        if d <= 0 { return "已过" }
        if d < 3600 { return "\(Int(d / 60))分钟后" }
        if d < 86400 { return "\(Int(d / 3600))小时后" }
        return "\(Int(d / 86400))天后"
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
