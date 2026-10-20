# Changelog

## 2.0.0 (2026-10-20)

Adds the dashboard, easy account setup, safety limits and a full redesign.

### Accounts and setup
- **Add accounts from the dashboard,** in three ways:
  - **open a new MT5 and log in there** (recommended; MT5's own broker search finds the server),
  - type the login into the form,
  - or **attach an MT5 you already have**, e.g. a prop firm's own install.
- **Launch all accounts, Start / Stop / Remove, Start with Windows.** Remove can also delete the account's MT5 folder.
- **Start MT5** button on offline account cards, and **Launch all** in the Overview banner when something needs attention.
- Logins are detected from MT5's journal, so new accounts register the moment they log in.
- New MT5s get the biggest broker server list on the PC, or one from an account on the same broker.
- `deploy.ps1` updates every added account, including normal (non-portable) installs.

### Copying
- **Separate open and close delays,** each a fixed time plus a random extra, set in seconds.
- **Close-all is fast:** closes are sent to the broker together, then confirmed.
- **Symbol aliases** (`GOLD` ↔ `XAUUSD`, indices, oil, crypto), **automatic suffix detection**, and **contract-size lot scaling**.
- **Free margin is checked before opening.** Unfixable rejections (no money, market closed) are skipped with the broker's reason instead of retried.
- The symbol is added to Market Watch while a delay runs, so the copy has a price ready.

### Safety limits (per account)
- Daily loss limit and equity floor, optionally closing all copies when hit.
- Max lot per trade, max open trades, max total lots.
- Trading hours and a pause around high-impact news.

### Dashboard
- **Pages:** Overview, Accounts, Copied trades (price difference against the main account), Activity (filters, search, CSV export), Templates.
- **Settings** applied live, with a lot-size preview. **Pause all copying.** Desktop and in-page alerts.
- **Redesign:** always-light, full-width layout with a plain-language health banner and account cards.
- **Security:** listens on 127.0.0.1 only, with CSRF and DNS-rebinding protection.
- **Playwright end-to-end tests** and a screenshot script (`npm run screenshots`, account numbers anonymized).

### Fixes
- An account could be wrongly treated as netting right after MT5 started.
- Brief master-file read failures showed as "no master".
- New MT5s couldn't log in to brokers missing from the copied server list.
- Normal MT5 installs were mistaken for portable ones, and vice versa.

## 1.0.0

First working version.
- `CopierMaster` and `CopierFollower` EAs for MT5.
- Copies opens, closes, partial closes and SL/TP across accounts on one PC.
- Lot multiplier and symbol suffix per follower.
- Links file and comment-based recovery, so restarts don't create duplicates.
- Tested on FxPro → Pepperstone + Exness demo accounts.
