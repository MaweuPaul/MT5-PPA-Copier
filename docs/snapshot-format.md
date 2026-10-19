# Snapshot & file formats (v1)

Every TradeCopier component (the MQL5 EAs and the Go dashboard now; MQL4 and cTrader later) talks through plain files in the MetaTrader **Common Files** folder:

```
%APPDATA%\MetaQuotes\Terminal\Common\Files\TradeCopier\
├── master_<login>.json            # master EA: open positions (+ heartbeat)
├── control.json                   # dashboard: {"paused": true|false} for every follower
├── status\follower_<login>.json   # follower EA: state, balance, latency, live settings (~1/s)
├── config\follower_<login>.json   # dashboard: that follower's settings, re-read live by the EA
├── events\follower_<login>.jsonl  # follower EA: activity log, one JSON object per line
└── state\links_<login>.csv        # follower EA: which trades it has copied
```

All files are UTF-8 text. Times named `*_ms` are **Windows uptime in milliseconds** (`GetTickCount64`). This is one clock shared by every program on the PC, so values from different terminals can be compared directly. Resolution is about 10–16 ms.

## Master snapshot: `master_<login>.json`

The master rewrites this file whenever its positions change, and at least once a second as a heartbeat.

```json
{"seq":1760886000124,"version":1,"master_id":"5012345","server":"FxPro-MT5 Demo","pub_ms":91234567,
 "balance":10000,"equity":10012.5,
 "positions":[
  {"ticket":123456789,"symbol":"EURUSD","type":"buy","volume":1,"price":1.08512,"sl":1.08,"tp":0,"magic":0,"time_msc":1760886000100}
 ],
 "seq_end":1760886000124}
```

| Field | Meaning |
|---|---|
| `seq` | Goes up by one on every write, including heartbeats. Readers treat any **change** as new data, not only an increase. |
| `version` | Format version, currently `1`. |
| `master_id` | Master account login. |
| `server` | Master's broker server name. |
| `pub_ms` | Uptime ms when the snapshot was taken. Followers use it for latency and to detect a stale master. |
| `balance`, `equity` | Master account values in deposit currency. |
| `positions[]` | Every open position on the master account. |
| `ticket` | Master position ticket. This is the key that links a copy to its original. |
| `symbol` | The master broker's raw symbol name. Each follower maps it to its own name. |
| `type` | `"buy"` or `"sell"`. |
| `volume` | Lots, never platform units. cTrader converts lots to units itself. |
| `price`, `sl`, `tp` | Open price, stop-loss and take-profit. `0` means not set. |
| `magic`, `time_msc` | Master magic number and open time in server ms. These are informational only. |
| `seq_end` | Must equal `seq`. If it doesn't, the reader caught a half-written file and retries. |

**Rules for writers:**
- Write `seq` first and `seq_end` last.
- Use no nested objects inside a position.
- Don't put `{` or `}` inside string values.

**Rules for readers:**
- If the file can't be opened, or `seq` ≠ `seq_end`, try again on the next poll.

## Follower status: `status/follower_<login>.json`

```json
{"login":7012345,"server":"Pepperstone-Demo","master_id":"5012345","state":"copying",
 "balance":10000,"equity":9995.2,"multiplier":0.5,"open_copies":1,"last_seq":1760886000124,
 "latency_last_ms":18.4,"latency_avg_ms":21.0,"latency_max_ms":64.2,
 "updated_ms":91234990,"updated_local":"2026.10.19 16:40:12"}
```

| `state` | Meaning |
|---|---|
| `copying` | Healthy and following the master |
| `no_master` | No master file found. Check `MasterId` and whether the master EA is running. |
| `master_stale` | The master stopped publishing. Copies are **kept open** and nothing is closed. |
| `algo_off` | Algo Trading is off in this terminal, or trading isn't allowed on this account |
| `not_logged_in` | The terminal has no account connected yet |
| `netting_unsupported` | The account uses netting mode. Only hedging is supported for now. |
| `is_master` | `MasterId` is this account's own login |
| `stopped` | The EA was removed |

## Follower links: `state/links_<login>.csv`

```
master,follower,multiplier,state
123456789,987654321,0.5,1
```

`state` values:
- `0`: pending, waiting to (re)try the open
- `1`: open
- `2`: the copy was closed on the follower (e.g. its SL was hit) and won't be reopened
- `3`: skipped, either because the master trade already existed when the follower started or because it failed too often

`multiplier` is the one used when the copy was opened, so a later settings change never resizes an open copy.

## Follower settings: `config/follower_<login>.json`

Written by the dashboard through a temp file and a rename. The follower checks it about every 500 ms and applies changes without a restart.

```json
{"enabled":true,"multiplier":0.5,"max_lot":0,"round_up_min":true,"copy_sltp":true,
 "symbol_suffix":"m","symbol_prefix":"","strip_suffix":"","symbol_map":"XAUUSD=GOLD"}
```

- **Missing keys** keep the follower's current value. Until a file exists, the EA's inputs apply.
- **Invalid values** (multiplier outside 0.01–100, or max lot < 0) reject the whole file, and the follower keeps its last good settings.
- **The status file** carries the follower's live settings in the same shape, under `"settings"`.

## Global pause: `control.json`

```json
{"paused":true}
```

While paused, followers **don't open new copies**. A master trade opened during the pause is skipped for good rather than copied late. Closes, partial closes and SL/TP changes are **still mirrored**, so nothing is left unmanaged. A follower with `"enabled": false` behaves the same way.

## Activity log: `events/follower_<login>.jsonl`

```json
{"time":"2026.10.19 19:00:11","ms":3525671,"login":61619054,"kind":"copy","master":363671277,"msg":"OPEN SELL 0.1 EURUSD | noticed 0 ms after master, executed in 385.9 ms","latency_ms":385.9}
```

`kind` is one of:
- `copy`: open, close, partial close or SL/TP done
- `skip`: not copied, and why
- `error`
- `info`
- `config`: settings or pause changed
- `state`: follower state changed
- `start`

Past 2 MB the file is rotated to `.jsonl.1`.

## Risk, delays and templates (added later)

**Extra config keys** (all optional; `0` or `""` means off):
- **Risk:** `daily_loss_limit`, `equity_floor`, `close_on_limit`, `max_open_trades`, `max_total_lots`, `trade_start`/`trade_end` (`"HH:MM"`, PC time), `news_minutes` (high-impact MT5 calendar events).
- **Delays:** `delay_ms` + `delay_jitter_ms` (a random extra delay) before each copy. `delay_closes` applies the delay to closes too. It's off by default, so closes stay instant.

**Daily P&L** = deals closed since the broker's midnight + current floating P&L. It's calculated from history each time, so a restart can't forget today's losses.

**When a limit is hit:**
- No new copies are opened.
- With `close_on_limit`, every copy is closed and never reopened.
- A daily stop lasts until the broker's next day. An equity-floor stop lasts until equity recovers.

**Status** includes `"risk":{"daily_pnl","daily_loss_limit","equity_floor","breached","reason"}`, and the state is `risk_stop` while a limit is hit.

**Event kinds:**
- `open`, `close`, `partial`, `sltp`, `skip`, `error`, `risk`, `info`, `config`, `state`, `start`.
- `open` events also carry `symbol`, `side`, `lots`, `price` (the fill), `master_price`, `master_lots` and `point`, used for slippage.

**`templates.json`:** `{"<name>": <config>}`. Only the dashboard uses it, to store setting presets.
