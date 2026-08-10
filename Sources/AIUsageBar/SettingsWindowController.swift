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
    private let apiKeyField = NSSecureTextField()
    private let pollField = NSTextField()
    private let pollStepper = NSStepper()
    private let prefixField = NSTextField()
    private let addTeamStatus = NSTextField(labelWithString: "")
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
        if !hasShownOnce {
            window?.center()
            hasShownOnce = true
        }
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 布局

    private func buildContent() -> NSView {
        baseURLField.placeholderString = "https://gateway.example.com"
        apiKeyField.placeholderString = "sk-…"
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
        addTeamStatus.maximumNumberOfLines = 4
        addTeamStatus.preferredMaxLayoutWidth = 280

        let grid = NSGridView(views: [
            [gridLabel("显示来源"), claudeCheck],
            [NSGridCell.emptyContentView, addTeam],
            [NSGridCell.emptyContentView, addTeamStatus],
            [NSGridCell.emptyContentView, codexCheck],
            [NSGridCell.emptyContentView, litellmCheck],
            [gridLabel("网关地址"), baseURLField],
            [gridLabel("网关 API Key"), apiKeyField],
            [gridLabel("轮询间隔"), pollRow],
            [gridLabel("菜单栏前缀"), prefixField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        baseURLField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        apiKeyField.widthAnchor.constraint(equalToConstant: 280).isActive = true
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

    // MARK: - 数据

    /// 每次打开都从当前配置重新灌一遍，别显示上次没保存的残留。
    private func populate() {
        let settings = Settings.shared
        claudeCheck.state = settings.forProvider("claude-code").enabled ? .on : .off
        codexCheck.state = settings.forProvider("codex").enabled ? .on : .off

        let litellm = settings.forProvider("litellm")
        litellmCheck.state = litellm.enabled ? .on : .off
        baseURLField.stringValue = litellm.string("baseURL") ?? ""
        apiKeyField.stringValue = litellm.string("apiKey") ?? ""

        pollField.integerValue = max(5, settings.pollMinutes)
        pollStepper.integerValue = pollField.integerValue
        prefixField.stringValue = settings.menuBarPrefix
        litellmToggled()
    }

    // MARK: - 动作

    @objc private func litellmToggled() {
        let on = litellmCheck.state == .on
        baseURLField.isEnabled = on
        apiKeyField.isEnabled = on
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
            addTeamStatus.stringValue = "名字只能用字母、数字、- 和 _"
            return
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-\(name)")
        if UsageReader.read(dir, providerID: "claude-code").isLoggedIn {
            addTeamStatus.stringValue = "~/.claude-\(name) 已存在且已登录，直接就能看"
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
            addTeamStatus.stringValue = "准备登录脚本失败：\(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.open(scriptURL)
        addTeamStatus.stringValue = "已打开终端，等待 ~/.claude-\(name) 登录…"
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
                self.addTeamStatus.stringValue = """
                ✓ 已添加 \(account.org ?? name)。想在终端里日常用它，把这行放进 shell 配置：
                alias claude-\(name)='CLAUDE_CONFIG_DIR=$HOME/.claude-\(name) claude'
                """
                self.onTeamAdded?()
            } else if attempts <= 0 {
                timer.invalidate()
                self.addTeamStatus.stringValue = "没等到登录。之后登录完成也会自动出现在菜单里，不影响。"
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
                    "apiKey": apiKeyField.stringValue.trimmingCharacters(in: .whitespaces),
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
