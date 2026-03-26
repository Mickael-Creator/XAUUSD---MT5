//+------------------------------------------------------------------+
//| GoldML_DataBridge.mqh                                            |
//| MARKET DATA BRIDGE — MT5 Windows → VPS Linux                    |
//| Sends M15/M5 OHLCV candles to Python Sniper endpoint            |
//|                                                                  |
//| Usage (in EA OnInit):                                            |
//|   g_bridge = new CDataBridge();                                  |
//|   g_bridge.Initialize(                                           |
//|       "http://86.48.5.126:5002/v1/market_data",                  |
//|       API_Auth_Token, _Symbol);                                  |
//|                                                                  |
//| Usage (in EA OnTimer/OnTick):                                    |
//|   g_bridge.SendIfDue();                                          |
//+------------------------------------------------------------------+
#ifndef GOLDML_DATABRIDGE_MQH
#define GOLDML_DATABRIDGE_MQH

class CDataBridge {
private:
   //--- Configuration
   string   m_symbol;
   string   m_url;
   string   m_auth_token;
   int      m_timeout_ms;
   int      m_interval_sec;
   int      m_bars_m15;
   int      m_bars_m5;

   //--- State
   datetime m_last_send;
   bool     m_initialized;

   //--- Serialize MqlRates array to JSON array string.
   //    rates[] must be ArraySetAsSeries=true (index 0 = most recent bar).
   //    Output: chronological order — oldest bar first — for Python pandas.
   string SerializeRates(MqlRates &rates[], int count) {
      string s = "[";
      // Iterate from oldest (count-1) to newest (0)
      for(int i = count - 1; i >= 0; i--) {
         if(i < count - 1) s += ",";
         // Each bar: ~65 chars — StringFormat safe at this size
         s += StringFormat(
            "{\"t\":%d,\"o\":%.2f,\"h\":%.2f,\"l\":%.2f,\"c\":%.2f,\"v\":%d}",
            (long)rates[i].time,
            rates[i].open,
            rates[i].high,
            rates[i].low,
            rates[i].close,
            (long)rates[i].tick_volume
         );
      }
      s += "]";
      return s;
   }

   //--- Build complete payload JSON.
   //    Avoids StringFormat for the outer structure (payload can exceed 8KB).
   string BuildJSON(MqlRates &m15[], int m15_count, MqlRates &m5[], int m5_count) {
      string json = "{";
      json += "\"symbol\":\"" + m_symbol + "\",";
      json += "\"timestamp\":" + IntegerToString((long)TimeCurrent()) + ",";
      json += "\"m15\":" + SerializeRates(m15, m15_count) + ",";
      json += "\"m5\":"  + SerializeRates(m5,  m5_count);
      json += "}";
      return json;
   }

public:
   //+------------------------------------------------------------------+
   //| Constructor / Destructor                                          |
   //+------------------------------------------------------------------+
   CDataBridge() {
      m_symbol       = "XAUUSD";
      m_url          = "";
      m_auth_token   = "";
      m_timeout_ms   = 5000;
      m_interval_sec = 30;
      m_bars_m15     = 50;
      m_bars_m5      = 80;
      m_last_send    = 0;
      m_initialized  = false;
   }
   // Overload: pre-set symbol at construction (matches new CDataBridge(_Symbol) usage)
   CDataBridge(string symbol) {
      m_symbol       = (StringLen(symbol) > 0) ? symbol : "XAUUSD";
      m_url          = "";
      m_auth_token   = "";
      m_timeout_ms   = 5000;
      m_interval_sec = 30;
      m_bars_m15     = 50;
      m_bars_m5      = 80;
      m_last_send    = 0;
      m_initialized  = false;
   }
   ~CDataBridge() {}

   //+------------------------------------------------------------------+
   //| Initialize — call once in OnInit()                                |
   //+------------------------------------------------------------------+
   bool Initialize(string url,
                   string auth_token,
                   string symbol       = "XAUUSD",
                   int    interval_sec = 30,
                   int    timeout_ms   = 5000,
                   int    bars_m15     = 50,
                   int    bars_m5      = 80) {
      if(StringLen(url) == 0) {
         Print("❌ DataBridge.Initialize: URL cannot be empty");
         return false;
      }
      m_url          = url;
      m_auth_token   = auth_token;
      m_symbol       = symbol;
      m_interval_sec = interval_sec;
      m_timeout_ms   = timeout_ms;
      m_bars_m15     = bars_m15;
      m_bars_m5      = bars_m5;
      m_initialized  = true;

      Print("✅ DataBridge initialized");
      Print("   URL:      ", m_url);
      Print("   Symbol:   ", m_symbol);
      Print("   Interval: ", m_interval_sec, "s");
      Print("   Bars M15: ", m_bars_m15, " | Bars M5: ", m_bars_m5);
      Print("   Auth:     ", (StringLen(m_auth_token) > 0) ? "Bearer ***" : "NONE (⚠️ set API_Auth_Token)");
      return true;
   }

