import Foundation

/// One quota source.
///
/// Only Claude Code today, but Codex and a self-hosted AI gateway are coming,
/// so all data acquisition goes through this layer — the UI only knows `Account`,
/// never whose data it is.
///
/// To add a new source:
///   1. Implement this protocol
///   2. Add it to `ProviderRegistry.all`
/// No changes to the UI or refresh scheduling.
protocol UsageProvider {
    /// Stable identifier, used to route accounts back to their source.
    var id: String { get }

    /// Section title in the menu. Hidden when there is only one source.
    var displayName: String { get }

    /// Read local state — **no network requests**. Called every time the menu
    /// opens; must be fast.
    func readAccounts() -> [Account]

    /// Refresh one account. **Synchronous/blocking**; the scheduler runs it on a
    /// background queue.
    func refresh(_ account: Account) -> RefreshResult
}

enum RefreshResult {
    case updated
    /// Hit the source's own refresh window; the server kept the old data.
    case notYet(age: TimeInterval)
    case failed(String)
    /// Login state is dead (expired/revoked/never logged in) — retrying won't help,
    /// the user must re-login. The UI offers a guided action for this; plain
    /// failed only shows the reason.
    case needsLogin(String)
    /// Source doesn't support manual refresh (e.g. a gateway that pushes passively).
    case notSupported
}

/// All sources. Adding a new one only touches this.
enum ProviderRegistry {
    private static let registered: [UsageProvider] = [
        ClaudeCodeProvider(),
        ClaudeSwapProvider(),
        CodexProvider(),
        LiteLLMProvider(),
    ]

    /// Sources enabled in config. Users can turn off ones they don't want in config.json.
    ///
    /// Recomputed every time (not `static let`) — otherwise "reload config" can't
    /// change the source toggles without restarting the app. There are only a
    /// handful of sources, so the cost is negligible.
    static var all: [UsageProvider] {
        registered.filter { Settings.shared.forProvider($0.id).enabled }
    }

    static func provider(id: String) -> UsageProvider? {
        all.first { $0.id == id }
    }

    static func readAllAccounts() -> [Account] {
        all.flatMap { $0.readAccounts() }
    }

    /// Refresh the given accounts in parallel (may span sources); callback on the
    /// main thread.
    static func refresh(_ accounts: [Account],
                        completion: @escaping ([String: RefreshResult]) -> Void) {
        guard !accounts.isEmpty else { completion([:]); return }
        // Demo mode (fake data for screenshots/tests): send no requests, don't touch
        // the Keychain — otherwise real usage would overwrite the fake data and fake
        // credentials would render a screenful of refresh errors.
        if ProcessInfo.processInfo.environment["AI_USAGE_BAR_DEMO"] != nil {
            completion([:]); return
        }

        DispatchQueue.global(qos: .utility).async {
            var results: [String: RefreshResult] = [:]
            let lock = NSLock()
            let group = DispatchGroup()

            for account in accounts {
                guard let provider = provider(id: account.providerID) else { continue }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let r = provider.refresh(account)
                    lock.lock(); results[account.key] = r; lock.unlock()
                    group.leave()
                }
            }

            group.wait()
            DispatchQueue.main.async { completion(results) }
        }
    }
}
