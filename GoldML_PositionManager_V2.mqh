//+------------------------------------------------------------------+
//|                   GoldML_PositionManager_V2.mqh                  |
//|              PROFESSIONAL POSITION MANAGEMENT SYSTEM             |
//|                    Gold ML Trading System v2.0                   |
//|         Partial TP â†’ Breakeven â†’ Structure Trailing â†’ Exit       |
//+------------------------------------------------------------------+
#property copyright "Gold ML System - Institutional Grade"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| POSITION STATE ENUM                                              |
//+------------------------------------------------------------------+
enum ENUM_POSITION_STATE {
   STATE_NEW,           // Just opened
   STATE_ACTIVE,        // Normal management
   STATE_PARTIAL_DONE,  // Partial TP executed
   STATE_BREAKEVEN,     // SL at breakeven
   STATE_TRAILING,      // Trailing active
   STATE_CLOSING        // About to close
};

//+------------------------------------------------------------------+
//| EXIT REASON ENUM                                                 |
//+------------------------------------------------------------------+
enum ENUM_EXIT_REASON {
   EXIT_TP_FULL,        // Full TP hit
   EXIT_TP_PARTIAL,     // Partial TP
   EXIT_SL,             // Stop loss hit
   EXIT_BREAKEVEN,      // Closed at breakeven
   EXIT_TRAILING,       // Trailing stop hit
   EXIT_BOS_AGAINST,    // BOS against position
   EXIT_STRUCTURE,      // Structure break
   EXIT_CONVICTION,     // Low conviction
   EXIT_MANUAL,         // Manual close
   EXIT_TIME,           // Time-based exit
   EXIT_NEWS,           // News protection
   EXIT_UNKNOWN         // Unknown reason
};

//+------------------------------------------------------------------+
//| POSITION INFO STRUCTURE                                          |
//+------------------------------------------------------------------+
struct PositionInfoV2 {
   ulong    ticket;
   string   symbol;
   double   entryPrice;
   double   currentPrice;
   double   originalSL;
   double   currentSL;
   double   originalTP;
   double   currentTP;
   double   originalLots;
   double   currentLots;
   double   profit;
   double   profitPips;
   double   riskPips;
   double   currentRR;        // Current R multiple
   double   progressToTP;     // 0-100%
   bool     isBuy;
   string   direction;
   string   tradeType;        // SCALP/HIGH/SLAM
   datetime openTime;
   int      barsOpen;
   
   // State tracking
   ENUM_POSITION_STATE state;
   bool     partialDone;
   double   partialProfit;
   double   partialLots;
   bool     beActivated;
   int      trailUpdates;
   double   maxProfit;        // Max profit reached
   double   maxRR;            // Max R:R reached
};

//+------------------------------------------------------------------+
//| TRAILING INFO STRUCTURE                                          |
//+------------------------------------------------------------------+
struct TrailingInfo {
   bool     active;
   double   currentLevel;     // Current trailing SL
   double   lastSwingLevel;   // Last structure level
   string   trailType;        // ATR or STRUCTURE
   int      updateCount;
   datetime lastUpdate;
};

//+------------------------------------------------------------------+
//| POSITION MANAGER CLASS                                           |
//+------------------------------------------------------------------+
class CPositionManagerV2 {
private:
   string   m_symbol;
   int      m_magic;
   CTrade   m_trade;
   
   // Settings - Partial TP
   bool     m_enablePartial;
   double   m_partialPercent;
   double   m_partialAtRR;
   bool     m_moveToBreakeven;
   double   m_beBuffer;
   
   // Settings - Trailing
   bool     m_enableTrailing;
   bool     m_trailByStructure;
   double   m_trailATR_Mult;
   double   m_trailMinProfit;
   int      m_swingLookback;
   
   // Settings - Exit conditions
   bool     m_exitOnBOS;
   double   m_minConviction;
   // FIX N4 (2026-04-03): m_exitBeforeNews supprimé (redondant avec newsBlackout)
   int      m_maxBarsOpen;
   double   m_emergencyLockRR;
   
