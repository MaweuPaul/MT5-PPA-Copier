# Multi-Account Trade Copier: Plan

## Goal
Place a trade on one **master** MT5/MT4 account and have it copied to all **follower** accounts on the same PC. Followers can be prop firm or personal broker accounts. Each follower has its own lot multiplier.

## Decisions so far
| Topic | Decision |
|---|---|
| Platform | MetaTrader 5 first, then an MT4 port that uses the same file format |
| Lot sizing | Multiplier per follower account (for example 1.0x, 0.5x, 2.0x) |
| Transport | Shared file in the MetaTrader **Common Files** folder (local, no server, no DLLs) |
| Copy model | State sync: followers repeatedly match the master's open positions |

## Architecture

```
 Terminal A (Master)                 Common\Files\TradeCopier\           Terminals B, C, D… (Followers)
 ┌──────────────────┐   writes       ┌──────────────────────┐   reads   ┌──────────────────────┐
 │ CopierMaster EA  │ ─────────────▶ │ master_<id>.json     │ ◀──────── │ CopierFollower EA    │
 │ (snapshot of all │  on each trade │ (open positions)     │           │ diff → open/modify/  │
 │  positions)      │                └──────────────────────┘           │ close to match       │
 └──────────────────┘                                                   └──────────────────────┘
```

- One MT5 terminal can log into only one account, so each account needs **its own terminal install**. Use separate folders, installed with `/portable` or from each firm's own installer.
- Every terminal on the PC can read and write `%APPDATA%\MetaQuotes\Terminal\Common\Files`, so the EAs use `FILE_COMMON`.

### Why state sync and not event copying
The follower does not replay "open/close" events. It compares *what the master has now* with *what the follower has now* and fixes any difference. This gives three things:
- Recovery after a follower restart, a disconnect or a missed update.
- Partial closes, SL/TP edits and closes all handled by the same code path.
- No duplicated or lost trades when a message gets dropped.

## Latency design
Target: a follower order is sent **under 5 ms** after the master's fill, not counting network time to the broker.

| Stage | Approach | Expected |
|---|---|---|
| 1. Master detects trade | `OnTradeTransaction` (event-driven, no polling) | < 1 ms |
| 2. Master publishes | Write snapshot immediately on the event; keep a timer only for heartbeat | < 1 ms |
| 3. Follower notices | Tight loop, `Sleep(1)`, checks a tiny `seq` file first and parses the full snapshot only when it changes | 1–2 ms (target), up to ~16 ms on default Windows timer |
| 4. Follower builds order | Symbol info, filling mode and lot rules **cached at startup**; symbols pre-selected; no `OrderCheck` | < 1 ms |
| 5. Order → broker → fill | Network + broker; **this dominates** | 1–5 ms on a VPS near the broker, 50–250 ms from a distant home PC |

Rules:
- **Followers run in parallel:** one terminal each, so no follower waits for another.
- **`OrderSendAsync`** when a follower has to send several orders at once, e.g. on a close-all.
- **Copy-on-fill** by default (safe). An optional "fast mode" could publish on the master's order *request*, before the fill. It saves a few ms but risks copying a trade the master's broker rejected.
- **Measure everything:** log master fill time, follower detect time, follower send time and follower fill time. Report the averages and the worst case.
- **Upgrade path if file polling is too slow:** shared memory plus a Windows named event (`kernel32.dll`: `CreateFileMappingW`, `MapViewOfFile`, `WaitForSingleObject`). This pushes changes in microseconds instead of polling, but needs "Allow DLL imports" in each terminal.
- **Biggest real-world gain:** host on a Windows VPS in the same data centre as the brokers' servers. Most use London LD4 or New York NY4; check each server's ping in MT5. A dedicated VPS still gives one consistent IP.

## Components

### 1. `CopierMaster.mq5`
- Publishes immediately in `OnTradeTransaction`. A 1-second timer is only a backup and heartbeat.
- Writes the snapshot to a temp file and then renames it, so a follower never reads a half-written file.
- Snapshot fields: `master_id`, `seq`, `timestamp`, `balance`, and per position: `ticket`, `symbol`, `type`, `volume`, `open_price`, `sl`, `tp`, `magic`.
- Sends a heartbeat every second, even when nothing has changed.
- **The format is platform-neutral** so cTrader (and MT4) can use it later. It's plain JSON. Volume is in **lots** (cTrader converts lots to units itself), symbols use the master's raw name (each follower maps them), and times are UTC.

