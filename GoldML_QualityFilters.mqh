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
   double   m_maxDailyDD;
   
   // Settings - Session
   bool     m_enableSessionFilter;
   string   m_sessionStart;
   string   m_sessionEnd;
   bool     m_allowAsian;
   
   // Settings - Trend (H4 structure)
   bool     m_enableTrendFilter;

   // Option E D.E.A.L. - H4 scoring
   bool     m_enableDEAL;      // Option E activée
   int      m_lastH4Score;     // Dernier score H4 calculé
   double   m_h4SizeFactor;    // DEAL v2: size factor H4 (0.0=blocked, 0.35-1.0)

   // P2 Veto H4 structurel (2026-04-22) — bloque BUY vs H4 BEARISH (LH+LL) et
   // SELL vs H4 BULLISH (HH+HL) independamment du score DEAL-v2.
   bool     m_enableH4HardVeto;
   bool     m_lastH4IsHardCounter;  // true si derniere eval H4 = contre-structure forte

   // P3 DEAL-v2 reject threshold (2026-04-22) — remplace le blocage hardcode
   // a -25 par un seuil configurable (defaut -20). Scores > threshold gardent
   // leur comportement de modulation via m_h4SizeFactor.
   int      m_dealRejectThreshold;

   // PR serie 3 (2026-04-22) — tag du dernier motif de blocage dans CheckTrendH4.
   // Valeurs : "" (pas bloque), "H4-VETO" (P2), "DEAL-v2-REJECT" (P3).
   // Utilise par l EA pour declencher les alertes SELL opportunity.
   string   m_lastH4BlockReason;

   // Indicator handles
   int      m_hATR;
   
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
   // IMPROVE 3 (2026-04-03): Structure H4 au lieu de EMA retail
   // Option E DEAL: scoring -25/+25 remplace blocage binaire
   int      GetH4ScoreContribution(string direction, double apiConfidence);
   bool     CheckTrendH4(string direction, double apiConfidence = 60.0);

public:
   CQualityFilters(string symbol, int magic);
   ~CQualityFilters();
   
   // Initialization
   bool Initialize(bool enableCooldown = true,
                   int cooldownMinutes = 30,
                   int cooldownAfterLoss = 30,
                   bool enableRange = true,
                   double minRangeATR = 0.5,
                   int rangeLookback = 12,
                   bool enableConsecutive = true,
                   int maxConsecutiveLosses = 4,
                   int maxConsecutiveWins = 10,  // FIX M3 (2026-04-03): 5->10 ne pas bloquer en tendance forte
                   int maxSameDirection = 5,
                   bool enableSameLevel = true,
                   double sameLevelPips = 30,
                   int sameLevelLookback = 5,
                   bool enableDailyLimits = true,
                   int maxDailyTrades = 6,
                   double maxDailyLoss = 400,
                   double maxDailyDD = 300,
                   bool enableSession = true,
                   string sessionStart = "07:00",
                   string sessionEnd = "18:00",
                   bool allowAsian = false,
                   bool enableTrendFilter = true,
                   bool enableH4HardVeto = true,
                   int dealRejectThreshold = -20);
   
   // Main filter check
   // FIX C-6.1 (2026-04-03): timingMode ajouté pour désactiver EMA en POST_NEWS
   // Option E DEAL: apiConfidence ajouté pour scoring H4
   FilterResult CheckAllFilters(string direction, double entryPrice, string timingMode = "CLEAR", double apiConfidence = 60.0);
   
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
   
   // Option E D.E.A.L. getters
   int GetLastH4Score() { return m_lastH4Score; }
   bool IsEnableDEAL()  { return m_enableDEAL; }
   double GetH4SizeFactor() { return m_h4SizeFactor; }

   // P2 Veto H4 structurel (2026-04-22)
   bool IsLastH4HardCounter() { return m_lastH4IsHardCounter; }
   bool IsH4HardVetoEnabled() { return m_enableH4HardVeto; }

   // P3 DEAL-v2 reject threshold (2026-04-22)
   int GetDealRejectThreshold() { return m_dealRejectThreshold; }

   // PR serie 3 (2026-04-22) — motif de blocage H4 pour alertes SELL opportunity
   string GetLastH4BlockReason() { return m_lastH4BlockReason; }

   // Diagnostic helper (Log A) : expose le test de session sans le filtre on/off
   bool IsInSession() { return InTradingSession(); }

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
   m_enableDEAL = true;   // Option E activé directement
   m_lastH4Score = 0;
   m_h4SizeFactor = 1.0;  // DEAL v2: défaut taille normale
   m_enableH4HardVeto = true;       // P2 (2026-04-22): veto structurel actif par defaut
   m_lastH4IsHardCounter = false;
   m_dealRejectThreshold = -20;     // P3 (2026-04-22): seuil de rejet DEAL-v2 (defaut -20)
   m_lastH4BlockReason = "";        // PR serie 3: tag motif blocage H4 (P2/P3)

   ArrayResize(m_recentTrades, 0);
}