   // Settings - Progressive trailing
   double   m_trailMult90;
   double   m_trailMult70;
   double   m_trailMult50;
   double   m_trailMult30;
   
   // Indicator handles
   int      m_hATR;
   
   // Current position info
   PositionInfoV2 m_position;
   TrailingInfo m_trailing;
   
   // State
   bool     m_initialized;
   bool     m_hasPosition;
   
   // Private methods
   void     UpdatePositionInfo();
   double   GetCurrentSwingLow();
   double   GetCurrentSwingHigh();
   double   GetATR();
   bool     IsSwingHigh(int bar);
   bool     IsSwingLow(int bar);
   double   CalculateTrailLevel();
   double   GetProgressiveMultiplier();
   bool     IsBOSAgainstPosition();
   
public:
   CPositionManagerV2(string symbol, int magic);
   ~CPositionManagerV2();
   
   // Initialization
   bool Initialize(bool enablePartial = true,
                   double partialPercent = 50.0,
                   double partialAtRR = 1.0,
                   bool moveToBreakeven = true,
                   double beBuffer = 5.0,
                   bool enableTrailing = true,
                   bool trailByStructure = true,
                   double trailATRMult = 1.5,
                   double trailMinProfit = 0.5,
                   int swingLookback = 5,
                   bool exitOnBOS = true,
                   double minConviction = 3.0,
                   int maxBarsOpen = 200,
                   double emergencyLockRR = 0.5,
                   double trailMult90 = 0.3,
                   double trailMult70 = 0.5,
                   double trailMult50 = 0.7,
                   double trailMult30 = 0.85);
   
   // Position tracking
   bool LoadPosition(ulong ticket, string tradeType);
   void UnloadPosition();
   bool HasPosition() { return m_hasPosition; }
   PositionInfoV2 GetPositionInfo() { return m_position; }
   
   // Main management
   ENUM_EXIT_REASON ManagePosition(double currentConviction = 10.0, bool newsBlackout = false);
   
   // Specific actions
   bool ExecutePartialTP();
   bool MoveToBreakeven();
   bool UpdateTrailingStop();
   bool ClosePosition(string reason);
   
   // Getters
   bool IsPartialDone() { return m_position.partialDone; }
   bool IsBreakevenActive() { return m_position.beActivated; }
   double GetCurrentRR() { return m_position.currentRR; }
   double GetProgress() { return m_position.progressToTP; }
   ENUM_POSITION_STATE GetState() { return m_position.state; }

   // FIX C-2.1 (2026-04-03): Setter pour restaurer l'état partial après crash recovery
   void SetPartialDone(bool done) { m_position.partialDone = done; Print("[PosMgr] SetPartialDone: ", done); }

   // Utilities
   void PrintPositionStatus();
   string GetStateText();
   string GetExitReasonText(ENUM_EXIT_REASON reason);
};

//+------------------------------------------------------------------+
//| Constructor                                                       |
//+------------------------------------------------------------------+
CPositionManagerV2::CPositionManagerV2(string symbol, int magic) {
   m_symbol = symbol;
   m_magic = magic;
   m_initialized = false;
   m_hasPosition = false;
   
   m_hATR = INVALID_HANDLE;
   
   m_trade.SetExpertMagicNumber(magic);
   m_trade.SetDeviationInPoints(10);
}

//+------------------------------------------------------------------+
//| Destructor                                                        |
//+------------------------------------------------------------------+
CPositionManagerV2::~CPositionManagerV2() {
   if(m_hATR != INVALID_HANDLE) IndicatorRelease(m_hATR);
}

