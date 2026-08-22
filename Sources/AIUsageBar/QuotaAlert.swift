import Foundation
import UserNotifications

/// Quota alert: system notification when the team in use is nearly full, plus a
/// recommendation of the team with the most headroom.
///
/// Pairs with a Desktop-indexed team pool:
/// after the notification, switch orgs in Desktop and reopen the same conversation
/// to keep going — that's the automatable part of "seamless switching"; actually
/// clicking the switcher for the user has no supported API, so we don't.
enum QuotaAlert {

    /// Alert above this percentage.
    /// ponytail: hardcoded at 90; add a settings knob only if someone actually needs it.
    static let threshold: Double = 90

    /// One alert per (account + window + reset time); unlocks naturally after the
    /// window resets.
    private static let alertedKey = "quotaAlertedKeys"

    /// Call after a refresh completes. `focused` = the account in use (followed or
    /// pinned); nil means check everyone's tightest — only over-threshold ones alert anyway.
    static func check(focused: Account?, all: [Account]) {
        // Under plain `swift run` (no bundle) UNUserNotificationCenter crashes; skip.
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

        // Recommend the other account with the most headroom (same source, logged
        // in, not the focused one).
        let alternative = all
            .filter { $0.key != account.key && $0.providerID == account.providerID && $0.isLoggedIn }
            .min { ($0.tightestWindow?.percent ?? 0) < ($1.tightestWindow?.percent ?? 0) }

        var body = String(format: L("%@ 已用 %d%%，重置 %@", "%@ at %d%%, resets %@"),
                          window.displayName, Int(window.percent.rounded()), Fmt.until(window.resetsAt))
        if let alt = alternative {
            let altName = alt.org ?? alt.label
            let altPct = Int((alt.tightestWindow?.percent ?? 0).rounded())
            body += "\n" + String(format: L("建议切到 %@（最紧窗口 %d%%），Desktop 切 org 后点开原会话即可",
                                            "Consider switching to %@ (tightest window %d%%) — switch org in Desktop, then reopen the session"),
                                  altName, altPct)
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(format: L("%@ 额度快满", "%@ quota almost full"), name)
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: "quota-\(account.key)",
                content: content, trigger: nil))
        }
    }
}
