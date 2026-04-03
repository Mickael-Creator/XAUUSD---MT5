//+------------------------------------------------------------------+
//|                      GoldML_QualityFilters.mqh                   |
//|              PROFESSIONAL TRADE QUALITY FILTER SYSTEM            |
//|                    Gold ML Trading System v1.0                   |
//|         Cooldown  Range  Consecutive  Same Level  Quality    |
//+------------------------------------------------------------------+
#property copyright "Gold ML System - Institutional Grade"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| FILTER RESULT STRUCTURE                                          |
//+------------------------------------------------------------------+
struct FilterResult {
   bool     passed;           // All filters passed
   string   blockReason;      // If blocked, why
   string   details;          // Detailed info
   
   // Individual filter results
   bool     cooldownOK;
   bool     rangeOK;
   bool     consecutiveOK;
   bool     sameLevelOK;
   bool     dailyLimitOK;
   bool     sessionOK;
   bool     drawdownOK;
   bool     trendOK;

   // Metrics
   int      minutesSinceLastTrade;
   double   currentATR;
   double   rangeATR_Ratio;
   int      consecutiveLosses;
   int      consecutiveWins;
   int      sameDirTrades;
   double   dailyPnL;
   double   dailyMaxDD;
};

//+------------------------------------------------------------------+
//| TRADE RECORD STRUCTURE                                           |
//+------------------------------------------------------------------+
struct TradeRecord {
   ulong    ticket;
   datetime closeTime;
   double   profit;
   string   direction;
   double   entryPrice;
   double   closePrice;
   bool     isWin;
};

//+------------------------------------------------------------------+
//| QUALITY FILTERS CLASS                                            |
//+------------------------------------------------------------------+
class CQualityFilters {
private:
   string   m_symbol;
   int      m_magic;
   
   // Settings - Cooldown
   bool     m_enableCooldown;
   int      m_cooldownMinutes;
   int      m_cooldownAfterLoss;
   int      m_cooldownAfterWin;
   
   // Settings - Range
   bool     m_enableRangeFilter;
   double   m_minRangeATR;
   int      m_rangeLookback;
   
   // Settings - Consecutive
   bool     m_enableConsecutive;
   int      m_maxConsecutiveLosses;
   int      m_maxConsecutiveWins;
   int      m_maxSameDirection;
   
   // Settings - Same Level
   bool     m_enableSameLevelFilter;
   double   m_sameLevelPips;
   int      m_sameLevelLookback;
   
   // Settings - Daily Limits
   bool     m_enableDailyLimits;
   int      m_maxDailyTrades;
   double   m_maxDailyLoss;
   double   m_maxDailyProfit;
   double   m_maxDailyDD;
   
   // Settings - Session
   bool     m_enableSessionFilter;
   string   m_sessionStart;
   string   m_sessionEnd;
   bool     m_allowAsian;
   
   // Settings - Trend EMA
   bool     m_enableTrendFilter;

   // Indicator handles
   int      m_hATR;
   int      m_hEMA21;
   int      m_hEMA55;
   
   // State tracking
   datetime m_lastTradeTime;
   string   m_lastTradeDirection;
   double   m_lastTradeEntry;
   bool     m_lastTradeWin;
   int      m_consecutiveLosses;
   int      m_consecutiveWins;
   int      m_sameDirCount;
   int      m_tradesToday;
   double   m_dailyPnL;
   double   m_dailyHighWater;
   double   m_dailyMaxDD;
   datetime m_dayStart;
   
   // Trade history
   TradeRecord m_recentTrades[];
   int      m_maxTradeHistory;
   
   // Private methods
   void     UpdateDailyStats();
   void     ResetDailyStats();
   double   GetATR();
   double   GetRangeATRRatio();
   bool     IsSameLevel(double price);
   bool     InTradingSession();
   int      GetMinutesSinceLastTrade();
   bool     CheckTrendEMA(string direction);
   
public:
   CQualityFilters(string symbol, int magic);
   ~CQualityFilters();
   
