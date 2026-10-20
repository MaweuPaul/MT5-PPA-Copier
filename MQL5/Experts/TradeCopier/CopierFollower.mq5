//+------------------------------------------------------------------+
//| CopierFollower.mq5                                                |
//| Mirrors the master account's positions onto this account.         |
//| Attach to any one chart in each follower terminal.                |
//|                                                                    |
//| State sync: every poll compares the master's open positions with  |
//| our copies and fixes the difference (open / shrink / SL-TP /      |
//| close), so restarts and missed updates heal themselves.           |
//+------------------------------------------------------------------+
#property copyright   "TradeCopier"
#property version     "1.00"
#property description "TradeCopier follower: copies the master's positions with a lot multiplier."

#include <Trade\Trade.mqh>
#include <TradeCopier\Snapshot.mqh>
#include <TradeCopier\SymbolMap.mqh>
#include <TradeCopier\Links.mqh>
#include <TradeCopier\Lots.mqh>
#include <TradeCopier\Settings.mqh>
#include <TradeCopier\EventLog.mqh>
#include <TradeCopier\Latency.mqh>
#include <TradeCopier\Risk.mqh>

// The comment after each input is the label MT5 shows in the Inputs tab.
// Sizing, Symbols and Copy SL/TP are only defaults: once settings are saved
// from the dashboard (config\follower_<login>.json), that file wins and is
// re-read live, no restart needed.
input group "Master"
input string MasterId            = "";      // Master ID (master account login number)
input int    MasterStaleMs       = 5000;    // Master stale after (ms) - copies are kept, nothing closes

input group "Sizing"
input double LotMultiplier       = 1.0;     // Lot multiplier (follower lots = master lots x this)
input double MaxLotPerTrade      = 0;       // Max lot per trade (0 = broker maximum)
input bool   RoundUpToMinLot     = true;    // Round up to minimum lot (false = skip small copies)

input group "Symbols"
input string SymbolSuffix        = "";      // Symbol suffix (e.g. "m" for Exness: EURUSD -> EURUSDm)
input string SymbolPrefix        = "";      // Symbol prefix
input string StripMasterSuffix   = "";      // Remove from master symbol (e.g. ".r")
input string SymbolMap           = "";      // Symbol map (e.g. XAUUSD=GOLD;US30=DJ30)

input group "Execution"
input bool   CopySLTP            = true;    // Copy SL/TP
input int    MaxSlippagePoints   = 30;      // Max slippage (points)
input int    MaxOpenAttempts     = 5;       // Max open attempts
input bool   CopyExistingOnStart = false;   // Copy trades already open at start
input int    PollIntervalMs      = 1;       // Poll interval (ms)
input long   MagicNumber         = 20261019; // Magic number

#define TC_APPEAR_GRACE_MS   5000   // a just-opened position can take a moment to show up
#define TC_CLOSE_CONFIRM_MS  3000   // resend an async close not confirmed by then
#define TC_RECONCILE_MS      200    // periodic pass for retries while the master is quiet
#define TC_FILES_CHECK_MS    500    // how often to look for dashboard changes
#define TC_STATUS_MS         1000
#define TC_NO_MASTER_MS      2000   // read failures this long = master really missing

CTrade       g_trade;
CTcSymbolMap g_symbols;
CTcSettings  g_cfg;
CTcEventLog  g_log;
CTcLatency   g_latency;
CTcRisk      g_risk;
TcLink       g_links[];
TcSnapshot   g_snap;

long   g_login           = 0;
bool   g_ready           = false;
bool   g_seeded          = false;   // first fresh snapshot handled (pre-existing trades decided)
bool   g_paused          = false;   // global pause from the dashboard (control.json)
long   g_lastSeq         = 0;
ulong  g_detectMs        = 0;       // when we noticed the current snapshot
ulong  g_lastReconMs     = 0;
ulong  g_lastStatusMs    = 0;
ulong  g_lastFilesMs     = 0;
ulong  g_readFailSinceMs = 0;
int    g_closesInFlight  = 0;
string g_state           = "";
string g_masterFile      = "";
string g_linksFile       = "";
string g_statusFile      = "";
string g_configFile      = "";
string g_configText      = "";      // last file contents seen, to spot changes
string g_controlText     = "";

