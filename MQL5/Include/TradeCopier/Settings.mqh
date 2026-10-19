//+------------------------------------------------------------------+
//| Settings.mqh - a follower's live settings                         |
//| Start from the EA inputs, then follow config\follower_<login>.json|
//| written by the dashboard (same keys as dashboard store.Config).   |
//+------------------------------------------------------------------+
#ifndef TRADECOPIER_SETTINGS_MQH
#define TRADECOPIER_SETTINGS_MQH

#include "Common.mqh"

#define TC_MIN_MULTIPLIER 0.01
#define TC_MAX_MULTIPLIER 100.0

class CTcSettings
  {
private:
   static bool       Bool(const string &text, const string key, bool &out)
     {
      string raw;
      if(!TcJsonRaw(text, key, 0, StringLen(text), raw))
         return false;
      out = (raw == "true");
      return true;
     }
   static double     Num(const string &text, const string key, const double def)
     {
      double v = def;
      TcJsonDouble(text, key, 0, StringLen(text), v);
      return v;
     }
   static string     Str(const string &text, const string key, const string def)
     {
      string v = def;
      TcJsonString(text, key, 0, StringLen(text), v);
      return v;
     }

public:
   //--- copying
   bool              enabled, roundUpMin, copySLTP;
   double            multiplier, maxLot;
   string            suffix, prefix, strip, map;
   //--- risk (0 / "" = off; dashboard-only)
   double            dailyLossLimit;   // stop when today's loss reaches this (account currency)
   double            equityFloor;      // stop when equity falls to this
   bool              closeOnLimit;     // also close our copies when a limit is hit
   int               maxOpenTrades;
   double            maxTotalLots;
   string            tradeStart, tradeEnd;   // "HH:MM" local PC time; both empty = always
   int               newsMinutes;      // skip new copies +/- this many minutes around high-impact news
   //--- delays before copying (0 = instant)
   int               delayMs;          // fixed
   int               delayJitterMs;    // plus random 0..this
   bool              delayCloses;      // also delay closes (off: closes stay instant)
   string            lastError;

   static bool       ValidMultiplier(const double m) { return m >= TC_MIN_MULTIPLIER && m <= TC_MAX_MULTIPLIER; }

   // "HH:MM" -> minutes after midnight, -1 if empty or invalid.
   static int        Minutes(const string hhmm)
     {
      string p[];
      if(StringSplit(hhmm, ':', p) != 2)
         return -1;
      int h = (int)StringToInteger(p[0]), m = (int)StringToInteger(p[1]);
      return (h >= 0 && h < 24 && m >= 0 && m < 60) ? h * 60 + m : -1;
     }

   void              SetCopying(const bool en, const double mult, const double maxL, const bool roundUp, const bool sltp,
                                const string sfx, const string pfx, const string strp, const string mp)
     {
      enabled = en; multiplier = mult; maxLot = maxL; roundUpMin = roundUp; copySLTP = sltp;
      suffix = sfx; prefix = pfx; strip = strp; map = mp;
      dailyLossLimit = 0; equityFloor = 0; closeOnLimit = false; maxOpenTrades = 0;
      maxTotalLots = 0; tradeStart = ""; tradeEnd = ""; newsMinutes = 0;
      delayMs = 0; delayJitterMs = 0; delayCloses = false;
     }

   // Applies a config file. Missing keys keep their current value. An invalid
   // file is rejected as a whole (lastError says why) and nothing changes.
   bool              Apply(const string &text, bool &symbolsChanged)
     {
      CTcSettings n;
      n.Assign(this);                            // start from current values
      Bool(text, "enabled", n.enabled);
      Bool(text, "delay_closes", n.delayCloses);
      n.delayMs        = (int)Num(text, "delay_ms", delayMs);
      n.delayJitterMs  = (int)Num(text, "delay_jitter_ms", delayJitterMs);
      Bool(text, "round_up_min", n.roundUpMin);
      Bool(text, "copy_sltp", n.copySLTP);
      Bool(text, "close_on_limit", n.closeOnLimit);
      n.multiplier     = Num(text, "multiplier", multiplier);
      n.maxLot         = Num(text, "max_lot", maxLot);
      n.dailyLossLimit = Num(text, "daily_loss_limit", dailyLossLimit);
      n.equityFloor    = Num(text, "equity_floor", equityFloor);
      n.maxOpenTrades  = (int)Num(text, "max_open_trades", maxOpenTrades);
      n.maxTotalLots   = Num(text, "max_total_lots", maxTotalLots);
      n.newsMinutes    = (int)Num(text, "news_minutes", newsMinutes);
      n.suffix         = Str(text, "symbol_suffix", suffix);
      n.prefix         = Str(text, "symbol_prefix", prefix);
      n.strip          = Str(text, "strip_suffix", strip);
      n.map            = Str(text, "symbol_map", map);
      n.tradeStart     = Str(text, "trade_start", tradeStart);
      n.tradeEnd       = Str(text, "trade_end", tradeEnd);

      lastError = "";
      if(!ValidMultiplier(n.multiplier))
         lastError = "multiplier must be 0.01-100";
      else if(n.maxLot < 0 || n.dailyLossLimit < 0 || n.equityFloor < 0 || n.maxOpenTrades < 0 || n.maxTotalLots < 0)
         lastError = "limits can't be negative";
      else if(n.delayMs < 0 || n.delayMs > 60000 || n.delayJitterMs < 0 || n.delayJitterMs > 30000)
         lastError = "delay must be 0-60000 ms and random extra 0-30000 ms";
      else if(n.newsMinutes < 0 || n.newsMinutes > 240)
         lastError = "news window must be 0-240 minutes";
      else if((n.tradeStart == "") != (n.tradeEnd == "") ||
              (n.tradeStart != "" && (Minutes(n.tradeStart) < 0 || Minutes(n.tradeEnd) < 0)))
         lastError = "trading hours must both be HH:MM, or both empty";
      if(lastError != "")
         return false;

      symbolsChanged = n.suffix != suffix || n.prefix != prefix || n.strip != strip || n.map != map;
      Assign(n);
      return true;
     }

   // Field-by-field copy: MQL5 has no usable assignment for objects ("this" is a
   // pointer). Add new settings here, in SetCopying, Apply and ToJson.
   void              Assign(const CTcSettings &o)
     {
      enabled = o.enabled; roundUpMin = o.roundUpMin; copySLTP = o.copySLTP;
      multiplier = o.multiplier; maxLot = o.maxLot;
      suffix = o.suffix; prefix = o.prefix; strip = o.strip; map = o.map;
      dailyLossLimit = o.dailyLossLimit; equityFloor = o.equityFloor; closeOnLimit = o.closeOnLimit;
      maxOpenTrades = o.maxOpenTrades; maxTotalLots = o.maxTotalLots;
      tradeStart = o.tradeStart; tradeEnd = o.tradeEnd; newsMinutes = o.newsMinutes;
      delayMs = o.delayMs; delayJitterMs = o.delayJitterMs; delayCloses = o.delayCloses;
     }

   // Fixed delay + random 0..jitter, so accounts don't act in perfect sync.
   ulong             NextDelayMs()
     {
      return (ulong)delayMs + (delayJitterMs > 0 ? (ulong)(MathRand() % (delayJitterMs + 1)) : 0);
     }

   string            Summary()
     {
      return StringFormat("%s, x%s, suffix '%s', max lot %s, daily loss %s, floor %s",
                          enabled ? "enabled" : "disabled", TcNum(multiplier, 4), suffix,
                          TcNum(maxLot, 2), TcNum(dailyLossLimit, 2), TcNum(equityFloor, 2));
     }

   // Same shape as the config file, embedded in the status file.
   string            ToJson()
     {
      return "{\"enabled\":" + TcBool(enabled)
             + ",\"multiplier\":" + TcNum(multiplier, 4)
             + ",\"max_lot\":" + TcNum(maxLot, 4)
             + ",\"round_up_min\":" + TcBool(roundUpMin)
             + ",\"copy_sltp\":" + TcBool(copySLTP)
             + ",\"symbol_suffix\":" + TcJsonStr(suffix)
             + ",\"symbol_prefix\":" + TcJsonStr(prefix)
             + ",\"strip_suffix\":" + TcJsonStr(strip)
             + ",\"symbol_map\":" + TcJsonStr(map)
             + ",\"daily_loss_limit\":" + TcNum(dailyLossLimit, 2)
             + ",\"equity_floor\":" + TcNum(equityFloor, 2)
             + ",\"close_on_limit\":" + TcBool(closeOnLimit)
             + ",\"max_open_trades\":" + IntegerToString(maxOpenTrades)
             + ",\"max_total_lots\":" + TcNum(maxTotalLots, 2)
             + ",\"trade_start\":" + TcJsonStr(tradeStart)
             + ",\"trade_end\":" + TcJsonStr(tradeEnd)
             + ",\"news_minutes\":" + IntegerToString(newsMinutes)
             + ",\"delay_ms\":" + IntegerToString(delayMs)
             + ",\"delay_jitter_ms\":" + IntegerToString(delayJitterMs)
             + ",\"delay_closes\":" + TcBool(delayCloses)
             + "}";
     }
  };

#endif