//+------------------------------------------------------------------+
//| Initialize                                                        |
//+------------------------------------------------------------------+
bool CPositionManagerV2::Initialize(bool enablePartial, double partialPercent,
                                     double partialAtRR, bool moveToBreakeven,
                                     double beBuffer, bool enableTrailing,
                                     bool trailByStructure, double trailATRMult,
                                     double trailMinProfit, int swingLookback,
                                     bool exitOnBOS, double minConviction,
                                     int maxBarsOpen, double emergencyLockRR,
                                     double trailMult90, double trailMult70,
                                     double trailMult50, double trailMult30) {
   
   m_enablePartial = enablePartial;
   m_partialPercent = partialPercent;
   m_partialAtRR = partialAtRR;
   m_moveToBreakeven = moveToBreakeven;
   m_beBuffer = beBuffer;
   m_enableTrailing = enableTrailing;
   m_trailByStructure = trailByStructure;
   m_trailATR_Mult = trailATRMult;
   m_trailMinProfit = trailMinProfit;
   m_swingLookback = swingLookback;
   m_exitOnBOS = exitOnBOS;
   m_minConviction = minConviction;
   m_maxBarsOpen = maxBarsOpen;
   m_emergencyLockRR = emergencyLockRR;
   m_trailMult90 = trailMult90;
   m_trailMult70 = trailMult70;
   m_trailMult50 = trailMult50;
   m_trailMult30 = trailMult30;
   
   m_hATR = iATR(m_symbol, PERIOD_M5, 14);
   
   if(m_hATR == INVALID_HANDLE) {
      Print("âŒ Position Manager V2: Failed to create ATR");
      return false;
   }
   
   m_initialized = true;
   
   Print("â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—");
   Print("â•‘      POSITION MANAGER V2 - INITIALIZED                    â•‘");
   Print("â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
   Print("  Partial TP: ", m_enablePartial ? "ON" : "OFF", 
         " (", m_partialPercent, "% at ", m_partialAtRR, "R)");
   Print("  Trailing: ", m_enableTrailing ? "ON" : "OFF",
         " (", m_trailByStructure ? "STRUCTURE" : "ATR", ")");
   Print("  Exit on BOS: ", m_exitOnBOS ? "YES" : "NO");
   Print("  Emergency Lock: ", m_emergencyLockRR, "R");
   Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
   
   return true;
}

//+------------------------------------------------------------------+
//| Load Position                                                     |
//+------------------------------------------------------------------+
bool CPositionManagerV2::LoadPosition(ulong ticket, string tradeType) {
   if(!PositionSelectByTicket(ticket)) {
      m_hasPosition = false;
      return false;
   }
   
   m_position.ticket = ticket;
   m_position.symbol = PositionGetString(POSITION_SYMBOL);
   m_position.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   m_position.originalSL = PositionGetDouble(POSITION_SL);
   m_position.currentSL = m_position.originalSL;
   m_position.originalTP = PositionGetDouble(POSITION_TP);
   m_position.currentTP = m_position.originalTP;
   m_position.originalLots = PositionGetDouble(POSITION_VOLUME);
   m_position.currentLots = m_position.originalLots;
   m_position.isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   m_position.direction = m_position.isBuy ? "BUY" : "SELL";
   m_position.tradeType = tradeType;
   m_position.openTime = (datetime)PositionGetInteger(POSITION_TIME);
   
   // Initialize state
   m_position.state = STATE_NEW;
   m_position.partialDone = false;
   m_position.partialProfit = 0;
   m_position.partialLots = 0;
   m_position.beActivated = false;
   m_position.trailUpdates = 0;
   m_position.maxProfit = 0;
   m_position.maxRR = 0;
   
   // Calculate risk
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   m_position.riskPips = MathAbs(m_position.entryPrice - m_position.originalSL) / (point * 10);
   
   // Initialize trailing
   m_trailing.active = false;
   m_trailing.updateCount = 0;
   m_trailing.lastUpdate = 0;
   
   m_hasPosition = true;
   
   UpdatePositionInfo();
   
   Print("âœ… Position loaded: #", ticket, " ", m_position.direction, " ", tradeType);
   
   return true;
}

//+------------------------------------------------------------------+
//| Unload Position                                                   |
//+------------------------------------------------------------------+
// FIX M-2.1 (2026-04-03): Reset complet des états internes
void CPositionManagerV2::UnloadPosition() {
   m_hasPosition = false;
   m_position.ticket = 0;
   m_position.state = STATE_NEW;
   m_position.partialDone = false;
   m_position.beActivated = false;
   m_position.trailUpdates = 0;
   m_trailing.active = false;
   Print("[PosMgr] Position déchargée — états réinitialisés");
}

//+------------------------------------------------------------------+
//| Update Position Info                                              |
//+------------------------------------------------------------------+
void CPositionManagerV2::UpdatePositionInfo() {
   if(!m_hasPosition) return;
   if(!PositionSelectByTicket(m_position.ticket)) {
      m_hasPosition = false;
      return;
   }
   
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   
   m_position.currentPrice = m_position.isBuy ? 
      SymbolInfoDouble(m_symbol, SYMBOL_BID) : 
      SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   
   m_position.currentSL = PositionGetDouble(POSITION_SL);
   m_position.currentTP = PositionGetDouble(POSITION_TP);
   m_position.currentLots = PositionGetDouble(POSITION_VOLUME);
   m_position.profit = PositionGetDouble(POSITION_PROFIT);
   
   // Calculate profit in pips
   if(m_position.isBuy) {
      m_position.profitPips = (m_position.currentPrice - m_position.entryPrice) / (point * 10);
   } else {
      m_position.profitPips = (m_position.entryPrice - m_position.currentPrice) / (point * 10);
   }
   
   // Calculate current R:R
   if(m_position.riskPips > 0) {
      m_position.currentRR = m_position.profitPips / m_position.riskPips;
   }
   
   // Track max profit/RR
   if(m_position.profit > m_position.maxProfit) {
      m_position.maxProfit = m_position.profit;
   }
   if(m_position.currentRR > m_position.maxRR) {
      m_position.maxRR = m_position.currentRR;
   }
   
   // Calculate progress to TP
   double distToTP = MathAbs(m_position.currentTP - m_position.currentPrice);
   double totalDist = MathAbs(m_position.currentTP - m_position.entryPrice);
   if(totalDist > 0) {
      m_position.progressToTP = 100.0 * (1.0 - distToTP / totalDist);
      m_position.progressToTP = MathMax(0, MathMin(100, m_position.progressToTP));
   }
   
   // Calculate bars open
   m_position.barsOpen = Bars(m_symbol, PERIOD_M5, m_position.openTime, TimeCurrent());
   
   // Update state
   if(m_position.partialDone && m_position.beActivated) {
      m_position.state = STATE_TRAILING;
   } else if(m_position.partialDone) {
      m_position.state = STATE_PARTIAL_DONE;
   } else if(m_position.beActivated) {
      m_position.state = STATE_BREAKEVEN;
   } else {
      m_position.state = STATE_ACTIVE;
   }
}

//+------------------------------------------------------------------+
//| Get ATR                                                           |
//+------------------------------------------------------------------+
double CPositionManagerV2::GetATR() {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(m_hATR, 0, 0, 3, atr) < 3) return 0;
   return atr[0];
}

