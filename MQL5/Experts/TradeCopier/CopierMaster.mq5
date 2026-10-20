//+------------------------------------------------------------------+
//| CopierMaster.mq5                                                  |
//| Publishes this account's open positions for TradeCopier followers.|
//| Attach to any one chart in the master terminal.                   |
//+------------------------------------------------------------------+
#property copyright   "MT5 PPA Copier"
#property version     "1.00"
#property description "PPA Copier master: publishes open positions to followers on this PC."

#include <TradeCopier\Snapshot.mqh>

input int HeartbeatMs = 1000;   // Republish at least this often (ms) so followers know the master is alive

TcSnapshot g_snap;
long       g_seq       = 0;
bool       g_dirty     = true;   // a publish failed or is owed - retry on the next timer
ulong      g_lastPubMs = 0;

int OnInit()
  {
   TcEnsureFolders();
   g_seq       = (long)TimeLocal() * 1000;   // keeps increasing across restarts
   g_dirty     = true;
   g_lastPubMs = 0;
   EventSetMillisecondTimer(20);
   Publish();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

// Fires the moment anything happens on the account: publish immediately.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD ||   // open, close, partial close
      trans.type == TRADE_TRANSACTION_POSITION)     // SL/TP changed
      Publish();
  }

// Backup only: heartbeat, and retry if a write failed.
void OnTimer()
  {
   if(g_dirty || TcNowMs() - g_lastPubMs >= (ulong)HeartbeatMs)
      Publish();
  }

void Publish()
  {
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   if(login == 0)                       // terminal not connected to an account yet
     {
      g_dirty = true;
      return;
     }

   g_snap.pubMs    = TcNowMs();
   g_snap.seq      = ++g_seq;
   g_snap.masterId = IntegerToString(login);
   g_snap.server   = AccountInfoString(ACCOUNT_SERVER);
   g_snap.balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   g_snap.equity   = AccountInfoDouble(ACCOUNT_EQUITY);

   ArrayResize(g_snap.positions, 0, 32);
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      int n = ArraySize(g_snap.positions);
      ArrayResize(g_snap.positions, n + 1, 32);
      g_snap.positions[n].ticket  = (long)ticket;
      g_snap.positions[n].symbol  = PositionGetString(POSITION_SYMBOL);
      g_snap.positions[n].type    = (int)PositionGetInteger(POSITION_TYPE);
      g_snap.positions[n].volume  = PositionGetDouble(POSITION_VOLUME);
      g_snap.positions[n].contract = SymbolInfoDouble(g_snap.positions[n].symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      g_snap.positions[n].price   = PositionGetDouble(POSITION_PRICE_OPEN);
      g_snap.positions[n].sl      = PositionGetDouble(POSITION_SL);
      g_snap.positions[n].tp      = PositionGetDouble(POSITION_TP);
      g_snap.positions[n].magic   = PositionGetInteger(POSITION_MAGIC);
      g_snap.positions[n].timeMsc = PositionGetInteger(POSITION_TIME_MSC);
     }

   g_dirty = !TcWriteAll(TcMasterFile(g_snap.masterId), TcSnapshotToJson(g_snap));
   if(!g_dirty)
     {
      g_lastPubMs = g_snap.pubMs;
      Comment(StringFormat("PPA Copier MASTER %s | %d position(s) | published %s",
                           g_snap.masterId, ArraySize(g_snap.positions), TimeToString(TimeLocal(), TIME_SECONDS)));
     }
  }