//+------------------------------------------------------------------+
//| Lifecycle                                                        |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(MasterId == "")
     {
      Alert("TradeCopier: set MasterId to the master account's login number.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!CTcSettings::ValidMultiplier(LotMultiplier))
     {
      Alert("TradeCopier: LotMultiplier must be between 0.01 and 100.");
      return INIT_PARAMETERS_INCORRECT;
     }

   // Globals survive some re-inits (e.g. account switch), so reset everything.
   g_login = 0;
   g_ready = g_seeded = g_paused = false;
   g_lastSeq = 0;
   g_lastReconMs = g_lastStatusMs = g_lastFilesMs = g_readFailSinceMs = 0;
   g_closesInFlight = 0;
   g_state = g_linksFile = g_statusFile = g_configFile = g_configText = g_controlText = "";
   ArrayResize(g_links, 0);
   g_latency.Reset();
   g_risk.Reset();
   g_log.Close();
   g_cfg.SetCopying(true, LotMultiplier, MaxLotPerTrade, RoundUpToMinLot, CopySLTP,
                    SymbolSuffix, SymbolPrefix, StripMasterSuffix, SymbolMap);
   MathSrand((uint)(GetMicrosecondCount() & 0x7FFFFFFF));   // random delays differ per terminal

   TcEnsureFolders();
   g_masterFile = TcMasterFile(MasterId);
   g_trade.SetExpertMagicNumber((ulong)MagicNumber);
   g_trade.SetDeviationInPoints((ulong)MaxSlippagePoints);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   RebuildSymbolMap();

   EventSetMillisecondTimer(1);          // first timer event starts the polling loop
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   SetState("stopped");
   g_lastStatusMs = 0;
   WriteStatusIfDue(TcNowMs());
   Comment("");
  }

// The timer only kicks things off: we then poll in a tight loop, because the
// Windows timer is too coarse (~16 ms) for low-latency copying.
void OnTimer()
  {
   EventKillTimer();
   while(!IsStopped())
     {
      Step();
      Sleep(PollIntervalMs);
     }
  }

//+------------------------------------------------------------------+
//| One poll                                                         |
//+------------------------------------------------------------------+
void Step()
  {
   ulong now = TcNowMs();
   if(!EnsureAccount())
     {
      WriteStatusIfDue(now);
      return;
     }
   if(now - g_lastFilesMs >= TC_FILES_CHECK_MS)
     {
      g_lastFilesMs = now;
      CheckDashboardFiles();
      UpdateRisk();
     }

   // A failed read is usually the master rewriting the file right now, so
   // only report "no_master" once reads have kept failing for a while.
   string text;
   if(!TcReadAll(g_masterFile, text) || text == "")
     {
      if(g_readFailSinceMs == 0)
         g_readFailSinceMs = now;
      else if(now - g_readFailSinceMs >= TC_NO_MASTER_MS)
         SetState("no_master");
      WriteStatusIfDue(now);
      return;
     }
   g_readFailSinceMs = 0;

   // Full parse only when the master wrote something new, plus a periodic
   // pass so retries still run while the master is quiet. While async closes
   // are in flight, reconcile every poll to confirm them fast.
   long  seq = 0;
   bool  changed = TcPeekSeq(text, seq) && seq != g_lastSeq;
   ulong every   = (g_closesInFlight > 0) ? 0 : TC_RECONCILE_MS;
   if((changed || now - g_lastReconMs >= every) && TcParseSnapshot(text, g_snap))
     {
      g_lastSeq     = g_snap.seq;
      g_lastReconMs = now;
      g_detectMs    = now;

      if(now > g_snap.pubMs && now - g_snap.pubMs > (ulong)MasterStaleMs)
         SetState("master_stale");
      else if(!TradingAllowed())
         SetState("algo_off");
      else
        {
         // Paused still mirrors closes and SL/TP so nothing is left unmanaged;
         // it only stops new copies from being opened.
         SetState(g_risk.breached ? "risk_stop" : CopyingNew() ? "copying" : "paused");
         Reconcile(now);
        }
     }
   WriteStatusIfDue(now);
  }

bool EnsureAccount()
  {
   if(g_login != 0)
      return g_ready;

   // Right after a terminal starts, the login can be known before the account
   // details (margin mode etc.) have arrived. Wait until it's connected, and
   // never latch a failed check - just re-check on the next poll.
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   if(login == 0 || !TerminalInfoInteger(TERMINAL_CONNECTED) || AccountInfoString(ACCOUNT_SERVER) == "")
     {
      SetState("not_logged_in");
      return false;
     }
   g_linksFile  = TcLinksFile(login);
   g_statusFile = TcStatusFile(login);

   if(IntegerToString(login) == MasterId)
      return Refuse("is_master", "MasterId is this account's own login. Use CopierMaster here instead.");
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      return Refuse("netting_unsupported", "this account uses netting mode; only hedging accounts are supported for now.");

   g_login      = login;
   g_configFile = TcConfigFile(login);
   g_log.Open(login);
   TcLinksLoad(g_links, g_linksFile);
   CheckDashboardFiles();
   g_log.Write("start", 0, StringFormat("following master %s at x%s, %d saved link(s)",
                                       MasterId, TcNum(g_cfg.multiplier, 4), ArraySize(g_links)));
   g_ready = true;
   return true;
  }

// Alerts once per state, then keeps returning false so it's re-checked.
bool Refuse(const string state, const string why)
  {
   if(g_state != state)
      Alert("TradeCopier: ", why);
   SetState(state);
   return false;
  }

bool TradingAllowed()
  {
   return TerminalInfoInteger(TERMINAL_CONNECTED) &&
          TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
          MQLInfoInteger(MQL_TRADE_ALLOWED) &&
          AccountInfoInteger(ACCOUNT_TRADE_ALLOWED);
  }

bool CopyingNew() { return g_cfg.enabled && !g_paused && !g_risk.breached; }

void UpdateRisk()
  {
   bool was = g_risk.breached;
   g_risk.Update(g_cfg);
   if(g_risk.breached && !was)
     {
      g_log.Write("risk", 0, "copying stopped: " + g_risk.reason +
                  (g_cfg.closeOnLimit ? " - closing all copies" : " - open copies are kept"));
      Alert("TradeCopier: ", g_risk.reason);
     }
   else if(!g_risk.breached && was)
      g_log.Write("risk", 0, "risk limit cleared - copying new trades again");
  }

// Why a new copy shouldn't be opened right now, or "" if it may.
string BlockReason(const string sym, const double lots)
  {
   if(!CTcRisk::InTradingHours(g_cfg))
      return StringFormat("outside trading hours %s-%s", g_cfg.tradeStart, g_cfg.tradeEnd);
   string news;
   if(CTcRisk::NewsNear(sym, g_cfg.newsMinutes, news))
      return StringFormat("high-impact news within %d min: %s", g_cfg.newsMinutes, news);
   if(g_cfg.maxOpenTrades > 0 && OpenCopies() >= g_cfg.maxOpenTrades)
      return StringFormat("max open trades (%d) reached", g_cfg.maxOpenTrades);
   if(g_cfg.maxTotalLots > 0 && OpenLots() + lots > g_cfg.maxTotalLots + 1e-9)
      return StringFormat("max total lots (%s) would be exceeded", TcNum(g_cfg.maxTotalLots, 2));
   return "";
  }

//+------------------------------------------------------------------+
//| Dashboard files: per-follower settings and the global pause      |
//+------------------------------------------------------------------+
void CheckDashboardFiles()
  {
   string text;
   if(TcReadAll(TcControlFile(), text) && text != g_controlText)
     {
      g_controlText = text;
      string raw;
      bool paused = TcJsonRaw(text, "paused", 0, StringLen(text), raw) && raw == "true";
      if(paused != g_paused)
        {
         g_paused = paused;
         g_log.Write("config", 0, paused ? "copying paused from dashboard" : "copying resumed from dashboard");
        }
     }

   if(g_configFile != "" && TcReadAll(g_configFile, text) && text != "" && text != g_configText)
     {
      g_configText = text;
      bool symbolsChanged = false;
      if(!g_cfg.Apply(text, symbolsChanged))
         g_log.Write("error", 0, "dashboard settings rejected: " + g_cfg.lastError);
      else
        {
         if(symbolsChanged)
            RebuildSymbolMap();
         g_log.Write("config", 0, "settings applied: " + g_cfg.Summary());
        }
     }
  }

void RebuildSymbolMap()
  {
   g_symbols.Init(g_cfg.map, g_cfg.prefix, g_cfg.suffix, g_cfg.strip);
  }

//+------------------------------------------------------------------+
//| Make our copies match the master snapshot                        |
//+------------------------------------------------------------------+
void Reconcile(const ulong now)
  {
   bool dirty = false;
   int  n = ArraySize(g_snap.positions);

   if(!g_seeded)
     {
      dirty |= SeedExisting();
      g_seeded = true;
     }

   // 1. Every master position: open a copy, or keep the copy in sync.
   for(int i = 0; i < n; i++)
     {
      int k = TcLinkFind(g_links, g_snap.positions[i].ticket);
      if(k < 0)
        {
         k = TcLinkAdd(g_links, g_snap.positions[i].ticket, g_cfg.multiplier, TC_LINK_PENDING);
         g_links[k].retryAtMs = now + g_cfg.NextOpenDelayMs();   // configured copy delay
         // Resolve now: this adds the symbol to Market Watch, so its prices are
         // already streaming when the delay ends (a cold symbol has no tick yet).
         g_symbols.Resolve(g_snap.positions[i].symbol);
         dirty = true;
        }
      if(g_links[k].state == TC_LINK_PENDING)
        {
         // Paused / risk stop: a trade opened now is skipped for good rather
         // than copied late, at a worse price, when copying resumes.
         if(!CopyingNew())
            dirty |= Skip(k, g_risk.breached ? g_risk.reason : "copying is paused");
         else if(now >= g_links[k].retryAtMs)
            dirty |= TryOpen(k, i, now);
        }
      else if(g_links[k].state == TC_LINK_OPEN)
         dirty |= SyncOpen(k, i, now);
     }

   // 2. Links whose master position is gone: close our copy, then forget it.
   //    Closes are sent async, so a close-all reaches the broker all at once.
   for(int k = ArraySize(g_links) - 1; k >= 0; k--)
     {
      if(SnapshotIndex(g_links[k].master) >= 0)
         continue;
      if(g_links[k].state == TC_LINK_OPEN)
        {
         if(g_links[k].closeDueMs == 0 && g_links[k].closeSentMs == 0)
            g_links[k].closeDueMs = now + g_cfg.NextCloseDelayMs();   // 0 = close straight away
         if(now < g_links[k].closeDueMs || now < g_links[k].retryAtMs || !CloseCopy(k, now))
            continue;                        // delayed, in flight, or retry later
        }
      TcLinkRemove(g_links, k);
      dirty = true;
     }

   // 3. Risk limit hit with "close on limit": close every copy; the master's
   //    trades stay open, so mark the links closed so they're never reopened.
   if(g_risk.breached && g_cfg.closeOnLimit)
      for(int k = 0; k < ArraySize(g_links); k++)
         if(g_links[k].state == TC_LINK_OPEN && now >= g_links[k].retryAtMs && CloseCopy(k, now))
           {
            g_links[k].state = TC_LINK_CLOSED;
            g_links[k].closeSentMs = 0;
            dirty = true;
           }

   g_closesInFlight = 0;
   for(int k = 0; k < ArraySize(g_links); k++)
      if(g_links[k].closeSentMs != 0)
         g_closesInFlight++;

   if(dirty)
      TcLinksSave(g_links, g_linksFile);
  }

// First fresh snapshot after start: master trades we have no link for were
// opened while we weren't running. Adopt them if we already hold a copy,
// otherwise skip them (unless CopyExistingOnStart) - copying them late, at a
// worse price, is usually not what you want.
bool SeedExisting()
  {
   bool dirty = false;
   for(int i = 0; i < ArraySize(g_snap.positions); i++)
     {
      long mt = g_snap.positions[i].ticket;
      if(TcLinkFind(g_links, mt) >= 0)
         continue;
      long ft = FindCopyByComment(mt);
      if(ft > 0)
        {
         int k = TcLinkAdd(g_links, mt, g_cfg.multiplier, TC_LINK_OPEN);
         g_links[k].follower = ft;
         dirty = true;
        }
      else if(!CopyExistingOnStart)
         dirty |= Skip(TcLinkAdd(g_links, mt, g_cfg.multiplier, TC_LINK_PENDING),
                       "already open when this follower started (CopyExistingOnStart=false)");
     }
   return dirty;
  }

// Returns true if the link changed in a way worth saving.
bool TryOpen(const int k, const int i, const ulong now)
  {
   long   mt  = g_snap.positions[i].ticket;
   string sym = g_symbols.Resolve(g_snap.positions[i].symbol);
   if(sym == "")
      return Skip(k, "no matching symbol on this broker");

   // An earlier attempt may have timed out yet still filled.
   long existing = FindCopyByComment(mt);
   if(existing > 0)
     {
      MarkOpen(k, existing, now);
      return true;
     }

   double ratio = TcContractRatio(g_snap.positions[i].contract, sym);
   if(ratio != 1.0)
      g_log.Write("info", mt, StringFormat("%s contract size differs from master's %s - lots scaled x%s",
                                           sym, g_snap.positions[i].symbol, TcNum(ratio, 6)));
   double lots = TargetLots(sym, i, k);
   if(lots <= 0)
      return Skip(k, "copy size is below the broker's minimum lot");
   string block = BlockReason(sym, lots);
   if(block != "")
      return Skip(k, block);

   bool  buy = g_snap.positions[i].type == POSITION_TYPE_BUY;
   ENUM_ORDER_TYPE type = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0)
      return RetryOpen(k, now, mt, sym, 0, "no price yet for " + sym);
   double price = buy ? tick.ask : tick.bid;

   // Not enough margin won't fix itself in seconds: say so and don't retry.
   double margin = 0, free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(OrderCalcMargin(type, sym, lots, price, margin) && margin > free)
      return Skip(k, StringFormat("not enough free margin: needs %s, %s available", TcNum(margin, 2), TcNum(free, 2)));

   ulong t0 = GetMicrosecondCount();
   g_trade.SetTypeFillingBySymbol(sym);
   // Open without SL/TP: a stop that's invalid on this broker would reject the
   // whole order. SL/TP are set right after by SyncOpen.
   g_trade.PositionOpen(sym, type, lots, price, 0, 0, TcCopyComment(mt));
   uint rc = g_trade.ResultRetcode();

   if(rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED)
     {
      MarkOpen(k, (long)g_trade.ResultOrder(), TcNowMs());   // hedging: position ticket = opening order ticket
      // Fill vs master open price -> slippage, shown on the dashboard's Trades page.
      string details = "\"symbol\":" + TcJsonStr(sym)
                       + ",\"side\":" + TcJsonStr(buy ? "buy" : "sell")
                       + ",\"lots\":" + TcNum(lots, 8)
                       + ",\"price\":" + TcNum(g_trade.ResultPrice(), 8)
                       + ",\"master_price\":" + TcNum(g_snap.positions[i].price, 8)
                       + ",\"master_lots\":" + TcNum(g_snap.positions[i].volume, 8)
                       + ",\"point\":" + TcNum(SymbolInfoDouble(sym, SYMBOL_POINT), 10);
      LogCopy("open", StringFormat("OPEN %s %s %s", buy ? "BUY" : "SELL", TcNum(lots, 8), sym), mt, t0, NoticeMs(), details);
      return true;
     }

   // Rejections that retrying can't fix.
   if(rc == TRADE_RETCODE_NO_MONEY || rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_TRADE_DISABLED ||
      rc == TRADE_RETCODE_INVALID_VOLUME || rc == TRADE_RETCODE_LIMIT_VOLUME || rc == TRADE_RETCODE_LIMIT_POSITIONS)
      return Skip(k, StringFormat("broker rejected %s: %s", sym, g_trade.ResultRetcodeDescription()));
   return RetryOpen(k, now, mt, sym, rc, rc ? g_trade.ResultRetcodeDescription() : "order not sent");
  }