   // Initialization
   bool Initialize(bool enableCooldown = true,
                   int cooldownMinutes = 30,
                   int cooldownAfterLoss = 45,
                   int cooldownAfterWin = 20,
                   bool enableRange = true,
                   double minRangeATR = 0.5,
                   int rangeLookback = 12,
                   bool enableConsecutive = true,
                   int maxConsecutiveLosses = 3,
                   int maxConsecutiveWins = 10,  // FIX M3 (2026-04-03): 5->10 ne pas bloquer en tendance forte
                   int maxSameDirection = 3,
                   bool enableSameLevel = true,
                   double sameLevelPips = 30,
                   int sameLevelLookback = 5,
                   bool enableDailyLimits = true,
                   int maxDailyTrades = 5,
                   double maxDailyLoss = 400,
                   double maxDailyProfit = 300,
                   double maxDailyDD = 300,
                   bool enableSession = true,
                   string sessionStart = "08:00",
                   string sessionEnd = "20:00",
                   bool allowAsian = false,
                   bool enableTrendFilter = true);
   
   // Main filter check
   // FIX C-6.1 (2026-04-03): timingMode ajouté pour désactiver EMA en POST_NEWS
   FilterResult CheckAllFilters(string direction, double entryPrice, string timingMode = "CLEAR");
   
   // Individual filters
   bool CheckCooldown();
   bool CheckRange();
   bool CheckConsecutive(string direction);
   bool CheckSameLevel(double price);
   bool CheckDailyLimits();
   bool CheckSession();
   bool CheckDrawdown();

   // Trade recording
   void RecordTradeOpen(ulong ticket, string direction, double entryPrice);
   void RecordTradeClose(ulong ticket, double profit, double closePrice);
   void RecordLoss();
   void RecordWin();
   
   // Getters
   int GetTradesToday() { return m_tradesToday; }
   double GetDailyPnL() { return m_dailyPnL; }
   int GetConsecutiveLosses() { return m_consecutiveLosses; }
   int GetConsecutiveWins() { return m_consecutiveWins; }
   int GetSameDirectionCount() { return m_sameDirCount; }
   datetime GetLastTradeTime() { return m_lastTradeTime; }
   
   // Manual overrides
   void ResetConsecutive();
   void ResetDaily();
   void ForceAllowTrade() { m_lastTradeTime = 0; }
   
   // Utilities
   void PrintStatus();
   string GetFilterSummary();
};

//+------------------------------------------------------------------+
//| Constructor                                                       |
//+------------------------------------------------------------------+
CQualityFilters::CQualityFilters(string symbol, int magic) {
   m_symbol = symbol;
   m_magic = magic;
   
   m_hATR = INVALID_HANDLE;
   m_hEMA21 = INVALID_HANDLE;
   m_hEMA55 = INVALID_HANDLE;

   m_lastTradeTime = 0;
   m_lastTradeDirection = "";
   m_lastTradeEntry = 0;
   m_lastTradeWin = true;
   m_consecutiveLosses = 0;
   m_consecutiveWins = 0;
   m_sameDirCount = 0;
   m_tradesToday = 0;
   m_dailyPnL = 0;
   m_dailyHighWater = 0;
   m_dailyMaxDD = 0;
   m_dayStart = 0;
   m_maxTradeHistory = 20;
   
   ArrayResize(m_recentTrades, 0);
}

//+------------------------------------------------------------------+
//| Destructor                                                        |
//+------------------------------------------------------------------+
CQualityFilters::~CQualityFilters() {
   if(m_hATR != INVALID_HANDLE) IndicatorRelease(m_hATR);
   if(m_hEMA21 != INVALID_HANDLE) IndicatorRelease(m_hEMA21);
   if(m_hEMA55 != INVALID_HANDLE) IndicatorRelease(m_hEMA55);
}

