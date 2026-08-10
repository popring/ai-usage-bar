import Foundation

/// 强制刷新某个配置目录的用量数据。
///
/// 原理：`claude -p "/usage"` 在无头模式下能跑斜杠命令，它会向服务端取实时额度
/// 并把响应写回该目录的 `.claude.json`。这一步 **不过模型、不花钱**
/// （返回里 `total_cost_usd: 0`、`num_turns: 0`）。
enum Refresher {

    /// `/usage` 大约 5 分钟才会真的重新取数，窗口内重复调用是白跑。
    static let refreshWindow: TimeInterval = 5 * 60

    /// 刷新一个目录。**同步阻塞**，调用方自己放到后台队列。
    static func refresh(_ configDir: URL, timeout: TimeInterval = 120) -> RefreshResult {
        let before = fetchedAtMs(configDir)

        var env = ProcessInfo.processInfo.environment
        // 坑：默认目录必须 **不设** CLAUDE_CONFIG_DIR。显式设成 ~/.claude 会让
        // Claude Code 去 ~/.claude/.claude.json 找状态，那是另一个（空的）位置。
        if configDir.lastPathComponent == ".claude" {
            env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        } else {
            env["CLAUDE_CONFIG_DIR"] = configDir.path
        }
        // GUI 程序继承到的 PATH 很短，claude 一般装在 ~/.local/bin。
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
            + (env["PATH"] ?? "/usr/bin:/bin")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["claude", "-p", "/usage", "--safe-mode", "--output-format", "json"]
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()

        do {
            try proc.run()
        } catch {
            return .failed("起不来 claude：\(error.localizedDescription)")
        }

        // 超时看门狗：到点仍在跑就杀掉，别把 UI 线程的刷新任务永远挂住。
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if proc.isRunning {
            proc.terminate()
            return .failed("超时（\(Int(timeout))s）")
        }
        guard proc.terminationStatus == 0 else {
            return .failed("claude 退出码 \(proc.terminationStatus)")
        }

        // 关键：退出码 0 **不代表数据真的更新了**。窗口内重复调用时服务端会
        // 沿用上一份，命令照样成功返回。必须比对 fetchedAtMs 才知道。
        guard let after = fetchedAtMs(configDir) else {
            return .failed("跑通了但没写出用量数据")
        }
        if let before, after <= before {
            return .notYet(age: Date().timeIntervalSince1970 - after / 1000)
        }
        return .updated
    }

    private static func fetchedAtMs(_ configDir: URL) -> Double? {
        guard let state = UsageReader.stateFile(for: configDir),
              let data = try? Data(contentsOf: state),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any]
        else { return nil }
        return cached["fetchedAtMs"] as? Double
    }
}