// Logs a failed open and schedules a retry, or gives up after MaxOpenAttempts.
bool RetryOpen(const int k, const ulong now, const long mt, const string sym, const uint rc, const string why)
  {
   g_links[k].attempts++;
   g_log.Write("error", mt, StringFormat("open %s failed (attempt %d/%d): %s",
                                         sym, g_links[k].attempts, MaxOpenAttempts, why));
   if(g_links[k].attempts >= MaxOpenAttempts)
     {
      Alert(StringFormat("TradeCopier: gave up copying master #%I64d (%s) after %d attempts", mt, sym, MaxOpenAttempts));
      return Skip(k, "too many failed attempts");
     }
   // A timeout may still have filled: wait long enough for it to show up before retrying.
   ulong wait = Backoff(g_links[k].attempts);
   if(rc == TRADE_RETCODE_TIMEOUT && wait < TC_CLOSE_CONFIRM_MS)
      wait = TC_CLOSE_CONFIRM_MS;
   g_links[k].retryAtMs = now + wait;
   return false;
  }

void MarkOpen(const int k, const long followerTicket, const ulong now)
  {
   g_links[k].follower = followerTicket;
   g_links[k].state    = TC_LINK_OPEN;
   g_links[k].openedMs = now;
   g_links[k].attempts = 0;
  }

