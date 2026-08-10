import AppKit

/// 菜单栏图标 + 下拉菜单。
final class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var accounts: [Account] = []
    private var timer: Timer?
    private var isRefreshing = false
    private var lastRefreshNote: String?

    private lazy var settingsController: SettingsWindowController = {
        let controller = SettingsWindowController()
        controller.onSave = { [weak self] in self?.applyConfigChange() }
        return controller
    }()

    override init() {
        super.init()
        menu.delegate = self
        // 信息行没有 action，若交给 AppKit 自动判定会被当成禁用项渲染成灰色/半透明。
        // 关掉自动判定，由我们显式控制 enabled，颜色才正常。
        menu.autoenablesItems = false
        statusItem.menu = menu
        reload()
        refresh()
        restartTimer()
    }

    /// 轮询间隔来自配置，重新加载配置后要重建定时器。
    /// 下限 5 分钟：/usage 大约 5 分钟才真的重新取数，比这更密纯属白跑。
    private func restartTimer() {
        timer?.invalidate()
        let minutes = max(5, Settings.shared.pollMinutes)
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60,
                                     repeats: true) { [weak self] _ in
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

    /// 固定了某个账号就存它的 key；nil = 自动（显示最紧张的）。
    ///
    /// 场景：一个 team 用到上限后你切去别的 team 干活，「最紧张」永远是那个
    /// 满了的，标题就卡在 100% 没信息量了。点菜单里的账号名固定住当前在用的。
    private var pinnedKey: String? {
        get { UserDefaults.standard.string(forKey: "pinnedAccountKey") }
        set { UserDefaults.standard.set(newValue, forKey: "pinnedAccountKey") }
    }

    /// 默认显示所有账号里最紧张的那个窗口；固定了账号就只看它。
    private func updateTitle() {
        // 固定的账号可能已退出登录或被配置关掉，找不到就退回自动。
        let pinned = visibleAccounts.first { $0.key == pinnedKey }
        let worst = pinned.map { [$0] } ?? visibleAccounts
        let window = worst.compactMap(\.tightestWindow).max { $0.percent < $1.percent }
        statusItem.button?.toolTip = pinned.map { "已固定：\($0.org ?? $0.label)" }

        let prefix = Settings.shared.menuBarPrefix
        let text: String
        if isRefreshing {
            text = "\(prefix) …"
        } else if let window {
            text = "\(prefix) \(Int(window.percent.rounded()))%"
        } else {
            text = "\(prefix) —"
        }

        let color: NSColor = {
            guard let p = window?.percent else { return .secondaryLabelColor }
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

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…",
                                      action: #selector(settingsClicked), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // 手改 JSON 的路径依然保留（面板只覆盖常用项），所以重载入口不能少。
        let reloadItem = NSMenuItem(title: "重新加载配置",
                                    action: #selector(reloadConfigClicked), keyEquivalent: "l")
        reloadItem.target = self
        reloadItem.toolTip = Settings.path.path
        menu.addItem(reloadItem)

        menu.addItem(.separator())

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
        // 点账号名 = 固定/取消固定到菜单栏（✓ 标在固定的那个上）。
        let header = NSMenuItem(title: title, action: #selector(pinClicked(_:)),
                                keyEquivalent: "")
        header.target = self
        header.representedObject = account.key
        header.state = account.key == pinnedKey ? .on : .off
        header.toolTip = "点击后菜单栏只显示这个账号；再点一次恢复自动"
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

    @objc private func pinClicked(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        pinnedKey = pinnedKey == key ? nil : key
        updateTitle()
    }

    @objc private func settingsClicked() {
        settingsController.show()
    }

    /// 改完配置不用重启。来源开关、轮询间隔、菜单栏前缀都会立刻生效。
    @objc private func reloadConfigClicked() {
        Settings.reload()
        applyConfigChange()
    }

    /// 配置变了（面板保存 / 手动重载）之后的统一善后。
    private func applyConfigChange() {
        restartTimer()
        lastRefreshNote = nil
        refresh()
    }

    @objc private func quitClicked() { NSApp.terminate(nil) }
}
