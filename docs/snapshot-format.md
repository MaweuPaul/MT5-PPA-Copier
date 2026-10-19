# Snapshot & file formats (v1)

Every TradeCopier component (MQL5 EAs now; MQL4, cTrader and the Go dashboard later) talks through plain files in the MetaTrader **Common Files** folder:

```
%APPDATA%\MetaQuotes\Terminal\Common\Files\TradeCopier\
├── master_<login>.json          # written by the master EA
├── status\follower_<login>.json # written by each follower EA, about once a second
└── state\links_<login>.csv      # follower's own record of which trades it has copied
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
