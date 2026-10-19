//+------------------------------------------------------------------+
//| SymbolMap.mqh - master symbol name -> this broker's symbol name   |
//+------------------------------------------------------------------+
#ifndef TRADECOPIER_SYMBOLMAP_MQH
#define TRADECOPIER_SYMBOLMAP_MQH

// Resolution order for a master symbol such as "EURUSD":
//   1. explicit map entry      "XAUUSD=GOLD;US30=DJ30"
//   2. prefix + base + suffix  base = master symbol minus StripMasterSuffix
//   3. base, the master symbol unchanged, then base + an auto-detected suffix
//   4. the same for each built-in alias (GOLD -> XAUUSD, US30 -> DJ30 ...)
// Results (including "not found") are cached, so each symbol is looked up once.

// Names brokers commonly use for the same instrument. Each line is one group.
// Contract sizes often differ between these - the follower adjusts lots for that.
string g_tcAliasGroups[] =
  {
   "XAUUSD,GOLD",
   "XAGUSD,SILVER",
   "US30,DJ30,WS30,DJI30,DOW30,US30CASH",
   "NAS100,US100,USTEC,NDX100,NQ100,USTECH,US100CASH",
   "SPX500,US500,SP500,SPX,US500CASH",
   "GER40,DE40,GER30,DE30,DAX40,GER40CASH",
   "UK100,FTSE100,UK100CASH",
   "JPN225,JP225,NIKKEI225,JP225CASH",
   "USOIL,WTI,XTIUSD,USOUSD,OILUSD",
   "UKOIL,BRENT,XBRUSD,UKOUSD",
   "BTCUSD,BITCOIN",
   "ETHUSD,ETHEREUM"
  };

class CTcSymbolMap
  {
private:
   string            m_from[];
   string            m_to[];
   string            m_prefix;
   string            m_suffix;
   string            m_strip;
   string            m_cacheKey[];
   string            m_cacheVal[];

   bool              Usable(const string name)
     {
      bool custom = false;
      if(name == "" || !SymbolExist(name, custom))
         return false;
      return SymbolSelect(name, true);       // must be in Market Watch to trade
     }

   // Last resort when no suffix is configured: look for exactly one broker
   // symbol that is `base` plus a short suffix (EURUSD -> EURUSDm, EURUSD.r).
   // More than one match (e.g. EURUSDm and EURUSDc) is ambiguous - give up and
   // let the user set SymbolSuffix or SymbolMap.
   string            AutoSuffix(const string base)
     {
      string found = "";
      int    len = StringLen(base);
      int    total = SymbolsTotal(false);
      for(int i = 0; i < total; i++)
        {
         string name = SymbolName(i, false);
         int extra = StringLen(name) - len;
         if(extra < 1 || extra > 4 || StringSubstr(name, 0, len) != base)
            continue;
         if(found != "")
           {
            PrintFormat("TradeCopier: '%s' matches both '%s' and '%s' - set SymbolSuffix or SymbolMap", base, found, name);
            return "";
           }
         found = name;
        }
      if(found != "" && Usable(found))
        {
         PrintFormat("TradeCopier: no suffix set - auto-detected '%s' for '%s'", found, base);
         return found;
        }
      return "";
     }

   // prefix + name + suffix, then name, then name + auto-detected suffix.
   string            FindName(const string name)
     {
      if(Usable(m_prefix + name + m_suffix))
         return m_prefix + name + m_suffix;
      if(Usable(name))
         return name;
      return AutoSuffix(name);
     }

   // Tries the other names in `name`'s alias group (case-insensitive).
   string            FindAlias(const string name)
     {
      string upper = name;
      StringToUpper(upper);
      for(int g = 0; g < ArraySize(g_tcAliasGroups); g++)
        {
         string names[];
         int n = StringSplit(g_tcAliasGroups[g], ',', names);
         bool inGroup = false;
         for(int i = 0; i < n && !inGroup; i++)
            inGroup = (names[i] == upper);
         if(!inGroup)
            continue;
         for(int i = 0; i < n; i++)
           {
            if(names[i] == upper)
               continue;
            string found = FindName(names[i]);
            if(found != "")
               return found;
           }
         return "";
        }
      return "";
     }

public:
   void              Init(const string spec, const string prefix, const string suffix, const string strip)
     {
      m_prefix = prefix;
      m_suffix = suffix;
      m_strip  = strip;
      ArrayResize(m_from, 0);
      ArrayResize(m_to, 0);
      ArrayResize(m_cacheKey, 0);
      ArrayResize(m_cacheVal, 0);

      string pairs[];
      int n = StringSplit(spec, ';', pairs);
      for(int i = 0; i < n; i++)
        {
         string kv[];
         if(StringSplit(pairs[i], '=', kv) != 2)
            continue;
         string k = kv[0], v = kv[1];
         StringTrimLeft(k);
         StringTrimRight(k);
         StringTrimLeft(v);
         StringTrimRight(v);
         if(k == "" || v == "")
            continue;
         int m = ArraySize(m_from);
         ArrayResize(m_from, m + 1);
         ArrayResize(m_to, m + 1);
         m_from[m] = k;
         m_to[m]   = v;
        }
     }

   // This broker's symbol for a master symbol, or "" if none is tradable.
   string            Resolve(const string masterSymbol)
     {
      for(int i = 0; i < ArraySize(m_cacheKey); i++)
         if(m_cacheKey[i] == masterSymbol)
            return m_cacheVal[i];

      string result = "";
      for(int i = 0; i < ArraySize(m_from) && result == ""; i++)
         if(m_from[i] == masterSymbol && Usable(m_to[i]))
            result = m_to[i];

      if(result == "")
        {
         string base = masterSymbol;
         int len = StringLen(base), stripLen = StringLen(m_strip);
         if(stripLen > 0 && len > stripLen && StringSubstr(base, len - stripLen) == m_strip)
            base = StringSubstr(base, 0, len - stripLen);

         result = FindName(base);
         if(result == "" && Usable(masterSymbol))
            result = masterSymbol;
         if(result == "")
            result = FindAlias(base);
        }

      int n = ArraySize(m_cacheKey);
      ArrayResize(m_cacheKey, n + 1);
      ArrayResize(m_cacheVal, n + 1);
      m_cacheKey[n] = masterSymbol;
      m_cacheVal[n] = result;

      if(result == "")
         PrintFormat("TradeCopier: no tradable symbol for master symbol '%s' - set SymbolSuffix or SymbolMap", masterSymbol);
      else if(result != masterSymbol)
         PrintFormat("TradeCopier: master symbol '%s' -> '%s'", masterSymbol, result);
      return result;
     }
  };

#endif