### 2. `CopierFollower.mq5`
Inputs:
- `MasterId`
- `LotMultiplier`
- `SymbolSuffix` / symbol map (e.g. `EURUSD` → `EURUSD.r`, `US30` → `DJ30`)
- `CopySLTP` (bool)
- `MaxSlippagePoints`
- `MaxLotPerTrade`
- `DailyLossLimit` (stop copying before the account's own limit is hit)
- `ReverseCopy` = false, kept off by default because many firms ban hedging across accounts
- `MagicNumber`

Main loop (a tight `Sleep(1)` loop, not a slow timer):
1. Read the small `seq` file. Only if it changed, read and parse the snapshot. If the heartbeat is older than N seconds, raise an alert and **do not close anything**.
2. Map master ticket → follower position using a links file (`state/links_<login>.csv`). The comment `CP|<master_ticket>` is a backup for recovery, because some brokers rewrite comments.
3. For each master position:
   - If it is missing on the follower → open it at `volume × multiplier`, normalized to the symbol's min, max and step.
   - If SL/TP differ → modify.
   - If the follower volume is larger than the target (a partial close on the master) → partially close.
4. For each follower position whose master ticket is gone → close it.
5. Retry failed orders with backoff, log every action, and use `Alert` for anything critical.

### 3. Optional: `CopierPanel`
An on-chart panel showing link status, latency, and a per-follower P&L vs. daily limit.

## Dashboard (Go backend + HTML/CSS)
The copy path stays EA → shared files → EA. The dashboard is a **control plane only**. If it is closed or crashes, copying continues.

```
 Browser (HTML/CSS + minimal vanilla JS)  ◀──HTTP──▶  Go server (127.0.0.1 only)  ◀──files──▶  Common\Files\TradeCopier\
```

**Go server** (standard library only: `net/http`, `encoding/json`, `embed`):
- Serves the HTML/CSS/JS, embedded into a single `tradecopier.exe` with `//go:embed`.
- Reads the master snapshot, each follower's status file, and the logs and latency stats.
- Writes follower settings (multiplier, symbol map, limits) to `config/<account>.json`. Followers re-read their file when it changes.
- Kill switch: writes a `paused` flag that every follower checks before sending orders.
- Listens on `127.0.0.1:<port>` only, never on `0.0.0.0`.

**API (JSON):**
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/accounts` | Master and followers: connected, balance, equity, open positions, last heartbeat |
| GET | `/api/latency` | Latest latency per follower (avg / worst) |
| GET/PUT | `/api/followers/{id}/config` | Read or update a follower's settings |
| POST | `/api/pause`, `/api/resume` | Global kill switch |
| GET | `/api/logs?account=` | Recent log lines |

**Frontend:** plain HTML + CSS, plus about 100 lines of vanilla JS that poll `/api/accounts` every second. No frameworks, no build step.

**Follower settings from the dashboard** (lot multiplier, symbol map, limits, enabled on/off):
- Followers are **discovered automatically**: each follower EA writes `status_<account>.json`, and the dashboard lists every account it finds.
- Saving in the UI writes `config/<account>.json` (temp file + rename). The follower checks the file's modified time about every 500 ms and reloads when it changes. **No terminal restart needed.**
- The EA's own inputs are only defaults, used when no config file exists yet.
- **A multiplier change applies to new trades only.** Each copied position stores the multiplier it was opened with in the mapping file, so changing 1.0 → 0.5 never resizes trades that are already open. Partial closes keep the same ratio.
- Validation in Go and again in the EA: multiplier between 0.01 and 100, max lot > 0. Invalid configs are rejected, and the follower keeps its last good config.

**Followers write a status file** (`status_<account>.json`, about once a second) with balance, equity, daily P&L, copy state and latency, so the dashboard can show it.

## Credentials & config (no database)
- **The copier never stores or sees passwords.** Each MT5 terminal logs into its own account, and MT5 keeps that login encrypted in its own profile ("Save password" when logging in). The EAs run inside terminals that are already logged in.
- **Settings** (multiplier, symbol map, limits) are the EA's inputs, saved as `.set` presets per account. A shared `copier.ini` in Common Files is optional.
- **Runtime state** (ticket mapping, logs) goes in plain files under `Common\Files\TradeCopier\`.
- **Auto-start:** a Windows Startup shortcut per terminal: `terminal64.exe /portable`. MT5 reconnects with its saved login, and the EA reattaches from the saved chart profile.
- **Avoid** putting passwords in `/config:` startup .ini files, scripts or this repo. If an external launcher ever needs them, use Windows Credential Manager (DPAPI), not a text file.

## Edge cases to handle
- **Lot normalization:** a result below the symbol's minimum lot means either skip the trade or round up to the minimum (configurable).
- **Symbol names differ between brokers:** use the symbol map, and check `SymbolSelect` before trading.
- **Market closed / requotes / `TRADE_RETCODE_*` errors:** retry within the slippage limit, then alert.
- **Follower EA started while trades are open:** it adopts matching trades only if `CopyExistingOnStart = true`. Otherwise it copies new trades only.
- **Netting vs. hedging accounts:** handle `ACCOUNT_MARGIN_MODE`. Most MT5 retail and prop accounts are hedging.
- **Pending orders:** phase 2.
- **Trades opened manually on a follower:** ignore anything without the copier's magic number.

## Broker & prop firm considerations
- Read each broker's and prop firm's rules. Many **allow copying between your own accounts** but **ban copying between different people**, opposite-direction hedging across accounts, and some HFT or latency-arbitrage patterns.
- Managing other people's accounts may require regulatory authorization. The copier is for accounts you own.
- Some firms flag identical trades across many accounts. Exact timing and size are usually fine for your own accounts, but check.
- Run a per-account daily drawdown guard **in the EA**. For prop accounts, set it slightly tighter than the firm's limit. For personal accounts, use your own risk limit.
- Use a VPS close to the brokers' servers if possible, because every extra millisecond of delay means more slippage on the followers.
- **Why run it yourself and not use a hosted copier:** every account trades from one consistent IP that only you use (your PC, or one dedicated VPS). Hosted copiers send orders from shared server IPs, which can link your accounts to other users' accounts in a firm's checks. Don't mix home and VPS logins on the same account, and don't use a VPN that changes IP.

## Project layout
```
MQL5/Experts/TradeCopier/   CopierMaster.mq5, CopierFollower.mq5
MQL5/Include/TradeCopier/   Common, Snapshot, SymbolMap, Links, Lots, Settings, Risk, EventLog, Latency
dashboard/                  Go server (api, store, terminals, jsonfile) + web/ UI + e2e/ Playwright tests
scripts/deploy.ps1          compile the EAs into every added account
docs/                       setup.md, snapshot-format.md
```

## Phases
| Phase | Scope | Status |
|---|---|---|
| 1. MVP (MT5) | Master snapshot; follower opens and closes, lot multiplier, symbol suffix | ✅ Done, tested FxPro → Pepperstone + Exness demos |
| 2. Robustness | SL/TP sync, partial closes, links file + comment recovery, heartbeat, retries, async close-all | ✅ Done |
| 2b. Dashboard | Go + HTML/CSS/JS: status, live settings, pause, activity log, alerts, templates | ✅ Done |
| 2c. Easy setup | Dashboard creates each account's MT5, installs the EA, logs in; Launch all; Start with Windows | ✅ Done |
| 3. Risk | Daily loss limit, equity floor, max lot/trades/total lots, trading hours, news pause, copy delay + random extra | ✅ Done |
| 4. Extras | Pending orders, MT4 port, Telegram alerts, lot modes (fixed / balance ratio / risk %), several masters | Planned |

The phases below keep their original notes:
5. **cTrader support:** a cBot (C#, cTrader Automate) that runs inside the cTrader desktop app and reads and writes the same snapshot files. Any platform can then be master or follower (MT5 → cTrader, cTrader → MT5, etc.). Because the cBot runs inside a logged-in cTrader app, there are still no credentials and no Open API/OAuth tokens. The cBot needs `AccessRights.FullAccess` to reach the shared folder.
6. **Later, if needed:** remote followers on another PC or VPS (replace the file transport with a small TCP/WebSocket relay).

## Testing
- Use demo accounts from 2–3 different brokers to cover different symbol names and lot steps.
- Test cases:
  - Open, modify SL/TP, partial close, full close.
  - Follower restart while trades are open.
  - Master terminal closed (followers must **not** close their trades).
  - Market closed.
  - Lot result below the minimum.
- Measure latency at every stage (see Latency design). Aim for under 5 ms from master fill to follower order sent, then compare home PC vs. VPS for total time to fill.

## Decided along the way
- **Accounts:** several followers at different brokers. In testing, FxPro is the master and Pepperstone and Exness are followers.
- **Hosting:** local PC first. A Windows VPS near the brokers is the recommended upgrade for lower latency.
- **Orders:** market orders only for now. Pending orders are phase 4.
- **Dashboard:** Go standard library only, vanilla JS modules, an always-light full-width UI in plain language.
