# Setup

## What you need

- **Windows** 10/11, or a Windows VPS. MT5 only runs properly on Windows.
- **MetaTrader 5 installed once**, from any broker. New accounts are copied from this install.
- **Go 1.22+** to build the dashboard. A **64-bit** Go install is best. With 32-bit Go, set `$env:GOARCH = "amd64"` before building, as shown below.
- Accounts in **hedging** mode. Netting accounts aren't supported yet.
- **Demo accounts first.** Test everything before using live or funded accounts.

## Quick setup (recommended)

### 1. Build and start the dashboard

```powershell
cd dashboard
$env:GOARCH = "amd64"; go build -o tradecopier-dashboard.exe .
.\tradecopier-dashboard.exe
```

It opens **http://127.0.0.1:8750**, which only works on this PC.

| Option | Default | Meaning |
|---|---|---|
| `-open=false` | open | Don't open the browser |
| `-launch=false` | launch | Don't start the accounts' MT5s when the dashboard starts |
| `-addr` | `127.0.0.1:8750` | Listen address. Must be loopback. |
| `-mql5` | auto-detected | The repo's `MQL5` folder, used to compile the EAs |

### 2. One-time setup

Go to **Accounts → Setup**:
- **MT5 installed in:** e.g. `C:\Program Files\MetaTrader 5`.
- **Keep account folders in:** e.g. `D:\MT5`. One folder per account is created here. Keep it **outside** the repo, since these folders are large and contain saved logins.
- **Start with Windows:** after a reboot, opens the dashboard and every account's MT5.

### 3. Add accounts

Click **+ Add account**. Add your **main** account first, then each account to copy to.

**Which MT5?** There are three ways:

