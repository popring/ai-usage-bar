import AppKit

/// 菜单栏应用入口。
///
/// `.accessory` 让它不出现在 Dock 和 Cmd-Tab 里 —— 这样即使不打成 .app bundle，
/// 直接 `swift run` 也是个正经的菜单栏程序。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = StatusBarController()
    }
}

/// `--dump` / `--dump --refresh`：不起 UI，把解析结果打到终端。
/// 用来验证数据层和排查"菜单里数字不对"的问题。
func runDump(refresh: Bool) -> Never {
    if refresh {
        let targets = ProviderRegistry.readAllAccounts().filter(\.isLoggedIn)
        print("刷新 \(targets.count) 个账号…")
        let semaphore = DispatchSemaphore(value: 0)
        ProviderRegistry.refresh(targets) { results in
            for account in targets {
                let name = account.label
                switch results[account.key] {
                case .updated:            print("  ✓ \(name) 已更新")
                case .notYet(let age):    print("  · \(name) 窗口内重复调用，仍是 \(Fmt.ago(age))的")
                case .failed(let m):      print("  ✗ \(name) \(m)")
                case .needsLogin(let m):  print("  ✗ \(name) \(m)（重新登录：claude auth login）")
                case .notSupported:       print("  – \(name) 该来源不支持主动刷新")
                case nil:                 print("  ? \(name) 无结果")
                }
            }
            semaphore.signal()
        }
        // refreshAll 的回调派发到主队列，这里必须转主 runloop 而不是干等，否则死锁。
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        print("")
    }

    for account in ProviderRegistry.readAllAccounts() {
        guard account.isLoggedIn else {
            print("\(account.label): \(account.error ?? "未登录")")
            continue
        }
        print("\(account.org ?? account.label)  [\(account.label)]")
        if let email = account.email, let tier = account.seatTier {
            // org uuid 截前 8 位够肉眼对；缺失说明状态文件太老，跟随/去重会退回按名字匹配。
            let uuid = account.orgUuid.map { "org \($0.prefix(8))" } ?? "org uuid 缺失"
            print("  \(email) · \(tier) · \(uuid)")
        }
        if let age = account.cacheAge {
            print("  数据 \(Fmt.ago(age))\(account.isStale ? " ⚠ 已过期" : "")")
        }
        if let error = account.error { print("  \(error)") }
        for w in account.windows.sorted(by: { ($0.sortRank, $0.label) < ($1.sortRank, $1.label) }) {
            let mark = w.isActive ? "●" : " "
            print(String(format: "  %@ %@ %3d%%  %@ · 重置 %@",
                         mark, Fmt.bar(w.percent), Int(w.percent.rounded()),
                         w.displayName, Fmt.until(w.resetsAt)))
        }
        if let e = account.extraUsage {
            print(String(format: "    额外额度 $%.2f / $%.2f%@",
                         e.used, e.limit, e.hasBuffer ? "" : "（无兜底）"))
        }
        print("")
    }
    exit(0)
}

let args = CommandLine.arguments
if args.contains("--dump") {
    runDump(refresh: args.contains("--refresh") || args.contains("-r"))
}

/// `--test-alert`：造一个 95% 的假账号走一遍通知链路（授权弹窗 + 横幅）。
/// 必须从 .app bundle 里跑，`swift run` 直跑没有 bundle 会被静默跳过。
if args.contains("--test-alert") {
    var fake = Account(providerID: "claude-code", localID: "/tmp/fake", label: "测试Team")
    fake.isLoggedIn = true
    fake.org = "测试Team"
    fake.windows = [LimitWindow(kind: "session", label: "", percent: 95,
                                resetsAt: Date().addingTimeInterval(3600), isActive: true)]
    var alt = Account(providerID: "claude-code", localID: "/tmp/fake2", label: "备胎Team")
    alt.isLoggedIn = true
    alt.org = "备胎Team"
    alt.windows = [LimitWindow(kind: "session", label: "", percent: 12,
                               resetsAt: nil, isActive: true)]
    UserDefaults.standard.removeObject(forKey: "quotaAlertedKeys")   // 测试不受去重挡
    QuotaAlert.check(focused: fake, all: [fake, alt])
    print("已触发测试通知（若无横幅：检查系统设置 > 通知 > AI Usage Bar）")
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    exit(0)
}

/// `--desktop-org`：不起 UI，盯着 Desktop 的「当前 org」快通道信号打日志。
/// 用来验证「跟随 Desktop」为什么没跳/跳得慢。
if args.contains("--desktop-org") {
    // 输出常被重定向到文件观察，块缓冲会让日志迟迟不落盘，关掉。
    setvbuf(stdout, nil, _IONBF, 0)
    let watcher = DesktopTeamWatcher { uuid in
        print("\(Date()) org -> \(uuid)")
    }
    print("初值: \(watcher.currentOrgUuid ?? "未抓到（历史值已被压进 .ldb，切一次 team 就有了）")")
    print("盯着 Desktop 切 team…（Ctrl-C 退出）")
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
