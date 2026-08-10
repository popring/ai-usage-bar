import Foundation

/// Claude Code 订阅额度（Pro / Max / Team 的 5 小时窗与 7 天窗）。
///
/// 读：解析各配置目录的 `.claude.json`，不碰凭证。
/// 刷新：`claude -p "/usage"` 无头调用，不过模型、不花钱。
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