//+------------------------------------------------------------------+
//| Get Current Swing Low                                             |
//+------------------------------------------------------------------+
double CPositionManagerV2::GetCurrentSwingLow() {
   double low[];
   ArraySetAsSeries(low, true);
   int bars = m_swingLookback * 3;
   
   if(CopyLow(m_symbol, PERIOD_M5, 0, bars, low) < bars) return 0;
   
   for(int i = m_swingLookback; i < bars - m_swingLookback; i++) {
      if(IsSwingLow(i)) {
         return low[i];
      }
   }
   
   return low[ArrayMinimum(low, 0, bars)];
}

//+------------------------------------------------------------------+
//| Get Current Swing High                                            |
//+------------------------------------------------------------------+
double CPositionManagerV2::GetCurrentSwingHigh() {
   double high[];
   ArraySetAsSeries(high, true);
   int bars = m_swingLookback * 3;
   
   if(CopyHigh(m_symbol, PERIOD_M5, 0, bars, high) < bars) return 0;
   
   for(int i = m_swingLookback; i < bars - m_swingLookback; i++) {
      if(IsSwingHigh(i)) {
         return high[i];
      }
   }
   
   return high[ArrayMaximum(high, 0, bars)];
}

//+------------------------------------------------------------------+
//| Is Swing High                                                     |
//+------------------------------------------------------------------+
bool CPositionManagerV2::IsSwingHigh(int bar) {
   double high[];
   ArraySetAsSeries(high, true);
   int bars = m_swingLookback * 3;
   if(CopyHigh(m_symbol, PERIOD_M5, 0, bars, high) < bars) return false;
   
   double h = high[bar];
   for(int i = 1; i <= 2; i++) {
      if(bar + i >= bars || bar - i < 0) return false;
      if(high[bar + i] >= h || high[bar - i] >= h) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Is Swing Low                                                      |
//+------------------------------------------------------------------+
bool CPositionManagerV2::IsSwingLow(int bar) {
   double low[];
   ArraySetAsSeries(low, true);
   int bars = m_swingLookback * 3;
   if(CopyLow(m_symbol, PERIOD_M5, 0, bars, low) < bars) return false;
   
   double l = low[bar];
   for(int i = 1; i <= 2; i++) {
      if(bar + i >= bars || bar - i < 0) return false;
      if(low[bar + i] <= l || low[bar - i] <= l) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Is BOS Against Position                                           |
//+------------------------------------------------------------------+
bool CPositionManagerV2::IsBOSAgainstPosition() {
   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(m_symbol, PERIOD_M5, 0, 10, close) < 10) return false;

   // FIX B1 (2026-04-05): Utiliser bougie fermee (close[1]) au lieu de close[0]
   // close[0] = bougie courante non fermee -> faux BOS sur spike intra-bougie
   // close[1] = derniere bougie fermee -> signal fiable et coherent avec le reste du systeme
   if(m_position.isBuy) {
      // For BUY: BOS is when price closes below a recent swing low
      double swingLow = GetCurrentSwingLow();
      if(swingLow > 0 && close[1] < swingLow) {
         return true;
      }
   } else {
      // For SELL: BOS is when price closes above a recent swing high
      double swingHigh = GetCurrentSwingHigh();
      if(swingHigh > 0 && close[1] > swingHigh) {
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Get Progressive Multiplier                                        |
//+------------------------------------------------------------------+
double CPositionManagerV2::GetProgressiveMultiplier() {
   double progress = m_position.progressToTP;
   
   if(progress >= 90) return m_trailMult90;
   if(progress >= 70) return m_trailMult70;
   if(progress >= 50) return m_trailMult50;
   if(progress >= 30) return m_trailMult30;
   
   return 1.0;
}

//+------------------------------------------------------------------+
//| Calculate Trail Level                                             |
//+------------------------------------------------------------------+
double CPositionManagerV2::CalculateTrailLevel() {
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   double atr = GetATR();
   double trailDist;
   
   if(m_trailByStructure) {
      // Trail by structure
      if(m_position.isBuy) {
         double swingLow = GetCurrentSwingLow();
         if(swingLow > 0 && swingLow > m_position.currentSL) {
            return swingLow - (3 * point * 10); // 3 pip buffer
         }
      } else {
         double swingHigh = GetCurrentSwingHigh();
         if(swingHigh > 0 && swingHigh < m_position.currentSL) {
            return swingHigh + (3 * point * 10); // 3 pip buffer
         }
      }
   }
   
   // Fallback to ATR-based trailing
   double mult = GetProgressiveMultiplier();
   trailDist = atr * m_trailATR_Mult * mult;
   
   if(m_position.isBuy) {
      return m_position.currentPrice - trailDist;
   } else {
      return m_position.currentPrice + trailDist;
   }
}

//+------------------------------------------------------------------+
//| Main Manage Position                                              |
//+------------------------------------------------------------------+
ENUM_EXIT_REASON CPositionManagerV2::ManagePosition(double currentConviction, bool newsBlackout) {
   if(!m_hasPosition) return EXIT_UNKNOWN;
   if(!m_initialized) return EXIT_UNKNOWN;
   
   UpdatePositionInfo();
   
   // Position closed externally?
   if(!PositionSelectByTicket(m_position.ticket)) {
      m_hasPosition = false;
      return EXIT_UNKNOWN;
   }
   
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   // CHECK 1: NEWS PROTECTION
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   // FIX M-2.2 (2026-04-03): Fermer en blackout si profit OU si perte > 0.5R
   // P2 VALIDATION (2026-04-15): comportement INTENTIONNEL (audit confirme).
   // Zone safe [-0.5R, +emergencyLockRR (0.3R)] : on tient la position pendant
   // le blackout. Hors de cette zone :
   //   - >= +0.3R : on lock le profit (emergency lock, evite retracement news)
   //   - <= -0.5R : on coupe la perte (protection FTMO : spike news peut
   //                doubler la perte, DD journalier critique)
   bool shouldCloseForNews = newsBlackout && (
      m_position.currentRR >= m_emergencyLockRR ||  // Profit >= 0.3R : lock
      m_position.currentRR <= -0.5                  // Perte >= 0.5R : cut preemptif
   );
   if(shouldCloseForNews) {
      Print("News protection - closing at ", DoubleToString(m_position.currentRR, 1), "R");
      ClosePosition("News protection");
      return EXIT_NEWS;
   }
   
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   // CHECK 2: CONVICTION DROP
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   if(currentConviction < m_minConviction && m_position.currentRR >= 0) {
      Print("ðŸ“‰ Conviction dropped to ", DoubleToString(currentConviction, 1), " - closing");
      ClosePosition("Low conviction");
      return EXIT_CONVICTION;
   }
   
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   // CHECK 3: MAX BARS OPEN
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   // FIX A2 (2026-04-04): Fermer aussi les positions en perte apres maxBarsOpen
   // Une position bloquee >16h en perte est dangereuse pour FTMO DD
   if(m_position.barsOpen > m_maxBarsOpen) {
      Print("[PM] Max bars atteint (", m_position.barsOpen,
            ") RR=", DoubleToString(m_position.currentRR, 2), "R - fermeture forcee");
      ClosePosition("Time exit - max bars");
      return EXIT_TIME;
   }
   
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   // CHECK 4: BOS AGAINST POSITION
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   if(m_exitOnBOS && m_position.partialDone && IsBOSAgainstPosition()) {
      Print("ðŸ’” BOS against position detected - closing");
      ClosePosition("BOS against");
      return EXIT_BOS_AGAINST;
   }
   
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   // STEP 1: PARTIAL TAKE PROFIT
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   if(m_enablePartial && !m_position.partialDone) {
      if(m_position.currentRR >= m_partialAtRR) {
         if(ExecutePartialTP()) {
            Print("ðŸ’° Partial TP executed at ", DoubleToString(m_position.currentRR, 2), "R");
            return EXIT_TP_PARTIAL;
         }
      }
   }
   
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   // STEP 2: MOVE TO BREAKEVEN (after partial)
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   if(m_moveToBreakeven && m_position.partialDone && !m_position.beActivated) {
      if(MoveToBreakeven()) {
         Print("ðŸ”’ Moved to breakeven");
      }
   }
   
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   // STEP 3: TRAILING STOP
   // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   if(m_enableTrailing && m_position.partialDone && m_position.beActivated) {
      if(m_position.currentRR >= m_trailMinProfit) {
         if(UpdateTrailingStop()) {
            m_trailing.updateCount++;
         }
      }
   }
   
   return EXIT_UNKNOWN; // Position still open
}

//+------------------------------------------------------------------+
//| Execute Partial TP                                                |
//+------------------------------------------------------------------+
bool CPositionManagerV2::ExecutePartialTP() {
   if(!m_hasPosition) return false;
   if(m_position.partialDone) return false;
   
   double lotsToClose = m_position.currentLots * (m_partialPercent / 100.0);
   double minLot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
   
   lotsToClose = MathFloor(lotsToClose / lotStep) * lotStep;
   lotsToClose = MathMax(minLot, lotsToClose);
   
   double remainingLots = m_position.currentLots - lotsToClose;
   
   if(remainingLots < minLot) {
      // FIX PARTIAL-BUG (2026-04-04): Ne PAS mettre partialDone=true si le partial n'a pas eu lieu
      // Avant: partialDone=true ici lancait le trailing sans filet de securite
      // Maintenant: partialDone reste false, breakeven et trailing ne se lanceront pas
      Print("[PARTIAL-BUG] Position trop petite pour partial TP (",
            DoubleToString(m_position.currentLots, 2), " lots, min=",
            DoubleToString(minLot, 2), ") - partialDone reste false");
      // m_position.partialDone = true;  // SUPPRIME: causait trailing sans partial reel
      return false;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = m_symbol;
   request.volume = lotsToClose;
   request.type = m_position.isBuy ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = m_position.currentPrice;
   request.position = m_position.ticket;
   request.magic = m_magic;
   request.deviation = 10;
   request.comment = "PARTIAL " + DoubleToString(m_partialPercent, 0) + "% @" + DoubleToString(m_position.currentRR, 1) + "R";
   
   if(OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE) {
      m_position.partialDone = true;
      m_position.partialLots = lotsToClose;
      m_position.partialProfit = m_position.currentRR * m_position.riskPips * lotsToClose * 10;
      m_position.currentLots = remainingLots;
      
      Print("â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—");
      Print("â•‘         ðŸ’° PARTIAL TAKE PROFIT EXECUTED                   â•‘");
      Print("â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
      Print("  Closed: ", DoubleToString(lotsToClose, 2), " lots (", m_partialPercent, "%)");
      Print("  At R: ", DoubleToString(m_position.currentRR, 2));
      Print("  Profit locked: ~â‚¬", DoubleToString(m_position.partialProfit, 0));
      Print("  Remaining: ", DoubleToString(remainingLots, 2), " lots â†’ FREE TRADE");
      Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
      
      return true;
   }
   
   Print("âŒ Partial TP failed: ", result.retcode, " - ", result.comment);
   return false;
}

//+------------------------------------------------------------------+
//| Move To Breakeven                                                 |
//+------------------------------------------------------------------+
bool CPositionManagerV2::MoveToBreakeven() {
   if(!m_hasPosition) return false;
   if(m_position.beActivated) return false;
   
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   double buffer = m_beBuffer * point * 10;
   double newSL;
   
   if(m_position.isBuy) {
      newSL = m_position.entryPrice + buffer;
      if(newSL <= m_position.currentSL) return false; // SL already better
   } else {
      newSL = m_position.entryPrice - buffer;
      if(newSL >= m_position.currentSL) return false; // SL already better
   }
   
   int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
   newSL = NormalizeDouble(newSL, digits);
   
   if(m_trade.PositionModify(m_position.ticket, newSL, m_position.currentTP)) {
      m_position.beActivated = true;
      m_position.currentSL = newSL;
      
      Print("ðŸ”’ Breakeven activated @ ", newSL);
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Update Trailing Stop                                              |
//+------------------------------------------------------------------+
bool CPositionManagerV2::UpdateTrailingStop() {
   if(!m_hasPosition) return false;
   if(!m_position.beActivated) return false;
   
   double newSL = CalculateTrailLevel();
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   double minMove = 5 * point * 10;
   
   bool shouldUpdate = false;
   
   if(m_position.isBuy) {
      // For BUY: new SL must be higher and above entry
      shouldUpdate = (newSL > m_position.currentSL + minMove) && 
                     (newSL > m_position.entryPrice);
   } else {
      // For SELL: new SL must be lower and below entry
      shouldUpdate = (newSL < m_position.currentSL - minMove) && 
                     (newSL < m_position.entryPrice);
   }
   
   if(shouldUpdate) {
      int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      newSL = NormalizeDouble(newSL, digits);
      
      if(m_trade.PositionModify(m_position.ticket, newSL, m_position.currentTP)) {
         m_position.currentSL = newSL;
         m_position.trailUpdates++;
         m_trailing.lastUpdate = TimeCurrent();
         m_trailing.currentLevel = newSL;
         m_trailing.active = true;
         
         Print("ðŸ“ˆ Trail update #", m_position.trailUpdates, 
               " @ ", DoubleToString(m_position.progressToTP, 0), "% â†’ SL: ", newSL);
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Close Position                                                    |
//+------------------------------------------------------------------+
bool CPositionManagerV2::ClosePosition(string reason) {
   if(!m_hasPosition) return false;
   
   if(m_trade.PositionClose(m_position.ticket)) {
      Print("â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—");
      Print("â•‘               POSITION CLOSED                             â•‘");
      Print("â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
      Print("  Reason: ", reason);
      Print("  Final P&L: â‚¬", DoubleToString(m_position.profit, 2));
      Print("  Max R reached: ", DoubleToString(m_position.maxRR, 2));
      Print("  Bars open: ", m_position.barsOpen);
      if(m_position.partialDone) {
         Print("  Partial profit: ~â‚¬", DoubleToString(m_position.partialProfit, 0));
      }
      Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
      
      m_hasPosition = false;
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Print Position Status                                             |
//+------------------------------------------------------------------+
void CPositionManagerV2::PrintPositionStatus() {
   if(!m_hasPosition) {
      Print("No active position");
      return;
   }
   
   UpdatePositionInfo();
   
   Print("â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—");
   Print("â•‘               POSITION STATUS                             â•‘");
   Print("â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
   Print("  Ticket: #", m_position.ticket);
   Print("  Direction: ", m_position.direction, " ", m_position.tradeType);
   Print("  State: ", GetStateText());
   Print("  Entry: ", m_position.entryPrice);
   Print("  Current: ", m_position.currentPrice);
   Print("  SL: ", m_position.currentSL);
   Print("  TP: ", m_position.currentTP);
   Print("â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€");
   Print("  Profit: â‚¬", DoubleToString(m_position.profit, 2));
   Print("  Profit pips: ", DoubleToString(m_position.profitPips, 1));
   Print("  Current R: ", DoubleToString(m_position.currentRR, 2));
   Print("  Max R: ", DoubleToString(m_position.maxRR, 2));
   Print("  Progress to TP: ", DoubleToString(m_position.progressToTP, 1), "%");
   Print("â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€");
   Print("  Partial done: ", m_position.partialDone ? "YES" : "NO");
   Print("  BE active: ", m_position.beActivated ? "YES" : "NO");
   Print("  Trail updates: ", m_position.trailUpdates);
   Print("  Bars open: ", m_position.barsOpen);
   Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
}

//+------------------------------------------------------------------+
//| Get State Text                                                    |
//+------------------------------------------------------------------+
string CPositionManagerV2::GetStateText() {
   switch(m_position.state) {
      case STATE_NEW: return "NEW";
      case STATE_ACTIVE: return "ACTIVE";
      case STATE_PARTIAL_DONE: return "PARTIAL DONE";
      case STATE_BREAKEVEN: return "BREAKEVEN";
      case STATE_TRAILING: return "TRAILING";
      case STATE_CLOSING: return "CLOSING";
      default: return "UNKNOWN";
   }
}

//+------------------------------------------------------------------+
//| Get Exit Reason Text                                              |
//+------------------------------------------------------------------+
string CPositionManagerV2::GetExitReasonText(ENUM_EXIT_REASON reason) {
   switch(reason) {
      case EXIT_TP_FULL: return "Full TP";
      case EXIT_TP_PARTIAL: return "Partial TP";
      case EXIT_SL: return "Stop Loss";
      case EXIT_BREAKEVEN: return "Breakeven";
      case EXIT_TRAILING: return "Trailing Stop";
      case EXIT_BOS_AGAINST: return "BOS Against";
      case EXIT_STRUCTURE: return "Structure Break";
      case EXIT_CONVICTION: return "Low Conviction";
      case EXIT_MANUAL: return "Manual";
      case EXIT_TIME: return "Time Exit";
      case EXIT_NEWS: return "News Protection";
      default: return "Unknown";
   }
}
//+------------------------------------------------------------------+