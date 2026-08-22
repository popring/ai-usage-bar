import AppKit

/// Menu bar app entry point.
///
/// `.accessory` keeps it out of the Dock and Cmd-Tab — so even without a .app
/// bundle, plain `swift run` behaves like a proper menu bar app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = StatusBarController()
    }
}

/// `--dump` / `--dump --refresh`: no UI, print parsed results to the terminal.
/// For verifying the data layer and debugging "the numbers in the menu look wrong".
func runDump(refresh: Bool) -> Never {
    if refresh {
        let targets = ProviderRegistry.readAllAccounts().filter(\.isLoggedIn)
        print(String(format: L("刷新 %d 个账号…", "Refreshing %d account(s)…"), targets.count))
        let semaphore = DispatchSemaphore(value: 0)
        ProviderRegistry.refresh(targets) { results in
            for account in targets {
                let name = account.label
                switch results[account.key] {
                case .updated:            print("  ✓ \(name) " + L("已更新", "updated"))
                case .notYet(let age):    print("  · \(name) " + String(format: L("窗口内重复调用，仍是 %@的", "still within refresh window, data from %@"), Fmt.ago(age)))
                case .failed(let m):      print("  ✗ \(name) \(m)")
                case .needsLogin(let m):  print("  ✗ \(name) \(m)" + L("（重新登录：claude auth login）", " (re-login: claude auth login)"))
                case .notSupported:       print("  – \(name) " + L("该来源不支持主动刷新", "provider does not support manual refresh"))
                case nil:                 print("  ? \(name) " + L("无结果", "no result"))
                }
            }
            semaphore.signal()
        }
        // refreshAll's callback dispatches to the main queue; must pump the main
        // runloop here instead of blocking, or we deadlock.
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        print("")
    }

    for account in ProviderRegistry.readAllAccounts() {
        guard account.isLoggedIn else {
            print("\(account.label): \(account.error ?? L("未登录", "not logged in"))")
            continue
        }
        print("\(account.org ?? account.label)  [\(account.label)]")
        if let email = account.email, let tier = account.seatTier {
            // First 8 chars of the org uuid are enough to eyeball; missing means the
            // state file is too old — follow/dedupe falls back to name matching.
            let uuid = account.orgUuid.map { "org \($0.prefix(8))" } ?? L("org uuid 缺失", "org uuid missing")
            print("  \(email) · \(tier) · \(uuid)")
        }
        if let age = account.cacheAge {
            print("  " + L("数据 ", "Data ") + Fmt.ago(age) + (account.isStale ? L(" ⚠ 已过期", " ⚠ stale") : ""))
        }
        if let error = account.error { print("  \(error)") }
        for w in account.windows.sorted(by: { ($0.sortRank, $0.label) < ($1.sortRank, $1.label) }) {
            let mark = w.isActive ? "●" : " "
            print(String(format: L("  %@ %@ %3d%%  %@ · 重置 %@", "  %@ %@ %3d%%  %@ · resets %@"),
                         mark, Fmt.bar(w.percent), Int(w.percent.rounded()),
                         w.displayName, Fmt.until(w.resetsAt)))
        }
        if let e = account.extraUsage {
            let amounts = e.isCredits
                ? String(format: "%g / %g credits", e.used, e.limit)
                : String(format: "$%.2f / $%.2f", e.used, e.limit)
            print("    " + L("额外额度 ", "Extra usage ") + amounts + (e.hasBuffer ? "" : L("（无兜底）", " (no buffer)")))
        }
        print("")
    }
    exit(0)
}

let args = CommandLine.arguments
if args.contains("--dump") {
    runDump(refresh: args.contains("--refresh") || args.contains("-r"))
}

/// `--test-alert`: fabricate a 95% account and exercise the notification chain
/// (authorization prompt + banner). Must run from the .app bundle — under plain
/// `swift run` there is no bundle and it's silently skipped.
if args.contains("--test-alert") {
    var fake = Account(providerID: "claude-code", localID: "/tmp/fake", label: L("测试Team", "Test Team"))
    fake.isLoggedIn = true
    fake.org = L("测试Team", "Test Team")
    fake.windows = [LimitWindow(kind: "session", label: "", percent: 95,
                                resetsAt: Date().addingTimeInterval(3600), isActive: true)]
    var alt = Account(providerID: "claude-code", localID: "/tmp/fake2", label: L("备胎Team", "Backup Team"))
    alt.isLoggedIn = true
    alt.org = L("备胎Team", "Backup Team")
    alt.windows = [LimitWindow(kind: "session", label: "", percent: 12,
                               resetsAt: nil, isActive: true)]
    UserDefaults.standard.removeObject(forKey: "quotaAlertedKeys")   // don't let dedupe block the test
    QuotaAlert.check(focused: fake, all: [fake, alt])
    print(L("已触发测试通知（若无横幅：检查系统设置 > 通知 > AI Usage Bar）",
            "Test notification fired (no banner? check System Settings > Notifications > AI Usage Bar)"))
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    exit(0)
}

/// `--desktop-org`: no UI, log Desktop's "current org" fast-path signal.
/// For debugging why "follow Desktop" didn't jump or jumped late.
if args.contains("--desktop-org") {
    // Output is often redirected to a file for observation; block buffering delays
    // the log lines, so disable it.
    setvbuf(stdout, nil, _IONBF, 0)
    let watcher = DesktopTeamWatcher { uuid in
        print("\(Date()) org -> \(uuid)")
    }
    print("\(L("初值: ", "Initial: "))\(watcher.currentOrgUuid ?? L("未抓到（历史值已被压进 .ldb，切一次 team 就有了）", "not captured (history compacted into .ldb; switch team once to populate)"))")
    print(L("盯着 Desktop 切 team…（Ctrl-C 退出）", "Watching Desktop team switches… (Ctrl-C to quit)"))
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