// Keeps an open copy in line with its master: partial closes and SL/TP.
bool SyncOpen(const int k, const int i, const ulong now)
  {
   ulong ft = (ulong)g_links[k].follower;
   if(!PositionSelectByTicket(ft))
     {
      if(now - g_links[k].openedMs < TC_APPEAR_GRACE_MS)
         return false;                       // just opened, not visible yet
      g_links[k].state = TC_LINK_CLOSED;
      g_log.Write("info", g_links[k].master,
                  StringFormat("copy #%I64u was closed on this account (SL/TP or manual) - it will not be reopened", ft));
      return true;
     }
   if(now < g_links[k].retryAtMs)
      return false;

   string sym   = PositionGetString(POSITION_SYMBOL);
   double vol   = PositionGetDouble(POSITION_VOLUME);
   double curSl = PositionGetDouble(POSITION_SL);
   double curTp = PositionGetDouble(POSITION_TP);

   if(!SyncVolume(k, i, now, ft, sym, vol))
      return false;
   if(g_cfg.copySLTP)
      SyncStops(k, i, now, ft, sym, curSl, curTp);
   return false;
  }

// Master partially closed: shrink our copy to the same ratio.
// Returns false if a retry is pending.
bool SyncVolume(const int k, const int i, const ulong now, const ulong ft, const string sym, const double vol)
  {
   double target = TargetLots(sym, i, k);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(target <= 0 || step <= 0 || vol - target < step * 0.5)
      return true;

   double cut = NormalizeDouble(vol - target, TcStepDigits(step));
   ulong  t0  = GetMicrosecondCount();
   g_trade.SetTypeFillingBySymbol(sym);
   if(g_trade.PositionClosePartial(ft, cut) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
     {
      LogCopy("partial", StringFormat("PARTIAL CLOSE %s %s", TcNum(cut, 8), sym), g_links[k].master, t0, NoticeMs());
      return true;
     }
   g_log.Write("error", g_links[k].master, StringFormat("partial close of #%I64u failed: %u %s",
               ft, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
   g_links[k].retryAtMs = now + 1000;
   return false;
  }

void SyncStops(const int k, const int i, const ulong now, const ulong ft, const string sym,
               const double curSl, const double curTp)
  {
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double half   = SymbolInfoDouble(sym, SYMBOL_POINT) / 2;
   double sl     = NormalizeDouble(g_snap.positions[i].sl, digits);
   double tp     = NormalizeDouble(g_snap.positions[i].tp, digits);
   bool differs  = MathAbs(curSl - sl) > half || MathAbs(curTp - tp) > half;
   bool tried    = MathAbs(g_links[k].lastSl - sl) <= half && MathAbs(g_links[k].lastTp - tp) <= half;
   if(!differs || tried)
      return;

   g_links[k].lastSl = sl;
   g_links[k].lastTp = tp;
   ulong t0 = GetMicrosecondCount();
   if(g_trade.PositionModify(ft, sl, tp) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
     {
      LogCopy("sltp", StringFormat("SL/TP %s / %s", TcNum(sl, digits), TcNum(tp, digits)), g_links[k].master, t0, NoticeMs());
      return;
     }
   uint rc = g_trade.ResultRetcode();
   g_log.Write("error", g_links[k].master, StringFormat("SL/TP for #%I64u failed: %u %s",
               ft, rc, g_trade.ResultRetcodeDescription()));
   // Invalid stops for this broker: don't retry until the master changes them.
   // Anything else is temporary: forget the attempt so it's retried shortly.
   if(rc != TRADE_RETCODE_INVALID_STOPS)
     {
      g_links[k].lastSl = -1;
      g_links[k].lastTp = -1;
      g_links[k].retryAtMs = now + 2000;
     }
  }

// Sends the close without waiting for the broker's reply (OrderSendAsync),
// so closing many copies doesn't queue them one round trip after another.
// Returns true once the copy is confirmed gone.
bool CloseCopy(const int k, const ulong now)
  {
   ulong ft = (ulong)g_links[k].follower;
   if(!PositionSelectByTicket(ft))
     {
      if(g_links[k].closeSentMs != 0)
        {
         LogCopy("close", StringFormat("CLOSE #%I64u", ft), g_links[k].master, g_links[k].closeSentUs, g_links[k].closeNoticeMs);
         return true;
        }
      return now - g_links[k].openedMs >= TC_APPEAR_GRACE_MS;   // gone - unless it was opened a moment ago
     }

   if(g_links[k].closeSentMs != 0)
     {
      if(now - g_links[k].closeSentMs < TC_CLOSE_CONFIRM_MS)
         return false;                       // close in flight, wait for it
      g_log.Write("error", g_links[k].master, StringFormat("close of #%I64u not confirmed after %d ms - sending again",
                  ft, TC_CLOSE_CONFIRM_MS));
     }

   string sym = PositionGetString(POSITION_SYMBOL);
   ulong  t0  = GetMicrosecondCount();
   g_trade.SetTypeFillingBySymbol(sym);
   g_trade.SetAsyncMode(true);
   bool sent = g_trade.PositionClose(ft);
   g_trade.SetAsyncMode(false);
   uint rc = g_trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE))
     {
      g_links[k].closeSentMs   = now;
      g_links[k].closeSentUs   = t0;
      g_links[k].closeNoticeMs = NoticeMs();
      return false;                          // confirmed on a later poll
     }

   g_links[k].closeSentMs = 0;
   g_links[k].attempts++;
   g_links[k].retryAtMs = now + Backoff(g_links[k].attempts);
   g_log.Write("error", g_links[k].master, StringFormat("close of #%I64u failed (attempt %d): %u %s",
               ft, g_links[k].attempts, rc, g_trade.ResultRetcodeDescription()));
   if(g_links[k].attempts == MaxOpenAttempts)
      Alert(StringFormat("TradeCopier: cannot close copy #%I64u on %s - check it manually", ft, sym));
   return false;
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool Skip(const int k, const string reason)
  {
   g_links[k].state = TC_LINK_SKIPPED;
   g_log.Write("skip", g_links[k].master, reason);
   return true;
  }

int SnapshotIndex(const long masterTicket)
  {
   for(int i = ArraySize(g_snap.positions) - 1; i >= 0; i--)
      if(g_snap.positions[i].ticket == masterTicket)
         return i;
   return -1;
  }

long FindCopyByComment(const long masterTicket)
  {
   string want = TcCopyComment(masterTicket);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t != 0 && PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_COMMENT) == want)
         return (long)t;
     }
   return 0;
  }

