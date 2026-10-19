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
powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1
# options: -Mt5Root D:\MT5 -Terminals Master,Follower1,Follower2
```

The script copies `MQL5\` into every terminal and compiles it. Each line should say `OK`. In each terminal, open **Navigator → Expert Advisors** and right-click → **Refresh** to see `TradeCopier`.

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

## Behaviour to know

- **Trades already open when a follower starts are not copied,** unless `CopyExistingOnStart = true`, because copying them late would be at a worse price.
- **If a copy is closed on the follower** (its own SL hit, or closed by hand), it won't be reopened.
- **If the master stops publishing** (EA removed or terminal closed), followers show `master_stale` and **keep their copies open**. Nothing is closed automatically.
- **Changing a follower's multiplier** only affects new trades. Open copies keep the multiplier they were opened with.
- **Files** live in `%APPDATA%\MetaQuotes\Terminal\Common\Files\TradeCopier\`. See [snapshot-format.md](snapshot-format.md).
