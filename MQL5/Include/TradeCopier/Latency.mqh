//+------------------------------------------------------------------+
//| Latency.mqh - running copy-latency stats (last / avg / max)       |
//+------------------------------------------------------------------+
#ifndef TRADECOPIER_LATENCY_MQH
#define TRADECOPIER_LATENCY_MQH

#include "Common.mqh"

class CTcLatency
  {
private:
   double            m_last, m_sum, m_max;
   long              m_count;

public:
                     CTcLatency() { Reset(); }

   void              Reset() { m_last = 0; m_sum = 0; m_max = 0; m_count = 0; }

   void              Add(const double ms)
     {
      m_last = ms;
      m_sum += ms;
      m_count++;
      if(ms > m_max)
         m_max = ms;
     }

   double            Last() { return m_last; }
   double            Avg()  { return m_count > 0 ? m_sum / m_count : 0; }
   double            Max()  { return m_max; }

   string            ToJsonFields()
     {
      return "\"latency_last_ms\":" + TcNum(m_last, 1)
             + ",\"latency_avg_ms\":" + TcNum(Avg(), 1)
             + ",\"latency_max_ms\":" + TcNum(m_max, 1);
     }
  };

#endif
