import AppKit

/// 设置面板。纯代码 AppKit（本机没有完整 Xcode，用不了 xib）。
///
/// 保存 = 写回 config.json（0600）→ `Settings.reload()` → 通过 `onSave` 让
/// 状态栏那边重建定时器并刷一次。手改 JSON 依然可用，面板只是常用项的快捷入口。
final class SettingsWindowController: NSWindowController {

    /// 保存成功后回调（Settings 已 reload 完）。
    var onSave: (() -> Void)?
    /// 「添加 Claude team」检测到登录完成后回调（拿新 team 的用量）。
    var onTeamAdded: (() -> Void)?

    private let claudeCheck = NSButton(checkboxWithTitle: "Claude Code", target: nil, action: nil)
    private let codexCheck = NSButton(checkboxWithTitle: "Codex", target: nil, action: nil)
    private let litellmCheck = NSButton(checkboxWithTitle: "LiteLLM 网关", target: nil, action: nil)
    private let baseURLField = NSTextField()
    // API key 的密文/明文是两个字段切着用（NSSecureTextField 自己变不了明文），
    // 值以当前可见的那个为准，切换时互相同步。
    private let apiKeyField = NSSecureTextField()
    private let apiKeyPlainField = NSTextField()
    private let apiKeyToggle = NSButton()
    private var apiKeyVisible = false
    private let pollField = NSTextField()
    private let pollStepper = NSStepper()
    private let prefixField = NSTextField()
    private let addTeamStatus = NSTextField(labelWithString: "")
    private var addTeamStatusRow: NSView!
    private let teamsStack = NSStackView()
    private var teamDirs: [URL] = []
    private let codexStatus = NSTextField(labelWithString: "")
    private let litellmNote = NSTextField(labelWithString: "")
    private var litellmNoteRow: NSView!
    private var teamPollTimer: Timer?
    private var hasShownOnce = false

    init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "AI Usage Bar 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// app 是 .accessory（不进 Dock），必须先 activate 窗口才会到前台，
    /// 否则开在别的应用后面，看着像没反应。
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

    /// 窗口是 contentRect: .zero 建的，尺寸全靠 AutoLayout 撑，实际会比内容窄一圈——
    /// 表现为输入框顶到右边缘、焦点环被裁。每次内容变化后按 fittingSize 定一次尺寸。
    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    // MARK: - 布局

