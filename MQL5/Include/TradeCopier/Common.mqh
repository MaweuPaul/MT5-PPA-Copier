//+------------------------------------------------------------------+
//| Common.mqh - shared paths, file I/O and minimal JSON helpers      |
//| File formats: docs/snapshot-format.md                             |
//+------------------------------------------------------------------+
#ifndef TRADECOPIER_COMMON_MQH
#define TRADECOPIER_COMMON_MQH

#define TC_ROOT           "TradeCopier"
#define TC_FORMAT_VERSION 1

string TcMasterFile(const string masterId) { return TC_ROOT + "\\master_" + masterId + ".json"; }
string TcLinksFile(const long login)       { return TC_ROOT + "\\state\\links_" + IntegerToString(login) + ".csv"; }
string TcStatusFile(const long login)      { return TC_ROOT + "\\status\\follower_" + IntegerToString(login) + ".json"; }
string TcConfigFile(const long login)      { return TC_ROOT + "\\config\\follower_" + IntegerToString(login) + ".json"; }
string TcEventsFile(const long login)      { return TC_ROOT + "\\events\\follower_" + IntegerToString(login) + ".jsonl"; }
string TcControlFile()                     { return TC_ROOT + "\\control.json"; }
string TcCopyComment(const long masterTicket) { return "CP|" + IntegerToString(masterTicket); }

void TcEnsureFolders()
  {
   FolderCreate(TC_ROOT, FILE_COMMON);
   FolderCreate(TC_ROOT + "\\state", FILE_COMMON);
   FolderCreate(TC_ROOT + "\\status", FILE_COMMON);
   FolderCreate(TC_ROOT + "\\config", FILE_COMMON);
   FolderCreate(TC_ROOT + "\\events", FILE_COMMON);
  }

// Milliseconds since Windows started. Every terminal on this PC shares
// this clock, so master and follower timestamps can be compared directly.
ulong TcNowMs() { return GetTickCount64(); }

//--- Files (all in Common\Files so every terminal can reach them)

// Reads a whole UTF-8 file. Returns false if it can't be opened right now
// (missing, or being rewritten) - callers just try again on the next poll.
bool TcReadAll(const string path, string &out)
  {
   out = "";
   int h = FileOpen(path, FILE_READ | FILE_BIN | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
      return false;
   int size = (int)FileSize(h);
   uchar buf[];
   uint n = (size > 0) ? FileReadArray(h, buf, 0, size) : 0;
   FileClose(h);
   if(n > 0)
      out = CharArrayToString(buf, 0, (int)n, CP_UTF8);
   return true;
  }

// Overwrites a file with UTF-8 text. Readers detect a half-written file
// themselves (see seq/seq_end), so no temp file + rename is needed.
bool TcWriteAll(const string path, const string text)
  {
   int h = FileOpen(path, FILE_WRITE | FILE_BIN | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
      return false;
   uchar buf[];
   int n = StringToCharArray(text, buf, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0 && buf[n - 1] == 0)
      n--;                                   // drop the string terminator
   uint written = (n > 0) ? FileWriteArray(h, buf, 0, n) : 0;
   FileClose(h);
   return (int)written == n;
  }

// Appends one line (e.g. a JSON event). Past 2 MB the file is rotated to
// <path>.1 so the log can't grow without limit.
bool TcAppendLine(const string path, const string line)
  {
   int flags = FILE_READ | FILE_WRITE | FILE_BIN | FILE_COMMON | FILE_SHARE_READ;
   int h = FileOpen(path, flags);
   if(h == INVALID_HANDLE)
      return false;
   if(FileSize(h) > 2 * 1024 * 1024)
     {
      FileClose(h);
      FileMove(path, FILE_COMMON, path + ".1", FILE_COMMON | FILE_REWRITE);
      h = FileOpen(path, flags);
      if(h == INVALID_HANDLE)
         return false;
     }
   FileSeek(h, 0, SEEK_END);
   uchar buf[];
   int n = StringToCharArray(line + "\n", buf, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0 && buf[n - 1] == 0)
      n--;
   uint written = (n > 0) ? FileWriteArray(h, buf, 0, n) : 0;
   FileClose(h);
   return (int)written == n;
  }

//--- Formatting

// DoubleToString without trailing zeros: 1.50000 -> "1.5", 2.0 -> "2".
string TcNum(const double v, const int digits)
  {
   string s = DoubleToString(v, digits);
   if(StringFind(s, ".") < 0)
      return s;
   int n = StringLen(s);
   while(n > 0 && StringGetCharacter(s, n - 1) == '0')
      n--;
   if(n > 0 && StringGetCharacter(s, n - 1) == '.')
      n--;
   return StringSubstr(s, 0, n);
  }

string TcJsonStr(const string s)
  {
   string r = s;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, "\"", "\\\"");
   return "\"" + r + "\"";
  }

//--- Minimal JSON reading
// Our files are flat objects plus one array of flat objects, so a key
// lookup inside a [from, to) range is all we need - no general parser.

bool TcIsSpace(const ushort c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

// Finds "key": inside text[from, to) and returns its value as raw text
// (strings are unquoted and unescaped). The value must end before `to`.
bool TcJsonRaw(const string &text, const string key, const int from, const int to, string &raw)
  {
   string pat = "\"" + key + "\"";
   int p = StringFind(text, pat, from);
   if(p < 0 || p >= to)
      return false;
   p += StringLen(pat);
   while(p < to && TcIsSpace(StringGetCharacter(text, p)))
      p++;
   if(p >= to || StringGetCharacter(text, p) != ':')
      return false;
   p++;
   while(p < to && TcIsSpace(StringGetCharacter(text, p)))
      p++;
   if(p >= to)
      return false;

   if(StringGetCharacter(text, p) == '"')
     {
      int e = p + 1;
      while(e < to)
        {
         ushort c = StringGetCharacter(text, e);
         if(c == '\\') { e += 2; continue; }
         if(c == '"')  break;
         e++;
        }
      if(e >= to)
         return false;
      raw = StringSubstr(text, p + 1, e - p - 1);
      StringReplace(raw, "\\\"", "\"");
      StringReplace(raw, "\\\\", "\\");
      return true;
     }

   int e = p;
   while(e < to)
     {
      ushort c = StringGetCharacter(text, e);
      if(c == ',' || c == '}' || c == ']' || TcIsSpace(c))
         break;
      e++;
     }
   if(e == p || e >= to)                     // empty, or cut off by `to`
      return false;
   raw = StringSubstr(text, p, e - p);
   return true;
  }

bool TcJsonLong(const string &text, const string key, const int from, const int to, long &out)
  {
   string raw;
   if(!TcJsonRaw(text, key, from, to, raw))
      return false;
   out = StringToInteger(raw);
   return true;
  }

bool TcJsonDouble(const string &text, const string key, const int from, const int to, double &out)
  {
   string raw;
   if(!TcJsonRaw(text, key, from, to, raw))
      return false;
   out = StringToDouble(raw);
   return true;
  }

bool TcJsonString(const string &text, const string key, const int from, const int to, string &out)
  {
   return TcJsonRaw(text, key, from, to, out);
  }

#endif
