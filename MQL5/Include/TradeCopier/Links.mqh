//+------------------------------------------------------------------+
//| Links.mqh - which master position each follower copy belongs to   |
//| Persisted as state\links_<login>.csv (docs/snapshot-format.md)    |
//+------------------------------------------------------------------+
#ifndef TRADECOPIER_LINKS_MQH
#define TRADECOPIER_LINKS_MQH

#include "Common.mqh"

enum ENUM_TC_LINK_STATE
  {
   TC_LINK_PENDING = 0,   // not opened yet, waiting to (re)try
   TC_LINK_OPEN    = 1,   // copy is open on this account
   TC_LINK_CLOSED  = 2,   // copy was closed here (SL/TP/manual) - never reopen
   TC_LINK_SKIPPED = 3    // never copy (pre-existing at start, or failed too often)
  };

struct TcLink
  {
   long              master;        // master position ticket
   long              follower;      // our position ticket, 0 until opened
   double            multiplier;    // multiplier used for this copy (fixed once opened)
   int               state;         // ENUM_TC_LINK_STATE
   //--- runtime only, not saved
   int               attempts;
   ulong             retryAtMs;
   ulong             openedMs;      // when we opened it; the position may take a moment to appear
   double            lastSl;        // last SL/TP we asked for, so a rejected modify isn't spammed
   double            lastTp;
  };

int TcLinkFind(const TcLink &links[], const long master)
  {
   for(int i = ArraySize(links) - 1; i >= 0; i--)
      if(links[i].master == master)
         return i;
   return -1;
  }

int TcLinkAdd(TcLink &links[], const long master, const double multiplier, const int state)
  {
   int n = ArraySize(links);
   ArrayResize(links, n + 1, 32);
   links[n].master     = master;
   links[n].follower   = 0;
   links[n].multiplier = multiplier;
   links[n].state      = state;
   links[n].attempts   = 0;
   links[n].retryAtMs  = 0;
   links[n].openedMs   = 0;
   links[n].lastSl     = -1;
   links[n].lastTp     = -1;
   return n;
  }

// Order is not preserved: the last link moves into the gap.
void TcLinkRemove(TcLink &links[], const int idx)
  {
   int last = ArraySize(links) - 1;
   if(idx != last)
      links[idx] = links[last];
   ArrayResize(links, last, 32);
  }

bool TcLinksSave(const TcLink &links[], const string path)
  {
   string s = "master,follower,multiplier,state\r\n";
   for(int i = 0; i < ArraySize(links); i++)
      s += IntegerToString(links[i].master) + ","
           + IntegerToString(links[i].follower) + ","
           + TcNum(links[i].multiplier, 4) + ","
           + IntegerToString(links[i].state) + "\r\n";
   return TcWriteAll(path, s);
  }

bool TcLinksLoad(TcLink &links[], const string path)
  {
   ArrayResize(links, 0, 32);
   string text;
   if(!TcReadAll(path, text))
      return false;
   string lines[];
   int n = StringSplit(text, '\n', lines);
   for(int i = 1; i < n; i++)                // line 0 is the header
     {
      string line = lines[i];
      StringReplace(line, "\r", "");
      string f[];
      if(StringSplit(line, ',', f) != 4)
         continue;
      int k = TcLinkAdd(links, StringToInteger(f[0]), StringToDouble(f[2]), (int)StringToInteger(f[3]));
      links[k].follower = StringToInteger(f[1]);
     }
   return true;
  }

#endif
