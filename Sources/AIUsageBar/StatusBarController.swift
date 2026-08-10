import AppKit

/// 菜单栏图标 + 下拉菜单。
final class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var accounts: [Account] = []
    private var timer: Timer?
    private var isRefreshing = false
    private var lastRefreshNote: String?

    /// 轮询间隔。/usage 大约 5 分钟才真的重新取数，比这更密是白跑，所以取 6 分钟。
    private let pollInterval: TimeInterval = 6 * 60

    override init() {
        super.init()
        menu.delegate = self
        // 信息行没有 action，若交给 AppKit 自动判定会被当成禁用项渲染成灰色/半透明。
        // 关掉自动判定，由我们显式控制 enabled，颜色才正常。
        menu.autoenablesItems = false
        statusItem.menu = menu
        reload()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - 数据

    /// 只重读本地状态，不发请求。
    private func reload() {
        accounts = ProviderRegistry.readAllAccounts()
        updateTitle()
    }

    /// 让每个来源各自刷新一遍再重读。只刷会展示的那些，藏起来的默认目录不浪费一次调用。
    private func refresh() {
        guard !isRefreshing else { return }
        reload()
        let targets = visibleAccounts
        guard !targets.isEmpty else { return }

        isRefreshing = true
        updateTitle()

        ProviderRegistry.refresh(targets) { [weak self] results in
            guard let self else { return }
            self.isRefreshing = false

            let failures = results.values.compactMap { r -> String? in
                if case .failed(let m) = r { return m }
                return nil
            }
            self.lastRefreshNote = failures.isEmpty ? nil : "刷新失败：\(failures[0])"

            self.reload()
        }
    }

    // MARK: - 菜单栏标题

    /// 显示所有账号里最紧张的那个窗口。看一眼就知道要不要担心。
    private func updateTitle() {
        let worst = visibleAccounts
            .compactMap(\.tightestWindow)
            .max { $0.percent < $1.percent }

        let prefix = Settings.shared.menuBarPrefix
        let text: String
        if isRefreshing {
            text = "\(prefix) …"
        } else if let worst {
            text = "\(prefix) \(Int(worst.percent.rounded()))%"
        } else {
            text = "\(prefix) —"
        }

        let color: NSColor = {
            guard let p = worst?.percent else { return .secondaryLabelColor }
            if p >= 90 { return .systemRed }
            if p >= 70 { return .systemOrange }
            return .labelColor
        }()

        statusItem.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color,
            ]
        )
    }

    // MARK: - 菜单

    /// 每次点开都重建，保证时间差（"3分钟前"）是新的。
    func menuWillOpen(_ menu: NSMenu) {
        reload()
        rebuildMenu()
    }

    /// 要展示的账号。
    ///
    /// 默认目录 `~/.claude` 跟着界面切 team 而变，经常和某个专用目录指着同一个 team。
    /// 那种情况下把默认目录藏掉 —— 专用目录才是稳定的那份。
    private var visibleAccounts: [Account] {
        let loggedIn = accounts.filter(\.isLoggedIn)
        let dedicatedOrgs = Set(loggedIn.filter { !$0.isDefaultDir }.compactMap(\.org))
        return loggedIn.filter { account in
            guard account.isDefaultDir, let org = account.org else { return true }
            return !dedicatedOrgs.contains(org)
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let shown = visibleAccounts
        if shown.isEmpty {
            menu.addItem(info("没有已登录的账号", size: 12))
            menu.addItem(info("先跑 claude 登录，或建 ~/.claude-<名字> 目录", size: 11))
        } else {
            // 多个来源时按来源分组；只有一个来源就不加这层噪音。
            let providers = ProviderRegistry.all.filter { p in
                shown.contains { $0.providerID == p.id }
            }
            for provider in providers {
                if providers.count > 1 {
                    menu.addItem(info(provider.displayName.uppercased(), size: 10))
                }
                for account in shown where account.providerID == provider.id {
                    addAccount(account)
                }
            }
        }

        menu.addItem(.separator())

        // 数据年龄放全局一行 —— 各账号是一起刷新的，没必要每组重复一次。
        if let oldest = shown.compactMap(\.cacheAge).max() {
            let stale = shown.contains { $0.isStale }
            menu.addItem(info("数据 \(Fmt.ago(oldest))" + (stale ? " · 已过期" : ""),
                              size: 11, color: stale ? .systemOrange : .tertiaryLabelColor))
        }
        if let note = lastRefreshNote {
            menu.addItem(info("⚠ \(note)", size: 11, color: .systemOrange))
        }

        let refreshItem = NSMenuItem(
            title: isRefreshing ? "刷新中…" : "立即刷新",
            action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !isRefreshing
        menu.addItem(refreshItem)

        let quit = NSMenuItem(title: "退出", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addAccount(_ account: Account) {
        // 标题行。有兜底额度就顺带挂在后面，省一行。
        var title = account.org ?? account.label
        if let extra = account.extraUsage, extra.hasBuffer {
            title += String(format: "   $%.2f / $%.0f", extra.used, extra.limit)
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        header.isEnabled = true
        menu.addItem(header)

        if let error = account.error {
            menu.addItem(info("   \(error)", size: 11))
            return
        }

        // 全 0 的 team 没什么可看的，折叠成一行，细节丢进 tooltip。
        let windows = account.windows.sorted { $0.percent > $1.percent }
        guard windows.contains(where: { $0.percent > 0 }) else {
            let item = info("   未使用", size: 11, color: .tertiaryLabelColor)
            item.toolTip = windows
                .map { "\($0.displayName) 0% · 重置 \(Fmt.until($0.resetsAt))" }
                .joined(separator: "\n")
            menu.addItem(item)
            return
        }

        for window in windows {
            let mark = window.isActive ? "●" : " "
            let pct = String(format: "%3d%%", Int(window.percent.rounded()))
            let line = "  \(mark) \(Fmt.bar(window.percent, width: 8)) \(pct)  \(window.displayName) · \(Fmt.until(window.resetsAt))"
            let color: NSColor = window.percent >= 90 ? .systemRed
                : window.percent >= 70 ? .systemOrange : .labelColor
            menu.addItem(info(line, size: 11, mono: true, color: color))
        }
    }

    /// 纯展示行。**必须 `isEnabled = true`** —— 否则 AppKit 会当禁用项渲染成灰色/半透明。
    /// 菜单已关掉 autoenablesItems，所以这里的 enabled 不会被覆盖，
    /// 而没有 action 意味着点它也不会触发任何事。
    private func info(_ text: String, size: CGFloat = 12,
                      mono: Bool = false, color: NSColor = .secondaryLabelColor) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                            : NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
            ])
        item.isEnabled = true
        return item
    }

    // MARK: - 动作

    @objc private func refreshClicked() { refresh() }

    @objc private func quitClicked() { NSApp.terminate(nil) }
}