| Option | How it works | Use when |
|---|---|---|
| **Open a new MT5 and I'll log in there** (recommended) | A fresh MT5 opens with the copier installed. You log in inside it: **File → Open an Account** → search your broker → **Connect with an existing trade account** → tick **Save password**. The dashboard spots the login (it waits up to 10 minutes) and finishes setting up. | Most accounts. MT5's own broker search always finds the right server. |
| Set up a new MT5 with the login I type here | You enter the login, password and server in the form. | The broker's server is already known on this PC, e.g. you already have another account there. |
| An MT5 I already have | You give the folder of an MT5 that's already logged in, e.g. your prop firm's own MT5. The dashboard detects the account, closes that MT5 for a moment, adds the copier on a **new chart** (yours aren't touched) and starts it again. | You already use that MT5. |

**Copying fields** (copy accounts only):

| Field | Example |
|---|---|
| Main account number | Filled in for you |
| Lot size | `1` = same as main, `0.5` = half (account size ÷ main account size) |
| Symbol ending | Optional, e.g. `m` for Exness. Usually detected automatically. |
| Open delay + random up to | e.g. `1` + `2` s, so copies land 1–3 s after yours |
| Close delay + random up to | `0` = instant (recommended) |

**Good to know:**
- **Server names must match exactly what MT5 shows** (e.g. Maven's is `MavenTrade-Server`). If unsure, use the first option.
- **The password** (second option only) goes into a one-time start-up file that's deleted within 20 seconds. After that, MT5 keeps the login itself. The dashboard never stores it.
- **Each new MT5** gets the copier attached to its saved chart, so it comes back after every restart. It also gets the biggest broker server list on this PC (or one from an account on the same broker).
- **On its first start,** MT5 may download an update and restart by itself. That's normal.

### 4. Test

Open a small trade (e.g. 0.01 lot) on the main account. Each account should copy it within about a second, and you'll see it on **Overview** and **Copied trades**. Then try a stop-loss change, a partial close and a full close.

## Everyday use

- **Accounts page:**
  - **Launch all accounts** starts every MT5 that isn't running, main account first.
  - Each account has **Start / Stop / Remove**. Stop closes MT5 cleanly, like clicking ✕.
  - **Remove** closes that MT5, unregisters it and, if you choose, **deletes its folder**. Only folders inside your accounts folder are deleted. Trades already open on that account are **not** closed.
- **Settings** on each account card:
  - lot size, symbol mapping
  - safety limits: daily loss, equity floor, max trades/lots, trading hours, news pause
  - open and close delays (fixed + random extra, in seconds)
  - "Copy new trades to this account": untick to hold an account without removing it
  
  Changes apply within about a second. A new lot size only affects **new** trades; open copies keep their size.
- **Pause all copying:** new trades aren't copied. Closes and stop changes still are, so nothing is left unmanaged.
- **Alerts:** click **Enable desktop alerts**. In-page alerts appear either way.
- **Closing the dashboard doesn't stop copying.** It only manages the copier.

## After changing the EA code

```powershell
powershell -ExecutionPolicy Bypass -Command "& .\scripts\deploy.ps1"
```

This compiles the EAs into **every account added in the dashboard** and refreshes the build that **Add account** installs from. Each line should say `OK`.

Then **restart the follower MT5s**: Stop → Start on the Accounts page. A follower runs a continuous loop, so MT5 doesn't swap in the new build by itself. The master EA reloads automatically.

To deploy to specific folders: `-Terminals Master,Follower1` (names under `-Mt5Root`, default `D:\MT5`) or full paths.

## Manual setup (without the dashboard)

1. Copy an MT5 install into one folder per account and start each with `terminal64.exe /portable`.
2. In each MT5:
   - **File → Login to Trade Account** with **Save password** ticked.
   - **Tools → Options → Expert Advisors → Allow algorithmic trading**.
   - Make sure the **Algo Trading** button is green.
3. Run `scripts\deploy.ps1 -Terminals <folders>`.
4. In the main account's MT5, drag **TradeCopier → CopierMaster** onto any chart.
5. In each follower's MT5, drag **TradeCopier → CopierFollower** onto any chart and set **Master ID** to the main account's login. Set **Lot multiplier** and **Symbol suffix** too, or set them later in the dashboard.

Use one chart per MT5 for the EA. Settings saved in the dashboard override the EA's inputs. To go back to the inputs, delete `config\follower_<login>.json`.

## How the copier behaves

- **Trades already open when a follower starts aren't copied** (set `CopyExistingOnStart` to change this), because copying them late would be at a worse price.
- **Trades opened while paused,** blocked by a safety limit, outside trading hours or near news **are skipped for good**, not copied late.
- **If a copy is closed on the follower** (its own SL, or by hand), it isn't reopened.
- **If the main account goes offline,** followers keep their copies open and close nothing.
- **Not enough margin, market closed or trading disabled:** the trade is skipped straight away with the broker's reason, shown in Activity.
- **A daily loss limit** counts closed trades since the broker's midnight plus open P&L. A restart can't reset it. It clears at the broker's next day, or when you change the limit.
- **Files** live in `%APPDATA%\MetaQuotes\Terminal\Common\Files\TradeCopier\`. See [snapshot-format.md](snapshot-format.md).

## Tests

End-to-end tests drive the dashboard in a real browser against your running accounts:

```powershell
cd dashboard\e2e
npm install; npx playwright install chromium   # first time only
npm test
```

**Don't place trades while the tests run.** They pause copying for a moment and change settings, and restore everything afterwards. A trade opened during the pause would be skipped.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| Account card says **Algo Trading is off** | Turn on the **Algo Trading** button in that MT5 |
| **Can't find main account** / **Main account offline** | The main account's MT5 is closed or CopierMaster isn't attached. Click **Launch all**. |
| A new account never logs in | MT5 doesn't know that broker's server, or the password or server is wrong. **Remove** it (with its folder), then add it again with **Open a new MT5 and I'll log in there**, searching your broker inside MT5. |
| Trades skipped: **no matching symbol** | Set the symbol ending (e.g. `m`) or a symbol map (`GOLD=XAUUSD`) in Settings |
| Trades skipped: **not enough free margin** | The account is fully used. Close trades, lower its lot size, or top it up. |
| Accounts show as stopped but MT5 is open | It's a different MT5 install than the one registered. Check the folder on the Accounts page. |
| Everything closed after a reboot | Tick **Start with Windows**, or click **Launch all accounts** |