//+------------------------------------------------------------------+
//| Initialize                                                        |
//+------------------------------------------------------------------+
bool CQualityFilters::Initialize(bool enableCooldown, int cooldownMinutes,
                                  int cooldownAfterLoss, int cooldownAfterWin,
                                  bool enableRange, double minRangeATR, int rangeLookback,
                                  bool enableConsecutive, int maxConsecutiveLosses,
                                  int maxConsecutiveWins, int maxSameDirection,
                                  bool enableSameLevel, double sameLevelPips, int sameLevelLookback,
                                  bool enableDailyLimits, int maxDailyTrades,
                                  double maxDailyLoss, double maxDailyProfit, double maxDailyDD,
                                  bool enableSession, string sessionStart, string sessionEnd,
                                  bool allowAsian,
                                  bool enableTrendFilter) {
   
   m_enableCooldown = enableCooldown;
   m_cooldownMinutes = cooldownMinutes;
   m_cooldownAfterLoss = cooldownAfterLoss;
   m_cooldownAfterWin = cooldownAfterWin;
   
   m_enableRangeFilter = enableRange;
   m_minRangeATR = minRangeATR;
   m_rangeLookback = rangeLookback;
   
   m_enableConsecutive = enableConsecutive;
   m_maxConsecutiveLosses = maxConsecutiveLosses;
   m_maxConsecutiveWins = maxConsecutiveWins;
   m_maxSameDirection = maxSameDirection;
   
   m_enableSameLevelFilter = enableSameLevel;
   m_sameLevelPips = sameLevelPips;
   m_sameLevelLookback = sameLevelLookback;
   
   m_enableDailyLimits = enableDailyLimits;
   m_maxDailyTrades = maxDailyTrades;
   m_maxDailyLoss = maxDailyLoss;
   m_maxDailyProfit = maxDailyProfit;
   m_maxDailyDD = maxDailyDD;
   
   m_enableSessionFilter = enableSession;
   m_sessionStart = sessionStart;
   m_sessionEnd = sessionEnd;
   m_allowAsian = allowAsian;

   m_enableTrendFilter = enableTrendFilter;

   m_hATR = iATR(m_symbol, PERIOD_M15, 14);
   m_hEMA21 = iMA(m_symbol, PERIOD_M15, 21, 0, MODE_EMA, PRICE_CLOSE);
   m_hEMA55 = iMA(m_symbol, PERIOD_M15, 55, 0, MODE_EMA, PRICE_CLOSE);
   
   if(m_hATR == INVALID_HANDLE || m_hEMA21 == INVALID_HANDLE || m_hEMA55 == INVALID_HANDLE) {
      Print("Quality Filters: Failed to create indicators (ATR/EMA21/EMA55)");
      return false;
   }
   
   m_dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   
   Print("");
   Print("       QUALITY FILTERS - INITIALIZED                      ");
   Print("");
   Print("  Cooldown: ", m_enableCooldown ? "ON" : "OFF", 
         " (", m_cooldownMinutes, " min / ", m_cooldownAfterLoss, " after loss)");
   Print("  Range Filter: ", m_enableRangeFilter ? "ON" : "OFF", 
         " (min ", m_minRangeATR, "x ATR)");
   Print("  Consecutive: ", m_enableConsecutive ? "ON" : "OFF",
         " (max ", m_maxConsecutiveLosses, " losses / ", m_maxSameDirection, " same dir)");
   Print("  Same Level: ", m_enableSameLevelFilter ? "ON" : "OFF",
         " (", m_sameLevelPips, " pips)");
   Print("  Daily Limits: ", m_enableDailyLimits ? "ON" : "OFF",
         " (max ", m_maxDailyTrades, " trades)");
   Print("  Session: ", m_enableSessionFilter ? "ON" : "OFF",
         " (", m_sessionStart, " - ", m_sessionEnd, ")");
   Print("");
   
   return true;
}

//+------------------------------------------------------------------+
//| Get ATR                                                           |
//+------------------------------------------------------------------+
double CQualityFilters::GetATR() {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(m_hATR, 0, 0, 3, atr) < 3) return 0;
   return atr[0];
}

//+------------------------------------------------------------------+
//| Get Range ATR Ratio                                               |
//+------------------------------------------------------------------+
double CQualityFilters::GetRangeATRRatio() {
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   if(CopyHigh(m_symbol, PERIOD_M15, 0, m_rangeLookback, high) < m_rangeLookback) return 0;
   if(CopyLow(m_symbol, PERIOD_M15, 0, m_rangeLookback, low) < m_rangeLookback) return 0;
   
   double highestHigh = high[ArrayMaximum(high, 0, m_rangeLookback)];
   double lowestLow = low[ArrayMinimum(low, 0, m_rangeLookback)];
   double range = highestHigh - lowestLow;
   
   double atr = GetATR();
   if(atr == 0) return 0;
   
   return range / atr;
}

