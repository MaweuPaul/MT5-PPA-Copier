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

// The comment after each input is the label MT5 shows in the Inputs tab.
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

#define TC_APPEAR_GRACE_MS 5000              // a just-opened position can take a moment to show up

CTrade       g_trade;
CTcSymbolMap g_symbols;
TcLink       g_links[];
TcSnapshot   g_snap;

long   g_login        = 0;
bool   g_ready        = false;
bool   g_seeded       = false;   // first fresh snapshot handled (pre-existing trades decided)
long   g_lastSeq      = 0;
ulong  g_detectMs     = 0;       // when we noticed the current snapshot
ulong  g_lastReconMs  = 0;
ulong  g_lastStatusMs = 0;
ulong  g_readFailSinceMs = 0;
string g_state        = "";
string g_masterFile   = "";
string g_linksFile    = "";
string g_statusFile   = "";

double g_latLast = 0, g_latSum = 0, g_latMax = 0;
long   g_latCount = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(MasterId == "")
     {
      Alert("TradeCopier: set MasterId to the master account's login number.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(LotMultiplier < 0.01 || LotMultiplier > 100)
     {
      Alert("TradeCopier: LotMultiplier must be between 0.01 and 100.");
      return INIT_PARAMETERS_INCORRECT;
     }

   // Globals survive some re-inits (e.g. account switch), so reset everything.
   g_login = 0;
   g_ready = false;
   g_seeded = false;
   g_lastSeq = 0;
   g_lastReconMs = 0;
   g_lastStatusMs = 0;
   g_readFailSinceMs = 0;
   g_state = "";
   g_latLast = 0;
   g_latSum = 0;
   g_latMax = 0;
   g_latCount = 0;
   ArrayResize(g_links, 0);

   TcEnsureFolders();
   g_masterFile = TcMasterFile(MasterId);
   g_trade.SetExpertMagicNumber((ulong)MagicNumber);
   g_trade.SetDeviationInPoints((ulong)MaxSlippagePoints);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   g_symbols.Init(SymbolMap, SymbolPrefix, SymbolSuffix, StripMasterSuffix);

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
void Step()
  {
   ulong now = TcNowMs();
   if(!EnsureAccount())
     {
      WriteStatusIfDue(now);
      return;
     }

   // A failed read is usually the master rewriting the file right now, so
   // only report "no_master" once reads have kept failing for a while.
   string text;
   if(!TcReadAll(g_masterFile, text) || text == "")
     {
      if(g_readFailSinceMs == 0)
         g_readFailSinceMs = now;
      else if(now - g_readFailSinceMs >= 2000)
         SetState("no_master");
      WriteStatusIfDue(now);
      return;
     }
   g_readFailSinceMs = 0;

   // Full parse only when the master wrote something new, plus a periodic
   // pass so retries and backoffs still run while the master is quiet.
   long seq = 0;
   bool changed = TcPeekSeq(text, seq) && seq != g_lastSeq;
   if((changed || now - g_lastReconMs >= 200) && TcParseSnapshot(text, g_snap))
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
         SetState("copying");
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
     {
      if(g_state != "is_master")
         Alert("TradeCopier: MasterId is this account's own login. Use CopierMaster here instead.");
      SetState("is_master");
      return false;
     }
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      if(g_state != "netting_unsupported")
         Alert("TradeCopier: this account uses netting mode; only hedging accounts are supported for now.");
      SetState("netting_unsupported");
      return false;
     }

   g_login = login;
   TcLinksLoad(g_links, g_linksFile);
   PrintFormat("TradeCopier: follower %I64d following master %s, x%s, %d saved link(s)",
               login, MasterId, TcNum(LotMultiplier, 4), ArraySize(g_links));
   g_ready = true;
   return true;
  }

bool TradingAllowed()
  {
   return TerminalInfoInteger(TERMINAL_CONNECTED) &&
          TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
          MQLInfoInteger(MQL_TRADE_ALLOWED) &&
          AccountInfoInteger(ACCOUNT_TRADE_ALLOWED);
  }

//+------------------------------------------------------------------+
//| Make our copies match the master snapshot                        |
//+------------------------------------------------------------------+
void Reconcile(const ulong now)
  {
   bool dirty = false;
   int  n = ArraySize(g_snap.positions);

   // First fresh snapshot after start: master trades we have no link for were
   // opened while we weren't running. Adopt them if we already hold a copy,
   // otherwise skip them (unless CopyExistingOnStart) - copying them late, at a
   // worse price, is usually not what you want.
   if(!g_seeded)
     {
      for(int i = 0; i < n; i++)
        {
         long mt = g_snap.positions[i].ticket;
         if(TcLinkFind(g_links, mt) >= 0)
            continue;
         long ft = FindCopyByComment(mt);
         if(ft > 0)
           {
            int k = TcLinkAdd(g_links, mt, LotMultiplier, TC_LINK_OPEN);
            g_links[k].follower = ft;
           }
         else if(!CopyExistingOnStart)
           {
            TcLinkAdd(g_links, mt, LotMultiplier, TC_LINK_SKIPPED);
            PrintFormat("TradeCopier: master #%I64d was already open at start - not copied (CopyExistingOnStart=false)", mt);
           }
         dirty = true;
        }
      g_seeded = true;
     }

   // 1. Every master position: open a copy, or keep the copy in sync.
   for(int i = 0; i < n; i++)
     {
      int k = TcLinkFind(g_links, g_snap.positions[i].ticket);
      if(k < 0)
        {
         k = TcLinkAdd(g_links, g_snap.positions[i].ticket, LotMultiplier, TC_LINK_PENDING);
         dirty = true;
        }
      if(g_links[k].state == TC_LINK_PENDING && now >= g_links[k].retryAtMs)
         dirty |= TryOpen(k, i, now);
      else if(g_links[k].state == TC_LINK_OPEN)
         dirty |= SyncOpen(k, i, now);
     }

   // 2. Links whose master position is gone: close our copy, then forget it.
   for(int k = ArraySize(g_links) - 1; k >= 0; k--)
     {
      if(SnapshotIndex(g_links[k].master) >= 0)
         continue;
      if(g_links[k].state == TC_LINK_OPEN)
        {
         if(now < g_links[k].retryAtMs || !CloseCopy(k, now))
            continue;                        // keep the link and retry later
        }
      TcLinkRemove(g_links, k);
      dirty = true;
     }

   if(dirty)
      TcLinksSave(g_links, g_linksFile);
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
      g_links[k].follower = existing;
      g_links[k].state    = TC_LINK_OPEN;
      g_links[k].openedMs = now;
      return true;
     }

   double lots = NormalizeLots(sym, g_snap.positions[i].volume * g_links[k].multiplier);
   if(lots <= 0)
      return Skip(k, "copy size is below the broker's minimum lot");

   bool  buy = g_snap.positions[i].type == POSITION_TYPE_BUY;
   ulong t0  = GetMicrosecondCount();
   MqlTick tick;
   g_trade.SetTypeFillingBySymbol(sym);
   // Open without SL/TP: a stop that's invalid on this broker would reject the
   // whole order. SL/TP are set right after by SyncOpen.
   bool sent = SymbolInfoTick(sym, tick) &&
               g_trade.PositionOpen(sym, buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, lots,
                                    buy ? tick.ask : tick.bid, 0, 0, TcCopyComment(mt));
   uint rc = sent ? g_trade.ResultRetcode() : 0;

   if(rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED)
     {
      g_links[k].follower = (long)g_trade.ResultOrder();   // hedging: position ticket = opening order ticket
      g_links[k].state    = TC_LINK_OPEN;
      g_links[k].openedMs = TcNowMs();
      g_links[k].attempts = 0;
      LogLatency(StringFormat("OPEN %s %s %s", buy ? "BUY" : "SELL", TcNum(lots, 8), sym), mt, t0);
      return true;
     }

   g_links[k].attempts++;
   PrintFormat("TradeCopier: open %s for master #%I64d failed (attempt %d/%d): %u %s",
               sym, mt, g_links[k].attempts, MaxOpenAttempts, rc,
               sent ? g_trade.ResultRetcodeDescription() : "no price / not sent");
   if(g_links[k].attempts >= MaxOpenAttempts)
     {
      Alert(StringFormat("TradeCopier: gave up copying master #%I64d (%s) after %d attempts", mt, sym, MaxOpenAttempts));
      return Skip(k, "too many failed attempts");
     }
   // A timeout may still have filled: wait long enough for it to show up before retrying.
   ulong wait = Backoff(g_links[k].attempts);
   if(rc == TRADE_RETCODE_TIMEOUT && wait < 3000)
      wait = 3000;
   g_links[k].retryAtMs = now + wait;
   return false;
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
      PrintFormat("TradeCopier: copy #%I64u of master #%I64d was closed on this account - it will not be reopened",
                  ft, g_links[k].master);
      return true;
     }
   if(now < g_links[k].retryAtMs)
      return false;

   string sym    = PositionGetString(POSITION_SYMBOL);
   double vol    = PositionGetDouble(POSITION_VOLUME);
   double curSl  = PositionGetDouble(POSITION_SL);
   double curTp  = PositionGetDouble(POSITION_TP);
   long   mt     = g_links[k].master;

   // Master partially closed: shrink our copy to the same ratio.
   double target = NormalizeLots(sym, g_snap.positions[i].volume * g_links[k].multiplier);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(target > 0 && step > 0 && vol - target >= step * 0.5)
     {
      double cut = NormalizeDouble(vol - target, StepDigits(step));
      ulong  t0  = GetMicrosecondCount();
      g_trade.SetTypeFillingBySymbol(sym);
      if(g_trade.PositionClosePartial(ft, cut) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
         LogLatency(StringFormat("PARTIAL CLOSE %s %s", TcNum(cut, 8), sym), mt, t0);
      else
        {
         PrintFormat("TradeCopier: partial close of #%I64u failed: %u %s",
                     ft, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
         g_links[k].retryAtMs = now + 1000;
         return false;
        }
     }

   if(CopySLTP)
     {
      int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double half   = SymbolInfoDouble(sym, SYMBOL_POINT) / 2;
      double sl     = NormalizeDouble(g_snap.positions[i].sl, digits);
      double tp     = NormalizeDouble(g_snap.positions[i].tp, digits);
      bool differs  = MathAbs(curSl - sl) > half || MathAbs(curTp - tp) > half;
      bool tried    = MathAbs(g_links[k].lastSl - sl) <= half && MathAbs(g_links[k].lastTp - tp) <= half;
      if(differs && !tried)
        {
         g_links[k].lastSl = sl;
         g_links[k].lastTp = tp;
         ulong t0 = GetMicrosecondCount();
         if(g_trade.PositionModify(ft, sl, tp) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
            LogLatency(StringFormat("SL/TP %s / %s", TcNum(sl, digits), TcNum(tp, digits)), mt, t0);
         else
           {
            uint rc = g_trade.ResultRetcode();
            PrintFormat("TradeCopier: SL/TP for #%I64u failed: %u %s", ft, rc, g_trade.ResultRetcodeDescription());
            if(rc != TRADE_RETCODE_INVALID_STOPS)
              {
               // Temporary problem: forget the attempt so it's retried shortly.
               g_links[k].lastSl = -1;
               g_links[k].lastTp = -1;
               g_links[k].retryAtMs = now + 2000;
              }
            // Invalid stops for this broker: don't retry until the master changes them.
           }
        }
     }
   return false;
  }

// Returns true once the copy is closed (or already gone).
bool CloseCopy(const int k, const ulong now)
  {
   ulong ft = (ulong)g_links[k].follower;
   if(!PositionSelectByTicket(ft))
      return now - g_links[k].openedMs >= TC_APPEAR_GRACE_MS;   // gone - unless it was opened a moment ago

   string sym = PositionGetString(POSITION_SYMBOL);
   ulong  t0  = GetMicrosecondCount();
   g_trade.SetTypeFillingBySymbol(sym);
   if(g_trade.PositionClose(ft) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
     {
      LogLatency("CLOSE " + sym, g_links[k].master, t0);
      return true;
     }

   g_links[k].attempts++;
   g_links[k].retryAtMs = now + Backoff(g_links[k].attempts);
   PrintFormat("TradeCopier: close of #%I64u failed (attempt %d): %u %s",
               ft, g_links[k].attempts, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
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
   PrintFormat("TradeCopier: not copying master #%I64d: %s", g_links[k].master, reason);
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

int StepDigits(const double step)
  {
   int d = 0;
   while(d < 8 && MathAbs(step * MathPow(10, d) - MathRound(step * MathPow(10, d))) > 1e-9)
      d++;
   return d;
  }

// Rounds down to the broker's lot step and applies min/max limits.
// Returns 0 if the copy should be skipped.
double NormalizeLots(const string sym, const double raw)
  {
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0 || raw <= 0)
      return 0;
   double cap = vmax;
   if(MaxLotPerTrade > 0 && MaxLotPerTrade < cap)
      cap = MaxLotPerTrade;

   double v = MathFloor(raw / step + 1e-7) * step;
   if(v > cap)
      v = MathFloor(cap / step + 1e-7) * step;
   if(v < vmin)
      v = (RoundUpToMinLot && vmin <= cap) ? vmin : 0;
   return NormalizeDouble(v, StepDigits(step));
  }

// "noticed" = master publish -> we saw it (shared Windows clock, ~16 ms resolution)
// "executed" = our order round trip to the broker (microsecond timer)
void LogLatency(const string what, const long masterTicket, const ulong t0)
  {
   double execMs   = (GetMicrosecondCount() - t0) / 1000.0;
   double noticeMs = (g_detectMs >= g_snap.pubMs) ? (double)(g_detectMs - g_snap.pubMs) : 0;
   double total    = noticeMs + execMs;
   g_latLast = total;
   g_latSum += total;
   g_latCount++;
   if(total > g_latMax)
      g_latMax = total;
   PrintFormat("TradeCopier: %s (master #%I64d) | noticed %.0f ms after master, executed in %.1f ms",
               what, masterTicket, noticeMs, execMs);
  }

void SetState(const string state)
  {
   if(state == g_state)
      return;
   PrintFormat("TradeCopier: state %s -> %s", g_state == "" ? "start" : g_state, state);
   if(state == "master_stale")
      Alert("TradeCopier: master ", MasterId, " stopped publishing - copies are kept open, nothing will be closed.");
   g_state = state;
  }

void WriteStatusIfDue(const ulong now)
  {
   if(now - g_lastStatusMs < 1000)
      return;
   g_lastStatusMs = now;

   int openCopies = 0;
   for(int k = 0; k < ArraySize(g_links); k++)
      if(g_links[k].state == TC_LINK_OPEN)
         openCopies++;
   double avg = g_latCount > 0 ? g_latSum / g_latCount : 0;

   Comment(StringFormat("TradeCopier FOLLOWER x%s | master %s | %s | %d open cop%s | latency last %.1f ms, avg %.1f ms",
                        TcNum(LotMultiplier, 4), MasterId, g_state, openCopies, openCopies == 1 ? "y" : "ies",
                        g_latLast, avg));
   if(g_statusFile == "")
      return;

   string j = "{\"login\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
              + ",\"server\":" + TcJsonStr(AccountInfoString(ACCOUNT_SERVER))
              + ",\"master_id\":" + TcJsonStr(MasterId)
              + ",\"state\":" + TcJsonStr(g_state)
              + ",\"balance\":" + TcNum(AccountInfoDouble(ACCOUNT_BALANCE), 2)
              + ",\"equity\":" + TcNum(AccountInfoDouble(ACCOUNT_EQUITY), 2)
              + ",\"multiplier\":" + TcNum(LotMultiplier, 4)
              + ",\"open_copies\":" + IntegerToString(openCopies)
              + ",\"last_seq\":" + IntegerToString(g_lastSeq)
              + ",\"latency_last_ms\":" + TcNum(g_latLast, 1)
              + ",\"latency_avg_ms\":" + TcNum(avg, 1)
              + ",\"latency_max_ms\":" + TcNum(g_latMax, 1)
              + ",\"updated_ms\":" + IntegerToString((long)now)
              + ",\"updated_local\":" + TcJsonStr(TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS))
              + "}";
   TcWriteAll(g_statusFile, j);
  }
