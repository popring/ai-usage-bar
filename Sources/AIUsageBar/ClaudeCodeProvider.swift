import Foundation

/// Claude Code 订阅额度（Pro / Max / Team 的 5 小时窗与 7 天窗）。
///
/// 读：解析各配置目录的 `.claude.json` + 本应用直连缓存，谁新用谁。
/// 刷新：Keychain 取 token 直连 usage 端点（CLI ≥2.1.228 无头 /usage 已废，见 Refresher）。
struct ClaudeCodeProvider: UsageProvider {
    let id = "claude-code"
    let displayName = "Claude Code"

    func readAccounts() -> [Account] {
        UsageReader.configDirs().map { UsageReader.read($0, providerID: id) }
    }

    func refresh(_ account: Account) -> RefreshResult {
        Refresher.refresh(URL(fileURLWithPath: account.localID))
    }
}