ulong Backoff(const int attempts)
  {
   if(attempts <= 1) return 250;
   if(attempts == 2) return 1000;
   if(attempts == 3) return 3000;
   return 10000;
  }

// This copy's lots: master lots x the link's multiplier x contract-size ratio.
double TargetLots(const string sym, const int i, const int k)
  {
   double raw = g_snap.positions[i].volume * g_links[k].multiplier
                * TcContractRatio(g_snap.positions[i].contract, sym);
   return TcNormalizeLots(sym, raw, g_cfg.maxLot, g_cfg.roundUpMin);
  }

// Master publish -> we noticed it (shared Windows clock, ~16 ms resolution).
double NoticeMs()
  {
   return (g_detectMs >= g_snap.pubMs) ? (double)(g_detectMs - g_snap.pubMs) : 0;
  }

// Records a completed copy action. t0 = microsecond timer when we sent it.
// kind: open | close | partial | sltp. details: optional extra JSON fields.
void LogCopy(const string kind, const string what, const long masterTicket, const ulong t0,
             const double noticeMs, const string details = "")
  {
   double execMs = (GetMicrosecondCount() - t0) / 1000.0;
   g_latency.Add(noticeMs + execMs);
   g_log.Write(kind, masterTicket, StringFormat("%s | noticed %.0f ms after master, executed in %.1f ms",
                                                what, noticeMs, execMs), noticeMs + execMs, details);
  }