//+------------------------------------------------------------------+
//| Is Same Level                                                     |
//+------------------------------------------------------------------+
bool CQualityFilters::IsSameLevel(double price) {
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   double tolerance = m_sameLevelPips * point * 10;
   
   for(int i = 0; i < ArraySize(m_recentTrades); i++) {
      if(MathAbs(m_recentTrades[i].entryPrice - price) < tolerance) {
         // Check if within lookback period
         int minutesAgo = (int)((TimeCurrent() - m_recentTrades[i].closeTime) / 60);
         if(minutesAgo < m_sameLevelLookback * 60) { // Convert hours to minutes
            return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| In Trading Session                                                |
//+------------------------------------------------------------------+
bool CQualityFilters::InTradingSession() {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   int now = t.hour * 60 + t.min;
   
   string p1[], p2[];
   StringSplit(m_sessionStart, ':', p1);
   StringSplit(m_sessionEnd, ':', p2);
   
   int start = (int)StringToInteger(p1[0]) * 60 + (int)StringToInteger(p1[1]);
   int end = (int)StringToInteger(p2[0]) * 60 + (int)StringToInteger(p2[1]);
   
   bool inMainSession = (now >= start && now <= end);
   
   if(inMainSession) return true;
   
   // Check Asian session
   if(m_allowAsian) {
      int asianStart = 23 * 60; // 23:00
      int asianEnd = 8 * 60;    // 08:00
      
      if(now >= asianStart || now <= asianEnd) return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Get Minutes Since Last Trade                                      |
//+------------------------------------------------------------------+
int CQualityFilters::GetMinutesSinceLastTrade() {
   if(m_lastTradeTime == 0) return 9999;
   return (int)((TimeCurrent() - m_lastTradeTime) / 60);
}

//+------------------------------------------------------------------+
//| Update Daily Stats                                                |
//+------------------------------------------------------------------+
void CQualityFilters::UpdateDailyStats() {
   // Check for new day
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   
   if(today != m_dayStart) {
      ResetDailyStats();
      m_dayStart = today;
   }
   
   // Calculate daily P&L from history
   m_dailyPnL = 0;
   
   if(!HistorySelect(m_dayStart, TimeCurrent())) return;
   
   for(int i = 0; i < HistoryDealsTotal(); i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0 && HistoryDealGetInteger(ticket, DEAL_MAGIC) == m_magic) {
         m_dailyPnL += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      }
   }
   
   // Update high water mark and drawdown
   if(m_dailyPnL > m_dailyHighWater) {
      m_dailyHighWater = m_dailyPnL;
   }
   
   double dd = m_dailyHighWater - m_dailyPnL;
   if(dd > m_dailyMaxDD) {
      m_dailyMaxDD = dd;
   }
}

//+------------------------------------------------------------------+
//| CORRECTION 1 : ResetDailyStats()                                  |
//| Fichier: GoldML_QualityFilters.mqh                                |
//| Cherche la fonction ResetDailyStats() et remplace-la par :        |
//+------------------------------------------------------------------+

void CQualityFilters::ResetDailyStats() {
   m_tradesToday = 0;
   m_dailyPnL = 0;
   m_dailyHighWater = 0;
   m_dailyMaxDD = 0;
   
   // AJOUT: Reset des compteurs consecutifs chaque jour
   m_consecutiveLosses = 0;
   m_consecutiveWins = 0;
   m_sameDirCount = 0;
   
   Print("Daily stats reset (including consecutive counters)");
}

//+------------------------------------------------------------------+
//| Check Cooldown                                                    |
//+------------------------------------------------------------------+
bool CQualityFilters::CheckCooldown() {
   if(!m_enableCooldown) return true;
   
   int minutesSince = GetMinutesSinceLastTrade();
   
   int requiredCooldown = m_cooldownMinutes;
   
   // Longer cooldown after loss
   if(!m_lastTradeWin) {
      requiredCooldown = m_cooldownAfterLoss;
   } else {
      requiredCooldown = m_cooldownAfterWin;
   }
   
   return (minutesSince >= requiredCooldown);
}

//+------------------------------------------------------------------+
//| Check Range                                                       |
//+------------------------------------------------------------------+
bool CQualityFilters::CheckRange() {
   if(!m_enableRangeFilter) return true;
   
   double ratio = GetRangeATRRatio();
   
   return (ratio >= m_minRangeATR);
}

//+------------------------------------------------------------------+
//| Check Consecutive                                                 |
//+------------------------------------------------------------------+
bool CQualityFilters::CheckConsecutive(string direction) {
   if(!m_enableConsecutive) return true;
   
   // Check consecutive losses
   if(m_consecutiveLosses >= m_maxConsecutiveLosses) {
      return false;
   }
   
   // Check consecutive wins (optional - prevent overtrading on hot streak)
   if(m_consecutiveWins >= m_maxConsecutiveWins) {
      return false;
   }
   
   // Check same direction trades
   if(direction == m_lastTradeDirection) {
      if(m_sameDirCount >= m_maxSameDirection) {
         return false;
      }
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check Same Level                                                  |
//+------------------------------------------------------------------+
bool CQualityFilters::CheckSameLevel(double price) {
   if(!m_enableSameLevelFilter) return true;
   
   return !IsSameLevel(price);
}

//+------------------------------------------------------------------+
//| Check Daily Limits                                                |
//+------------------------------------------------------------------+
bool CQualityFilters::CheckDailyLimits() {
   if(!m_enableDailyLimits) return true;
   
   UpdateDailyStats();
   
   // Check max trades
   if(m_tradesToday >= m_maxDailyTrades) {
      return false;
   }
   
   // Check max loss
   if(m_dailyPnL <= -m_maxDailyLoss) {
      return false;
   }
   
   // Check max profit (optional - lock in profits)
   if(m_dailyPnL >= m_maxDailyProfit) {
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check Session                                                     |
//+------------------------------------------------------------------+
bool CQualityFilters::CheckSession() {
   if(!m_enableSessionFilter) return true;
   
   return InTradingSession();
}

//+------------------------------------------------------------------+
//| Check Drawdown                                                    |
//+------------------------------------------------------------------+
bool CQualityFilters::CheckDrawdown() {
   if(!m_enableDailyLimits) return true;
   
   UpdateDailyStats();
   
   return (m_dailyMaxDD < m_maxDailyDD);
}

//+------------------------------------------------------------------+
//| Check Trend EMA  M15 EMA21/EMA55 directional alignment          |
//+------------------------------------------------------------------+
bool CQualityFilters::CheckTrendEMA(string direction) {
   if(!m_enableTrendFilter) return true;
   if(m_hEMA21 == INVALID_HANDLE || m_hEMA55 == INVALID_HANDLE) return true;

   double ema21[1], ema55[1];
   if(CopyBuffer(m_hEMA21, 0, 0, 1, ema21) <= 0) return true;
   if(CopyBuffer(m_hEMA55, 0, 0, 1, ema55) <= 0) return true;

   double price = SymbolInfoDouble(m_symbol, SYMBOL_BID);

   // BUY bloqu si prix < EMA21 ET EMA21 < EMA55 (downtrend confirm)
   if(direction == "BUY" && price < ema21[0] && ema21[0] < ema55[0]) {
      Print("Trend filter BLOCK BUY: price=", DoubleToString(price, 2),
            " < EMA21=", DoubleToString(ema21[0], 2),
            " < EMA55=", DoubleToString(ema55[0], 2));
      return false;
   }

   // SELL bloqu si prix > EMA21 ET EMA21 > EMA55 (uptrend confirm)
   if(direction == "SELL" && price > ema21[0] && ema21[0] > ema55[0]) {
      Print("Trend filter BLOCK SELL: price=", DoubleToString(price, 2),
            " > EMA21=", DoubleToString(ema21[0], 2),
            " > EMA55=", DoubleToString(ema55[0], 2));
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check All Filters                                                 |
//+------------------------------------------------------------------+
FilterResult CQualityFilters::CheckAllFilters(string direction, double entryPrice, string timingMode = "CLEAR") {
   FilterResult result;
   result.passed = false;
   result.blockReason = "";
   result.details = "";
   
   UpdateDailyStats();
   
   // Individual checks
   result.cooldownOK = CheckCooldown();
   result.rangeOK = CheckRange();
   result.consecutiveOK = CheckConsecutive(direction);
   result.sameLevelOK = CheckSameLevel(entryPrice);
   result.dailyLimitOK = CheckDailyLimits();
   result.sessionOK = CheckSession();
   result.drawdownOK = CheckDrawdown();
   // FIX C-6.1 (2026-04-03): EMA filter désactivé en POST_NEWS
   // Le mode POST_NEWS est un fade trade (contre-tendance par design)
   if(timingMode == "POST_NEWS_ENTRY") {
      result.trendOK = true;  // Fade autorisé — contre-tendance intentionnelle
   } else {
      result.trendOK = CheckTrendEMA(direction);
   }

   // Metrics
   result.minutesSinceLastTrade = GetMinutesSinceLastTrade();
   result.currentATR = GetATR();
   result.rangeATR_Ratio = GetRangeATRRatio();
   result.consecutiveLosses = m_consecutiveLosses;
   result.consecutiveWins = m_consecutiveWins;
   result.sameDirTrades = m_sameDirCount;
   result.dailyPnL = m_dailyPnL;
   result.dailyMaxDD = m_dailyMaxDD;
   
   // Determine block reason
   if(!result.sessionOK) {
      result.blockReason = "Outside trading session";
   }
   else if(!result.dailyLimitOK) {
      if(m_tradesToday >= m_maxDailyTrades) {
         result.blockReason = "Max daily trades reached (" + IntegerToString(m_tradesToday) + ")";
      }
      else if(m_dailyPnL <= -m_maxDailyLoss) {
         result.blockReason = "Max daily loss reached (" + DoubleToString(m_dailyPnL, 0) + ")";
      }
      else if(m_dailyPnL >= m_maxDailyProfit) {
         result.blockReason = "Daily profit target reached (" + DoubleToString(m_dailyPnL, 0) + ")";
      }
   }
   else if(!result.drawdownOK) {
      result.blockReason = "Max daily drawdown reached (" + DoubleToString(m_dailyMaxDD, 0) + ")";
   }
   else if(!result.cooldownOK) {
      int required = m_lastTradeWin ? m_cooldownAfterWin : m_cooldownAfterLoss;
      result.blockReason = "Cooldown active (" + IntegerToString(result.minutesSinceLastTrade) + 
                           "/" + IntegerToString(required) + " min)";
   }
   else if(!result.consecutiveOK) {
      if(m_consecutiveLosses >= m_maxConsecutiveLosses) {
         result.blockReason = "Max consecutive losses (" + IntegerToString(m_consecutiveLosses) + ")";
      }
      else if(m_sameDirCount >= m_maxSameDirection) {
         result.blockReason = "Max same direction trades (" + IntegerToString(m_sameDirCount) + " " + m_lastTradeDirection + ")";
      }
      else {
         result.blockReason = "Max consecutive wins (" + IntegerToString(m_consecutiveWins) + ")";
      }
   }
   else if(!result.rangeOK) {
      result.blockReason = "Range market (" + DoubleToString(result.rangeATR_Ratio, 1) + "x ATR < " + DoubleToString(m_minRangeATR, 1) + ")";
   }
   else if(!result.sameLevelOK) {
      result.blockReason = "Same level as recent trade";
   }
   else if(!result.trendOK) {
      result.blockReason = "EMA trend filter: " + direction + " against M15 EMA21/EMA55";
   }
   
   // Check if all passed
   result.passed = result.cooldownOK && result.rangeOK && result.consecutiveOK &&
                   result.sameLevelOK && result.dailyLimitOK && result.sessionOK &&
                   result.drawdownOK && result.trendOK;
   
   // Build details
   result.details = "CD:" + (result.cooldownOK ? "OK" : "XX") +
                    " RNG:" + (result.rangeOK ? "OK" : "XX") +
                    " CON:" + (result.consecutiveOK ? "OK" : "XX") +
                    " LVL:" + (result.sameLevelOK ? "OK" : "XX") +
                    " DAY:" + (result.dailyLimitOK ? "OK" : "XX") +
                    " SES:" + (result.sessionOK ? "OK" : "XX") +
                    " TRD:" + (result.trendOK ? "OK" : "XX");
   
   return result;
}

//+------------------------------------------------------------------+
//| Record Trade Open                                                 |
//+------------------------------------------------------------------+
void CQualityFilters::RecordTradeOpen(ulong ticket, string direction, double entryPrice) {
   m_lastTradeTime = TimeCurrent();
   m_lastTradeEntry = entryPrice;
   
   if(direction == m_lastTradeDirection) {
      m_sameDirCount++;
   } else {
      m_sameDirCount = 1;
      m_lastTradeDirection = direction;
   }
   
   m_tradesToday++;
   
   Print("Trade recorded: ", direction, " @ ", entryPrice, 
         " | Same dir: ", m_sameDirCount, " | Today: ", m_tradesToday);
}

//+------------------------------------------------------------------+
//| Record Trade Close                                                |
//+------------------------------------------------------------------+
void CQualityFilters::RecordTradeClose(ulong ticket, double profit, double closePrice) {
   // Add to recent trades
   int size = ArraySize(m_recentTrades);
   
   if(size >= m_maxTradeHistory) {
      // Remove oldest
      for(int i = 0; i < size - 1; i++) {
         m_recentTrades[i] = m_recentTrades[i + 1];
      }
      size = m_maxTradeHistory - 1;
   }
   
   ArrayResize(m_recentTrades, size + 1);
   m_recentTrades[size].ticket = ticket;
   m_recentTrades[size].closeTime = TimeCurrent();
   m_recentTrades[size].profit = profit;
   m_recentTrades[size].direction = m_lastTradeDirection;
   m_recentTrades[size].entryPrice = m_lastTradeEntry;
   m_recentTrades[size].closePrice = closePrice;
   m_recentTrades[size].isWin = (profit > 0);
   
   // Update consecutive tracking
   if(profit > 0) {
      RecordWin();
   } else {
      RecordLoss();
   }
   
   m_lastTradeTime = TimeCurrent();
}

//+------------------------------------------------------------------+
//| Record Loss                                                       |
//+------------------------------------------------------------------+
void CQualityFilters::RecordLoss() {
   m_lastTradeWin = false;
   m_consecutiveLosses++;
   m_consecutiveWins = 0;
   
   Print("Loss recorded | Consecutive losses: ", m_consecutiveLosses);
}

//+------------------------------------------------------------------+
//| Record Win                                                        |
//+------------------------------------------------------------------+
void CQualityFilters::RecordWin() {
   m_lastTradeWin = true;
   m_consecutiveWins++;
   m_consecutiveLosses = 0;
   
   Print("Win recorded | Consecutive wins: ", m_consecutiveWins);
}

//+------------------------------------------------------------------+
//| Reset Consecutive                                                 |
//+------------------------------------------------------------------+
void CQualityFilters::ResetConsecutive() {
   m_consecutiveLosses = 0;
   m_consecutiveWins = 0;
   m_sameDirCount = 0;
   Print("Consecutive counters reset");
}

//+------------------------------------------------------------------+
//| Reset Daily                                                       |
//+------------------------------------------------------------------+
void CQualityFilters::ResetDaily() {
   ResetDailyStats();
   m_dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
}

//+------------------------------------------------------------------+
//| Print Status                                                      |
//+------------------------------------------------------------------+
void CQualityFilters::PrintStatus() {
   UpdateDailyStats();
   
   Print("");
   Print("              QUALITY FILTERS STATUS                      ");
   Print("");
   Print("  Last trade: ", GetMinutesSinceLastTrade(), " min ago");
   Print("  Last result: ", m_lastTradeWin ? "WIN" : "LOSS");
   Print("  Consecutive losses: ", m_consecutiveLosses, "/", m_maxConsecutiveLosses);
   Print("  Consecutive wins: ", m_consecutiveWins, "/", m_maxConsecutiveWins);
   Print("  Same direction: ", m_sameDirCount, " ", m_lastTradeDirection);
   Print("");
   Print("  Trades today: ", m_tradesToday, "/", m_maxDailyTrades);
   Print(" Daily P&L: ", DoubleToString(m_dailyPnL, 2));
   Print(" Daily max DD: ", DoubleToString(m_dailyMaxDD, 2));
   Print("  Range/ATR: ", DoubleToString(GetRangeATRRatio(), 2));
   Print("  Session: ", InTradingSession() ? "ACTIVE" : "CLOSED");
   Print("");
}

//+------------------------------------------------------------------+
//| Get Filter Summary                                                |
//+------------------------------------------------------------------+
string CQualityFilters::GetFilterSummary() {
   return "T:" + IntegerToString(m_tradesToday) + "/" + IntegerToString(m_maxDailyTrades) +
          " L:" + IntegerToString(m_consecutiveLosses) +
          " CD:" + IntegerToString(GetMinutesSinceLastTrade()) + "m";
}
//+------------------------------------------------------------------+