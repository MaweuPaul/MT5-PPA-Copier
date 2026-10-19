//+------------------------------------------------------------------+
//| Lots.mqh - lot sizing: broker steps/limits and contract sizes     |
//| Mirrored for the dashboard preview in dashboard/web/js/lots.js    |
//+------------------------------------------------------------------+
#ifndef TRADECOPIER_LOTS_MQH
#define TRADECOPIER_LOTS_MQH

// Decimal places of a lot step: 0.01 -> 2, 0.1 -> 1, 1 -> 0.
int TcStepDigits(const double step)
  {
   int d = 0;
   while(d < 8 && MathAbs(step * MathPow(10, d) - MathRound(step * MathPow(10, d))) > 1e-9)
      d++;
   return d;
  }

// Rounds down to the symbol's lot step and applies the broker's min/max and
// our own cap (maxLot, 0 = none). Returns 0 if the copy should be skipped.
double TcNormalizeLots(const string sym, const double raw, const double maxLot, const bool roundUpToMin)
  {
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double cap  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0 || raw <= 0)
      return 0;
   if(maxLot > 0 && maxLot < cap)
      cap = maxLot;

   double v = MathFloor(raw / step + 1e-7) * step;
   if(v > cap)
      v = MathFloor(cap / step + 1e-7) * step;
   if(v < vmin)
      v = (roundUpToMin && vmin <= cap) ? vmin : 0;
   return NormalizeDouble(v, TcStepDigits(step));
  }

// Brokers can define one lot differently for the same instrument (gold is
// usually 100 oz, but indices vary a lot). Returns the factor that gives the
// copy the same exposure as the master; 1.0 when either size is unknown.
double TcContractRatio(const double masterContract, const string sym)
  {
   double mine = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
   if(masterContract <= 0 || mine <= 0 || MathAbs(masterContract - mine) < 1e-9)
      return 1.0;
   return masterContract / mine;
  }

#endif
