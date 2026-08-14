import CryptoKit
import Foundation

/// 直连 Anthropic 的 usage 端点刷新某个配置目录的额度。
///
/// 背景：CLI ≥2.1.228（2026-08-12）起，无头 `claude -p "/usage"` 变成空转 ——
/// 退出码 0、~40ms 返回、不发网络请求、不写 `cachedUsageUtilization`，
/// 原来「起子进程替我们刷缓存」的路死了。现在自己动手：
///   1. 从 Keychain 读该目录的 OAuth access token（只读，不刷新、不写回）
///   2. `GET api.anthropic.com/api/oauth/usage`（Claude Code 自己也走这个口）
///   3. 结果落到本应用自己的缓存 —— **不回写 `.claude.json`**，那是 Claude Code
///      的活状态文件，读改写有竞态，丢数据的锅背不起。
enum Refresher {

    /// 刷新节流（UI 层用）。端点每次都返回实时数据，这只是别打太勤。
    static let refreshWindow: TimeInterval = 5 * 60

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// 多个 team 串行打端点、隔一点距离，别给限流留话柄。
    /// （2026-08-13 实测的"并发只活一个"其实是另外三个 token 过期 —— 这个端点
    /// 对过期 OAuth token 回的是 429 rate_limit_error，不是 401，别被骗了。）
    private static let gate = NSLock()
    private static var lastRequestAt = Date.distantPast
    private static let requestSpacing: TimeInterval = 2

    /// 刷新一个目录。**同步阻塞**，调用方自己放到后台队列。
    static func refresh(_ configDir: URL, timeout: TimeInterval = 25) -> RefreshResult {
        gate.lock()
        defer { gate.unlock() }
        let wait = requestSpacing - Date().timeIntervalSince(lastRequestAt)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        lastRequestAt = Date()
        return doRefresh(configDir, timeout: timeout)
    }

    private static func doRefresh(_ configDir: URL, timeout: TimeInterval) -> RefreshResult {
        let token: String
        switch readAccessToken(configDir) {
        case .ok(let t):           token = t
        case .missing(let msg):    return .needsLogin(msg)
        case .fail(let msg):       return .failed(msg)
        }

        var request = URLRequest(url: usageURL, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ai-usage-bar", forHTTPHeaderField: "User-Agent")

        var payload: Data?
        var status = 0
        var transportError: String?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            payload = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            transportError = error?.localizedDescription
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + timeout + 5) == .success else {
            return .failed("超时（\(Int(timeout))s）")
        }

        if let transportError { return .failed(transportError) }
        if status == 401 {
            return .needsLogin("token 失效（401）")
        }
        if status == 429 {
            // 实测这个端点对过期 OAuth session 回 429（不是 401）。真限流也长这样，
            // 但托盘一小时打一次不至于，按过期处理。
            return .needsLogin("登录已过期（429）")
        }
        guard status == 200 else {
            // 排查形状变化全靠响应体，截一段带出来。
            let body = payload.flatMap { String(data: $0, encoding: .utf8) }?
                .prefix(120) ?? ""
            return .failed("HTTP \(status) \(body)")
        }
        guard let payload,
              let util = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        else { return .failed("返回不是 JSON") }
        // 响应结构 = `.claude.json` 里 cachedUsageUtilization.utilization。
        // 一个额度字段都没有说明接口形状变了，别把垃圾当数据存下去。
        guard util["limits"] != nil || util["five_hour"] != nil || util["seven_day"] != nil
        else { return .failed("返回缺额度字段（接口变了？）") }

        do {
            let record: [String: Any] = [
                "fetchedAtMs": Date().timeIntervalSince1970 * 1000,
                "utilization": util,
            ]
            let file = cacheFile(configDir)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: record).write(to: file)
        } catch {
            return .failed("缓存写不进去：\(error.localizedDescription)")
        }
        return .updated
    }

    /// 本应用自己缓存的最近一次直连结果。没刷过 / 读不出来为 nil。
    static func cached(_ configDir: URL) -> (fetchedAt: Date, utilization: [String: Any])? {
        guard let data = try? Data(contentsOf: cacheFile(configDir)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ms = root["fetchedAtMs"] as? Double,
              let util = root["utilization"] as? [String: Any]
        else { return nil }
        return (Date(timeIntervalSince1970: ms / 1000), util)
    }

    private static func cacheFile(_ configDir: URL) -> URL {
        UsageReader.home
            .appendingPathComponent(".cache/ai-usage-bar/claude")
            .appendingPathComponent(configDir.lastPathComponent + ".json")
    }

    // MARK: - Keychain

    /// Claude Code 存 token 的 Keychain service 名（binary 里 `KJ()` 的逻辑）：
    /// 默认目录是 `Claude Code-credentials`；自定义 CLAUDE_CONFIG_DIR 追加
    /// `-<sha256(路径 NFC 规范化)的前 8 位 hex>`。
    static func keychainService(for configDir: URL) -> String {
        let base = "Claude Code-credentials"
        guard configDir.lastPathComponent != ".claude" else { return base }
        let path = configDir.path.precomposedStringWithCanonicalMapping
        let hex = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(base)-\(hex)"
    }

    private enum TokenResult {
        case ok(String)
        /// Keychain 里压根没有这份凭证 —— 走「重新登录」引导。
        case missing(String)
        case fail(String)
    }

    /// 走 `/usr/bin/security` 读，不走进程内 Security.framework —— Claude Code 自己
    /// 就是用 `security` 写入的，创建者 = 读取者，不会弹「想访问你的钥匙串」授权框；
    /// 换成 framework 调用则每次 token 轮换都要重新授权一次。
    private static func readAccessToken(_ configDir: URL) -> TokenResult {
        let service = keychainService(for: configDir)
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-a", user, "-w", "-s", service]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch {
            return .fail("起不来 security：\(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        if proc.terminationStatus == 44 {   // errSecItemNotFound
            return .missing("没登录过（Keychain 无凭证）")
        }
        guard proc.terminationStatus == 0 else {
            return .fail("读 Keychain 失败（rc \(proc.terminationStatus)）")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return .fail("凭证格式看不懂") }
        return .ok(token)
    }
}