   //+------------------------------------------------------------------+
   //| SendIfDue — call from OnTimer() or OnTick()                       |
   //| Returns true only when a send was attempted.                      |
   //+------------------------------------------------------------------+
   bool SendIfDue() {
      if(!m_initialized) return false;
      datetime now = TimeCurrent();
      if((now - m_last_send) < (datetime)m_interval_sec) return false;
      return Send();
   }

   //+------------------------------------------------------------------+
   //| Send — force immediate send (for OnInit warm-up or manual call)   |
   //+------------------------------------------------------------------+
   bool Send() {
      if(!m_initialized) {
         Print("❌ DataBridge.Send: call Initialize() first");
         return false;
      }

      //--- 1. Fetch M15 candles
      MqlRates rates_m15[];
      ArraySetAsSeries(rates_m15, true);
      int copied_m15 = CopyRates(m_symbol, PERIOD_M15, 0, m_bars_m15, rates_m15);
      if(copied_m15 <= 0) {
         Print("❌ DataBridge: CopyRates M15 failed — error=", GetLastError(),
               " | Market closed or insufficient history?");
         m_last_send = TimeCurrent(); // Still update to avoid hammering
         return false;
      }

      //--- 2. Fetch M5 candles
      MqlRates rates_m5[];
      ArraySetAsSeries(rates_m5, true);
      int copied_m5 = CopyRates(m_symbol, PERIOD_M5, 0, m_bars_m5, rates_m5);
      if(copied_m5 <= 0) {
         Print("❌ DataBridge: CopyRates M5 failed — error=", GetLastError());
         m_last_send = TimeCurrent();
         return false;
      }

      //--- 3. Serialize to JSON
      string json     = BuildJSON(rates_m15, copied_m15, rates_m5, copied_m5);
      int    json_len = StringLen(json);

      //--- 4. Convert JSON string → char array for POST body
      //       StringToCharArray with explicit length excludes the null terminator
      char post_data[];
      ArrayResize(post_data, json_len);
      StringToCharArray(json, post_data, 0, json_len, CP_UTF8);

      //--- 5. Build headers — same pattern as FetchNewsSignal()
      string headers = "Content-Type: application/json\r\n";
      if(StringLen(m_auth_token) > 0)
         headers += "Authorization: Bearer " + m_auth_token + "\r\n";

      //--- 6. Send HTTP POST
      char   result_data[];
      string result_headers;
      ResetLastError();

      int http_code = WebRequest(
         "POST",
         m_url,
         headers,
         m_timeout_ms,
         post_data,
         result_data,
         result_headers
      );

      m_last_send = TimeCurrent(); // Always update timestamp after attempt

      //--- 7. Handle result
      if(http_code == -1) {
         int err = GetLastError();
         if(err == 4014) {
            // URL not in MT5 allowed list — log once
            static bool warned_4014 = false;
            if(!warned_4014) {
               Print("⚠️  DataBridge: URL not allowed in MT5.");
               Print("   Go to: Tools > Options > Expert Advisors > Allow WebRequest");
               Print("   Add URL: ", m_url);
               warned_4014 = true;
            }
         } else {
            static int last_err = -1;
            if(err != last_err) {
               Print("❌ DataBridge: WebRequest failed — error=", err);
               last_err = err;
            }
         }
         return false;
      }

      if(http_code != 200) {
         static int last_http_err = 0;
         if(http_code != last_http_err) {
            string resp = CharArrayToString(result_data, 0, WHOLE_ARRAY, CP_UTF8);
            Print("❌ DataBridge: HTTP ", http_code,
                  " → ", StringSubstr(resp, 0, 200));
            last_http_err = http_code;
         }
         return false;
      }

      //--- Success
      Print("📡 DataBridge: OK — M15×", copied_m15,
            " M5×", copied_m5,
            " | payload=", json_len, "B",
            " | ts=", TimeToString(m_last_send, TIME_DATE|TIME_SECONDS));
      return true;
   }

   //+------------------------------------------------------------------+
   //| Diagnostics                                                       |
   //+------------------------------------------------------------------+
   bool     IsInitialized()       { return m_initialized; }
   datetime LastSend()            { return m_last_send; }
   int      SecsSinceLastSend()   { return (int)(TimeCurrent() - m_last_send); }
   bool     IsOverdue()           { return SecsSinceLastSend() >= m_interval_sec * 2; }
};

#endif // GOLDML_DATABRIDGE_MQH