//+------------------------------------------------------------------+
//| Destructor                                                        |
//+------------------------------------------------------------------+
CQualityFilters::~CQualityFilters() {
   if(m_hATR != INVALID_HANDLE) IndicatorRelease(m_hATR);
}

//+------------------------------------------------------------------+
//| Initialize                                                        |
//+------------------------------------------------------------------+
bool CQualityFilters::Initialize(bool enableCooldown, int cooldownMinutes,
                                  int cooldownAfterLoss,
                                  bool enableRange, double minRangeATR, int rangeLookback,
                                  bool enableConsecutive, int maxConsecutiveLosses,
                                  int maxConsecutiveWins, int maxSameDirection,
                                  bool enableSameLevel, double sameLevelPips, int sameLevelLookback,
                                  bool enableDailyLimits, int maxDailyTrades,
                                  double maxDailyLoss, double maxDailyDD,
                                  bool enableSession, string sessionStart, string sessionEnd,
                                  bool allowAsian,
                                  bool enableTrendFilter,
                                  bool enableH4HardVeto,
                                  int dealRejectThreshold) {
   
   m_enableCooldown = enableCooldown;
   m_cooldownMinutes = cooldownMinutes;
   m_cooldownAfterLoss = cooldownAfterLoss;
   
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
   m_maxDailyDD = maxDailyDD;
   
   m_enableSessionFilter = enableSession;
   m_sessionStart = sessionStart;
   m_sessionEnd = sessionEnd;
   m_allowAsian = allowAsian;

   m_enableTrendFilter = enableTrendFilter;

   m_enableH4HardVeto = enableH4HardVeto;
   m_lastH4IsHardCounter = false;

   m_dealRejectThreshold = dealRejectThreshold;

   m_hATR = iATR(m_symbol, PERIOD_M15, 14);

   if(m_hATR == INVALID_HANDLE) {
      Print("Quality Filters: Failed to create ATR indicator");
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
   Print("  H4 Hard Veto (P2): ", m_enableH4HardVeto ? "ON" : "OFF",
         " (bloque BUY vs BEARISH_LH_LL / SELL vs BULLISH_HH_HL)");
   Print("  DEAL-v2 Reject Threshold (P3): ", m_dealRejectThreshold,
         " (score <= threshold -> REJECT)");
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
   // FIX TIMEZONE FINAL (2026-04-05): TimeGMT() au lieu de TimeCurrent()
   // Session_Start='07:00' et Session_End='18:00' sont documentes en GMT
   // TimeCurrent() = heure serveur MT5 (UTC+2/+3 chez FTMO) -> decalage 2-3h
   // TimeGMT() = heure GMT reelle -> coherent avec Sniper, LocalSignal et VPS
   TimeToStruct(TimeGMT(), t);
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

   // IMPROVE 4 (2026-04-03): Suppression cooldown after win
   // En tendance forte post-news, le cooldown after win bloque des trades valides
   // Seul le cooldown after LOSS est conserve pour la protection psychologique
   if(!m_lastTradeWin) {
      requiredCooldown = m_cooldownAfterLoss;
   } else {
      requiredCooldown = 0; // Pas de cooldown apres un trade gagnant
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
   // REMOVED: redondant avec FTMO DD check 4.5% dans EA (CheckFTMOLimits)
   // Le triple check DD (QF 300$ + QF 400$ + EA 4.5%) bloquait trop tot
   // La protection DD est assuree par CheckFTMOLimits() qui calcule le DD reel
   return true;
}

//+------------------------------------------------------------------+
//| Option E D.E.A.L. — Scoring H4 (-25/+25 pts)                   |
//| Remplace le blocage binaire par un scoring integre au Sniper    |
//+------------------------------------------------------------------+
int CQualityFilters::GetH4ScoreContribution(string direction, double apiConfidence) {
   // P2 (2026-04-22): reset du flag a chaque evaluation pour eviter etat herite
   m_lastH4IsHardCounter = false;

   double h4High[], h4Low[];
   ArraySetAsSeries(h4High, true);
   ArraySetAsSeries(h4Low, true);

   if(CopyHigh(m_symbol, PERIOD_H4, 1, 50, h4High) < 10) { m_h4SizeFactor = 1.0; return 0; }
   if(CopyLow(m_symbol,  PERIOD_H4, 1, 50, h4Low)  < 10) { m_h4SizeFactor = 1.0; return 0; }

   double swH[3], swL[3];
   int shC = 0, slC = 0;

   for(int i = 3; i < 47 && (shC < 3 || slC < 3); i++) {
      if(shC < 3 &&
         h4High[i] > h4High[i-1] && h4High[i] > h4High[i-2] &&
         h4High[i] > h4High[i+1] && h4High[i] > h4High[i+2])
         swH[shC++] = h4High[i];
      if(slC < 3 &&
         h4Low[i] < h4Low[i-1]  && h4Low[i] < h4Low[i-2] &&
         h4Low[i] < h4Low[i+1]  && h4Low[i] < h4Low[i+2])
         swL[slC++] = h4Low[i];
   }

   if(shC < 2 || slC < 2) { m_h4SizeFactor = 1.0; return 0; }

   // DEAL v2: 4 etats H4 — aligne / ranging / contre leger / contre fort
   bool hhDetected = (swH[0] > swH[1]);  // Higher High
   bool hlDetected = (swL[0] > swL[1]);  // Higher Low
   bool lhDetected = (swH[0] < swH[1]);  // Lower High
   bool llDetected = (swL[0] < swL[1]);  // Lower Low

   bool h4Bullish     = (hhDetected && hlDetected);  // HH+HL = tendance haussiere
   bool h4Bearish     = (lhDetected && llDetected);  // LH+LL = tendance baissiere
   bool h4ContraLight = (lhDetected != llDetected);  // 1 seul critere casse

   int score = 0;

   if(direction == "BUY") {
      if(h4Bullish) {
         score = 25; m_h4SizeFactor = 1.0;
         Print("[DEAL-v2] H4 BULLISH (HH+HL) -> +25 pts | size 100%");
      }
      else if(!h4Bearish && !h4ContraLight) {
         // RANGING (HH+LL ou LH+HL = ni trend ni contre clair)
         if(apiConfidence >= 70.0)      { score = 10;  m_h4SizeFactor = 0.85; Print("[DEAL-v2] H4 RANGING + API>=70% -> +10 | size 85%"); }
         else if(apiConfidence >= 60.0) { score =  0;  m_h4SizeFactor = 0.70; Print("[DEAL-v2] H4 RANGING + API 60-70% -> 0 | size 70%"); }
         else                           { score = -10; m_h4SizeFactor = 0.50; Print("[DEAL-v2] H4 RANGING + API<60% -> -10 | size 50%"); }
      }
      else if(h4ContraLight) {
         // CONTRE LEGER: LH seul OU LL seul (pas les deux)
         if(apiConfidence >= 70.0)      { score = -5;  m_h4SizeFactor = 0.65; Print("[DEAL-v2] H4 CONTRA-LIGHT + API>=70% -> -5 | size 65%"); }
         else if(apiConfidence >= 60.0) { score = -15; m_h4SizeFactor = 0.50; Print("[DEAL-v2] H4 CONTRA-LIGHT + API 60-70% -> -15 | size 50%"); }
         else                           { score = -25; m_h4SizeFactor = 0.0;  Print("[DEAL-v2] H4 CONTRA-LIGHT + API<60% -> -25 | BLOCKED"); }
      }
      else if(h4Bearish) {
         // CONTRE FORT: LH+LL confirmes
         m_lastH4IsHardCounter = true;  // P2: flag pour veto structurel dans CheckTrendH4
         if(apiConfidence >= 70.0)      { score = -10; m_h4SizeFactor = 0.50; Print("[DEAL-v2] H4 BEARISH (LH+LL) + API>=70% -> -10 | size 50%"); }
         else if(apiConfidence >= 60.0) { score = -20; m_h4SizeFactor = 0.35; Print("[DEAL-v2] H4 BEARISH (LH+LL) + API 60-70% -> -20 | size 35%"); }
         else                           { score = -25; m_h4SizeFactor = 0.0;  Print("[DEAL-v2] H4 BEARISH (LH+LL) + API<60% -> -25 | BLOCKED"); }
      }
   }
   else if(direction == "SELL") {
      if(h4Bearish) {
         score = 25; m_h4SizeFactor = 1.0;
         Print("[DEAL-v2] H4 BEARISH (LH+LL) -> +25 pts | size 100%");
      }
      else if(!h4Bullish && !h4ContraLight) {
         if(apiConfidence >= 70.0)      { score = 10;  m_h4SizeFactor = 0.85; Print("[DEAL-v2] H4 RANGING + API>=70% -> +10 | size 85%"); }
         else if(apiConfidence >= 60.0) { score =  0;  m_h4SizeFactor = 0.70; Print("[DEAL-v2] H4 RANGING + API 60-70% -> 0 | size 70%"); }
         else                           { score = -10; m_h4SizeFactor = 0.50; Print("[DEAL-v2] H4 RANGING + API<60% -> -10 | size 50%"); }
      }
      else if(h4ContraLight) {
         if(apiConfidence >= 70.0)      { score = -5;  m_h4SizeFactor = 0.65; Print("[DEAL-v2] H4 CONTRA-LIGHT + API>=70% -> -5 | size 65%"); }
         else if(apiConfidence >= 60.0) { score = -15; m_h4SizeFactor = 0.50; Print("[DEAL-v2] H4 CONTRA-LIGHT + API 60-70% -> -15 | size 50%"); }
         else                           { score = -25; m_h4SizeFactor = 0.0;  Print("[DEAL-v2] H4 CONTRA-LIGHT + API<60% -> -25 | BLOCKED"); }
      }
      else if(h4Bullish) {
         m_lastH4IsHardCounter = true;  // P2 symetrie: flag pour veto SELL vs H4 BULLISH
         if(apiConfidence >= 70.0)      { score = -10; m_h4SizeFactor = 0.50; Print("[DEAL-v2] H4 BULLISH (HH+HL) + API>=70% -> -10 | size 50%"); }
         else if(apiConfidence >= 60.0) { score = -20; m_h4SizeFactor = 0.35; Print("[DEAL-v2] H4 BULLISH (HH+HL) + API 60-70% -> -20 | size 35%"); }
         else                           { score = -25; m_h4SizeFactor = 0.0;  Print("[DEAL-v2] H4 BULLISH (HH+HL) + API<60% -> -25 | BLOCKED"); }
      }
   }

   m_lastH4Score = score;
   return score;
}

//+------------------------------------------------------------------+
//| IMPROVE 3 (2026-04-03): Structure HTF H4 au lieu de EMA retail  |
//| Option E DEAL: scoring remplace blocage binaire                 |
//+------------------------------------------------------------------+
bool CQualityFilters::CheckTrendH4(string direction, double apiConfidence) {
   if(!m_enableTrendFilter) return true;

   if(!m_enableDEAL) {
      // Comportement original conservé quand DEAL désactivé
      double high[], low[];
      ArraySetAsSeries(high, true);
      ArraySetAsSeries(low, true);

      if(CopyHigh(m_symbol, PERIOD_H4, 1, 50, high) < 50) return true;
      if(CopyLow(m_symbol, PERIOD_H4, 1, 50, low) < 50) return true;

      double swingHighs[3], swingLows[3];
      int shCount = 0, slCount = 0;

      for(int i = 3; i < 47 && (shCount < 3 || slCount < 3); i++) {
         if(shCount < 3 &&
            high[i] > high[i-1] && high[i] > high[i-2] && high[i] > high[i+1] && high[i] > high[i+2]) {
            swingHighs[shCount++] = high[i];
         }
         if(slCount < 3 &&
            low[i] < low[i-1] && low[i] < low[i-2] && low[i] < low[i+1] && low[i] < low[i+2]) {
            swingLows[slCount++] = low[i];
         }
      }

      if(shCount < 2 || slCount < 2) return true;

      bool h4Bullish = (swingHighs[0] > swingHighs[1] && swingLows[0] > swingLows[1]);
      bool h4Bearish = (swingHighs[0] < swingHighs[1] && swingLows[0] < swingLows[1]);

      if(direction == "BUY" && h4Bearish) {
         Print("H4 structure BLOCK BUY: Lower Highs + Lower Lows on H4");
         return false;
      }
      if(direction == "SELL" && h4Bullish) {
         Print("H4 structure BLOCK SELL: Higher Highs + Higher Lows on H4");
         return false;
      }
      return true;
   }

   // Option E activée : calculer le score, jamais bloquer sauf cas extrême
   int h4Score = GetH4ScoreContribution(direction, apiConfidence);

   // PR serie 3 (2026-04-22): reset du tag motif a chaque evaluation
   m_lastH4BlockReason = "";

   // P2 Veto H4 structurel (2026-04-22) — blocage AVANT seuil de score.
   // Cible : BUY vs H4 BEARISH (LH+LL) ou SELL vs H4 BULLISH (HH+HL).
   // H4 CONTRA-LIGHT (1 critere seul) n'est pas impacte.
   if(m_enableH4HardVeto && m_lastH4IsHardCounter) {
      string counterStruct = (direction == "BUY") ? "BEARISH LH+LL" : "BULLISH HH+HL";
      Print("[H4-VETO] ", direction, " bloque: H4 contre-structure forte (",
            counterStruct, ") | score calcule=", h4Score,
            " ignore (veto structurel independant du score DEAL)");
      m_lastH4BlockReason = "H4-VETO";
      return false;
   }

   // P3 DEAL-v2 reject threshold (2026-04-22) — remplace le blocage hardcode a -25.
   // Defaut -20 : bloque les cas "H4 contre + API 60-70%" (score -20) en plus
   // de l ancien cas "H4 contre + API<60%" (score -25, deja bloque).
   // Rollback safety : DEAL_Reject_Threshold = -99 -> seuil jamais atteint.
   // Interaction P2 : ce check n est atteint que si P2 n a pas bloque (return plus haut).
   if(h4Score <= m_dealRejectThreshold) {
      Print("[DEAL-v2-REJECT] score=", h4Score, " <= threshold=", m_dealRejectThreshold,
            " | direction=", direction, " | sizeFactor=", DoubleToString(m_h4SizeFactor, 2),
            " ignore, trade bloque");
      m_lastH4BlockReason = "DEAL-v2-REJECT";
      return false;
   }

   Print("[DEAL-v2] H4 score=", h4Score, " | sizeFactor=", DoubleToString(m_h4SizeFactor, 2), " -> passage autorise");
   return true;
}

//+------------------------------------------------------------------+
//| Check All Filters                                                 |
//+------------------------------------------------------------------+
FilterResult CQualityFilters::CheckAllFilters(string direction, double entryPrice, string timingMode = "CLEAR", double apiConfidence = 60.0) {
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
   // IMPROVE 3 (2026-04-03): Structure H4 au lieu de EMA retail
   // Le mode POST_NEWS est un fade trade (contre-tendance par design)
   if(timingMode == "POST_NEWS_ENTRY") {
      result.trendOK = true;  // Fade autorise — contre-tendance intentionnelle
      // B3 Fix (2026-04-14): POST_NEWS bypass H4 -> neutraliser DEAL v2 pour eviter
      // un m_h4SizeFactor stale (potentiellement 0.0) herite d'un appel precedent.
      m_h4SizeFactor = 1.0;
      m_lastH4Score  = 0;
      m_lastH4IsHardCounter = false;  // P2: aussi reset le flag veto en bypass POST_NEWS
      Print("[POST_NEWS] H4 bypassed -> sizeFactor=1.0");
   } else {
      result.trendOK = CheckTrendH4(direction, apiConfidence);
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
   }
   else if(!result.drawdownOK) {
      result.blockReason = "Max daily drawdown reached (" + DoubleToString(m_dailyMaxDD, 0) + ")";
   }
   else if(!result.cooldownOK) {
      int required = m_lastTradeWin ? 0 : m_cooldownAfterLoss;
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
      result.blockReason = "H4 structure filter: " + direction + " against H4 trend (HH/HL or LH/LL)";
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