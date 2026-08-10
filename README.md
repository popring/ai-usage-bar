# AI Usage Bar

> A macOS menu bar app that shows the usage quota of all your AI subscriptions in one place —
> **Claude Code** (including multiple teams under one account), **Codex**, and a self-hosted
> **LiteLLM** gateway. No telemetry, no third parties; it only talks to the vendors' own
> endpoints. Requires macOS 13+ and Swift 6 (Command Line Tools is enough — no full Xcode).
> Docs below are in Chinese; see [Privacy & Security](#隐私与安全) for exactly what it reads and sends.

macOS 菜单栏应用：把你所有 AI 订阅的额度放在一个地方看。

支持 **Claude Code**（含同账号下的多个 team）、**Codex**、**自建 LiteLLM 网关**。菜单栏常驻显示所有来源里最紧张的那个窗口，点开看明细 —— 以及**每份数据是多久之前取的**。点菜单里的账号名可以把菜单栏**固定**成只看那个账号（一个 team 用满、切到别的 team 干活时用），再点一次恢复自动。

```
CLAUDE CODE
Work Team                              $6.02 / $200
  ● █████░░░  63%  7d Opus · 21小时后
    ███░░░░░  33%  7d 全部 · 21小时后
    ░░░░░░░░   0%  5h · 4小时后
Personal
    未使用
CODEX
you@example.com（business）      $208.18 / $30000
  ● █░░░░░░░   1%  预算 · 21天后
LiteLLM
gateway-key                            $0.00 / $700
  ● ░░░░░░░░   0%  7d 预算 · 6天后
─────────────
数据 1分钟前
立即刷新  ⌘R
─────────────
设置…     ⌘,
重新加载配置 ⌘L
─────────────
退出      ⌘Q
```

## 安装

需要 Swift 6（macOS Command Line Tools 自带即可，**不需要完整 Xcode**）。

```bash
./scripts/bundle.sh && cp -R "build/AI Usage Bar.app" ~/Applications/
```

也可以直接下 [Releases](../../releases) 里打包好的 `.app`。

开机自启：系统设置 → 通用 → 登录项。

## 配置

菜单 → **设置…**（⌘,）打开配置面板：来源开关、LiteLLM 网关地址与 API Key、轮询间隔、菜单栏前缀，以及**一键添加 Claude team**（见下方「看多个 team」）。保存立刻生效，不用重启。

面板背后就是 `~/.config/ai-usage-bar/config.json`（尊重 `XDG_CONFIG_HOME`；首次运行自动生成，权限 `0600`），喜欢手改 JSON 依然可以，改完点 **重新加载配置**（⌘L）生效：

```json
{
  "pollMinutes": 60,
  "menuBarPrefix": "AI",
  "providers": {
    "claude-code": { "enabled": true },
    "codex":       { "enabled": true },
    "litellm":     { "enabled": false, "baseURL": "", "apiKey": "" }
  }
}
```

不想看的来源把 `enabled` 改成 `false`，那一组会整个消失（连刷新都不会跑）。`pollMinutes` 下限 5 分钟 —— 原因见下方「两个设计取舍」。

改完点「重新加载配置」即可，来源开关、轮询间隔、菜单栏前缀都会立刻生效。

## 各来源怎么工作

### Claude Code

读各配置目录里的 `.claude.json`（`cachedUsageUtilization`），**不碰任何凭证**。刷新靠 `claude -p "/usage" --safe-mode` —— 无头模式能跑斜杠命令，向服务端取实时额度并写回缓存，**不过模型、不花钱**（返回里 `total_cost_usd: 0`、`num_turns: 0`）。

**看多个 team**：同一个账号下的多个 team 需要各自一份登录态，靠多个配置目录实现。**推荐走面板**：设置 → **添加 Claude team…**，起个短名 → 自动建目录并打开终端 → 你在终端里正常登录（选对应的 team）→ 登录完成后自动出现在菜单里。

手动做等价于：

```bash
mkdir -p ~/.claude-work ~/.claude-personal
CLAUDE_CONFIG_DIR=~/.claude-work claude       # 登录时选 team A
CLAUDE_CONFIG_DIR=~/.claude-personal claude   # 登录时选 team B
```

本程序自动发现 `~/.claude` 和所有 `~/.claude-*`。每个 team 登录一次是 Claude Code 凭证模型决定的（一份登录态只属于一个 org），绕不开。

> ⚠️ **别把 `CLAUDE_CONFIG_DIR` export 进 shell 配置** —— 那会让你所有的 `claude` 都搬家，历史、settings、MCP、plugins 全都读不到。用 alias：
> ```bash
> alias claude-work='CLAUDE_CONFIG_DIR=$HOME/.claude-work claude'
> ```

### Codex

`GET https://chatgpt.com/backend-api/wham/usage`，用 `~/.codex/auth.json` 里的 OAuth token 认证 —— 和 Codex CLI 自己用的是同一个凭证、同一个口。

> ⚠️ **未公开接口**，OpenAI 随时可能改。影响范围限于 `CodexProvider.swift`。

**额度长在哪取决于计划类型**，这是最容易踩的坑：

| 计划 | 额度字段 |
|---|---|
| 个人版（Plus / Pro） | `rate_limit.primary` / `.secondary` 百分比窗口 |
| business / team | `spend_control.individual_limit` 的美元额度（此时 `rate_limit` 和 `credits` 都是 `null` / 0） |

本地 session rollout（`~/.codex/sessions/**/rollout-*.jsonl`）**只记 `rate_limits`**，所以在 business 计划下翻本地文件会得出「没有额度数据」的错误结论。必须打接口。

token 过期时（401）会自动跑一次 `codex doctor` —— 它用 refresh_token 换新 token 并写回 `auth.json`，走官方流程，不动你的登录态。

### LiteLLM 网关

[LiteLLM](https://github.com/BerriAI/litellm) 是常见的自建 AI 网关：团队用它统一代理各家模型、按 key 发额度、集中记账。如果你们公司给你发了一个 `sk-` 开头的网关 key 和一个内网地址，多半就是它。

`GET {baseURL}/key/info` 返回这个 key 的 `spend` / `max_budget` / `budget_duration` / `budget_reset_at` —— 也就是「这个周期你花了多少、上限多少、什么时候重置」。这是 LiteLLM 自己的公开接口，不是私有口，所以这条最稳。

配置来源按优先级：配置文件 → 环境变量 `LITELLM_BASE_URL` / `LITELLM_API_KEY` → shell 配置里的对应 `export`。

最后一条不是偷懒 —— 从 Finder 启动的 `.app` **拿不到 shell 环境变量**，不兜这一层就等于没配。

## 隐私与安全

这个工具会碰到你的凭证，所以把边界写清楚，方便自己审计（全部代码不到 1000 行）。

**读什么**

| 文件 | 内容 | 用途 |
|---|---|---|
| `~/.claude.json`、`~/.claude*/.claude.json` | 用量缓存与账号元信息，**不含凭证** | 展示 Claude Code 额度 |
| `~/.codex/auth.json` | **含 OAuth access token** | 仅用作请求 ChatGPT 的 `Authorization` 头 |
| `~/.config/ai-usage-bar/config.json` | 你填的 LiteLLM 地址与 key | 请求你自己的网关 |
| shell 配置（如 `~/.zshrc`） | 只匹配 `LITELLM_BASE_URL` / `LITELLM_API_KEY` 两行 | 配置回退 |

**发到哪**

- `https://chatgpt.com/backend-api/wham/usage` —— 带 Codex token（和 Codex CLI 自己发的是同一个请求）
- `{你配置的 baseURL}/key/info` —— 带你的网关 key，只发到你自己的网关

**没有第三方、没有遥测、没有分析。** 除上面两个地址外不发任何网络请求。

**跑什么子进程**

- `claude -p "/usage" --safe-mode --output-format json` —— 取 Claude Code 额度
- `zsh -lc "codex doctor"` —— **仅在 Codex 返回 401 时**，用官方命令刷新过期 token

**写什么**

- `~/.cache/ai-usage-bar/*.json` —— 只落用得上的用量数字，**不含任何 token**
- `~/.config/ai-usage-bar/config.json` —— 首次运行生成模板，权限 `0600`；已存在但权限过松时启动会收紧

**不做的事**：不读 Keychain、不读浏览器数据、不上传任何东西、不改你的登录态（`codex doctor` 走官方刷新流程，和你自己敲一遍完全一样）。

## 两个设计取舍

**1. 刷新有下限。** Claude Code 的 `/usage` 大约 5 分钟才真的重新取数，窗口内重复调用服务端沿用旧数据，**而且命令退出码仍然是 0**。所以程序比对刷新前后的时间戳，只有真往前走了才算更新；后台轮询默认 60 分钟只是兜底 —— 点开菜单时数据超过 5 分钟会自动刷新，看到的总是新的；手动把 pollMinutes 调密也不会低于 5。

**2. 永远显示数据年龄。** 这是快照不是实时流，超过 10 分钟标「已过期」。宁可让你看见「3 分钟前」，也不假装实时。

## 加一个新来源

数据获取全在 `UsageProvider` 协议后面，UI 只认 `Account`：

```swift
struct FooProvider: UsageProvider {
    let id = "foo"
    let displayName = "Foo"
    func readAccounts() -> [Account] { ... }                    // 读本地缓存，不发请求
    func refresh(_ account: Account) -> RefreshResult { ... }    // 同步阻塞，调度层负责并发
}
```

然后注册进 `Provider.swift` 的 `registered` 数组。菜单栏标题、分组展示、并行刷新、数据年龄标注都不用改。

被动推送型的来源可以在 `refresh` 里返回 `.notSupported`，UI 会如实标出来而不是假装刷新过。

## 调试

```bash
swift run AIUsageBar --dump              # 不起 UI，只读本地
swift run AIUsageBar --dump --refresh    # 先刷新再打印
```

## 已知限制

- Claude Code 的默认目录 `~/.claude` 会跟着你在界面里切 team 而变。它和某个专用目录指向同一个 team 时会被自动隐藏 —— 专用目录才是稳定的那份。
- 只覆盖订阅制额度。API 计费账号（Anthropic Console / OpenAI Platform）是另一套，不在这里。
- 没被刷新过的来源显示「还没取过」，点一次「立即刷新」即可。

## License

MIT
