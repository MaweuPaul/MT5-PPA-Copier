# Setup

## 1. One MT5 install per account

MetaTrader allows one logged-in account per terminal, so each account gets its own **portable** install. Keep these installs outside the repo: they're large and contain saved logins.

```
D:\MT5\
├── Master\  Follower1\  Follower2\     copies of an MT5 install
└── Start-All.cmd                       starts each with /portable
```

In each terminal:
1. **File → Login to Trade Account** (or **Open an Account** for a new demo), with **Save password** ticked.
2. **Tools → Options → Expert Advisors** → tick **Allow algorithmic trading**.
3. Make sure the **Algo Trading** toolbar button is green.

The account must use **hedging** mode. Netting isn't supported yet.

## 2. Deploy the EAs

From the repo root:

```powershell
powershell -ExecutionPolicy Bypass -Command "& .\scripts\deploy.ps1"
# options: -Mt5Root D:\MT5 -Terminals Master,Follower1,Follower2
```

The script copies `MQL5\` into every terminal and compiles it. Each line should say `OK`. In each terminal, open **Navigator → Expert Advisors** and right-click → **Refresh** to see `TradeCopier`.

**After redeploying, restart the follower terminals** (or remove and re-attach the EA). The follower runs a continuous polling loop, so MT5 doesn't swap in the new build by itself. A restart reloads the chart with the EA and keeps its settings.

## 3. Attach the master EA

In the **master** terminal, drag **TradeCopier → CopierMaster** onto any chart and click OK. The chart then shows `TradeCopier MASTER <login> | N position(s)`.

## 4. Attach a follower EA to each follower

In each **follower** terminal, drag **TradeCopier → CopierFollower** onto any chart and set:

| Input | Example | Notes |
|---|---|---|
| `MasterId` | `592208623` | The master account's login number |
| `LotMultiplier` | `1.0`, `0.5` | Follower lots = master lots × this |
| `SymbolSuffix` | `m` | For brokers like Exness (`EURUSD` → `EURUSDm`). Leave empty if the names match. |
| `SymbolMap` | `XAUUSD=GOLD;US30=DJ30` | Only for names that differ in other ways |

The chart then shows `TradeCopier FOLLOWER x<multiplier> | master <id> | copying | …`.

**Each EA must sit on only one chart per terminal.** The follower uses a chart's event loop for polling, so put it on a chart you don't need for anything else.

## 5. Test

1. Open a small trade on the master, e.g. 0.10 lot EURUSD.
2. Check that each follower opens its copy. The **Experts** tab shows a line like:
   `OPEN BUY 0.05 EURUSDm (master #…) | noticed 3 ms after master, executed in 72.4 ms`
3. Set an SL/TP on the master. The followers should match it.
4. Partially close the master, e.g. 0.10 → 0.05. The followers should shrink by the same ratio.
5. Close the master. The followers should close.

## 6. Dashboard

Build and run it from the repo root (needs Go 1.22+):

```powershell
cd dashboard
go build -o tradecopier-dashboard.exe .
.\tradecopier-dashboard.exe          # opens http://127.0.0.1:8750
```

Options:
- `-addr 127.0.0.1:8750`: listen address. Loopback only, so anything else is refused.
- `-open=false`: don't open the browser.
- `-root <path>`: a different TradeCopier folder.

**What the dashboard shows and does:**
- **Master:** online state, balance, equity and open positions.
- **Followers:** state, multiplier, open copies, balance and equity, and latency (last / average / max).
- **Settings:** lot multiplier with a live preview ("master 0.20 → 0.10 here"), max lot, suffix, prefix, symbol map and copy SL/TP. Changes apply within about a second, with no restart.
- **Pause all copying:** stops new copies. Closes and SL/TP changes are still mirrored.
- **Activity:** copies, skips, errors and setting changes, filterable by account.

**Closing the dashboard doesn't affect copying.**

## Behaviour to know

- **Trades already open when a follower starts are not copied,** unless `CopyExistingOnStart = true`, because copying them late would be at a worse price.
- **If a copy is closed on the follower** (its own SL hit, or closed by hand), it won't be reopened.
- **If the master stops publishing** (EA removed or terminal closed), followers show `master_stale` and **keep their copies open**. Nothing is closed automatically.
- **Changing a follower's multiplier** only affects new trades. Open copies keep the multiplier they were opened with.
- **Settings saved in the dashboard override the EA inputs** for sizing, symbols and SL/TP. To go back to the inputs, delete that follower's `config\follower_<login>.json`.
- **Files** live in `%APPDATA%\MetaQuotes\Terminal\Common\Files\TradeCopier\`. See [snapshot-format.md](snapshot-format.md).
