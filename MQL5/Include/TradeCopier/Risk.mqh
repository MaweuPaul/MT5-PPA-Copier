//+------------------------------------------------------------------+
//| Risk.mqh - account-level guards for a follower                    |
//|   daily loss limit, equity floor, trading hours, news window      |
//+------------------------------------------------------------------+
#ifndef TRADECOPIER_RISK_MQH
#define TRADECOPIER_RISK_MQH

#include "Settings.mqh"

class CTcRisk
  {
private:
   datetime          m_breachDay;   // server day a daily-loss stop happened
   double            m_breachLimit; // the limit in force when it happened

   static datetime   ServerDayStart()
     {
      MqlDateTime t;
      TimeToStruct(TimeTradeServer(), t);
      t.hour = 0; t.min = 0; t.sec = 0;
      return StructToTime(t);
     }

public:
   double            dailyPnl;      // closed today + floating now, account currency
   bool              breached;
   string            reason;

                     CTcRisk() { Reset(); }
   void              Reset() { m_breachDay = 0; m_breachLimit = 0; dailyPnl = 0; breached = false; reason = ""; }

   // Today's P&L = deals closed since the broker's midnight + current floating.
   // Stateless, so a restart can't "forget" today's losses.
   void              Update(CTcSettings &cfg)
     {
      datetime day = ServerDayStart();
      double closed = 0;
      if(HistorySelect(day, TimeTradeServer() + 60))
         for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
           {
            ulong d = HistoryDealGetTicket(i);
            long type = HistoryDealGetInteger(d, DEAL_TYPE);
            if(type == DEAL_TYPE_BUY || type == DEAL_TYPE_SELL)
               closed += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION)
                         + HistoryDealGetDouble(d, DEAL_SWAP);
           }
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      dailyPnl = closed + equity - AccountInfoDouble(ACCOUNT_BALANCE);

      // A daily stop lasts until the broker's next day (or until you change the
      // limit); the floor until equity recovers.
      if(m_breachDay != 0 && (m_breachDay != day || cfg.dailyLossLimit != m_breachLimit))
         m_breachDay = 0;
      if(cfg.dailyLossLimit > 0 && -dailyPnl >= cfg.dailyLossLimit)
        {
         m_breachDay   = day;
         m_breachLimit = cfg.dailyLossLimit;
        }

      breached = true;
      if(m_breachDay != 0)
         reason = StringFormat("daily loss limit %s reached", TcNum(cfg.dailyLossLimit, 2));
      else if(cfg.equityFloor > 0 && equity <= cfg.equityFloor)
         reason = StringFormat("equity %s at or below floor %s", TcNum(equity, 2), TcNum(cfg.equityFloor, 2));
      else
        {
         breached = false;
         reason = "";
        }
     }

   static bool       InTradingHours(CTcSettings &cfg)
     {
      int s = CTcSettings::Minutes(cfg.tradeStart), e = CTcSettings::Minutes(cfg.tradeEnd);
      if(s < 0 || e < 0)
         return true;
      MqlDateTime t;
      TimeToStruct(TimeLocal(), t);
      int m = t.hour * 60 + t.min;
      return s <= e ? (m >= s && m < e) : (m >= s || m < e);   // window may cross midnight
     }

   // High-impact calendar event for either currency of sym within +/- minutes.
   static bool       NewsNear(const string sym, const int minutes, string &eventName)
     {
      if(minutes <= 0)
         return false;
      datetime now = TimeTradeServer();
      string cur[2];
      cur[0] = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
      cur[1] = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
      for(int c = 0; c < 2; c++)
        {
         MqlCalendarValue v[];
         if(cur[c] == "" || !CalendarValueHistory(v, now - minutes * 60, now + minutes * 60, NULL, cur[c]))
            continue;
         for(int j = 0; j < ArraySize(v); j++)
           {
            MqlCalendarEvent ev;
            if(CalendarEventById(v[j].event_id, ev) && ev.importance == CALENDAR_IMPORTANCE_HIGH)
              {
               eventName = cur[c] + " " + ev.name;
               return true;
              }
           }
        }
      return false;
     }

   string            ToJson(CTcSettings &cfg)
     {
      return "{\"daily_pnl\":" + TcNum(dailyPnl, 2)
             + ",\"daily_loss_limit\":" + TcNum(cfg.dailyLossLimit, 2)
             + ",\"equity_floor\":" + TcNum(cfg.equityFloor, 2)
             + ",\"breached\":" + TcBool(breached)
             + ",\"reason\":" + TcJsonStr(reason) + "}";
     }
  };

#endif
