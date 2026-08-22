import AppKit

/// Settings panel. Programmatic AppKit (no full Xcode on this machine, so no xib).
///
/// Save = write config.json (0600) → `Settings.reload()` → `onSave` lets the status bar
/// rebuild its timer and refresh once. Hand-editing the JSON still works; the panel is
/// just a shortcut for common options.
final class SettingsWindowController: NSWindowController {

    /// Called after a successful save (Settings already reloaded).
    var onSave: (() -> Void)?
    /// Called when "Add Claude team" detects a completed login (to fetch the new team's usage).
    var onTeamAdded: (() -> Void)?

    private let claudeCheck = NSButton(checkboxWithTitle: "Claude Code", target: nil, action: nil)
    private let codexCheck = NSButton(checkboxWithTitle: "Codex", target: nil, action: nil)
    private let litellmCheck = NSButton(checkboxWithTitle: L("LiteLLM 网关", "LiteLLM Gateway"), target: nil, action: nil)
    private let baseURLField = NSTextField()
    // Masked/plain API key are two fields swapped in place (an NSSecureTextField can't
    // reveal itself); the visible one holds the truth, and they sync on toggle.
    private let apiKeyField = NSSecureTextField()
    private let apiKeyPlainField = NSTextField()
    private let apiKeyToggle = NSButton()
    private var apiKeyVisible = false
    private let pollField = NSTextField()
    private let pollStepper = NSStepper()
    private let prefixField = NSTextField()
    private let languagePopup = NSPopUpButton()
    private let addTeamStatus = NSTextField(labelWithString: "")
    private var addTeamStatusRow: NSView!
    private let teamsStack = NSStackView()
    private var teamDirs: [URL] = []
    private let codexStatus = NSTextField(labelWithString: "")
    private let swapCheck = NSButton(checkboxWithTitle: "Claude Swap", target: nil, action: nil)
    private let swapStatus = NSTextField(labelWithString: "")
    private let litellmNote = NSTextField(labelWithString: "")
    private var litellmNoteRow: NSView!
    private var teamPollTimer: Timer?
    private var hasShownOnce = false

