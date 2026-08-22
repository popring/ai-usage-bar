import AppKit

/// 菜单栏图标 + 下拉菜单。
final class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var accounts: [Account] = []
    private var timer: Timer?
    private var isRefreshing = false
    private var isMenuOpen = false
    /// 上一轮刷新里出问题的账号（key → 结果），在对应账号下方就地展示。
    private var refreshIssues: [String: RefreshResult] = [:]
    private var defaultDirWatcher: FileWatcher?
    private var desktopTeamWatcher: DesktopTeamWatcher?
    /// 上次跟随的目标，用来区分「切了 team」和普通的状态文件写入。
    private var lastFollowTargetKey: String?

    private lazy var settingsController: SettingsWindowController = {
        let controller = SettingsWindowController()
        controller.onSave = { [weak self] in self?.applyConfigChange() }
        controller.onTeamAdded = { [weak self] in self?.refresh() }
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
        lastFollowTargetKey = followTargetKey
        refresh()
        restartTimer()
        watchDesktopTeam()
    }

    /// 两路信号盯住「Desktop 当前在哪个 team」：
    /// - 快通道：Desktop 自己的 Local Storage，切 org 的瞬间落盘（见 `DesktopTeamWatcher`）；
    /// - 慢通道：默认目录状态文件 `~/.claude.json`。Desktop 和默认目录共享登录态，
    ///   但要等内嵌 Claude Code 重新同步才改写，滞后几十秒，当兜底和启动初值。
    private func watchDesktopTeam() {
        desktopTeamWatcher = DesktopTeamWatcher { [weak self] _ in
            self?.desktopSignalChanged()
        }
        let state = UsageReader.stateFile(for: UsageReader.home.appendingPathComponent(".claude"))
            ?? UsageReader.home.appendingPathComponent(".claude.json")
        defaultDirWatcher = FileWatcher(path: state.path) { [weak self] in
            self?.desktopSignalChanged()
        }
    }

    /// 用来探测「跟随目标变没变」的键。
    private var followTargetKey: String? { followedAccount?.key ?? desktopOrgKey }

    /// 任一信号动了。慢通道多数时候只是 Claude Code 在写用量缓存，
    /// 顺手把新数字带出来；真正切了 team 才需要额外动作。
    private func desktopSignalChanged() {
        reload()
        if isMenuOpen { rebuildMenu() }

        guard followTargetKey != lastFollowTargetKey else { return }
        lastFollowTargetKey = followTargetKey
        // 刚切过去的 team 数据可能是很久以前的，顺手刷一遍。
        if followDesktop, let followed = followedAccount, followed.isStale {
            refresh()
        }
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

            self.refreshIssues = results.filter { _, r in
                switch r {
                case .failed, .needsLogin: return true
                default: return false
                }
            }

            self.reload()
            // 正在用的 team 快满了就主动喊人，别等用户自己发现 100%。
            QuotaAlert.check(focused: self.pinnedOrFollowed, all: self.visibleAccounts)
            // 菜单开着时原地更新，别让用户对着旧数字等到下次打开。
            if self.isMenuOpen { self.rebuildMenu() }
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

    /// 跟随模式：菜单栏自动固定到 Desktop（=默认目录）当前登录的 team。
    /// 手动固定优先于跟随；找不到跟随目标（没登录默认目录）就退回自动。
    private var followDesktop: Bool {
        get { UserDefaults.standard.object(forKey: "followDesktopTeam") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "followDesktopTeam") }
    }

    /// Desktop 当前登录的账号（默认目录的登录态就是 Desktop 的登录态）。
    private var desktopAccount: Account? {
        accounts.first { $0.isDefaultDir && $0.isLoggedIn }
    }

    /// Desktop 当前的 org，只用来探测「切没切 team」。
    private var desktopOrgKey: String? { desktopAccount?.orgKey }

    /// 跟随模式下菜单栏应该盯住的账号。默认目录被同 org 的专用目录顶掉时，
    /// 匹配到的是那个专用目录 —— 数据是同一份配额，无所谓哪份 cache。
    ///
    /// 快通道信号优先（uuid 精确匹配）；抓不到或者那个 org 没配过 team 目录，
    /// 退回慢通道（默认目录登录态）。
    private var followedAccount: Account? {
        guard followDesktop else { return nil }
        if let uuid = desktopTeamWatcher?.currentOrgUuid,
           let hit = visibleAccounts.first(where: { $0.orgUuid == uuid }) {
            return hit
        }
        guard let desktop = desktopAccount else { return nil }
        return visibleAccounts.first { $0.sameOrg(as: desktop) }
    }

    /// 正在关注的账号：手动固定优先，其次跟随 Desktop；都没有为 nil（自动模式）。
    private var pinnedOrFollowed: Account? {
        (visibleAccounts.first { $0.key == pinnedKey }) ?? followedAccount
    }

    /// 默认显示所有账号里最紧张的那个窗口；固定/跟随了账号就只看它。
    private func updateTitle() {
        // 固定的账号可能已退出登录或被配置关掉，找不到就退回跟随/自动。
        let pinned = visibleAccounts.first { $0.key == pinnedKey }
        let focused = pinned ?? followedAccount
        let worst = focused.map { [$0] } ?? visibleAccounts
        let window = worst.compactMap(\.tightestWindow).max { $0.percent < $1.percent }
        statusItem.button?.toolTip = pinned.map { "已固定：\($0.org ?? $0.label)" }
            ?? followedAccount.map { "跟随 Desktop：\($0.org ?? $0.label)" }

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
    /// 数据超过 /usage 的刷新窗口就顺手刷一遍 —— 后台轮询默认 1 小时，
    /// 「点开时看到的是新的」主要靠这里。
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        reload()
        // 有账号还没取过数据（cacheAge 为 nil，比如刚加的 team）也要刷。
        let accounts = visibleAccounts
        let ages = accounts.compactMap(\.cacheAge)
        if ages.count < accounts.count || (ages.max() ?? .infinity) > Refresher.refreshWindow {
            refresh()
        }
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    /// 要展示的账号。
    ///
    /// 默认目录 `~/.claude` 跟着界面切 team 而变，经常和某个专用目录指着同一个 team。
    /// 那种情况下把默认目录藏掉 —— 专用目录才是稳定的那份。
    private var visibleAccounts: [Account] {
        let loggedIn = accounts.filter(\.isLoggedIn)
        let dedicated = loggedIn.filter {
            !$0.isDefaultDir && $0.providerID != "claude-swap"
        }
        let stable = loggedIn.filter { account in
            guard account.isDefaultDir else { return true }
            return !dedicated.contains { $0.sameOrg(as: account) }
        }
        // claude-swap 的槽位和已登录的 Claude Code 目录经常指同一批 org。
        // 目录那份能主动刷新，同 org 时留它；swap 只补没有目录登录态的 org。
        let fromDirs = stable.filter { $0.providerID == "claude-code" }
        return stable.filter { account in
            guard account.providerID == "claude-swap" else { return true }
            return !fromDirs.contains { $0.sameOrg(as: account) }
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
        let refreshItem = NSMenuItem(
            title: isRefreshing ? "刷新中…" : "立即刷新",
            action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !isRefreshing
        menu.addItem(refreshItem)

        let followItem = NSMenuItem(title: "跟随 Desktop 当前 team",
                                    action: #selector(followClicked), keyEquivalent: "")
        followItem.target = self
        followItem.state = followDesktop ? .on : .off
        followItem.toolTip = "菜单栏自动固定到 Claude Desktop（也就是默认目录 ~/.claude）"
            + "当前登录的 team，切 team 秒级跟随。手动固定的账号优先。"
        menu.addItem(followItem)

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
            title += extra.isCredits
                ? String(format: "   %g / %g credits", extra.used, extra.limit)
                : String(format: "   $%.2f / $%.0f", extra.used, extra.limit)
        }
        // 点账号名 = 固定/取消固定到菜单栏（✓ 标在固定的那个上，– 标在跟随目标上）。
        let header = NSMenuItem(title: title, action: #selector(pinClicked(_:)),
                                keyEquivalent: "")
        header.target = self
        header.representedObject = account.key
        header.state = account.key == pinnedKey ? .on
            : (pinnedKey == nil && account.key == followedAccount?.key ? .mixed : .off)
        header.toolTip = "点击后菜单栏只显示这个账号；再点一次恢复"
            + (followDesktop ? "跟随 Desktop" : "自动")
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
            addRefreshIssue(for: account)
            return
        }

        // 全 0 的 team 没什么可看的，折叠成一行，细节丢进 tooltip。
        // 固定顺序（5h → 7d 全部 → 7d 单模型 → 预算），不按用量排 —— 会跳的顺序没法逐次对比。
        let windows = account.windows.sorted {
            ($0.sortRank, $0.label) < ($1.sortRank, $1.label)
        }
        guard windows.contains(where: { $0.percent > 0 }) else {
            let item = info("   未使用", size: 11, color: .tertiaryLabelColor)
            item.toolTip = windows
                .map { "\($0.displayName) 0% · 重置 \(Fmt.until($0.resetsAt))" }
                .joined(separator: "\n")
            menu.addItem(item)
            addRefreshIssue(for: account)
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

        addRefreshIssue(for: account)
    }

    /// 上一轮刷新的问题就地挂在账号下面。登录死了的给一个可点的修复入口，
    /// 其他失败只说原因。
    private func addRefreshIssue(for account: Account) {
        switch refreshIssues[account.key] {
        case .needsLogin(let message):
            menu.addItem(info("   ⚠ \(message)，数据停在上面那份", size: 11, color: .systemOrange))
            guard account.providerID == "claude-code" else { break }
            let fix = NSMenuItem(title: "   ⟳ 在终端重新登录…",
                                 action: #selector(reloginClicked(_:)), keyEquivalent: "")
            fix.target = self
            fix.representedObject = account.localID
            fix.toolTip = "打开终端跑 claude auth login（\(account.label)），"
                + "浏览器授权完成后回来点「立即刷新」"
            menu.addItem(fix)
        case .failed(let message):
            menu.addItem(info("   ⚠ 刷新失败：\(message)", size: 11, color: .systemOrange))
        default:
            break
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

    /// 生成一个 .command 丢给 Terminal 跑 `claude auth login`。
    /// 不走 AppleScript 控制 Terminal —— 那要多弹一次「自动化」授权框。
    @objc private func reloginClicked(_ sender: NSMenuItem) {
        guard let dirPath = sender.representedObject as? String else { return }
        let dirName = URL(fileURLWithPath: dirPath).lastPathComponent

        var lines = [
            "#!/bin/zsh",
            #"export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH""#,
        ]
        if dirName != ".claude" {
            lines.append("export CLAUDE_CONFIG_DIR=\"$HOME/\(dirName)\"")
        }
        lines += [
            "echo '==> 重新登录 \(dirName)：浏览器会弹授权页，选对 team 后回到这里'",
            "claude auth login",
            "echo '==> 完成。回菜单栏点「立即刷新」，本窗口可以关了'",
        ]

        let file = AppHome.url
            .appendingPathComponent(".cache/ai-usage-bar")
            .appendingPathComponent("relogin\(dirName).command")
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            NSSound.beep()
        }
    }

    @objc private func pinClicked(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        pinnedKey = pinnedKey == key ? nil : key
        updateTitle()
    }

    @objc private func followClicked() {
        followDesktop.toggle()
        lastFollowTargetKey = followTargetKey
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
        refreshIssues = [:]
        refresh()
    }

    @objc private func quitClicked() { NSApp.terminate(nil) }
}
