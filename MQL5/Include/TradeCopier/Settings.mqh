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
public:
   bool              enabled;
   double            multiplier;
   double            maxLot;
   bool              roundUpMin;
   bool              copySLTP;
   string            suffix;
   string            prefix;
   string            strip;
   string            map;
   string            lastError;

   static bool       ValidMultiplier(const double m) { return m >= TC_MIN_MULTIPLIER && m <= TC_MAX_MULTIPLIER; }

   void              Set(const bool en, const double mult, const double maxL, const bool roundUp, const bool sltp,
                         const string sfx, const string pfx, const string strp, const string mp)
     {
      enabled    = en;
      multiplier = mult;
      maxLot     = maxL;
      roundUpMin = roundUp;
      copySLTP   = sltp;
      suffix     = sfx;
      prefix     = pfx;
      strip      = strp;
      map        = mp;
     }

   // Applies a config file. Missing keys keep their current value. An invalid
   // file is rejected as a whole (lastError says why) and nothing changes.
   // symbolsChanged tells the caller to rebuild its symbol map.
   bool              Apply(const string &text, bool &symbolsChanged)
     {
      int    len = StringLen(text);
      string raw;
      bool   en = enabled, roundUp = roundUpMin, sltp = copySLTP;
      double mult = multiplier, maxL = maxLot;
      string sfx = suffix, pfx = prefix, strp = strip, mp = map;

      if(TcJsonRaw(text, "enabled", 0, len, raw))      en      = (raw == "true");
      if(TcJsonRaw(text, "round_up_min", 0, len, raw)) roundUp = (raw == "true");
      if(TcJsonRaw(text, "copy_sltp", 0, len, raw))    sltp    = (raw == "true");
      TcJsonDouble(text, "multiplier", 0, len, mult);
      TcJsonDouble(text, "max_lot", 0, len, maxL);
      TcJsonString(text, "symbol_suffix", 0, len, sfx);
      TcJsonString(text, "symbol_prefix", 0, len, pfx);
      TcJsonString(text, "strip_suffix", 0, len, strp);
      TcJsonString(text, "symbol_map", 0, len, mp);

      if(!ValidMultiplier(mult) || maxL < 0)
        {
         lastError = StringFormat("multiplier must be %s-%s and max lot >= 0",
                                  TcNum(TC_MIN_MULTIPLIER, 2), TcNum(TC_MAX_MULTIPLIER, 0));
         return false;
        }
      symbolsChanged = sfx != suffix || pfx != prefix || strp != strip || mp != map;
      Set(en, mult, maxL, roundUp, sltp, sfx, pfx, strp, mp);
      lastError = "";
      return true;
     }

   string            Summary()
     {
      return StringFormat("%s, x%s, suffix '%s', max lot %s", enabled ? "enabled" : "disabled",
                          TcNum(multiplier, 4), suffix, TcNum(maxLot, 2));
     }

   // Same shape as the config file, embedded in the status file.
   string            ToJson()
     {
      return "{\"enabled\":" + (enabled ? "true" : "false")
             + ",\"multiplier\":" + TcNum(multiplier, 4)
             + ",\"max_lot\":" + TcNum(maxLot, 4)
             + ",\"round_up_min\":" + (roundUpMin ? "true" : "false")
             + ",\"copy_sltp\":" + (copySLTP ? "true" : "false")
             + ",\"symbol_suffix\":" + TcJsonStr(suffix)
             + ",\"symbol_prefix\":" + TcJsonStr(prefix)
             + ",\"strip_suffix\":" + TcJsonStr(strip)
             + ",\"symbol_map\":" + TcJsonStr(map)
             + "}";
     }
  };

#endif
