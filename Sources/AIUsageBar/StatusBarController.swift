import AppKit

/// Menu bar icon and its dropdown menu.
final class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var accounts: [Account] = []
    private var timer: Timer?
    private var isRefreshing = false
    private var isMenuOpen = false
    /// Accounts that had problems in the last refresh (key → result), shown inline under each account.
    private var refreshIssues: [String: RefreshResult] = [:]
    private var defaultDirWatcher: FileWatcher?
    private var desktopTeamWatcher: DesktopTeamWatcher?
    private var swapStateWatcher: FileWatcher?
    /// Last follow target, to distinguish an actual team switch from routine state-file writes.
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
        // Info rows have no action; AppKit's auto-enabling would treat them as disabled
        // and render them gray/translucent. Turn it off and control enabled explicitly.
        menu.autoenablesItems = false
        statusItem.menu = menu
        reload()
        lastFollowTargetKey = followTargetKey
        refresh()
        restartTimer()
        watchDesktopTeam()
    }

    /// Two signals track which team Desktop is currently on:
    /// - Fast path: Desktop's own Local Storage, written the moment the org switches (see `DesktopTeamWatcher`).
    /// - Slow path: the default dir's state file `~/.claude.json`. Desktop shares login state
    ///   with the default dir, but it's only rewritten when the embedded Claude Code re-syncs —
    ///   lags by tens of seconds; serves as fallback and initial value.
    private func watchDesktopTeam() {
        desktopTeamWatcher = DesktopTeamWatcher { [weak self] _ in
            self?.desktopSignalChanged()
        }
        let state = UsageReader.stateFile(for: UsageReader.home.appendingPathComponent(".claude"))
            ?? UsageReader.home.appendingPathComponent(".claude.json")
        defaultDirWatcher = FileWatcher(path: state.path) { [weak self] in
            self?.desktopSignalChanged()
        }
        // Third signal: cswap updates autoswitch_state.json when switching slots.
        swapStateWatcher = FileWatcher(path: ClaudeSwapProvider.autoswitchStateFile.path) { [weak self] in
            self?.desktopSignalChanged()
        }
    }

    /// Key used to detect whether the follow target changed.
    private var followTargetKey: String? { followedAccount?.key ?? desktopOrgKey }

    /// Any signal fired. The slow path usually just means Claude Code wrote its usage
    /// cache — pick up the fresh numbers; only a real team switch needs extra work.
    private func desktopSignalChanged() {
        reload()
        if isMenuOpen { rebuildMenu() }

        guard followTargetKey != lastFollowTargetKey else { return }
        lastFollowTargetKey = followTargetKey
        // The team just switched to may have very old data; refresh it.
        if followDesktop, let followed = followedAccount, followed.isStale {
            refresh()
        }
    }

    /// Poll interval comes from config; rebuild the timer after a config reload.
    /// Floor of 5 minutes: /usage only re-fetches about every 5 minutes, so polling more often is wasted.
    private func restartTimer() {
        timer?.invalidate()
        let minutes = max(5, Settings.shared.pollMinutes)
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60,
                                     repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Data

    /// Re-reads local state only; no network requests.
    private func reload() {
        accounts = ProviderRegistry.readAllAccounts()
        updateTitle()
    }

    /// Ask each provider to refresh, then re-read. Only refreshes the accounts that will be
    /// shown — no wasted call on a hidden default dir.
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
            // Alert proactively when the team in use is nearly full; don't wait for the user to discover 100%.
            QuotaAlert.check(focused: self.pinnedOrFollowed, all: self.visibleAccounts)
            // Update in place while the menu is open so the user isn't staring at stale numbers.
            if self.isMenuOpen { self.rebuildMenu() }
        }
    }

    // MARK: - Menu bar title

    /// Key of the pinned account; nil = auto (show the tightest one).
    ///
    /// Scenario: one team hits its limit and you switch to another team to keep working —
    /// the "tightest" is forever the maxed-out one, so the title sticks at 100% and carries
    /// no information. Clicking an account name in the menu pins the one in use.
    private var pinnedKey: String? {
        get { UserDefaults.standard.string(forKey: "pinnedAccountKey") }
        set { UserDefaults.standard.set(newValue, forKey: "pinnedAccountKey") }
    }

    /// Follow mode: the menu bar auto-pins to the team Desktop (= default dir) is logged into.
    /// Manual pin beats follow; with no follow target (default dir not logged in) fall back to auto.
    private var followDesktop: Bool {
        get { UserDefaults.standard.object(forKey: "followDesktopTeam") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "followDesktopTeam") }
    }

    /// The account Desktop is currently logged into (the default dir's login state is Desktop's).
    private var desktopAccount: Account? {
        accounts.first { $0.isDefaultDir && $0.isLoggedIn }
    }

    /// Desktop's current org; only used to detect team switches.
    private var desktopOrgKey: String? { desktopAccount?.orgKey }

    /// The account the menu bar should track in follow mode. When the default dir is deduped
    /// away by a dedicated dir of the same org, the match is that dedicated dir — same quota,
    /// doesn't matter which cache.
    ///
    /// The fast-path signal wins (exact uuid match); if unavailable, or that org has no team
    /// dir configured, fall back to the slow path (default dir login state).
    private var followedAccount: Account? {
        guard followDesktop else { return nil }
        // cswap slot switches and Desktop org switches are two independent "in use" signals;
        // trust whichever is newer. The slot account may be deduped away by a same-org
        // directory, so search all accounts first, then map back to the visible one.
        if let swapAt = ClaudeSwapProvider.lastSwitchAt,
           swapAt > (desktopTeamWatcher?.currentOrgAt ?? .distantPast),
           let live = accounts.first(where: { $0.isLiveSwapSlot }),
           let hit = visibleAccounts.first(where: { $0.key == live.key || $0.sameOrg(as: live) }) {
            return hit
        }
        if let uuid = desktopTeamWatcher?.currentOrgUuid,
           let hit = visibleAccounts.first(where: { $0.orgUuid == uuid }) {
            return hit
        }
        guard let desktop = desktopAccount else { return nil }
        return visibleAccounts.first { $0.sameOrg(as: desktop) }
    }

    /// The account in focus: manual pin first, then Desktop follow; nil = auto mode.
    private var pinnedOrFollowed: Account? {
        (visibleAccounts.first { $0.key == pinnedKey }) ?? followedAccount
    }

    /// By default show the tightest window across all accounts; if pinned/followed, only that one.
    private func updateTitle() {
        // The pinned account may have logged out or been disabled in config; fall back to follow/auto.
        let pinned = visibleAccounts.first { $0.key == pinnedKey }
        let focused = pinned ?? followedAccount
        let worst = focused.map { [$0] } ?? visibleAccounts
        let window = worst.compactMap(\.tightestWindow).max { $0.percent < $1.percent }
        statusItem.button?.toolTip = pinned.map { "\(L("已固定：", "Pinned: "))\($0.org ?? $0.label)" }
            ?? followedAccount.map { "\(L("跟随：", "Following: "))\($0.org ?? $0.label)" }

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

    // MARK: - Menu

    /// Rebuilt on every open so relative times ("3 min ago") stay fresh.
    /// Also refreshes when data is older than /usage's refresh window — background polling
    /// defaults to 1 hour, so "fresh numbers on open" mostly relies on this.
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        reload()
        // Also refresh when some account has never been fetched (cacheAge nil, e.g. a just-added team).
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

    /// Accounts to display.
    ///
    /// The default dir `~/.claude` changes as the UI switches teams and often points at the
    /// same team as some dedicated dir. In that case hide the default dir — the dedicated
    /// dir is the stable one.
    private var visibleAccounts: [Account] {
        let loggedIn = accounts.filter(\.isLoggedIn)
        let dedicated = loggedIn.filter {
            !$0.isDefaultDir && $0.providerID != "claude-swap"
        }
        let stable = loggedIn.filter { account in
            guard account.isDefaultDir else { return true }
            return !dedicated.contains { $0.sameOrg(as: account) }
        }
        // claude-swap slots and logged-in Claude Code dirs often point at the same orgs.
        // The dir copy can actively refresh, so it wins on same org; swap only fills in
        // orgs with no dir login.
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
            menu.addItem(info(L("没有已登录的账号", "No logged-in accounts"), size: 12))
            menu.addItem(info(L("先跑 claude 登录，或建 ~/.claude-<名字> 目录",
                               "Run claude to log in, or create a ~/.claude-<name> directory"), size: 11))
        } else {
            // Group by provider only when there are several; a single provider skips the noise.
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

        // Data age as one global line — accounts refresh together, no need to repeat per group.
        if let oldest = shown.compactMap(\.cacheAge).max() {
            let stale = shown.contains { $0.isStale }
            menu.addItem(info(L("数据 ", "Data ") + Fmt.ago(oldest) + (stale ? L(" · 已过期", " · stale") : ""),
                              size: 11, color: stale ? .systemOrange : .tertiaryLabelColor))
        }
        let refreshItem = NSMenuItem(
            title: isRefreshing ? L("刷新中…", "Refreshing…") : L("立即刷新", "Refresh Now"),
            action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !isRefreshing
        menu.addItem(refreshItem)

        let followItem = NSMenuItem(title: L("跟随当前在用账号", "Follow the account in use"),
                                    action: #selector(followClicked), keyEquivalent: "")
        followItem.target = self
        followItem.state = followDesktop ? .on : .off
        followItem.toolTip = L("菜单栏自动固定到当前在用的账号 —— Claude Code CLI（含 cswap 切换）"
                                   + "和 Claude Desktop 的切换都会秒级跟随。手动固定的账号优先。",
                               "Pins the menu bar to whichever account is currently in use — follows"
                                   + " switches from Claude Code CLI (incl. cswap) and Claude Desktop"
                                   + " within seconds. A manually pinned account takes priority.")
        menu.addItem(followItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: L("设置…", "Settings…"),
                                      action: #selector(settingsClicked), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Hand-editing the JSON is still supported (the panel only covers common options), so keep the reload entry.
        let reloadItem = NSMenuItem(title: L("重新加载配置", "Reload Config"),
                                    action: #selector(reloadConfigClicked), keyEquivalent: "l")
        reloadItem.target = self
        reloadItem.toolTip = Settings.path.path
        menu.addItem(reloadItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("退出", "Quit"), action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addAccount(_ account: Account) {
        // Header line; append the fallback quota to it to save a row.
        var title = account.org ?? account.label
        if let extra = account.extraUsage, extra.hasBuffer {
            title += extra.isCredits
                ? String(format: "   %g / %g credits", extra.used, extra.limit)
                : String(format: "   $%.2f / $%.0f", extra.used, extra.limit)
        }
        // Clicking the account name pins/unpins it to the menu bar (✓ = pinned, – = follow target).
        let header = NSMenuItem(title: title, action: #selector(pinClicked(_:)),
                                keyEquivalent: "")
        header.target = self
        header.representedObject = account.key
        header.state = account.key == pinnedKey ? .on
            : (pinnedKey == nil && account.key == followedAccount?.key ? .mixed : .off)
        header.toolTip = followDesktop
            ? L("点击后菜单栏只显示这个账号；再点一次恢复跟随",
                "Click to show only this account in the menu bar; click again to undo (back to Follow)")
            : L("点击后菜单栏只显示这个账号；再点一次恢复自动",
                "Click to show only this account in the menu bar; click again to undo (back to Auto)")
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

        // A team at all zeros has nothing to show; collapse to one line, details in the tooltip.
        // Fixed order (5h → 7d overall → 7d per-model → budget), not by usage — an order
        // that jumps around can't be compared across opens.
        let windows = account.windows.sorted {
            ($0.sortRank, $0.label) < ($1.sortRank, $1.label)
        }
        guard windows.contains(where: { $0.percent > 0 }) else {
            let item = info("   " + L("未使用", "unused"), size: 11, color: .tertiaryLabelColor)
            item.toolTip = windows
                .map { "\($0.displayName) 0% · \(L("重置 ", "resets "))\(Fmt.until($0.resetsAt))" }
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

    /// Issues from the last refresh, attached under the account. Dead logins get a
    /// clickable fix entry; other failures just state the reason.
    private func addRefreshIssue(for account: Account) {
        switch refreshIssues[account.key] {
        case .needsLogin(let message):
            menu.addItem(info("   ⚠ \(message)" + L("，数据停在上面那份", " — showing last fetched data"),
                              size: 11, color: .systemOrange))
            guard account.providerID == "claude-code" else { break }
            let fix = NSMenuItem(title: "   ⟳ " + L("在终端重新登录…", "Re-login in Terminal…"),
                                 action: #selector(reloginClicked(_:)), keyEquivalent: "")
            fix.target = self
            fix.representedObject = account.localID
            fix.toolTip = String(format: L("打开终端跑 claude auth login（%@），浏览器授权完成后回来点「立即刷新」",
                                           "Opens Terminal to run claude auth login (%@); after authorizing in the browser, come back and click \"Refresh Now\""),
                                 account.label)
            menu.addItem(fix)
        case .failed(let message):
            menu.addItem(info("   ⚠ " + L("刷新失败：", "Refresh failed: ") + message,
                              size: 11, color: .systemOrange))
        default:
            break
        }
    }

    /// Display-only row. **Must set `isEnabled = true`** — otherwise AppKit renders it as
    /// disabled (gray/translucent). The menu has autoenablesItems off, so this value isn't
    /// overridden, and having no action means clicking it does nothing anyway.
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

    // MARK: - Actions

    @objc private func refreshClicked() { refresh() }

    /// Writes a .command file and hands it to Terminal to run `claude auth login`.
    /// Not AppleScript-driving Terminal — that would trigger an extra Automation permission prompt.
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
        let echoIntro = String(
            format: L("==> 重新登录 %@：浏览器会弹授权页，选对 team 后回到这里",
                      "==> Re-login %@: the browser will open an auth page; pick the right team, then come back here"),
            dirName)
        let echoOutro = L("==> 完成。回菜单栏点「立即刷新」，本窗口可以关了",
                          "==> Done. Click \"Refresh Now\" in the menu bar; you can close this window")
        lines += [
            "echo '\(echoIntro)'",
            "claude auth login",
            "echo '\(echoOutro)'",
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

    /// Config changes apply without restart: provider toggles, poll interval, and menu bar prefix take effect immediately.
    @objc private func reloadConfigClicked() {
        Settings.reload()
        applyConfigChange()
    }

    /// Common follow-up after a config change (panel save / manual reload).
    private func applyConfigChange() {
        restartTimer()
        refreshIssues = [:]
        refresh()
    }

    @objc private func quitClicked() { NSApp.terminate(nil) }
}
