import Foundation

/// Claude Code subscription quota (Pro / Max / Team 5-hour and 7-day windows).
///
/// Read: parse each config dir's `.claude.json` + this app's direct-fetch cache;
/// whichever is newer wins.
/// Refresh: pull the token from the Keychain and hit the usage endpoint directly;
/// on token expiry, run one headless CLI to renew it and retry (see Refresher).
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
