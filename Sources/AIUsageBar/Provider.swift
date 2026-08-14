import Foundation

/// 一个额度来源。
///
/// 目前只有 Claude Code，但后面要接 Codex 和自建 AI 网关，
/// 所以数据获取全部走这层，UI 只认 `Account`，不认具体是谁家的。
///
/// 加一个新来源要做的事：
///   1. 写个类型实现本协议
///   2. 塞进 `ProviderRegistry.all`
/// UI 和刷新调度都不用改。
protocol UsageProvider {
    /// 稳定标识，用于把账号路由回它的来源。
    var id: String { get }

    /// 菜单里的分组标题。只有一个来源时不显示。
    var displayName: String { get }

    /// 读本地状态，**不发网络请求**。菜单每次打开都会调，必须快。
    func readAccounts() -> [Account]

    /// 刷新一个账号。**同步阻塞**，调度层负责放后台并发。
    func refresh(_ account: Account) -> RefreshResult
}

enum RefreshResult {
    case updated
    /// 命中来源自己的刷新窗口，服务端沿用了旧数据。
    case notYet(age: TimeInterval)
    case failed(String)
    /// 登录态已死（过期/被拒/没登录过），重试救不回来，得用户重新登录。
    /// UI 对它给引导动作，普通 failed 只展示原因。
    case needsLogin(String)
    /// 该来源不支持主动刷新（比如网关是被动推的）。
    case notSupported
}

/// 所有来源。加新来源只动这里。
enum ProviderRegistry {
    /// 全部已实现的来源。加新来源只动这里。
    private static let registered: [UsageProvider] = [
        ClaudeCodeProvider(),
        CodexProvider(),
        LiteLLMProvider(),
    ]

    /// 配置里启用了的来源。用户可以在 config.json 里关掉不想看的。
    ///
    /// 每次都重算（而不是 `static let`）—— 否则「重新加载配置」改不动来源开关，
    /// 得重启应用才生效。来源就个位数，这点开销无所谓。
    static var all: [UsageProvider] {
        registered.filter { Settings.shared.forProvider($0.id).enabled }
    }

    static func provider(id: String) -> UsageProvider? {
        all.first { $0.id == id }
    }

    /// 读全部来源的账号。
    static func readAllAccounts() -> [Account] {
        all.flatMap { $0.readAccounts() }
    }

    /// 并行刷新给定账号（可以跨来源），回调在主线程。
    static func refresh(_ accounts: [Account],
                        completion: @escaping ([String: RefreshResult]) -> Void) {
        guard !accounts.isEmpty else { completion([:]); return }

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
