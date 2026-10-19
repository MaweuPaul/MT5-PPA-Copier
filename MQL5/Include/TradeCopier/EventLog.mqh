//+------------------------------------------------------------------+
//| EventLog.mqh - what the follower did, for the dashboard           |
//| Each event goes to the Experts log and, once the account is       |
//| known, to events\follower_<login>.jsonl (one JSON per line).      |
//+------------------------------------------------------------------+
#ifndef TRADECOPIER_EVENTLOG_MQH
#define TRADECOPIER_EVENTLOG_MQH

#include "Common.mqh"

// kind: open | close | partial | sltp | skip | error | risk | info | config | state | start
class CTcEventLog
  {
private:
   string            m_path;
   long              m_login;

public:
                     CTcEventLog() : m_path(""), m_login(0) {}

   void              Open(const long login)
     {
      m_login = login;
      m_path  = TcEventsFile(login);
     }

   void              Close() { m_path = ""; m_login = 0; }

   // extra: optional pre-built JSON fields (e.g. trade details), no leading comma.
   void              Write(const string kind, const long masterTicket, const string msg,
                           const double latencyMs = -1, const string extra = "")
     {
      PrintFormat("TradeCopier: [%s]%s %s", kind,
                  masterTicket > 0 ? StringFormat(" master #%I64d", masterTicket) : "", msg);
      if(m_path == "")
         return;
      TcAppendLine(m_path,
                   "{\"time\":" + TcJsonStr(TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS))
                   + ",\"ms\":" + IntegerToString((long)TcNowMs())
                   + ",\"login\":" + IntegerToString(m_login)
                   + ",\"kind\":" + TcJsonStr(kind)
                   + ",\"master\":" + IntegerToString(masterTicket)
                   + ",\"msg\":" + TcJsonStr(msg)
                   + (latencyMs >= 0 ? ",\"latency_ms\":" + TcNum(latencyMs, 1) : "")
                   + (extra != "" ? "," + extra : "")
                   + "}");
     }
  };

#endif