    init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = L("AI Usage Bar 设置", "AI Usage Bar Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The app is .accessory (no Dock icon): must activate first or the window opens
    /// behind other apps and looks unresponsive.
    func show() {
        populate()
        NSApp.activate(ignoringOtherApps: true)
        fitWindow()
        if !hasShownOnce {
            window?.center()
            hasShownOnce = true
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// The window was created with contentRect .zero and sized purely by Auto Layout,
    /// which comes out a bit narrower than the content — fields hit the right edge and
    /// the focus ring gets clipped. Re-size to fittingSize after every content change.
    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        baseURLField.placeholderString = "https://gateway.example.com"
        apiKeyField.placeholderString = "sk-…"
        apiKeyPlainField.placeholderString = "sk-…"
        apiKeyPlainField.isHidden = true
        apiKeyToggle.bezelStyle = .inline
        apiKeyToggle.isBordered = false
        apiKeyToggle.image = NSImage(systemSymbolName: "eye",
                                     accessibilityDescription: L("显示 API Key", "Show API Key"))
        apiKeyToggle.target = self
        apiKeyToggle.action = #selector(apiKeyToggleClicked)
        apiKeyToggle.toolTip = L("显示/隐藏明文", "Show/hide plain text")
        prefixField.placeholderString = "AI"

        let pollFormatter = NumberFormatter()
        pollFormatter.minimum = 5
        pollFormatter.maximum = 720
        pollFormatter.allowsFloats = false
        pollField.formatter = pollFormatter
        pollStepper.minValue = 5
        pollStepper.maxValue = 720
        pollStepper.increment = 1
        pollStepper.target = self
        pollStepper.action = #selector(pollStepped)

        litellmCheck.target = self
        litellmCheck.action = #selector(litellmToggled)

        let pollRow = NSStackView(views: [pollField, pollStepper, smallLabel(L("分钟，下限 5", "minutes, minimum 5"))])
        pollRow.orientation = .horizontal
        pollField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let addTeam = NSButton(title: L("添加 Claude team…", "Add Claude Team…"),
                               target: self, action: #selector(addTeamClicked))
        addTeam.controlSize = .small
        addTeamStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        addTeamStatus.textColor = .secondaryLabelColor
        addTeamStatus.isSelectable = true            // the alias hint must be copyable
        addTeamStatus.lineBreakMode = .byWordWrapping
        addTeamStatus.maximumNumberOfLines = 6   // keep the alias line intact and copyable, don't truncate
        addTeamStatus.preferredMaxLayoutWidth = 260

        // List of discovered teams (rebuilt in populate).
        teamsStack.orientation = .vertical
        teamsStack.alignment = .leading
        teamsStack.spacing = 3

        // Codex is zero-config (reads ~/.codex/auth.json automatically); the panel can only show status.
        codexStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let codexRow = NSStackView(views: [codexCheck, codexStatus])
        codexRow.orientation = .horizontal
        codexRow.spacing = 8

        // claude-swap is likewise zero-config (reads ~/.claude-swap-backup); status only.
        swapStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        swapCheck.toolTip = L(
            "读 claude-swap（cswap）录入的账号，无需在本应用重复登录；"
                + "和 Claude Code 目录同 org 时自动去重，目录那份优先",
            "Reads accounts registered via claude-swap (cswap); no need to log in again here. "
                + "Deduplicated automatically when sharing an org with a Claude Code directory, which takes priority")
        let swapRow = NSStackView(views: [swapCheck, swapStatus])
        swapRow.orientation = .horizontal
        swapRow.spacing = 8

        // Gateway values may come from env vars / ~/.zshrc (a Finder-launched app can't see
        // the shell env, but the provider digs into ~/.zshrc). populate fills in the
        // effective values and labels their source here.
        litellmNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        litellmNote.textColor = .secondaryLabelColor
        litellmNoteRow = indented(litellmNote)
        litellmNoteRow.isHidden = true

        // The whole Sources block is one vertical stack: the team list, add-team button and
        // status row are indented to show they belong to Claude Code; an empty status row
        // hides entirely, leaving no gap.
        addTeamStatusRow = indented(addTeamStatus)
        addTeamStatusRow.isHidden = true
        let sourceStack = NSStackView(views: [
            claudeCheck, indented(teamsStack), indented(addTeam), addTeamStatusRow,
            swapRow, codexRow, litellmCheck, litellmNoteRow,
        ])
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 8
        sourceStack.setCustomSpacing(4, after: claudeCheck)
        sourceStack.setCustomSpacing(6, after: litellmCheck)

        let apiKeyRow = NSStackView(views: [apiKeyField, apiKeyPlainField, apiKeyToggle])
        apiKeyRow.orientation = .horizontal
        apiKeyRow.spacing = 6

        // The "中文" / "English" items stay in their own language, never translated with the UI.
        languagePopup.addItems(withTitles: [L("跟随系统", "Follow System"), "中文", "English"])

        let grid = NSGridView(views: [
            [gridLabel(L("显示来源", "Sources")), sourceStack],
            [gridLabel(L("网关地址", "Gateway URL")), baseURLField],
            [gridLabel(L("网关 API Key", "Gateway API Key")), apiKeyRow],
            [gridLabel(L("轮询间隔", "Poll Interval")), pollRow],
            [gridLabel(L("菜单栏前缀", "Menu Bar Prefix")), prefixField],
            [gridLabel(L("界面语言", "Language")), languagePopup],
        ])
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        baseURLField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        apiKeyField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        apiKeyPlainField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        prefixField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let reveal = NSButton(title: L("在 Finder 中显示配置文件", "Reveal Config File in Finder"),
                              target: self, action: #selector(revealClicked))
        reveal.bezelStyle = .inline
        reveal.controlSize = .small

        let cancel = NSButton(title: L("取消", "Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: L("保存", "Save"), target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"

        let buttons = NSStackView(views: [reveal, NSView(), cancel, save])
        buttons.orientation = .horizontal

        let root = NSStackView(views: [grid, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        return root
    }

    private func gridLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func smallLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Wraps a view with a left indent to show it belongs to the checkbox above (18pt ≈ checkbox icon width).
    private func indented(_ view: NSView) -> NSStackView {
        let row = NSStackView(views: [view])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        return row
    }

    private func setTeamStatus(_ text: String) {
        addTeamStatus.stringValue = text
        addTeamStatusRow.isHidden = text.isEmpty
        fitWindow()   // showing/hiding the row changes content height; resize or the text gets clipped
    }

    // MARK: - Data

    /// Repopulate from the current config on every open; don't show unsaved leftovers.
    private func populate() {
        let settings = Settings.shared
        claudeCheck.state = settings.forProvider("claude-code").enabled ? .on : .off
        codexCheck.state = settings.forProvider("codex").enabled ? .on : .off

        rebuildTeamList()
        let codexOn = CodexProvider.isLoggedIn
        codexStatus.stringValue = codexOn
            ? L("已登录", "Logged in")
            : L("未登录（跑一次 codex 登录即可）", "Not logged in (just run codex once to log in)")
        codexStatus.textColor = codexOn ? .secondaryLabelColor : .tertiaryLabelColor

        swapCheck.state = settings.forProvider("claude-swap").enabled ? .on : .off
        let swapCount = ClaudeSwapProvider().readAccounts().count
        swapStatus.stringValue = swapCount > 0
            ? L("已发现 \(swapCount) 个账号", "Found \(swapCount) account(s)")
            : L("未检测到 claude-swap 数据", "No claude-swap data detected")
        swapStatus.textColor = swapCount > 0 ? .secondaryLabelColor : .tertiaryLabelColor

        let litellm = settings.forProvider("litellm")
        litellmCheck.state = litellm.enabled ? .on : .off
        baseURLField.stringValue = litellm.string("baseURL") ?? ""
        apiKeyValue = litellm.string("apiKey") ?? ""
        setApiKeyVisible(false)             // always start masked

        // Values absent from the config file but effective anyway (env vars / ~/.zshrc):
        // fill them into the fields and label the source — otherwise the panel looks blank
        // while the gateway keeps producing numbers, which is confusing.
        litellmNoteRow.isHidden = true
        if baseURLField.stringValue.isEmpty, apiKeyValue.isEmpty,
           let cfg = LiteLLMProvider.resolveConfig(), cfg.source != .configFile {
            baseURLField.stringValue = cfg.baseURL
            apiKeyValue = cfg.apiKey
            litellmNote.stringValue = String(
                format: L("当前值读自 %@；点保存会写进配置文件（此后以配置文件为准）",
                          "Current values read from %@; Save writes them to the config file (which then takes precedence)"),
                cfg.source.label)
            litellmNoteRow.isHidden = false
        }

        pollField.integerValue = max(5, settings.pollMinutes)
        pollStepper.integerValue = pollField.integerValue
        prefixField.stringValue = settings.menuBarPrefix
        switch settings.language {
        case "zh": languagePopup.selectItem(at: 1)
        case "en": languagePopup.selectItem(at: 2)
        default:   languagePopup.selectItem(at: 0)
        }
        litellmToggled()
    }

    /// Rebuilds the discovered Claude team list. Same data source as the menu: ~/.claude and ~/.claude-*.
    private func rebuildTeamList() {
        teamsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        teamDirs = UsageReader.configDirs()
        for (index, dir) in teamDirs.enumerated() {
            teamsStack.addArrangedSubview(teamRow(dir, index: index))
        }
        teamsStack.isHidden = teamDirs.isEmpty
        fitWindow()
    }

    private func teamRow(_ dir: URL, index: Int) -> NSView {
        let account = UsageReader.read(dir, providerID: "claude-code")

        let isDefault = dir.lastPathComponent == ".claude"
        let name = NSTextField(labelWithString: dir.lastPathComponent + (isDefault ? L("（默认）", " (default)") : ""))
        name.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        if isDefault {
            name.toolTip = L("claude 命令默认用的目录，跟着你在终端里切 team 而变",
                             "The directory the claude command uses by default; changes as you switch teams in the terminal")
        }

        let detailText = account.isLoggedIn
            ? [account.org, account.email].compactMap { $0 }.joined(separator: " · ")
            : L("未登录", "Not logged in")
        let detail = smallLabel(detailText)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if !account.isLoggedIn { detail.textColor = .tertiaryLabelColor }

        // Per-row "⋯" action menu; tag links back to the teamDirs index.
        let action = NSButton(title: "⋯", target: self, action: #selector(teamActionsClicked(_:)))
        action.bezelStyle = .inline
        action.controlSize = .small
        action.tag = index
        action.toolTip = L("复制 alias、在 Finder 中显示、移除", "Copy alias, reveal in Finder, remove")

        let row = NSStackView(views: [name, detail, action])
        row.orientation = .horizontal
        row.spacing = 6
        row.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        return row
    }

    // MARK: - Actions

    @objc private func litellmToggled() {
        let on = litellmCheck.state == .on
        baseURLField.isEnabled = on
        apiKeyField.isEnabled = on
        apiKeyPlainField.isEnabled = on
        apiKeyToggle.isEnabled = on
    }

    private var apiKeyValue: String {
        get { (apiKeyVisible ? apiKeyPlainField : apiKeyField).stringValue }
        set {
            apiKeyField.stringValue = newValue
            apiKeyPlainField.stringValue = newValue
        }
    }

    @objc private func apiKeyToggleClicked() {
        setApiKeyVisible(!apiKeyVisible)
    }

    private func setApiKeyVisible(_ visible: Bool) {
        let current = apiKeyValue          // grab the value before toggling; don't lose half-typed input
        let wasEditingKey = apiKeyField.currentEditor() != nil
            || apiKeyPlainField.currentEditor() != nil
        apiKeyVisible = visible
        apiKeyValue = current
        apiKeyField.isHidden = visible
        apiKeyPlainField.isHidden = !visible
        apiKeyToggle.image = NSImage(systemSymbolName: visible ? "eye.slash" : "eye",
                                     accessibilityDescription: visible
                                        ? L("隐藏 API Key", "Hide API Key")
                                        : L("显示 API Key", "Show API Key"))
        // If the key was being edited, move focus along; don't leave the caret in a hidden field
        if wasEditingKey {
            window?.makeFirstResponder(visible ? apiKeyPlainField : apiKeyField)
        }
    }

    @objc private func pollStepped() {
        pollField.integerValue = pollStepper.integerValue
    }

    /// Guided team add: pick a name → open Terminal to log in → appears in the menu once
    /// logged in. The login itself can't be done for the user (browser OAuth + team
    /// selection); all we can automate is the directory, the env var, and detecting
    /// whether login completed.
    @objc private func addTeamClicked() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("添加 Claude team", "Add Claude Team")
        alert.informativeText = L("起个短名（建议英文，如 work）。会打开终端让你登录一次，登录时选对应的 team。",
                                  "Pick a short name (English recommended, e.g. work). A terminal will open for a one-time login; pick the matching team when logging in.")
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        nameField.placeholderString = "work"
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField
        alert.addButton(withTitle: L("打开终端登录", "Open Terminal to Log In"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.startTeamLogin(nameField.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    private func startTeamLogin(_ name: String) {
        guard name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            setTeamStatus(L("名字只能用字母、数字、- 和 _", "Name can only contain letters, digits, - and _"))
            return
        }
        let dir = AppHome.url
            .appendingPathComponent(".claude-\(name)")
        if UsageReader.read(dir, providerID: "claude-code").isLoggedIn {
            setTeamStatus(L("~/.claude-\(name) 已存在且已登录，直接就能看",
                            "~/.claude-\(name) already exists and is logged in, ready to view"))
            return
        }

        // A .command file runs on open in Terminal — no automation permission needed.
        // A GUI-launched Terminal is a login shell, but PATH still gets an explicit fallback (same as Refresher).
        // The prompt text goes inside shell double quotes, so quotes in the English text must be escaped as \\" for the shell.
        let echoIntro = L("为 team「\(name)」登录 Claude Code：跟着提示走，登录时选对应的 team。",
                          "Log in to Claude Code for team \\\"\(name)\\\": follow the prompts and pick the matching team.")
        let echoOutro = L("登录完成后退出（/exit）并关掉本窗口，AI Usage Bar 会自动发现。",
                          "After logging in, exit (/exit) and close this window; AI Usage Bar will detect it automatically.")
        let script = """
        #!/bin/bash
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        export CLAUDE_CONFIG_DIR="$HOME/.claude-\(name)"
        echo "\(echoIntro)"
        echo "\(echoOutro)"
        claude
        """
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-usage-bar-login-\(name).command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            setTeamStatus(L("准备登录脚本失败：\(error.localizedDescription)",
                            "Failed to prepare login script: \(error.localizedDescription)"))
            return
        }
        NSWorkspace.shared.open(scriptURL)
        setTeamStatus(L("已打开终端，等待 ~/.claude-\(name) 登录…",
                        "Terminal opened, waiting for ~/.claude-\(name) to log in…"))
        pollForLogin(name: name, dir: dir)
    }

    private func pollForLogin(name: String, dir: URL) {
        teamPollTimer?.invalidate()
        var attempts = 180                            // 5s × 180 = 15 minutes
        teamPollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            attempts -= 1
            let account = UsageReader.read(dir, providerID: "claude-code")
            if account.isLoggedIn {
                timer.invalidate()
                self.setTeamStatus(L("""
                ✓ 已添加 \(account.org ?? name)。想在终端里日常用它，把这行放进 shell 配置：
                alias claude-\(name)='CLAUDE_CONFIG_DIR=$HOME/.claude-\(name) claude'
                """, """
                ✓ Added \(account.org ?? name). To use it in the terminal day-to-day, add this line to your shell config:
                alias claude-\(name)='CLAUDE_CONFIG_DIR=$HOME/.claude-\(name) claude'
                """))
                self.rebuildTeamList()
                self.onTeamAdded?()
            } else if attempts <= 0 {
                timer.invalidate()
                self.setTeamStatus(L("没等到登录。之后登录完成也会自动出现在菜单里，不影响。",
                                     "Login not detected in time. It will still appear in the menu automatically once you finish logging in."))
            }
        }
    }

    // MARK: - Team row actions

    @objc private func teamActionsClicked(_ sender: NSButton) {
        guard teamDirs.indices.contains(sender.tag) else { return }
        let dir = teamDirs[sender.tag]
        let isDefault = dir.lastPathComponent == ".claude"

        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            i.target = enabled ? self : nil
            i.representedObject = dir
            menu.addItem(i)
        }
        // The default dir is plain `claude` — no alias needed; removing it from here is also not allowed.
        item(L("复制 alias 命令", "Copy alias Command"), #selector(copyTeamAlias(_:)), enabled: !isDefault)
        item(L("在 Finder 中显示", "Reveal in Finder"), #selector(revealTeam(_:)))
        menu.addItem(.separator())
        item(isDefault
                ? L("移除（默认目录不可移除）", "Remove (default directory cannot be removed)")
                : L("移除…", "Remove…"),
             #selector(removeTeam(_:)), enabled: !isDefault)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func copyTeamAlias(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        let name = dir.lastPathComponent.replacingOccurrences(of: ".claude-", with: "")
        let alias = "alias claude-\(name)='CLAUDE_CONFIG_DIR=$HOME/\(dir.lastPathComponent) claude'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(alias, forType: .string)
        setTeamStatus(L("已复制：\(alias)", "Copied: \(alias)"))
    }

    @objc private func revealTeam(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// Remove = move the whole config dir to the Trash (recoverable from there). Login
    /// state lives in the dir, so showing this team again requires logging in again.
    @objc private func removeTeam(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL, let window else { return }
        let account = UsageReader.read(dir, providerID: "claude-code")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("移除 \(account.org ?? dir.lastPathComponent)？",
                              "Remove \(account.org ?? dir.lastPathComponent)?")
        alert.informativeText = L("""
        会把 \(dir.path) 移到废纸篓（含这个 team 的登录状态和本地会话记录）。
        之后想再显示它需要重新登录。如有终端正用这个目录跑 claude，会受影响。
        """, """
        This moves \(dir.path) to the Trash (including this team's login state and local session history).
        You'll need to log in again to show it later. Any terminal running claude with this directory will be affected.
        """)
        alert.addButton(withTitle: L("移到废纸篓", "Move to Trash"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.recycle([dir]) { _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.setTeamStatus(L("移除失败：\(error.localizedDescription)",
                                             "Failed to remove: \(error.localizedDescription)"))
                        return
                    }
                    self.setTeamStatus(L("已移除 \(dir.lastPathComponent)（在废纸篓里，可恢复）",
                                         "Removed \(dir.lastPathComponent) (in the Trash, recoverable)"))
                    self.rebuildTeamList()
                    self.onTeamAdded?()      // make the status bar re-read the account list
                }
            }
        }
    }

    @objc private func revealClicked() {
        Settings.writeTemplateIfMissing()
        NSWorkspace.shared.activateFileViewerSelecting([Settings.path])
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func saveClicked() {
        // Commit any in-progress text field edits first.
        window?.makeFirstResponder(nil)

        let prefix = prefixField.stringValue.trimmingCharacters(in: .whitespaces)
        do {
            try Settings.save(
                providerEnabled: [
                    "claude-code": claudeCheck.state == .on,
                    "claude-swap": swapCheck.state == .on,
                    "codex": codexCheck.state == .on,
                    "litellm": litellmCheck.state == .on,
                ],
                providerOptions: ["litellm": [
                    "baseURL": baseURLField.stringValue.trimmingCharacters(in: .whitespaces),
                    "apiKey": apiKeyValue.trimmingCharacters(in: .whitespaces),
                ]],
                pollMinutes: max(5, pollField.integerValue),
                menuBarPrefix: prefix.isEmpty ? Settings.defaults.menuBarPrefix : prefix,
                language: ["auto", "zh", "en"][max(0, languagePopup.indexOfSelectedItem)])
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("保存失败", "Save Failed")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        onSave?()
        window?.close()
    }
}
