# Prop Firm Trade Copier: Plan

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
 │ CopierMaster EA  │ ─────────────▶ │ master_<id>.json     │ ◀──────── │ CopierSlave EA       │
 │ (snapshot of all │  every ~100ms  │ (positions + orders) │           │ diff → open/modify/  │
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

## Components

### 1. `CopierMaster.mq5`
- Runs on a timer (`EventSetMillisecondTimer(100)`) and in `OnTradeTransaction`.
- Writes the snapshot to a temp file and then renames it, so a follower never reads a half-written file.
- Snapshot fields: `master_id`, `seq`, `timestamp`, `balance`, and per position: `ticket`, `symbol`, `type`, `volume`, `open_price`, `sl`, `tp`, `magic`.
- Sends a heartbeat every second, even when nothing has changed.
- **The format is platform-neutral** so cTrader (and MT4) can use it later. It's plain JSON. Volume is in **lots** (cTrader converts lots to units itself), symbols use the master's raw name (each follower maps them), and times are UTC.

### 2. `CopierSlave.mq5`
Inputs:
- `MasterId`
- `LotMultiplier`
- `SymbolSuffix` / symbol map (e.g. `EURUSD` → `EURUSD.r`, `US30` → `DJ30`)
- `CopySLTP` (bool)
- `MaxSlippagePoints`
- `MaxLotPerTrade`
- `DailyLossLimit` (stop copying before the prop firm's limit is hit)
- `ReverseCopy` = false, kept off for prop firm safety
- `MagicNumber`

Main loop:
1. Read the snapshot. Skip it if `seq` is unchanged. If the heartbeat is older than N seconds, raise an alert and **do not close anything**.
2. Map master ticket → follower position using the comment `CP|<master_ticket>` plus a local mapping file as a backup, because some brokers rewrite comments.
3. For each master position:
   - If it is missing on the follower → open it at `volume × multiplier`, normalized to the symbol's min, max and step.
   - If SL/TP differ → modify.
   - If the follower volume is larger than the target (a partial close on the master) → partially close.
4. For each follower position whose master ticket is gone → close it.
5. Retry failed orders with backoff, log every action, and use `Alert` for anything critical.

### 3. Optional: `CopierPanel`
An on-chart panel showing link status, latency, and a per-follower P&L vs. daily limit.

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
- **Netting vs. hedging accounts:** handle `ACCOUNT_MARGIN_MODE`. Most prop firm MT5 accounts are hedging.
- **Pending orders:** phase 2.
- **Trades opened manually on a follower:** ignore anything without the copier's magic number.

## Prop firm considerations
- Read each firm's rules. Many **allow copying between your own accounts** but **ban copying between different people**, opposite-direction hedging across accounts, and some HFT or latency-arbitrage patterns.
- Some firms flag identical trades across many accounts. Exact timing and size are usually fine for your own accounts, but check.
- Run a per-account daily drawdown guard **in the EA**, set slightly tighter than the firm's limit.
- Use a VPS close to the brokers' servers if possible, because every extra millisecond of delay means more slippage on the followers.
- **Why run it yourself and not use a hosted copier:** every account trades from one consistent IP that only you use (your PC, or one dedicated VPS). Hosted copiers send orders from shared server IPs, which can link your accounts to other users' accounts in a firm's checks. Don't mix home and VPS logins on the same account, and don't use a VPN that changes IP.

## Project layout
```
tradecopier/
├── plan.md
├── MQL5/
│   ├── Experts/CopierMaster.mq5
│   ├── Experts/CopierSlave.mq5
│   └── Include/Copier/
│       ├── Snapshot.mqh      # serialize / parse snapshot (simple JSON or CSV)
│       ├── SymbolMap.mqh
│       ├── LotCalc.mqh
│       └── RiskGuard.mqh
├── MQL4/                      # phase 3 port, same snapshot format
└── docs/setup.md              # how to install terminals and attach the EAs
```

## Phases
1. **MVP (MT5):** master snapshot, follower open/close market positions, multiplier, symbol suffix. Tested on 1 master + 2 demo followers.
2. **Robustness:** SL/TP sync, partial closes, mapping-file recovery, heartbeat, retries, logging.
3. **Risk & prop features:** daily loss guard, max lot, trading-hours filter, equity-based kill switch.
4. **Extras:** pending orders, MT4 port, on-chart panel, Telegram/Push alerts.
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
- Measure copy latency (master open time vs. follower fill time) and aim for under 300 ms locally.

## Open questions
- How many follower accounts, and are they all at the same firm?
- Is the master itself a prop account, or a personal or demo account?
- Do you trade pending orders, or only market orders?
- Will this run on your PC or a VPS?