void SetState(const string state)
  {
   if(state == g_state)
      return;
   g_log.Write("state", 0, StringFormat("%s -> %s", g_state == "" ? "start" : g_state, state));
   if(state == "master_stale")
      Alert("TradeCopier: master ", MasterId, " stopped publishing - copies are kept open, nothing will be closed.");
   g_state = state;
  }

int OpenCopies()
  {
   int n = 0;
   for(int k = 0; k < ArraySize(g_links); k++)
      if(g_links[k].state == TC_LINK_OPEN)
         n++;
   return n;
  }

double OpenLots()
  {
   double total = 0;
   for(int k = 0; k < ArraySize(g_links); k++)
      if(g_links[k].state == TC_LINK_OPEN && PositionSelectByTicket((ulong)g_links[k].follower))
         total += PositionGetDouble(POSITION_VOLUME);
   return total;
  }

void WriteStatusIfDue(const ulong now)
  {
   if(now - g_lastStatusMs < TC_STATUS_MS)
      return;
   g_lastStatusMs = now;

   int openCopies = OpenCopies();
   Comment(StringFormat("TradeCopier FOLLOWER x%s | master %s | %s | %d open cop%s | latency last %.1f ms, avg %.1f ms",
                        TcNum(g_cfg.multiplier, 4), MasterId, g_state, openCopies, openCopies == 1 ? "y" : "ies",
                        g_latency.Last(), g_latency.Avg()));
   if(g_statusFile == "")
      return;

   TcWriteAll(g_statusFile,
              "{\"login\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
              + ",\"server\":" + TcJsonStr(AccountInfoString(ACCOUNT_SERVER))
              + ",\"master_id\":" + TcJsonStr(MasterId)
              + ",\"state\":" + TcJsonStr(g_state)
              + ",\"balance\":" + TcNum(AccountInfoDouble(ACCOUNT_BALANCE), 2)
              + ",\"equity\":" + TcNum(AccountInfoDouble(ACCOUNT_EQUITY), 2)
              + ",\"multiplier\":" + TcNum(g_cfg.multiplier, 4)
              + ",\"paused\":" + (g_paused ? "true" : "false")
              + ",\"open_copies\":" + IntegerToString(openCopies)
              + ",\"last_seq\":" + IntegerToString(g_lastSeq)
              + "," + g_latency.ToJsonFields()
              + ",\"updated_ms\":" + IntegerToString((long)now)
              + ",\"updated_local\":" + TcJsonStr(TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS))
              + ",\"settings\":" + g_cfg.ToJson()
              + ",\"risk\":" + g_risk.ToJson(g_cfg)
              + "}");
  }
