//+------------------------------------------------------------------+
//| Snapshot.mqh - the master's position snapshot and its JSON form   |
//| Format spec: docs/snapshot-format.md                              |
//+------------------------------------------------------------------+
#ifndef TRADECOPIER_SNAPSHOT_MQH
#define TRADECOPIER_SNAPSHOT_MQH

#include "Common.mqh"

struct TcPosition
  {
   long              ticket;
   string            symbol;
   int               type;          // POSITION_TYPE_BUY or POSITION_TYPE_SELL
   double            volume;        // lots
   double            contract;      // master's contract size per lot (0 = unknown)
   double            price;
   double            sl;            // 0 = none
   double            tp;            // 0 = none
   long              magic;
   long              timeMsc;
  };

struct TcSnapshot
  {
   long              seq;
   string            masterId;
   string            server;
   ulong             pubMs;         // TcNowMs() when the snapshot was taken
   double            balance;
   double            equity;
   TcPosition        positions[];
  };

string TcSnapshotToJson(const TcSnapshot &s)
  {
   string seq = IntegerToString(s.seq);
   string j = "{\"seq\":" + seq
              + ",\"version\":" + IntegerToString(TC_FORMAT_VERSION)
              + ",\"master_id\":" + TcJsonStr(s.masterId)
              + ",\"server\":" + TcJsonStr(s.server)
              + ",\"pub_ms\":" + IntegerToString((long)s.pubMs)
              + ",\"balance\":" + TcNum(s.balance, 2)
              + ",\"equity\":" + TcNum(s.equity, 2)
              + ",\"positions\":[";
   int n = ArraySize(s.positions);
   for(int i = 0; i < n; i++)
     {
      if(i > 0)
         j += ",";
      j += "{\"ticket\":" + IntegerToString(s.positions[i].ticket)
           + ",\"symbol\":" + TcJsonStr(s.positions[i].symbol)
           + ",\"type\":" + (s.positions[i].type == POSITION_TYPE_BUY ? "\"buy\"" : "\"sell\"")
           + ",\"volume\":" + TcNum(s.positions[i].volume, 8)
           + ",\"contract\":" + TcNum(s.positions[i].contract, 8)
           + ",\"price\":" + TcNum(s.positions[i].price, 8)
           + ",\"sl\":" + TcNum(s.positions[i].sl, 8)
           + ",\"tp\":" + TcNum(s.positions[i].tp, 8)
           + ",\"magic\":" + IntegerToString(s.positions[i].magic)
           + ",\"time_msc\":" + IntegerToString(s.positions[i].timeMsc)
           + "}";
     }
   j += "],\"seq_end\":" + seq + "}";
   return j;
  }

// Cheap check used on every poll: read only the leading "seq".
bool TcPeekSeq(const string &text, long &seq)
  {
   return TcJsonLong(text, "seq", 0, MathMin(StringLen(text), 40), seq);
  }

// Returns false for a half-written or malformed file; the caller retries.
bool TcParseSnapshot(const string &text, TcSnapshot &s)
  {
   const string arrKey = "\"positions\":[";
   int len      = StringLen(text);
   int arrStart = StringFind(text, arrKey);
   if(arrStart < 0)
      return false;
   int endKey = StringFind(text, "\"seq_end\"", arrStart);
   if(endKey < 0)
      return false;

   long seqEnd = 0;
   if(!TcJsonLong(text, "seq", 0, arrStart, s.seq) ||
      !TcJsonLong(text, "seq_end", endKey, len, seqEnd) ||
      seqEnd != s.seq)
      return false;

   long pubMs = 0;
   s.masterId = "";
   s.server   = "";
   s.balance  = 0;
   s.equity   = 0;
   TcJsonString(text, "master_id", 0, arrStart, s.masterId);
   TcJsonString(text, "server", 0, arrStart, s.server);
   TcJsonLong(text, "pub_ms", 0, arrStart, pubMs);
   TcJsonDouble(text, "balance", 0, arrStart, s.balance);
   TcJsonDouble(text, "equity", 0, arrStart, s.equity);
   s.pubMs = (ulong)pubMs;

   ArrayResize(s.positions, 0, 32);
   int p = arrStart + StringLen(arrKey);
   while(true)
     {
      int ob = StringFind(text, "{", p);
      if(ob < 0 || ob > endKey)
         break;
      int cb = StringFind(text, "}", ob);
      if(cb < 0 || cb > endKey)
         return false;
      int to = cb + 1;                       // include '}' so the last value is terminated

      int n = ArraySize(s.positions);
      ArrayResize(s.positions, n + 1, 32);
      s.positions[n].contract = 0;
      s.positions[n].sl      = 0;
      s.positions[n].tp      = 0;
      s.positions[n].price   = 0;
      s.positions[n].magic   = 0;
      s.positions[n].timeMsc = 0;

      string side;
      if(!TcJsonLong(text, "ticket", ob, to, s.positions[n].ticket) ||
         !TcJsonString(text, "symbol", ob, to, s.positions[n].symbol) ||
         !TcJsonString(text, "type", ob, to, side) ||
         !TcJsonDouble(text, "volume", ob, to, s.positions[n].volume))
         return false;
      s.positions[n].type = (side == "buy") ? (int)POSITION_TYPE_BUY : (int)POSITION_TYPE_SELL;
      TcJsonDouble(text, "contract", ob, to, s.positions[n].contract);
      TcJsonDouble(text, "price", ob, to, s.positions[n].price);
      TcJsonDouble(text, "sl", ob, to, s.positions[n].sl);
      TcJsonDouble(text, "tp", ob, to, s.positions[n].tp);
      TcJsonLong(text, "magic", ob, to, s.positions[n].magic);
      TcJsonLong(text, "time_msc", ob, to, s.positions[n].timeMsc);
      p = to;
     }
   return true;
  }

#endif
