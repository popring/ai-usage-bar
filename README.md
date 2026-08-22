<p align="center">
  <img src="docs/ai-usage-bar-icon.png" width="128" alt="AI Usage Bar icon">
</p>

# AI Usage Bar

**English** | [中文](README.zh-CN.md)

**All your AI subscription quotas, one glance away.**

You subscribe to Claude Code and Codex, and your company hands you a gateway key on top — every quota lives in a different place, and nothing warns you before you hit the ceiling. AI Usage Bar pulls them all into the macOS menu bar: a percentage always in sight, full details one click away, and a notification before you run dry.

<p align="center">
  <img src="docs/menu.png" width="480" alt="AI Usage Bar menu screenshot">
</p>

## Features

- **Everything in one place**: Claude Code (multiple teams), every account managed by Claude Swap (cswap), Codex, and a self-hosted LiteLLM gateway — one menu covers them all
- **Follows the account in use**: the menu bar number automatically tracks whichever account is active — switches from Claude Code CLI (incl. claude-swap) and Claude Desktop are picked up within seconds; you can also pin any account manually
- **cswap compatible**: if you use [claude-swap](https://github.com/realiti4/claude-swap) (cswap), there is nothing to configure — the app reads its usage cache directly, every slot account shows up in the menu, and the currently active slot is marked. Read-only; never touches its credentials
- **Quota alerts**: a system notification fires when the account you're using approaches its limit — no more discovering it at 100%
- **Always shows data age**: every reading is labeled with how long ago it was fetched, and anything older than 10 minutes is marked stale — better an honest "3m ago" than fake real-time
- **Bilingual**: the UI follows your system language (English / Chinese) and can be forced either way in Settings
- **No telemetry**: nothing is uploaded anywhere; the app only talks to the vendors' own endpoints. The whole thing is ~1000 lines of code you can audit yourself

## Install

Requires macOS 13+ and Swift 6 (Command Line Tools is enough — **no full Xcode needed**).

```bash
./scripts/bundle.sh && cp -R "build/AI Usage Bar.app" ~/Applications/
```

Or grab a prebuilt `.app` from [Releases](../../releases).

Launch at login: System Settings → General → Login Items.

## Configuration

Menu → **Settings…** (⌘,) opens the panel: source toggles, LiteLLM gateway URL and API key, poll interval, menu bar prefix, UI language, and **one-click Add Claude Team**. Changes apply immediately, no restart.

Behind the panel sits `~/.config/ai-usage-bar/config.json` (respects `XDG_CONFIG_HOME`; auto-generated on first run with `0600` permissions). Hand-editing works too — hit **Reload Config** (⌘L) afterwards:

```json
{
  "pollMinutes": 20,
  "menuBarPrefix": "AI",
  "language": "auto",
  "providers": {
    "claude-code": { "enabled": true },
    "claude-swap": { "enabled": true },
    "codex":       { "enabled": true },
    "litellm":     { "enabled": false, "baseURL": "", "apiKey": "" }
  }
}
```

Set `enabled` to `false` to hide a source entirely (it won't even be refreshed). `language` accepts `auto` (follow system) / `zh` / `en`. `pollMinutes` has a floor of 5 — see "Two design trade-offs" below.

## How each source works

### Claude Code

Reads `.claude.json` (`cachedUsageUtilization`) from each config directory — **never touches credentials**. Refreshing runs `claude -p "/usage" --safe-mode`: headless mode can run slash commands, fetching live quota from the server and writing it back to the cache, **without invoking the model or spending anything** (`total_cost_usd: 0`, `num_turns: 0` in the response).

**Multiple teams**: each team under the same account needs its own login state, achieved with separate config directories. **Use the panel**: Settings → **Add Claude Team…** — pick a short name, the app creates the directory and opens Terminal, you log in as usual (choosing the right team), and it appears in the menu automatically.

The manual equivalent:

```bash
mkdir -p ~/.claude-work ~/.claude-personal
CLAUDE_CONFIG_DIR=~/.claude-work claude       # pick team A at login
CLAUDE_CONFIG_DIR=~/.claude-personal claude   # pick team B at login
```

The app auto-discovers `~/.claude` and every `~/.claude-*`. Logging in once per team is dictated by Claude Code's credential model (one login state belongs to one org) — there is no way around it.

> ⚠️ **Never export `CLAUDE_CONFIG_DIR` in your shell config** — it relocates *all* your `claude` runs, losing history, settings, MCP, and plugins. Use an alias instead:
> ```bash
> alias claude-work='CLAUDE_CONFIG_DIR=$HOME/.claude-work claude'
> ```

### Claude Swap (cswap)

If you manage multiple Claude accounts with [claude-swap](https://github.com/realiti4/claude-swap), **there is nothing to set up**: the app reads its artifacts directly (the usage cache and config backups under `~/.claude-swap-backup/`), every slot account appears in the menu, and the currently active slot is marked.

Read-only — never touches its credentials or state. cswap has no background daemon: its usage cache is only rewritten while its CLI runs, so left alone this group can sit frozen for hours. "Refresh Now" therefore drives cswap's own collector (`cswap list`, which reads every slot and switches nothing) and then re-reads the cache. Without cswap installed, the group simply doesn't appear.

### Codex

`GET https://chatgpt.com/backend-api/wham/usage`, authenticated with the OAuth token from `~/.codex/auth.json` — the same credential and the same endpoint the Codex CLI itself uses.

> ⚠️ **Undocumented endpoint** — OpenAI may change it at any time. Blast radius is limited to `CodexProvider.swift`.

**Where the quota lives depends on the plan type** — the easiest thing to get wrong:

| Plan | Quota field |
|---|---|
| Personal (Plus / Pro) | `rate_limit.primary` / `.secondary` percentage windows |
| business / team | `spend_control.individual_limit`, denominated in **credits** (not dollars; `rate_limit` is `null` here) |

Local session rollouts (`~/.codex/sessions/**/rollout-*.jsonl`) **only record `rate_limits`**, so inspecting local files on a business plan wrongly concludes "no quota data". You have to hit the endpoint.

On a 401 (expired token) the app runs `codex doctor` once — it exchanges the refresh_token for a new access token and writes it back to `auth.json`, via the official flow, without touching your login state.

### LiteLLM gateway

[LiteLLM](https://github.com/BerriAI/litellm) is a common self-hosted AI gateway: teams use it to proxy multiple model vendors, issue per-key budgets, and centralize billing. If your company gave you a gateway key starting with `sk-` and an internal URL, it's probably this.

`GET {baseURL}/key/info` returns the key's `spend` / `max_budget` / `budget_duration` / `budget_reset_at` — how much you've spent this cycle, the cap, and when it resets. This is LiteLLM's public API, not a private endpoint, so this source is the most stable of the bunch.

Config resolution order: config file → environment variables `LITELLM_BASE_URL` / `LITELLM_API_KEY` → the matching `export` lines in your shell config.

That last fallback isn't laziness — an `.app` launched from Finder **doesn't inherit shell environment variables**; without it, env-var-only setups would silently see nothing.

## Privacy & Security

This tool touches your credentials, so the boundaries are spelled out for easy auditing (the whole codebase is ~1000 lines).

**What it reads**

| File | Contents | Purpose |
|---|---|---|
| `~/.claude.json`, `~/.claude*/.claude.json` | Usage cache and account metadata, **no credentials** | Show Claude Code quota |
| `~/.claude-swap-backup/cache/usage.json` etc. | Per-slot usage and org metadata written by claude-swap's own collector, **read-only** | Show cswap account quota |
| `~/Library/Application Support/Claude/Local Storage/leveldb/*.log` | Regex-extracts only the `lastOrganization` org uuid; no other bytes parsed or stored | Real-time signal for the follow feature (Desktop side) |
| `~/.codex/auth.json` | **Contains the OAuth access token** | Used solely as the `Authorization` header to ChatGPT |
| `~/.config/ai-usage-bar/config.json` | The LiteLLM URL and key you entered | Query your own gateway |
| Shell config (e.g. `~/.zshrc`) | Matches only the `LITELLM_BASE_URL` / `LITELLM_API_KEY` lines | Config fallback |

**Where it sends**

- `https://chatgpt.com/backend-api/wham/usage` — with your Codex token (the identical request the Codex CLI sends)
- `{your configured baseURL}/key/info` — with your gateway key, only to your own gateway

**No third parties, no telemetry, no analytics.** No network requests beyond the two above.

**What it executes**

- `claude -p "/usage" --safe-mode --output-format json` — fetch Claude Code quota
- `zsh -lc "codex doctor"` — **only when Codex returns 401**, refreshing the expired token via the official command

**What it writes**

- `~/.cache/ai-usage-bar/*.json` — only the usage numbers it needs, **never any token**
- `~/.config/ai-usage-bar/config.json` — template generated on first run with `0600` permissions; loose permissions are tightened at startup

**What it never does**: read browser data, upload anything, or modify your login state (`codex doctor` is the official refresh flow — identical to typing it yourself).

## Two design trade-offs

**1. Refresh has a floor.** Claude Code's `/usage` only truly refetches about every 5 minutes; calls within the window get served stale data — **with exit code 0**. So the app compares timestamps before and after a refresh and only counts it as an update when the clock actually moved. The 20-minute background poll is just a safety net — opening the menu auto-refreshes anything older than 5 minutes, so what you see is always fresh; setting pollMinutes lower than 5 has no effect.

**2. Data age is always shown.** These are snapshots, not a live stream. Anything older than 10 minutes is marked stale. Better an honest "3m ago" than pretend real-time.

## Adding a new source

All data fetching lives behind the `UsageProvider` protocol; the UI only knows `Account`:

```swift
struct FooProvider: UsageProvider {
    let id = "foo"
    let displayName = "Foo"
    func readAccounts() -> [Account] { ... }                    // read local cache, no requests
    func refresh(_ account: Account) -> RefreshResult { ... }    // sync/blocking; scheduler handles concurrency
}
```

Register it in the `registered` array in `Provider.swift`. Menu bar title, grouped display, parallel refresh, and data-age labels all work without changes.

Push-style sources can return `.notSupported` from `refresh` — the UI labels it honestly instead of pretending to refresh.

## Debugging

```bash
swift run AIUsageBar --dump              # no UI, local reads only
swift run AIUsageBar --dump --refresh    # refresh first, then print
```

For screenshots / testing, `AI_USAGE_BAR_HOME=<dir>` redirects all local reads to a fake home directory, and `AI_USAGE_BAR_DEMO=1` disables all network refreshes — feed it fixture data and run the real UI.

## Known limitations

- Claude Code's default directory `~/.claude` changes as you switch teams in the UI. When it points at the same team as a dedicated directory, it is auto-hidden — the dedicated directory is the stable copy.
- Subscription quotas only. API billing accounts (Anthropic Console / OpenAI Platform) are a different system and out of scope.
- A source that has never been refreshed shows "Not fetched yet" — click "Refresh Now" once.

## Feedback

Hit a bug, want a new source supported, or have any suggestion — open an
[Issue](https://github.com/popring/ai-usage-bar/issues). Attaching the output of `swift run AIUsageBar --dump` (with emails and other sensitive bits redacted) speeds up diagnosis a lot.

If you find it useful, a ⭐ **Star** is the best way to keep this project moving.

## License

MIT
