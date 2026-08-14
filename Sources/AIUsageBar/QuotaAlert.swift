import Foundation
import UserNotifications

/// 额度预警：正在用的 team 快满时弹系统通知，并推荐余量最松的 team。
///
/// 配合 Desktop 索引池子（Claude多Team切换-方案-2026-08-13）：收到通知后
/// 在 Desktop 里切 org、点开同一个会话就完成续命 —— 这是"无缝切换"里
/// 能自动化的部分；真正替用户点切换器没有受支持的接口，不做。
enum QuotaAlert {

    /// 超过这个百分比就该提醒了。
    /// ponytail: 阈值写死 90，真有再调的需求再进设置面板。
    static let threshold: Double = 90

    /// 每个（账号+窗口+重置时间）只报一次，窗口重置后自然解锁再报。
    private static let alertedKey = "quotaAlertedKeys"

    /// 刷新完成后调用。`focused` = 正在用的账号（跟随/固定的那个），
    /// nil 时看全体里最紧的 —— 反正只对越线的报。
    static func check(focused: Account?, all: [Account]) {
        // swift run 直跑（无 bundle）时 UNUserNotificationCenter 会崩，跳过。
        guard Bundle.main.bundleIdentifier != nil else { return }

        let watched = focused.map { [$0] } ?? all
        for account in watched {
            guard let window = account.tightestWindow, window.percent >= threshold else { continue }

            let dedupe = "\(account.key)|\(window.kind)|\(window.resetsAt?.timeIntervalSince1970 ?? 0)"
            var alerted = UserDefaults.standard.stringArray(forKey: alertedKey) ?? []
            guard !alerted.contains(dedupe) else { continue }
            alerted.append(dedupe)
            UserDefaults.standard.set(Array(alerted.suffix(50)), forKey: alertedKey)

            notify(account: account, window: window, all: all)
        }
    }

    private static func notify(account: Account, window: LimitWindow, all: [Account]) {
        let name = account.org ?? account.label

        // 推荐余量最松的其他账号（同来源、已登录、没在焦点上的）。
        let alternative = all
            .filter { $0.key != account.key && $0.providerID == account.providerID && $0.isLoggedIn }
            .min { ($0.tightestWindow?.percent ?? 0) < ($1.tightestWindow?.percent ?? 0) }

        var body = "\(window.displayName) 已用 \(Int(window.percent.rounded()))%，重置 \(Fmt.until(window.resetsAt))"
        if let alt = alternative {
            let altName = alt.org ?? alt.label
            let altPct = Int((alt.tightestWindow?.percent ?? 0).rounded())
            body += "\n建议切到 \(altName)（最紧窗口 \(altPct)%），Desktop 切 org 后点开原会话即可"
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(name) 额度快满"
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: "quota-\(account.key)",
                content: content, trigger: nil))
        }
    }
}
