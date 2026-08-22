import CryptoKit
import Foundation

/// Refreshes a config directory's quota by hitting Anthropic's usage endpoint directly.
///
/// Main path:
///   1. Read the directory's OAuth access token from Keychain (read-only, never written back)
///   2. `GET api.anthropic.com/api/oauth/usage` (the same endpoint Claude Code itself uses)
///   3. Store the result in this app's own cache — **never write back to `.claude.json`**,
///      which is Claude Code's live state file; a read-modify-write race there could lose
///      data we can't afford to be blamed for.
///
/// Renewal fallback: access tokens only live 8 hours, and we don't rotate refresh tokens
/// ourselves (we'd fight the CLI over Keychain writes). On expiry, run a headless
/// `claude -p "/usage"` once — the CLI exchanges the refreshToken for a new token and
/// writes it to Keychain, then we retry the direct call. Headless /usage was a no-op in
/// CLI 2.1.228 (2026-08-12), fixed in 2.1.232; if it breaks again, only this directory
/// falls back to "needs re-login" — the direct main path is unaffected.
enum Refresher {

    /// Refresh throttle (for the UI layer). The endpoint always returns live data; this
    /// only avoids hammering it.
    static let refreshWindow: TimeInterval = 5 * 60

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Serialize endpoint calls across teams with a small gap, giving rate limiting no excuse.
    /// (The 2026-08-13 "only one survives concurrency" observation was actually three
    /// expired tokens — this endpoint returns 429 rate_limit_error for expired OAuth
    /// tokens, not 401. Don't be fooled.)
    private static let gate = NSLock()
    private static var lastRequestAt = Date.distantPast
    private static let requestSpacing: TimeInterval = 2

    /// Refresh one directory. **Blocks synchronously** — callers must dispatch to a background queue.
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

        var reply = hitUsageEndpoint(token, timeout: timeout)

        // Observed: this endpoint returns 429 rate_limit_error (not 401) for expired OAuth
        // tokens. Real rate limiting looks the same, but our polling rate makes that
        // unlikely — treat it as expiry: run the CLI once to renew, then retry once.
        if reply.error == nil, reply.status == 401 || reply.status == 429 {
            if reauthViaCLI(configDir), case .ok(let fresh) = readAccessToken(configDir) {
                reply = hitUsageEndpoint(fresh, timeout: timeout)
            }
        }

        if let error = reply.error { return .failed(error) }
        if reply.status == 401 {
            return .needsLogin(L("token 失效（401）", "token invalid (401)"))
        }
        if reply.status == 429 {
            return .needsLogin(L("登录已过期（429）", "login expired (429)"))
        }
        guard reply.status == 200 else {
            // The response body is the only clue when the shape changes; carry a snippet out.
            let body = reply.payload.flatMap { String(data: $0, encoding: .utf8) }?
                .prefix(120) ?? ""
            return .failed("HTTP \(reply.status) \(body)")
        }
        guard let payload = reply.payload,
              let util = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        else { return .failed(L("返回不是 JSON", "response is not JSON")) }
        // Response shape = cachedUsageUtilization.utilization in `.claude.json`.
        // No quota fields at all means the API shape changed — don't cache garbage as data.
        guard util["limits"] != nil || util["five_hour"] != nil || util["seven_day"] != nil
        else {
            return .failed(L("返回缺额度字段（接口变了？）",
                             "response missing quota fields (API changed?)"))
        }

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
            return .failed(L("缓存写不进去：\(error.localizedDescription)",
                             "can't write cache: \(error.localizedDescription)"))
        }
        return .updated
    }

    private static func hitUsageEndpoint(
        _ token: String, timeout: TimeInterval
    ) -> (status: Int, payload: Data?, error: String?) {
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
            return (0, nil, L("超时（\(Int(timeout))s）", "timed out (\(Int(timeout))s)"))
        }
        return (status, payload, transportError)
    }

    /// Renewal fallback for an expired token: run the headless CLI, which exchanges the
    /// refreshToken for a new access token and writes it to Keychain (its own credential,
    /// so no authorization prompt). We only care that the token gets renewed; output is ignored.
    private static func reauthViaCLI(_ configDir: URL, timeout: TimeInterval = 90) -> Bool {
        var env = ProcessInfo.processInfo.environment
        // Gotcha: for the default directory CLAUDE_CONFIG_DIR must be **unset**. Setting it
        // explicitly to ~/.claude makes Claude Code look for state in ~/.claude/.claude.json,
        // which is a different (empty) location.
        if configDir.lastPathComponent == ".claude" {
            env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        } else {
            env["CLAUDE_CONFIG_DIR"] = configDir.path
        }
        // GUI apps inherit a short PATH; claude is usually installed in ~/.local/bin.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
            + (env["PATH"] ?? "/usr/bin:/bin")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["claude", "-p", "/usage", "--safe-mode"]
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }

        // Watchdog: kill it if still running at the deadline, so a background refresh never hangs forever.
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if proc.isRunning { proc.terminate(); return false }
        return proc.terminationStatus == 0
    }

    /// This app's cached result of the last direct fetch; nil if never fetched or unreadable.
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

    /// The Keychain service name Claude Code stores tokens under (the `KJ()` logic in its
    /// binary): the default directory uses `Claude Code-credentials`; a custom
    /// CLAUDE_CONFIG_DIR appends `-<first 8 hex chars of sha256(NFC-normalized path)>`.
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
        /// No such credential in Keychain at all — route to the "log in again" guidance.
        case missing(String)
        case fail(String)
    }

    /// Read via `/usr/bin/security`, not the in-process Security.framework — Claude Code
    /// writes the item with `security`, so creator == reader and no "wants to access your
    /// keychain" prompt appears; a framework call would require re-authorization on every
    /// token rotation.
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
            return .fail(L("起不来 security：\(error.localizedDescription)",
                           "can't launch security: \(error.localizedDescription)"))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        if proc.terminationStatus == 44 {   // errSecItemNotFound
            return .missing(L("没登录过（Keychain 无凭证）", "Never logged in (no Keychain credentials)"))
        }
        guard proc.terminationStatus == 0 else {
            return .fail(L("读 Keychain 失败（rc \(proc.terminationStatus)）",
                           "can't read Keychain (rc \(proc.terminationStatus))"))
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return .fail(L("凭证格式看不懂", "unrecognized credential format")) }
        return .ok(token)
    }
}