    private func buildContent() -> NSView {
        baseURLField.placeholderString = "https://gateway.example.com"
        apiKeyField.placeholderString = "sk-…"
        apiKeyPlainField.placeholderString = "sk-…"
        apiKeyPlainField.isHidden = true
        apiKeyToggle.bezelStyle = .inline
        apiKeyToggle.isBordered = false
        apiKeyToggle.image = NSImage(systemSymbolName: "eye",
                                     accessibilityDescription: "显示 API Key")
        apiKeyToggle.target = self
        apiKeyToggle.action = #selector(apiKeyToggleClicked)
        apiKeyToggle.toolTip = "显示/隐藏明文"
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

        let pollRow = NSStackView(views: [pollField, pollStepper, smallLabel("分钟，下限 5")])
        pollRow.orientation = .horizontal
        pollField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let addTeam = NSButton(title: "添加 Claude team…",
                               target: self, action: #selector(addTeamClicked))
        addTeam.controlSize = .small
        addTeamStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        addTeamStatus.textColor = .secondaryLabelColor
        addTeamStatus.isSelectable = true            // alias 提示要能复制
        addTeamStatus.lineBreakMode = .byWordWrapping
        addTeamStatus.maximumNumberOfLines = 6   // alias 那行要完整可复制，别截断
        addTeamStatus.preferredMaxLayoutWidth = 260

        // 已发现的 team 列表（populate 时重建）。
        teamsStack.orientation = .vertical
        teamsStack.alignment = .leading
        teamsStack.spacing = 3

        // Codex 是零配置的（自动读 ~/.codex/auth.json），面板能给的只有状态反馈。
        codexStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let codexRow = NSStackView(views: [codexCheck, codexStatus])
        codexRow.orientation = .horizontal
        codexRow.spacing = 8

        // 网关的值可能来自环境变量 / ~/.zshrc（Finder 启动的 app 读不到 shell 环境，
        // 但 provider 会去 ~/.zshrc 捞）。populate 会把生效值回填并在这里标注来源。
        litellmNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        litellmNote.textColor = .secondaryLabelColor
        litellmNoteRow = indented(litellmNote)
        litellmNoteRow.isHidden = true

        // 「显示来源」整块收进一个竖向 stack：team 列表、add-team 按钮和状态行缩进，
        // 表示从属于 Claude Code；状态行空着就整行隐藏，不留空隙。
        addTeamStatusRow = indented(addTeamStatus)
        addTeamStatusRow.isHidden = true
        let sourceStack = NSStackView(views: [
            claudeCheck, indented(teamsStack), indented(addTeam), addTeamStatusRow,
            codexRow, litellmCheck, litellmNoteRow,
        ])
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 8
        sourceStack.setCustomSpacing(4, after: claudeCheck)
        sourceStack.setCustomSpacing(6, after: litellmCheck)

        let apiKeyRow = NSStackView(views: [apiKeyField, apiKeyPlainField, apiKeyToggle])
        apiKeyRow.orientation = .horizontal
        apiKeyRow.spacing = 6

        let grid = NSGridView(views: [
            [gridLabel("显示来源"), sourceStack],
            [gridLabel("网关地址"), baseURLField],
            [gridLabel("网关 API Key"), apiKeyRow],
            [gridLabel("轮询间隔"), pollRow],
            [gridLabel("菜单栏前缀"), prefixField],
        ])
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        baseURLField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        apiKeyField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        apiKeyPlainField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        prefixField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let reveal = NSButton(title: "在 Finder 中显示配置文件",
                              target: self, action: #selector(revealClicked))
        reveal.bezelStyle = .inline
        reveal.controlSize = .small

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "保存", target: self, action: #selector(saveClicked))
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

    /// 包一层左缩进，表示该控件从属于上一行的勾选项（18pt ≈ 勾选框图标宽度）。
    private func indented(_ view: NSView) -> NSStackView {
        let row = NSStackView(views: [view])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        return row
    }

    /// 状态行有内容才占位，空着时整行隐藏。
    private func setTeamStatus(_ text: String) {
        addTeamStatus.stringValue = text
        addTeamStatusRow.isHidden = text.isEmpty
        fitWindow()   // 状态行显隐会改变内容高度，窗口得跟着变，否则文案被裁
    }

    // MARK: - 数据

    /// 每次打开都从当前配置重新灌一遍，别显示上次没保存的残留。
    private func populate() {
        let settings = Settings.shared
        claudeCheck.state = settings.forProvider("claude-code").enabled ? .on : .off
        codexCheck.state = settings.forProvider("codex").enabled ? .on : .off

        rebuildTeamList()
        let codexOn = CodexProvider.isLoggedIn
        codexStatus.stringValue = codexOn ? "已登录" : "未登录（跑一次 codex 登录即可）"
        codexStatus.textColor = codexOn ? .secondaryLabelColor : .tertiaryLabelColor

        let litellm = settings.forProvider("litellm")
        litellmCheck.state = litellm.enabled ? .on : .off
        baseURLField.stringValue = litellm.string("baseURL") ?? ""
        apiKeyValue = litellm.string("apiKey") ?? ""
        setApiKeyVisible(false)             // 每次打开都从密文开始

        // 配置文件里没写但实际生效着（环境变量 / ~/.zshrc 捞到的）——把生效值回填
        // 进字段并标注来源，不然面板一片空白、网关却在正常出数，谁看谁迷惑。
        litellmNoteRow.isHidden = true
        if baseURLField.stringValue.isEmpty, apiKeyValue.isEmpty,
           let cfg = LiteLLMProvider.resolveConfig(), cfg.source != .configFile {
            baseURLField.stringValue = cfg.baseURL
            apiKeyValue = cfg.apiKey
            litellmNote.stringValue = "当前值读自 \(cfg.source.label)；点保存会写进配置文件（此后以配置文件为准）"
            litellmNoteRow.isHidden = false
        }

        pollField.integerValue = max(5, settings.pollMinutes)
        pollStepper.integerValue = pollField.integerValue
        prefixField.stringValue = settings.menuBarPrefix
        litellmToggled()
    }

    /// 重建已发现的 Claude team 列表。数据源和菜单一致：~/.claude 和 ~/.claude-*。
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
        let name = NSTextField(labelWithString: dir.lastPathComponent + (isDefault ? "（默认）" : ""))
        name.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        if isDefault { name.toolTip = "claude 命令默认用的目录，跟着你在终端里切 team 而变" }

        let detailText = account.isLoggedIn
            ? [account.org, account.email].compactMap { $0 }.joined(separator: " · ")
            : "未登录"
        let detail = smallLabel(detailText)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if !account.isLoggedIn { detail.textColor = .tertiaryLabelColor }

        // 每行一个「⋯」操作菜单。用 tag 关联 teamDirs 下标。
        let action = NSButton(title: "⋯", target: self, action: #selector(teamActionsClicked(_:)))
        action.bezelStyle = .inline
        action.controlSize = .small
        action.tag = index
        action.toolTip = "复制 alias、在 Finder 中显示、移除"

        let row = NSStackView(views: [name, detail, action])
        row.orientation = .horizontal
        row.spacing = 6
        row.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        return row
    }

    // MARK: - 动作

    @objc private func litellmToggled() {
        let on = litellmCheck.state == .on
        baseURLField.isEnabled = on
        apiKeyField.isEnabled = on
        apiKeyPlainField.isEnabled = on
        apiKeyToggle.isEnabled = on
    }

    /// API key 的当前值，读写都走可见的那个字段并保持两边同步。
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
        let current = apiKeyValue          // 先取当前值再切，编辑一半的内容不能丢
        let wasEditingKey = apiKeyField.currentEditor() != nil
            || apiKeyPlainField.currentEditor() != nil
        apiKeyVisible = visible
        apiKeyValue = current
        apiKeyField.isHidden = visible
        apiKeyPlainField.isHidden = !visible
        apiKeyToggle.image = NSImage(systemSymbolName: visible ? "eye.slash" : "eye",
                                     accessibilityDescription: visible ? "隐藏 API Key" : "显示 API Key")
        // 正在编辑 key 时焦点跟着切过去，光标别丢在已隐藏的字段里
        if wasEditingKey {
            window?.makeFirstResponder(visible ? apiKeyPlainField : apiKeyField)
        }
    }

    @objc private func pollStepped() {
        pollField.integerValue = pollStepper.integerValue
    }

    /// 一键引导加 team：起个名 → 开终端登录 → 登录完成自动出现在菜单里。
    /// 登录本身没法代办（浏览器 OAuth + 选 team），能自动化的只有目录、
    /// 环境变量和「登录好了没」的检测。
    @objc private func addTeamClicked() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "添加 Claude team"
        alert.informativeText = "起个短名（建议英文，如 work）。会打开终端让你登录一次，登录时选对应的 team。"
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        nameField.placeholderString = "work"
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField
        alert.addButton(withTitle: "打开终端登录")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.startTeamLogin(nameField.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    private func startTeamLogin(_ name: String) {
        guard name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            setTeamStatus("名字只能用字母、数字、- 和 _")
            return
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-\(name)")
        if UsageReader.read(dir, providerID: "claude-code").isLoggedIn {
            setTeamStatus("~/.claude-\(name) 已存在且已登录，直接就能看")
            return
        }

        // .command 文件 Terminal 双击即执行，不需要任何自动化权限。
        // GUI 起的 Terminal 是登录 shell，但 PATH 仍显式兜底（同 Refresher）。
        let script = """
        #!/bin/bash
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        export CLAUDE_CONFIG_DIR="$HOME/.claude-\(name)"
        echo "为 team「\(name)」登录 Claude Code：跟着提示走，登录时选对应的 team。"
        echo "登录完成后退出（/exit）并关掉本窗口，AI Usage Bar 会自动发现。"
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
            setTeamStatus("准备登录脚本失败：\(error.localizedDescription)")
            return
        }
        NSWorkspace.shared.open(scriptURL)
        setTeamStatus("已打开终端，等待 ~/.claude-\(name) 登录…")
        pollForLogin(name: name, dir: dir)
    }

    private func pollForLogin(name: String, dir: URL) {
        teamPollTimer?.invalidate()
        var attempts = 180                            // 5s × 180 = 15 分钟
        teamPollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            attempts -= 1
            let account = UsageReader.read(dir, providerID: "claude-code")
            if account.isLoggedIn {
                timer.invalidate()
                self.setTeamStatus("""
                ✓ 已添加 \(account.org ?? name)。想在终端里日常用它，把这行放进 shell 配置：
                alias claude-\(name)='CLAUDE_CONFIG_DIR=$HOME/.claude-\(name) claude'
                """)
                self.rebuildTeamList()
                self.onTeamAdded?()
            } else if attempts <= 0 {
                timer.invalidate()
                self.setTeamStatus("没等到登录。之后登录完成也会自动出现在菜单里，不影响。")
            }
        }
    }

    // MARK: - team 行操作

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
        // 默认目录就是裸 `claude`，不需要 alias；也不允许从这里移除。
        item("复制 alias 命令", #selector(copyTeamAlias(_:)), enabled: !isDefault)
        item("在 Finder 中显示", #selector(revealTeam(_:)))
        menu.addItem(.separator())
        item(isDefault ? "移除（默认目录不可移除）" : "移除…",
             #selector(removeTeam(_:)), enabled: !isDefault)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func copyTeamAlias(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        let name = dir.lastPathComponent.replacingOccurrences(of: ".claude-", with: "")
        let alias = "alias claude-\(name)='CLAUDE_CONFIG_DIR=$HOME/\(dir.lastPathComponent) claude'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(alias, forType: .string)
        setTeamStatus("已复制：\(alias)")
    }

    @objc private func revealTeam(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// 移除 = 整个配置目录扔进废纸篓（可从废纸篓恢复）。登录态跟着目录走，
    /// 移除后想再看这个 team 得重新登录。
    @objc private func removeTeam(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL, let window else { return }
        let account = UsageReader.read(dir, providerID: "claude-code")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "移除 \(account.org ?? dir.lastPathComponent)？"
        alert.informativeText = """
        会把 \(dir.path) 移到废纸篓（含这个 team 的登录状态和本地会话记录）。
        之后想再显示它需要重新登录。如有终端正用这个目录跑 claude，会受影响。
        """
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.recycle([dir]) { _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.setTeamStatus("移除失败：\(error.localizedDescription)")
                        return
                    }
                    self.setTeamStatus("已移除 \(dir.lastPathComponent)（在废纸篓里，可恢复）")
                    self.rebuildTeamList()
                    self.onTeamAdded?()      // 让菜单栏那边重读账号列表
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
        // 让正在编辑的文本框先提交值。
        window?.makeFirstResponder(nil)

        let prefix = prefixField.stringValue.trimmingCharacters(in: .whitespaces)
        do {
            try Settings.save(
                providerEnabled: [
                    "claude-code": claudeCheck.state == .on,
                    "codex": codexCheck.state == .on,
                    "litellm": litellmCheck.state == .on,
                ],
                providerOptions: ["litellm": [
                    "baseURL": baseURLField.stringValue.trimmingCharacters(in: .whitespaces),
                    "apiKey": apiKeyValue.trimmingCharacters(in: .whitespaces),
                ]],
                pollMinutes: max(5, pollField.integerValue),
                menuBarPrefix: prefix.isEmpty ? Settings.defaults.menuBarPrefix : prefix)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "保存失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        onSave?()
        window?.close()
    }
}
