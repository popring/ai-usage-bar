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
            print("  \(email) · \(tier)")
        }
        if let age = account.cacheAge {
            print("  数据 \(Fmt.ago(age))\(account.isStale ? " ⚠ 已过期" : "")")
        }
        if let error = account.error { print("  \(error)") }
        for w in account.windows.sorted(by: { $0.percent > $1.percent }) {
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
