//+------------------------------------------------------------------+
//| GoldML_SniperEntry_M15.mqh                                       |
//| INSTITUTIONAL SMC SNIPER - M15 TIMEFRAME                         |
//| Optimized for News Trading                                       |
//|                                                                  |
//| LOGIC:                                                           |
//| 1. M15 = Primary timeframe (structure, BOS, pullback)            |
//| 2. M5  = Confirmation (PD Arrays + CHoCH timing)                 |
//| 3. SL  = Based on M15 swing structure                            |
//+------------------------------------------------------------------+
#property copyright "Gold ML System - Institutional Grade"
#property version   "2.10"
#property strict

#include "GoldML_ICT_Detector.mqh"
// PHASE 2 APPROCHE A (2026-04-14) : acces aux niveaux de liquidite ICT
#include "GoldML_LiquidityLevels.mqh"

//+------------------------------------------------------------------+
//| ENUMS                                                             |
//+------------------------------------------------------------------+
enum ENUM_STRUCTURE {
   STRUCTURE_BULLISH,
   STRUCTURE_BEARISH,
   STRUCTURE_RANGING,
   STRUCTURE_UNKNOWN
};

enum ENUM_M5_PATTERN {
   PATTERN_NONE,
   PATTERN_PIN_BAR,
   PATTERN_ENGULFING,
   PATTERN_INSIDE_BAR,
   PATTERN_REJECTION
};

//+------------------------------------------------------------------+
//| SWING POINT STRUCTURE                                            |
//+------------------------------------------------------------------+
struct SwingPoint {
   double   price;
   datetime time;
   int      barIndex;
   bool     isHigh;      // true = swing high, false = swing low
   bool     broken;      // Has been broken
   bool     swept;       // Liquidity swept then reclaimed
};

//+------------------------------------------------------------------+
//| LIQUIDITY SWEEP STRUCTURE                                        |
//+------------------------------------------------------------------+
struct LiquiditySweep {
   bool     detected;
   double   sweepLevel;     // Level that was swept
   double   sweepPrice;     // Lowest/highest price during sweep
   datetime sweepTime;
   int      sweepBar;
   bool     reclaimed;      // Price came back after sweep
   int      barsSinceSweep;
   string   sweepType;      // "HIGH_SWEEP" or "LOW_SWEEP"
};

//+------------------------------------------------------------------+
//| BREAK OF STRUCTURE                                               |
//+------------------------------------------------------------------+
struct BreakOfStructure {
   bool     detected;
   double   bosLevel;       // Level that was broken
   double   bosPrice;       // Price that broke it
   datetime bosTime;
   int      bosBar;
   string   direction;      // "BULLISH" or "BEARISH"
   bool     confirmed;      // Closed beyond level
   int      barsSinceBOS;
};

//+------------------------------------------------------------------+
//| PULLBACK ZONE (Institutional style with PD Arrays)               |
//+------------------------------------------------------------------+
struct PullbackZone {
   bool     inZone;           // true when mitigation + timing shift satisfied
   bool     mitigated;        // price mitigated PD array zone
   string   pdType;           // "FVG" / "OB" / "NONE"
   double   pdStrength;       // 0..100 heuristic
   bool     chochM5;          // M5 Change of Character confirmed
   bool     bosM5;            // M5 BOS / impulsive break confirmed

   // Zone (PD array)
   double   zoneHigh;         // Top of PD array zone
   double   zoneLow;          // Bottom of PD array zone
   double   optimalEntry;     // Mid/optimal entry inside zone

   int      barsInZone;

   // Backward compatibility fields (legacy)
   double   fibLevel;         // mapped to pdStrength/100 for legacy prints
};

//+------------------------------------------------------------------+
//| M5 CONFIRMATION                                                  |
//+------------------------------------------------------------------+
struct M5Confirmation {
   bool              hasPattern;
   ENUM_M5_PATTERN   pattern;
   string            patternName;
   bool              candleConfirm;  // Closed in direction
   double            patternScore;   // 0-100
};

//+------------------------------------------------------------------+
//| SNIPER RESULT                                                    |
//+------------------------------------------------------------------+
struct SniperResultM15 {
   bool     isValid;
   int      score;             // 0-100
   double   entryPrice;
   double   stopLoss;
   double   slPips;
   string   reason;
   
   // Components
   ENUM_STRUCTURE      structure;
   LiquiditySweep      sweep;
   BreakOfStructure    bos;
   PullbackZone        pullback;
   M5Confirmation      m5Confirm;
   
   // Session
   string   activeSession;
   int      sessionBoost;
   
   // Timing
   datetime signalTime;
};

//+------------------------------------------------------------------+
//| SNIPER M15 CLASS                                                 |
//+------------------------------------------------------------------+
class CSniperM15 {
private:
   string   m_symbol;
   bool     m_initialized;
   
   // ICT Detector
   CICT_Detector* m_ictDetector;

   // PHASE 2 APPROCHE A (2026-04-14) : niveaux ICT + feature flag
   CLiquidityLevels* m_liquidity;
   bool              m_useICTLiquidity;
   
   // Settings
   int      m_swingLookback;
   int      m_minSwingBars;
   double   m_fibEntryMin;
   double   m_fibEntryMax;
   double   m_fibOptimal;
   int      m_maxBarsAfterBOS;
   int      m_maxBarsAfterSweep;
   bool     m_requireSweep;
   bool     m_requireBOS;
   double   m_minRR;
   int      m_minScore;
   double   m_maxSpread;
   double   m_slBuffer;
   double   m_slMin;
   double   m_slMax;
   bool     m_useM5Confirm;
   bool     m_boostSession;
   int      m_sessionBoost;
   
   // Indicator handles - M15
   int      m_hATR_M15;
   int      m_hEMA20_M15;
   int      m_hEMA50_M15;
   
   // Indicator handles - M5
   int      m_hATR_M5;
   
   // Price data cache
   double   m_high_M15[];
   double   m_low_M15[];
   double   m_close_M15[];
   double   m_open_M15[];
   datetime m_time_M15[];
   
   double   m_high_M5[];
   double   m_low_M5[];
   double   m_close_M5[];
   double   m_open_M5[];
   datetime m_time_M5[];
   
   // Swing points
   SwingPoint m_swingHighs[];
   SwingPoint m_swingLows[];
   
   // Last result
   SniperResultM15 m_lastResult;
   
   // Private methods
   void     RefreshM15Data();
   void     RefreshM5Data();
   void     DetectSwingPoints();
   ENUM_STRUCTURE AnalyzeStructure(string direction);
   LiquiditySweep DetectLiquiditySweep(string direction);
   // PHASE 2 APPROCHE A (2026-04-14) : sweep ICT vrai (PDH/PDL/PWH/PWL/London/Asian/EQL)
   LiquiditySweep DetectLiquiditySweep_ICT(string direction);
   // FIX ICT-B3: parametre sweepBar pour garantir BOS apres sweep
   BreakOfStructure DetectBOS(string direction, int sweepBar = -1);
   PullbackZone AnalyzePullback(string direction, BreakOfStructure &bos, string timingMode = "CLEAR");
   M5Confirmation CheckM5Confirmation(string direction);
   ENUM_M5_PATTERN DetectM5Pattern(string direction);
   double   CalculateSL(string direction, LiquiditySweep &sweep);
   bool     CheckH4Structure(string direction);
   int      CalculateScore(SniperResultM15 &result);
   string   GetActiveSession();
   int      GetSessionBoost(string session);
   bool     CheckSpread();
   
public:
   CSniperM15(string symbol);
   ~CSniperM15();
   
   bool Initialize(int swingLookback, int minSwingBars,
                   double fibMin, double fibMax, double fibOptimal,
                   int maxBarsAfterBOS, int maxBarsAfterSweep,
                   bool requireSweep, bool requireBOS,
                   double minRR, int minScore, double maxSpread,
                   bool boostSession, int sessionBoost,
                   double slBuffer, double slMin, double slMax,
                   bool useM5Confirm);
   
   SniperResultM15 AnalyzeEntry(string direction, double confidence, string timingMode);
   SniperResultM15 GetLastResult() { return m_lastResult; }
   void PrintAnalysis(SniperResultM15 &result);

   // PHASE 2 APPROCHE A (2026-04-14) : injection niveaux ICT + flag runtime
   // (Enable_ICT_Liquidity est un input EA, non accessible depuis la .mqh)
   void SetLiquidity(CLiquidityLevels* liq)  { m_liquidity = liq; }
   void SetUseICTLiquidity(bool use)         { m_useICTLiquidity = use; }
};

//+------------------------------------------------------------------+
//| Constructor                                                       |
//+------------------------------------------------------------------+
CSniperM15::CSniperM15(string symbol) {
   m_symbol = symbol;
   m_initialized = false;
   m_hATR_M15 = INVALID_HANDLE;
   m_hEMA20_M15 = INVALID_HANDLE;
   m_hEMA50_M15 = INVALID_HANDLE;
   m_hATR_M5 = INVALID_HANDLE;
   
   // CORRECTION 1: Initialiser ICT Detector
   m_ictDetector = new CICT_Detector(symbol);

   // PHASE 2 APPROCHE A (2026-04-14)
   m_liquidity        = NULL;
   m_useICTLiquidity  = false;
}

//+------------------------------------------------------------------+
//| Destructor                                                        |
//+------------------------------------------------------------------+
CSniperM15::~CSniperM15() {
   if(m_hATR_M15 != INVALID_HANDLE) IndicatorRelease(m_hATR_M15);
   if(m_hEMA20_M15 != INVALID_HANDLE) IndicatorRelease(m_hEMA20_M15);
   if(m_hEMA50_M15 != INVALID_HANDLE) IndicatorRelease(m_hEMA50_M15);
   if(m_hATR_M5 != INVALID_HANDLE) IndicatorRelease(m_hATR_M5);
   
   // CORRECTION 2: Nettoyer ICT Detector
   if(m_ictDetector != NULL) {
      delete m_ictDetector;
      m_ictDetector = NULL;
   }
}

//+------------------------------------------------------------------+
//| Initialize                                                        |
//+------------------------------------------------------------------+
bool CSniperM15::Initialize(int swingLookback, int minSwingBars,
                             double fibMin, double fibMax, double fibOptimal,
                             int maxBarsAfterBOS, int maxBarsAfterSweep,
                             bool requireSweep, bool requireBOS,
                             double minRR, int minScore, double maxSpread,
                             bool boostSession, int sessionBoost,
                             double slBuffer, double slMin, double slMax,
                             bool useM5Confirm) {
   
   // CORRECTION 3: VÃ©rifier ICT Detector
   if(m_ictDetector == NULL) {
      Print("âŒ SNIPER M15: ICT Detector not initialized");
      return false;
   }
   
   // Store settings
   m_swingLookback = swingLookback;
   m_minSwingBars = minSwingBars;
   m_fibEntryMin = fibMin;
   m_fibEntryMax = fibMax;
   m_fibOptimal = fibOptimal;
   m_maxBarsAfterBOS = maxBarsAfterBOS;
   m_maxBarsAfterSweep = maxBarsAfterSweep;
   m_requireSweep = requireSweep;
   m_requireBOS = requireBOS;
   m_minRR = minRR;
   m_minScore = minScore;
   m_maxSpread = maxSpread;
   m_boostSession = boostSession;
   m_sessionBoost = sessionBoost;
   m_slBuffer = slBuffer;
   m_slMin = slMin;
   m_slMax = slMax;
   m_useM5Confirm = useM5Confirm;
   
   // Create M15 indicators
   m_hATR_M15 = iATR(m_symbol, PERIOD_M15, 14);
   m_hEMA20_M15 = iMA(m_symbol, PERIOD_M15, 20, 0, MODE_EMA, PRICE_CLOSE);
   m_hEMA50_M15 = iMA(m_symbol, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
   
   // Create M5 indicator
   m_hATR_M5 = iATR(m_symbol, PERIOD_M5, 14);
   
   if(m_hATR_M15 == INVALID_HANDLE || m_hEMA20_M15 == INVALID_HANDLE || 
      m_hEMA50_M15 == INVALID_HANDLE || m_hATR_M5 == INVALID_HANDLE) {
      Print("âŒ SNIPER M15: Failed to create indicators");
      return false;
   }
   
   // Set arrays as series
   ArraySetAsSeries(m_high_M15, true);
   ArraySetAsSeries(m_low_M15, true);
   ArraySetAsSeries(m_close_M15, true);
   ArraySetAsSeries(m_open_M15, true);
   ArraySetAsSeries(m_time_M15, true);
   ArraySetAsSeries(m_high_M5, true);
   ArraySetAsSeries(m_low_M5, true);
   ArraySetAsSeries(m_close_M5, true);
   ArraySetAsSeries(m_open_M5, true);
   ArraySetAsSeries(m_time_M5, true);
   
   m_initialized = true;
   
   Print("â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—");
   Print("â•‘     SNIPER M15 INSTITUTIONAL - INITIALIZED                â•‘");
   Print("â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
   Print("  Primary TF: M15");
   Print("  Confirmation TF: M5 (", m_useM5Confirm ? "ON" : "OFF", ")");
   Print("  Swing Lookback: ", m_swingLookback, " bars (", m_swingLookback * 15, " min)");
   Print("  Pullback: ICT PD Arrays (FVG/OB) on M5 + CHoCH M5 timing");
   Print("  Max Bars After BOS: ", m_maxBarsAfterBOS, " (", m_maxBarsAfterBOS * 15, " min)");
   Print("  SL Range: ", m_slMin, " - ", m_slMax, " pips");
   Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
   
   return true;
}

//+------------------------------------------------------------------+
//| Refresh M15 Price Data                                           |
//+------------------------------------------------------------------+
void CSniperM15::RefreshM15Data() {
   int bars = m_swingLookback + 30;
   
   // CORRECTION 4: VÃ©rifier les retours de CopyXXX
   int copied = CopyHigh(m_symbol, PERIOD_M15, 0, bars, m_high_M15);
   if(copied < bars) {
      Print("âš ï¸ RefreshM15Data: CopyHigh failed (", copied, "/", bars, ")");
   }
   
   CopyLow(m_symbol, PERIOD_M15, 0, bars, m_low_M15);
   CopyClose(m_symbol, PERIOD_M15, 0, bars, m_close_M15);
   CopyOpen(m_symbol, PERIOD_M15, 0, bars, m_open_M15);
   CopyTime(m_symbol, PERIOD_M15, 0, bars, m_time_M15);

   ArraySetAsSeries(m_high_M15, true);
   ArraySetAsSeries(m_low_M15, true);
   ArraySetAsSeries(m_close_M15, true);
   ArraySetAsSeries(m_open_M15, true);
   ArraySetAsSeries(m_time_M15, true);
}

//+------------------------------------------------------------------+
//| Refresh M5 Price Data                                            |
//+------------------------------------------------------------------+
void CSniperM15::RefreshM5Data() {
   int bars = 150;
   
   // CORRECTION 5: VÃ©rifier les retours
   int copied = CopyHigh(m_symbol, PERIOD_M5, 0, bars, m_high_M5);
   if(copied < bars) {
      Print("âš ï¸ RefreshM5Data: CopyHigh failed (", copied, "/", bars, ")");
   }
   
   CopyLow(m_symbol, PERIOD_M5, 0, bars, m_low_M5);
   CopyClose(m_symbol, PERIOD_M5, 0, bars, m_close_M5);
   CopyOpen(m_symbol, PERIOD_M5, 0, bars, m_open_M5);
   CopyTime(m_symbol, PERIOD_M5, 0, bars, m_time_M5);

   ArraySetAsSeries(m_high_M5, true);
   ArraySetAsSeries(m_low_M5, true);
   ArraySetAsSeries(m_close_M5, true);
   ArraySetAsSeries(m_open_M5, true);
   ArraySetAsSeries(m_time_M5, true);
}

//+------------------------------------------------------------------+
//| Detect Swing Points on M15                                       |
//+------------------------------------------------------------------+
void CSniperM15::DetectSwingPoints() {
   ArrayResize(m_swingHighs, 0);
   ArrayResize(m_swingLows, 0);
   
   int barsNeeded = m_swingLookback;
   int arraySize = ArraySize(m_high_M15);
   
   // CORRECTION 6: Validation taille array
   if(arraySize < barsNeeded) {
      Print("âš ï¸ DetectSwingPoints: Insufficient data (", arraySize, "/", barsNeeded, ")");
      return;
   }
   
   // CORRECTION 7: Limites correctes pour Ã©viter out of range
   int startI = m_minSwingBars;
   int endI = MathMin(barsNeeded - m_minSwingBars, arraySize - m_minSwingBars - 1);
   
   if(startI >= endI) {
      Print("âš ï¸ DetectSwingPoints: Invalid range (", startI, " >= ", endI, ")");
      return;
   }
   
   // Detect swing highs
   for(int i = startI; i <= endI; i++) {
      bool isSwingHigh = true;
      
      // CORRECTION 8: VÃ©rifier les limites dans la boucle
      for(int j = 1; j <= m_minSwingBars; j++) {
         if(i - j < 0 || i + j >= arraySize) {
            isSwingHigh = false;
            break;
         }
         if(m_high_M15[i] <= m_high_M15[i - j] || m_high_M15[i] <= m_high_M15[i + j]) {
            isSwingHigh = false;
            break;
         }
      }
      
      if(isSwingHigh) {
         SwingPoint sp;
         sp.price = m_high_M15[i];
         sp.time = m_time_M15[i];
         sp.barIndex = i;
         sp.isHigh = true;
         sp.broken = false;
         sp.swept = false;
         
         int size = ArraySize(m_swingHighs);
         ArrayResize(m_swingHighs, size + 1);
         m_swingHighs[size] = sp;
      }
   }
   
   // Detect swing lows
   for(int i = startI; i <= endI; i++) {
      bool isSwingLow = true;
      
      for(int j = 1; j <= m_minSwingBars; j++) {
         if(i - j < 0 || i + j >= arraySize) {
            isSwingLow = false;
            break;
         }
         if(m_low_M15[i] >= m_low_M15[i - j] || m_low_M15[i] >= m_low_M15[i + j]) {
            isSwingLow = false;
            break;
         }
      }
      
      if(isSwingLow) {
         SwingPoint sp;
         sp.price = m_low_M15[i];
         sp.time = m_time_M15[i];
         sp.barIndex = i;
         sp.isHigh = false;
         sp.broken = false;
         sp.swept = false;
         
         int size = ArraySize(m_swingLows);
         ArrayResize(m_swingLows, size + 1);
         m_swingLows[size] = sp;
      }
   }
}

//+------------------------------------------------------------------+
//| Analyze Market Structure                                         |
//+------------------------------------------------------------------+
ENUM_STRUCTURE CSniperM15::AnalyzeStructure(string direction) {
   if(ArraySize(m_swingHighs) < 2 || ArraySize(m_swingLows) < 2) {
      return STRUCTURE_UNKNOWN;
   }
   
   // Get EMAs
   double ema20[], ema50[];
   ArraySetAsSeries(ema20, true);
   ArraySetAsSeries(ema50, true);
   
   // CORRECTION 9: VÃ©rifier CopyBuffer
   if(CopyBuffer(m_hEMA20_M15, 0, 0, 5, ema20) < 5 ||
      CopyBuffer(m_hEMA50_M15, 0, 0, 5, ema50) < 5) {
      Print("âš ï¸ AnalyzeStructure: Failed to copy EMA buffers");
      return STRUCTURE_UNKNOWN;
   }
   
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   double price = (direction == "BUY") ? ask : bid;
   
   // Check EMA alignment
   bool emaBullish = (price > ema20[0] && ema20[0] > ema50[0]);
   bool emaBearish = (price < ema20[0] && ema20[0] < ema50[0]);
   
   // Check swing structure
   bool higherHighs = (m_swingHighs[0].price > m_swingHighs[1].price);
   bool higherLows = (m_swingLows[0].price > m_swingLows[1].price);
   bool lowerHighs = (m_swingHighs[0].price < m_swingHighs[1].price);
   bool lowerLows = (m_swingLows[0].price < m_swingLows[1].price);
   
   if(direction == "BUY") {
      if((higherHighs && higherLows) || emaBullish) {
         return STRUCTURE_BULLISH;
      }
   } else {
      if((lowerHighs && lowerLows) || emaBearish) {
         return STRUCTURE_BEARISH;
      }
   }
   
   return STRUCTURE_RANGING;
}

//+------------------------------------------------------------------+
//| PHASE 2 APPROCHE A (2026-04-14)                                  |
//| DetectLiquiditySweep_ICT                                         |
//|                                                                  |
//| Nouvelle detection sur vrais niveaux ICT (PDH/PDL/PWH/PWL,       |
//| Asian/London ranges, Equal Highs/Lows) au lieu des pivots 4/4.   |
//|  - Reclaim autorise jusqu'a 8 bougies                            |
//|  - Verification displacement post-reclaim (ATR M15 x 0.4)        |
//|  - Option 5A : rejet si SL structurel > 45 pips                  |
//|                                                                  |
//| NOTE : utilise les arrays caches m_*_M15 (indexes bar 0) pour    |
//| garantir la coherence du sweepBar avec DetectBOS() (qui lit      |
//| aussi m_close_M15 / m_high_M15 / m_low_M15).                     |
//+------------------------------------------------------------------+
LiquiditySweep CSniperM15::DetectLiquiditySweep_ICT(string direction) {
   LiquiditySweep sweep;
   sweep.detected       = false;
   sweep.reclaimed      = false;
   sweep.sweepBar       = -1;
   sweep.sweepLevel     = 0;
   sweep.sweepPrice     = 0;
   sweep.sweepTime      = 0;
   sweep.barsSinceSweep = 999;
   sweep.sweepType      = "NONE";

   if(m_liquidity == NULL) {
      Print("[SWEEP-ICT] ERREUR: m_liquidity NULL");
      return sweep;
   }

   int arraySize = ArraySize(m_close_M15);
   if(arraySize < 30) {
      Print("[SWEEP-ICT] Donnees M15 insuffisantes (", arraySize, ")");
      return sweep;
   }

   // ATR M15 pour displacement (reutilise le handle cache)
   double atrVal = 0.0;
   if(m_hATR_M15 != INVALID_HANDLE) {
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(m_hATR_M15, 0, 1, 3, atr) >= 3) atrVal = atr[0];
   }

   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT) * 10.0;
   if(point <= 0.0) point = 0.01;

   int levelCount = m_liquidity.GetLevelCount();

   // Parcourir les niveaux de liquidite
   for(int lvlIdx = 0; lvlIdx < levelCount; lvlIdx++) {
      LiquidityLevel lvl = m_liquidity.GetLevel(lvlIdx);
      if(!lvl.active) continue;

      // === BUY : sweep sous niveau bullish ===
      if(direction == "BUY") {
         bool isBullishLevel = (lvl.type == "PDL"      ||
                                lvl.type == "PWL"      ||
                                lvl.type == "ASIAN_L"  ||
                                lvl.type == "LONDON_L" ||
                                lvl.type == "EQL_L");
         if(!isBullishLevel) continue;

         // Chercher bougie qui a penetre sous le niveau (bougies fermees, j>=1)
         for(int j = 1; j < 25 && j < arraySize; j++) {
            if(m_low_M15[j] < lvl.price - point * 0.5) {
               // Wick penetre le niveau

               // Verifier reclaim dans les 8 bougies
               bool reclaimed  = false;
               int  reclaimBar = -1;

               // Same candle reclaim
               if(m_close_M15[j] > lvl.price) {
                  reclaimed  = true;
                  reclaimBar = j;
               }
               else {
                  // Multi-candle reclaim jusqu'a 8 bougies (plus recent = index plus petit)
                  for(int k = 1; k <= 8; k++) {
                     int idx = j - k;
                     if(idx < 0) break;
                     if(m_close_M15[idx] > lvl.price) {
                        reclaimed  = true;
                        reclaimBar = idx;
                        break;
                     }
                  }
               }

               if(!reclaimed) {
                  Print("[SWEEP-ICT] BUY sweep sur ", lvl.type,
                        " @ ", DoubleToString(lvl.price, 2),
                        " — pas de reclaim dans 8 bougies");
                  continue;
               }

               // Verifier displacement post-reclaim (info seulement, non bloquant)
               bool hasDisplacement = false;
               if(atrVal > 0 && reclaimBar > 0 && reclaimBar - 1 >= 0) {
                  double body = m_close_M15[reclaimBar - 1] - m_close_M15[reclaimBar];
                  hasDisplacement = (body >= atrVal * 0.4);
               }

               // Calculer SL structurel
               double slPips = (lvl.price - m_low_M15[j]) / point;

               // Option 5A : rejeter si SL > 45 pips
               if(slPips > 45.0) {
                  Print("[SWEEP-ICT] BUY sweep rejete: SL ",
                        DoubleToString(slPips, 1), " pips > 45");
                  continue;
               }

               // Sweep valide
               sweep.detected       = true;
               sweep.sweepBar       = j;
               sweep.sweepLevel     = lvl.price;
               sweep.sweepPrice     = m_low_M15[j];
               sweep.sweepTime      = m_time_M15[j];
               sweep.reclaimed      = true;
               sweep.barsSinceSweep = (reclaimBar >= 0) ? reclaimBar : j;
               sweep.sweepType      = "ICT_" + lvl.type;

               Print("[SWEEP-ICT] BUY sweep valide!",
                     " Type=", lvl.type,
                     " Level=", DoubleToString(lvl.price, 2),
                     " Low=", DoubleToString(m_low_M15[j], 2),
                     " SL=", DoubleToString(slPips, 1), "pips",
                     " Displacement=", (hasDisplacement ? "YES" : "NO"),
                     " ReclaimBar=", reclaimBar);

               return sweep;
            }
         }
      }

      // === SELL : sweep au-dessus niveau bearish ===
      else if(direction == "SELL") {
         bool isBearishLevel = (lvl.type == "PDH"      ||
                                lvl.type == "PWH"      ||
                                lvl.type == "ASIAN_H"  ||
                                lvl.type == "LONDON_H" ||
                                lvl.type == "EQL_H");
         if(!isBearishLevel) continue;

         for(int j = 1; j < 25 && j < arraySize; j++) {
            if(m_high_M15[j] > lvl.price + point * 0.5) {

               bool reclaimed  = false;
               int  reclaimBar = -1;

               if(m_close_M15[j] < lvl.price) {
                  reclaimed  = true;
                  reclaimBar = j;
               }
               else {
                  for(int k = 1; k <= 8; k++) {
                     int idx = j - k;
                     if(idx < 0) break;
                     if(m_close_M15[idx] < lvl.price) {
                        reclaimed  = true;
                        reclaimBar = idx;
                        break;
                     }
                  }
               }

               if(!reclaimed) {
                  Print("[SWEEP-ICT] SELL sweep sur ", lvl.type,
                        " @ ", DoubleToString(lvl.price, 2),
                        " — pas de reclaim");
                  continue;
               }

               bool hasDisplacement = false;
               if(atrVal > 0 && reclaimBar > 0 && reclaimBar - 1 >= 0) {
                  double body = m_close_M15[reclaimBar] - m_close_M15[reclaimBar - 1];
                  hasDisplacement = (body >= atrVal * 0.4);
               }

               double slPips = (m_high_M15[j] - lvl.price) / point;
               if(slPips > 45.0) {
                  Print("[SWEEP-ICT] SELL sweep rejete: SL ",
                        DoubleToString(slPips, 1), " pips > 45");
                  continue;
               }

               sweep.detected       = true;
               sweep.sweepBar       = j;
               sweep.sweepLevel     = lvl.price;
               sweep.sweepPrice     = m_high_M15[j];
               sweep.sweepTime      = m_time_M15[j];
               sweep.reclaimed      = true;
               sweep.barsSinceSweep = (reclaimBar >= 0) ? reclaimBar : j;
               sweep.sweepType      = "ICT_" + lvl.type;

               Print("[SWEEP-ICT] SELL sweep valide!",
                     " Type=", lvl.type,
                     " Level=", DoubleToString(lvl.price, 2),
                     " High=", DoubleToString(m_high_M15[j], 2),
                     " SL=", DoubleToString(slPips, 1), "pips",
                     " Displacement=", (hasDisplacement ? "YES" : "NO"),
                     " ReclaimBar=", reclaimBar);

               return sweep;
            }
         }
      }
   }

   Print("[SWEEP-ICT] Aucun sweep sur ", levelCount, " niveaux ICT");
   return sweep;
}

//+------------------------------------------------------------------+
//| PHASE2-ANCIEN (2026-04-14)                                       |
//| Ancienne DetectLiquiditySweep sur pivots 4/4 locaux — conservee  |
//| intacte pour rollback (appelee quand Enable_ICT_Liquidity=false).|
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Detect Liquidity Sweep                                           |
//+------------------------------------------------------------------+
LiquiditySweep CSniperM15::DetectLiquiditySweep(string direction) {
   LiquiditySweep sweep;
   sweep.detected = false;
   sweep.reclaimed = false;
   sweep.barsSinceSweep = 999;
   sweep.sweepLevel = 0;
   sweep.sweepPrice = 0;
   sweep.sweepTime = 0;
   sweep.sweepBar = -1;
   sweep.sweepType = "NONE";
   
   int arraySize = ArraySize(m_close_M15);
   
   if(direction == "BUY") {
      // Look for sweep of swing lows
      for(int i = 0; i < ArraySize(m_swingLows); i++) {
         double level = m_swingLows[i].price;
         int swingBar = m_swingLows[i].barIndex;
         
         // CORRECTION 10: Limiter la recherche correctement
         int maxJ = MathMin(swingBar, m_maxBarsAfterSweep);
         
         // FIX ICT-S2 (2026-04-03): Sweep commence a j=1 (bougie fermee uniquement)
         // Coherence avec DetectBOS() qui commence aussi a j=1
         // Un sweep sur bougie non fermee (j=0) peut etre invalide a la cloture
         for(int j = 1; j < maxJ; j++) {
            if(j >= arraySize) break;

            if(m_low_M15[j] < level) {
               // IMPROVE 1 (2026-04-03): Filtre volume institutionnel
               // Un sweep sans volume n'est pas un sweep institutionnel
               long sweepVolume = (long)iVolume(m_symbol, PERIOD_M15, j);
               long avgVolume = 0;
               for(int v = j + 1; v <= j + 10 && v < arraySize; v++) {
                  avgVolume += (long)iVolume(m_symbol, PERIOD_M15, v);
               }
               if(j + 10 < arraySize) avgVolume /= 10;
               else if(avgVolume > 0) avgVolume /= MathMin(10, arraySize - j - 1);
               // Le sweep doit avoir un volume >= 80% de la moyenne des 10 bougies precedentes
               if(avgVolume > 0 && sweepVolume < (long)(avgVolume * 0.80)) {
                  continue; // Sweep sans volume = bruit, ignorer
               }

               // FIX ICT-S1 (2026-04-03): Support sweep multi-bougies
               // Methode 1: Same-candle sweep (wick + reclaim sur meme bougie) -- prioritaire
               if(m_close_M15[j] > level) {
                  sweep.detected = true;
                  sweep.sweepLevel = level;
                  sweep.sweepPrice = m_low_M15[j];
                  sweep.sweepTime = m_time_M15[j];
                  sweep.sweepBar = j;
                  sweep.reclaimed = true;
                  sweep.barsSinceSweep = j;
                  sweep.sweepType = "LOW_SWEEP";
                  return sweep;
               }
               // Methode 2: Multi-candle sweep (wick bougie j, reclaim bougie j-1 ou j-2)
               // Le marche perce le niveau puis revient au-dessus dans les 2 bougies suivantes
               else if(j >= 2 && j - 2 >= 0) {
                  if(m_close_M15[j-1] > level || m_close_M15[j-2] > level) {
                     int reclaimBar = (m_close_M15[j-1] > level) ? j-1 : j-2;
                     sweep.detected = true;
                     sweep.sweepLevel = level;
                     sweep.sweepPrice = m_low_M15[j];
                     sweep.sweepTime = m_time_M15[j];
                     sweep.sweepBar = j;
                     sweep.reclaimed = true;
                     sweep.barsSinceSweep = reclaimBar;
                     sweep.sweepType = "LOW_SWEEP";
                     return sweep;
                  }
               }
            }
         }
      }
   } else {
      // Look for sweep of swing highs
      for(int i = 0; i < ArraySize(m_swingHighs); i++) {
         double level = m_swingHighs[i].price;
         int swingBar = m_swingHighs[i].barIndex;
         
         int maxJ = MathMin(swingBar, m_maxBarsAfterSweep);
         
         // FIX ICT-S2 (2026-04-03): Sweep commence a j=1 (bougie fermee uniquement)
         // Coherence avec DetectBOS() qui commence aussi a j=1
         // Un sweep sur bougie non fermee (j=0) peut etre invalide a la cloture
         for(int j = 1; j < maxJ; j++) {
            if(j >= arraySize) break;

            if(m_high_M15[j] > level) {
               // IMPROVE 1 (2026-04-03): Filtre volume institutionnel (SELL)
               long sweepVolume = (long)iVolume(m_symbol, PERIOD_M15, j);
               long avgVolume = 0;
               for(int v = j + 1; v <= j + 10 && v < arraySize; v++) {
                  avgVolume += (long)iVolume(m_symbol, PERIOD_M15, v);
               }
               if(j + 10 < arraySize) avgVolume /= 10;
               else if(avgVolume > 0) avgVolume /= MathMin(10, arraySize - j - 1);
               if(avgVolume > 0 && sweepVolume < (long)(avgVolume * 0.80)) {
                  continue; // Sweep sans volume = bruit, ignorer
               }

               // FIX ICT-S1 (2026-04-03): Support sweep multi-bougies (SELL)
               // Methode 1: Same-candle sweep -- prioritaire
               if(m_close_M15[j] < level) {
                  sweep.detected = true;
                  sweep.sweepLevel = level;
                  sweep.sweepPrice = m_high_M15[j];
                  sweep.sweepTime = m_time_M15[j];
                  sweep.sweepBar = j;
                  sweep.reclaimed = true;
                  sweep.barsSinceSweep = j;
                  sweep.sweepType = "HIGH_SWEEP";
                  return sweep;
               }
               // Methode 2: Multi-candle sweep (wick bougie j, reclaim bougie j-1 ou j-2)
               else if(j >= 2 && j - 2 >= 0) {
                  if(m_close_M15[j-1] < level || m_close_M15[j-2] < level) {
                     int reclaimBar = (m_close_M15[j-1] < level) ? j-1 : j-2;
                     sweep.detected = true;
                     sweep.sweepLevel = level;
                     sweep.sweepPrice = m_high_M15[j];
                     sweep.sweepTime = m_time_M15[j];
                     sweep.sweepBar = j;
                     sweep.reclaimed = true;
                     sweep.barsSinceSweep = reclaimBar;
                     sweep.sweepType = "HIGH_SWEEP";
                     return sweep;
                  }
               }
            }
         }
      }
   }
   
   return sweep;
}

//+------------------------------------------------------------------+
//| Detect Break of Structure                                        |
//+------------------------------------------------------------------+
// FIX ICT-B3 (2026-04-03): BOS cherche uniquement apres le sweep (sequence temporelle ICT)
BreakOfStructure CSniperM15::DetectBOS(string direction, int sweepBar) {
   BreakOfStructure bos;
   bos.detected = false;
   bos.confirmed = false;
   bos.barsSinceBOS = 999;
   bos.bosLevel = 0;
   bos.bosPrice = 0;
   bos.bosTime = 0;
   bos.bosBar = -1;
   bos.direction = "NONE";

   int arraySize = ArraySize(m_close_M15);

   if(direction == "BUY") {
      for(int i = 0; i < ArraySize(m_swingHighs); i++) {
         double level = m_swingHighs[i].price;
         int swingBar = m_swingHighs[i].barIndex;

         // CORRECTION 12: Limites correctes
         // FIX ICT-B3: Si sweepBar fourni, ne chercher le BOS que APRES le sweep (j < sweepBar)
         // En ICT : Sweep se produit D'ABORD, puis le BOS confirme le retournement
         int maxJ = MathMin(swingBar, m_maxBarsAfterBOS + 5);
         if(sweepBar > 0) maxJ = MathMin(maxJ, sweepBar);

         // FIX ICT-B1 (2026-04-03): BOS uniquement sur bougies fermees (j>=1)
         // j=0 = bougie courante non fermee -> close peut encore changer -> faux signal
         for(int j = 1; j < maxJ; j++) {
            // CORRECTION 13: VÃ©rifier j+1 existe
            if(j >= arraySize || j + 1 >= arraySize) break;

            if(m_close_M15[j] > level && m_close_M15[j + 1] <= level) {
               // IMPROVE 1 (2026-04-03): BOS doit avoir un volume significatif
               // Un BOS sur doji sans volume n'est pas une vraie cassure institutionnelle
               long bosVolume = (long)iVolume(m_symbol, PERIOD_M15, j);
               long avgBosVolume = 0;
               for(int v = j + 1; v <= j + 10 && v < arraySize; v++) {
                  avgBosVolume += (long)iVolume(m_symbol, PERIOD_M15, v);
               }
               if(j + 10 < arraySize) avgBosVolume /= 10;
               else if(avgBosVolume > 0) avgBosVolume /= MathMin(10, arraySize - j - 1);
               // BOS doit avoir volume >= 70% de la moyenne (moins strict que sweep)
               if(avgBosVolume > 0 && bosVolume < (long)(avgBosVolume * 0.70)) {
                  continue; // BOS sans volume = faux signal, ignorer
               }

               bos.detected = true;
               bos.bosLevel = level;
               bos.bosPrice = m_close_M15[j];
               bos.bosTime = m_time_M15[j];
               bos.bosBar = j;
               bos.direction = "BULLISH";
               bos.confirmed = true;
               bos.barsSinceBOS = j;
               return bos;
            }
         }
      }
   } else {
      for(int i = 0; i < ArraySize(m_swingLows); i++) {
         double level = m_swingLows[i].price;
         int swingBar = m_swingLows[i].barIndex;

         // FIX ICT-B3: Limite temporelle sweep
         int maxJ = MathMin(swingBar, m_maxBarsAfterBOS + 5);
         if(sweepBar > 0) maxJ = MathMin(maxJ, sweepBar);

         // FIX ICT-B1 (2026-04-03): BOS uniquement sur bougies fermees (j>=1)
         for(int j = 1; j < maxJ; j++) {
            if(j >= arraySize || j + 1 >= arraySize) break;

            if(m_close_M15[j] < level && m_close_M15[j + 1] >= level) {
               // IMPROVE 1 (2026-04-03): BOS doit avoir un volume significatif (SELL)
               long bosVolume = (long)iVolume(m_symbol, PERIOD_M15, j);
               long avgBosVolume = 0;
               for(int v = j + 1; v <= j + 10 && v < arraySize; v++) {
                  avgBosVolume += (long)iVolume(m_symbol, PERIOD_M15, v);
               }
               if(j + 10 < arraySize) avgBosVolume /= 10;
               else if(avgBosVolume > 0) avgBosVolume /= MathMin(10, arraySize - j - 1);
               if(avgBosVolume > 0 && bosVolume < (long)(avgBosVolume * 0.70)) {
                  continue; // BOS sans volume = faux signal, ignorer
               }

               bos.detected = true;
               bos.bosLevel = level;
               bos.bosPrice = m_close_M15[j];
               bos.bosTime = m_time_M15[j];
               bos.bosBar = j;
               bos.direction = "BEARISH";
               bos.confirmed = true;
               bos.barsSinceBOS = j;
               return bos;
            }
         }
      }
   }

   return bos;
}

//+------------------------------------------------------------------+
//| Analyze Pullback Zone (Institutional ICT Style)                  |
//+------------------------------------------------------------------+
PullbackZone CSniperM15::AnalyzePullback(string direction, BreakOfStructure &bos, string timingMode) {
   PullbackZone zone;
   zone.inZone = false;
   zone.mitigated = false;
   zone.pdType = "NONE";
   zone.pdStrength = 0;
   zone.chochM5 = false;
   zone.bosM5 = false;
   zone.zoneHigh = 0;
   zone.zoneLow = 0;
   zone.optimalEntry = 0;
   zone.barsInZone = 0;
   zone.fibLevel = 0;

   if(!bos.detected) return zone;

   // CORRECTION 14: VÃ©rifier ICT Detector existe
   if(m_ictDetector == NULL) {
      Print("âš ï¸ AnalyzePullback: ICT Detector NULL");
      return zone;
   }

   // Use M5 for mitigation + timing
   RefreshM5Data();
   
   // CORRECTION 15: Valider taille array M5
   if(ArraySize(m_close_M5) < 20) {
      Print("âš ï¸ AnalyzePullback: Insufficient M5 data");
      return zone;
   }

   // Current price
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   double price = (direction == "BUY") ? ask : bid;

   // Get ATR M5
   double atrBuff[];
   ArraySetAsSeries(atrBuff, true);
   double atr = 0;
   
   if(m_hATR_M5 != INVALID_HANDLE) {
      if(CopyBuffer(m_hATR_M5, 0, 1, 3, atrBuff) >= 3) {
         atr = atrBuff[0];
      }
   }
   
   // CORRECTION 16: Validation ATR
   if(atr <= 0) {
      Print("âš ï¸ AnalyzePullback: Invalid ATR (", atr, ")");
      return zone;
   }

   // 1) Find PD array on M5 using ICT Detector
   ICT_PDArray fvg, ob;
   bool hasFVG = m_ictDetector.FindLatestFVG(direction, m_high_M5, m_low_M5, m_time_M5, 80, fvg);
   bool hasOB = m_ictDetector.FindLatestOB(direction, m_open_M5, m_close_M5, m_high_M5, m_low_M5, m_time_M5, atr, 80, 1.2, ob);

   ICT_PDArray pd;
   pd.found = false;

   // Priority: mitigated zone > closest zone
   if(hasFVG && m_ictDetector.IsMitigated(price, fvg)) {
      pd = fvg;
   }
   else if(hasOB && m_ictDetector.IsMitigated(price, ob)) {
      pd = ob;
   }
   else if(hasFVG && !hasOB) {
      pd = fvg;
   }
   else if(hasOB && !hasFVG) {
      pd = ob;
   }
   else if(hasFVG && hasOB) {
      // Choose closer zone
      double midF = (fvg.zoneHigh + fvg.zoneLow) / 2.0;
      double midO = (ob.zoneHigh + ob.zoneLow) / 2.0;
      pd = (MathAbs(price - midF) <= MathAbs(price - midO)) ? fvg : ob;
   }

   if(!pd.found) {
      return zone;
   }

   zone.zoneHigh = pd.zoneHigh;
   zone.zoneLow = pd.zoneLow;
   zone.optimalEntry = (pd.zoneHigh + pd.zoneLow) / 2.0;
   zone.pdType = pd.name;
   zone.pdStrength = pd.strength;
   zone.fibLevel = pd.strength / 100.0; // Legacy mapping

   // 2) Mitigation check
   zone.mitigated = m_ictDetector.IsMitigated(price, pd);

   if(!zone.mitigated) {
      zone.inZone = false;
      return zone;
   }

   // 3) Timing shift on M5 (CHoCH required)
   ICT_Shift sh = m_ictDetector.DetectShiftM5(direction, m_open_M5, m_close_M5, m_high_M5, m_low_M5, m_time_M5, 60, atr);

   // FIX ICT-C1 (2026-04-03): CHoCH M5 doit etre posterieur au BOS M15
   // Sequence ICT correcte : BOS M15 -> CHoCH M5 (pas l'inverse)
   // Un CHoCH M5 anterieur au BOS M15 n'est pas une confirmation valide
   if(sh.choch && bos.detected && bos.bosTime > 0) {
      // Convertir bosBar M15 en temps approximatif M5
      // BOS M15 = bos.bosBar bougies M15 en arriere
      // 1 bougie M15 = 3 bougies M5
      int bosBarInM5 = bos.bosBar * 3; // Approximation

      // Verifier que le CHoCH M5 s'est produit APRES le BOS M15
      // sh.bar = index M5 du CHoCH (0 = plus recent)
      // CHoCH valide si son index M5 < bosBarInM5 (plus recent que le BOS)
      if(sh.bar > bosBarInM5) {
         // CHoCH trop ancien — anterieur au BOS M15
         sh.choch = false;
         sh.bos = false;
         Print("[ICT-C1] CHoCH M5 invalide: anterieur au BOS M15 (choch=",
               sh.bar, " bars M5, BOS=", bos.bosBar, " bars M15 = ",
               bosBarInM5, " bars M5)");
      }
   }

   zone.chochM5 = sh.choch;
   zone.bosM5 = sh.bos;

   // Final: mitigation + confirmation = valid entry zone
   // SETUP-E (2026-04-04): En POST_NEWS, accepter pattern M5 sans CHoCH complet
   if(timingMode == "POST_NEWS_ENTRY" && zone.mitigated && !zone.chochM5) {
      // Verifier si un pattern de retournement M5 existe dans la zone
      M5Confirmation m5Check = CheckM5Confirmation(direction);
      if(m5Check.hasPattern && m5Check.patternScore >= 75) {
         zone.inZone = true;
         Print("[SETUP-E] POST_NEWS: pattern M5 ", m5Check.patternName,
               " (score=", m5Check.patternScore, ") accepte au lieu de CHoCH");
      } else {
         zone.inZone = false;
      }
   } else {
      zone.inZone = (zone.mitigated && zone.chochM5);
   }

   return zone;
}

//+------------------------------------------------------------------+
//| Check M5 Confirmation                                            |
//+------------------------------------------------------------------+
M5Confirmation CSniperM15::CheckM5Confirmation(string direction) {
   M5Confirmation confirm;
   confirm.hasPattern = false;
   confirm.pattern = PATTERN_NONE;
   confirm.patternName = "NONE";
   confirm.candleConfirm = false;
   confirm.patternScore = 0;
   
   if(!m_useM5Confirm) {
      confirm.patternScore = 50; // Neutral
      return confirm;
   }
   
   RefreshM5Data();
   
   if(ArraySize(m_close_M5) < 5) return confirm;
   
   confirm.pattern = DetectM5Pattern(direction);
   
   switch(confirm.pattern) {
      case PATTERN_PIN_BAR:
         confirm.hasPattern = true;
         confirm.patternName = "PIN_BAR";
         confirm.patternScore = 90;
         break;
      case PATTERN_ENGULFING:
         confirm.hasPattern = true;
         confirm.patternName = "ENGULFING";
         confirm.patternScore = 85;
         break;
      case PATTERN_REJECTION:
         confirm.hasPattern = true;
         confirm.patternName = "REJECTION";
         confirm.patternScore = 75;
         break;
      case PATTERN_INSIDE_BAR:
         confirm.hasPattern = true;
         confirm.patternName = "INSIDE_BAR";
         confirm.patternScore = 60;
         break;
      default:
         confirm.patternScore = 40;
   }
   
   // CORRECTION 17: VÃ©rifier index 1 existe
   if(ArraySize(m_close_M5) > 1 && ArraySize(m_open_M5) > 1) {
      if(direction == "BUY") {
         confirm.candleConfirm = (m_close_M5[1] > m_open_M5[1]);
      } else {
         confirm.candleConfirm = (m_close_M5[1] < m_open_M5[1]);
      }
      
      if(confirm.candleConfirm) confirm.patternScore += 10;
   }
   
   return confirm;
}

//+------------------------------------------------------------------+
//| Detect M5 Pattern                                                |
//+------------------------------------------------------------------+
ENUM_M5_PATTERN CSniperM15::DetectM5Pattern(string direction) {
   // CORRECTION 18: Validation taille minimum
   if(ArraySize(m_close_M5) < 3 || ArraySize(m_open_M5) < 3 ||
      ArraySize(m_high_M5) < 3 || ArraySize(m_low_M5) < 3) {
      return PATTERN_NONE;
   }
   
   double body1 = MathAbs(m_close_M5[1] - m_open_M5[1]);
   double range1 = m_high_M5[1] - m_low_M5[1];
   double body2 = MathAbs(m_close_M5[2] - m_open_M5[2]);
   
   // CORRECTION 19: Protection division par zÃ©ro
   if(range1 <= 0) return PATTERN_NONE;
   
   double bodyRatio = body1 / range1;
   
   if(direction == "BUY") {
      // Pin bar
      double lowerWick = MathMin(m_open_M5[1], m_close_M5[1]) - m_low_M5[1];
      double upperWick = m_high_M5[1] - MathMax(m_open_M5[1], m_close_M5[1]);
      
      if(lowerWick > body1 * 2 && lowerWick > upperWick * 2 && m_close_M5[1] > m_open_M5[1]) {
         return PATTERN_PIN_BAR;
      }
      
      // Bullish engulfing
      if(m_close_M5[2] < m_open_M5[2] &&
         m_close_M5[1] > m_open_M5[1] &&
         m_close_M5[1] > m_open_M5[2] &&
         m_open_M5[1] < m_close_M5[2]) {
         return PATTERN_ENGULFING;
      }
      
      // Rejection
      if(m_close_M5[1] > m_open_M5[1] && 
         (m_high_M5[1] - m_close_M5[1]) < body1 * 0.3) {
         return PATTERN_REJECTION;
      }
   } else {
      // Bearish pin bar
      double upperWick = m_high_M5[1] - MathMax(m_open_M5[1], m_close_M5[1]);
      double lowerWick = MathMin(m_open_M5[1], m_close_M5[1]) - m_low_M5[1];
      
      if(upperWick > body1 * 2 && upperWick > lowerWick * 2 && m_close_M5[1] < m_open_M5[1]) {
         return PATTERN_PIN_BAR;
      }
      
      // Bearish engulfing
      if(m_close_M5[2] > m_open_M5[2] &&
         m_close_M5[1] < m_open_M5[1] &&
         m_close_M5[1] < m_open_M5[2] &&
         m_open_M5[1] > m_close_M5[2]) {
         return PATTERN_ENGULFING;
      }
      
      // Rejection
      if(m_close_M5[1] < m_open_M5[1] && 
         (m_close_M5[1] - m_low_M5[1]) < body1 * 0.3) {
         return PATTERN_REJECTION;
      }
   }
   
   return PATTERN_NONE;
}

//+------------------------------------------------------------------+
//| Calculate Stop Loss                                              |
//+------------------------------------------------------------------+
double CSniperM15::CalculateSL(string direction, LiquiditySweep &sweep) {
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   
   // CORRECTION 20: Protection point invalide
   if(point <= 0) {
      Print("âš ï¸ CalculateSL: Invalid point (", point, ")");
      point = 0.00001; // Fallback pour XAUUSD
   }
   
   double sl = 0;
   
   if(sweep.detected && sweep.reclaimed) {
      if(direction == "BUY") {
         sl = sweep.sweepPrice - (m_slBuffer * point * 10);
      } else {
         sl = sweep.sweepPrice + (m_slBuffer * point * 10);
      }
   } else {
      if(direction == "BUY" && ArraySize(m_swingLows) > 0) {
         sl = m_swingLows[0].price - (m_slBuffer * point * 10);
      } else if(direction == "SELL" && ArraySize(m_swingHighs) > 0) {
         sl = m_swingHighs[0].price + (m_slBuffer * point * 10);
      }
   }
   
   // Calculate pips
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   double price = (direction == "BUY") ? ask : bid;
   double slPips = MathAbs(price - sl) / (point * 10);
   
   // Enforce min/max
   if(slPips < m_slMin) {
      if(direction == "BUY") sl = price - (m_slMin * point * 10);
      else sl = price + (m_slMin * point * 10);
   }
   if(slPips > m_slMax) {
      if(direction == "BUY") sl = price - (m_slMax * point * 10);
      else sl = price + (m_slMax * point * 10);
   }
   
   return sl;
}

//+------------------------------------------------------------------+
//| Check H4 Structure (for SETUP-A BOS Direct)                     |
//+------------------------------------------------------------------+
bool CSniperM15::CheckH4Structure(string direction) {
   double h4High[], h4Low[];
   ArraySetAsSeries(h4High, true);
   ArraySetAsSeries(h4Low, true);

   if(CopyHigh(m_symbol, PERIOD_H4, 1, 50, h4High) < 50) return false;
   if(CopyLow(m_symbol,  PERIOD_H4, 1, 50, h4Low)  < 50) return false;

   double swH[3], swL[3];
   int shC = 0, slC = 0;

   for(int i = 3; i < 47 && (shC < 3 || slC < 3); i++) {
      if(shC < 3 &&
         h4High[i] > h4High[i-1] && h4High[i] > h4High[i-2] &&
         h4High[i] > h4High[i+1] && h4High[i] > h4High[i+2])
         swH[shC++] = h4High[i];
      if(slC < 3 &&
         h4Low[i] < h4Low[i-1] && h4Low[i] < h4Low[i-2] &&
         h4Low[i] < h4Low[i+1] && h4Low[i] < h4Low[i+2])
         swL[slC++] = h4Low[i];
   }

   if(shC < 2 || slC < 2) return false;

   bool h4Bullish = (swH[0] > swH[1] && swL[0] > swL[1]);
   bool h4Bearish = (swH[0] < swH[1] && swL[0] < swL[1]);

   if(direction == "BUY")  return h4Bullish;
   if(direction == "SELL") return h4Bearish;
   return false;
}

//+------------------------------------------------------------------+
//| Calculate Score                                                  |
//+------------------------------------------------------------------+
int CSniperM15::CalculateScore(SniperResultM15 &result) {
   int score = 0;
   
   // Structure alignment (20 pts if aligned, 0 if not)
   if((result.structure == STRUCTURE_BULLISH && result.bos.direction == "BULLISH") ||
      (result.structure == STRUCTURE_BEARISH && result.bos.direction == "BEARISH")) {
      score += 20;
   }
   
   // Liquidity sweep (30 pts - pillar #1 ICT)
   // FIX A1 (2026-04-04): BOS Direct bypass = demi-score sweep
   if(result.sweep.detected && result.sweep.reclaimed) {
      if(result.sweep.sweepType == "BOS_DIRECT_BYPASS") {
         score += 15;  // 15 pts au lieu de 30 pour sweep virtuel
      } else {
         score += 30;
         if(result.sweep.barsSinceSweep <= 5) score += 5;
      }
   }
   
   // BOS (20 pts — pillar #2, secondary to sweep)
   if(result.bos.detected && result.bos.confirmed) {
      score += 20;
      if(result.bos.barsSinceBOS <= 5) score += 5;
   }
   
   // Pullback / PD Array (max 25 pts)
   if(result.pullback.mitigated) {
      score += 15;
      
      // PD array quality
      if(result.pullback.pdType == "FVG") score += 5;
      else if(result.pullback.pdType == "OB") score += 5;

      // Timing shift (key!)
      if(result.pullback.chochM5) score += 10;
      if(result.pullback.bosM5) score += 5;
   }
   
   // FIX ICT-F1 (2026-04-03): Zone OTE etendue a 50%-78.6% (ICT standard)
   // Avant : 61.8%-78.6% (trop etroite, ratait les entrees entre 50% et 61.8%)
   if(ArraySize(m_swingHighs) > 0 && ArraySize(m_swingLows) > 0) {
      double swH = m_swingHighs[0].price;
      double swL = m_swingLows[0].price;
      double range = swH - swL;
      if(range > 0) {
         double price = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         if(result.bos.direction == "BULLISH") {
            // BUY: retracement from high down into OTE zone
            double fibLow  = swH - range * m_fibEntryMax;   // 78.6% retracement -- bas de zone OTE
            double fibHigh = swH - range * m_fibEntryMin;   // 50% retracement  -- haut de zone OTE
            if(price >= fibLow && price <= fibHigh)
               score += 10;
         } else if(result.bos.direction == "BEARISH") {
            // SELL: retracement from low up into OTE zone
            double fibLow  = swL + range * m_fibEntryMin;  // 50% retracement  -- bas de zone OTE
            double fibHigh = swL + range * m_fibEntryMax;  // 78.6% retracement -- haut de zone OTE
            if(price >= fibLow && price <= fibHigh)
               score += 10;
         }
      }
   }

   // M5 Confirmation (15 pts max)
   if(m_useM5Confirm) {
      score += (int)(result.m5Confirm.patternScore * 0.15);
   } else {
      score += 10;
   }
   
   // Session boost
   score += result.sessionBoost;

   // DEAL: Log du score avant/apres H4 pour traçabilite
   Print("[DEAL-SCORE] Score avant H4: ", score);
   // Le score H4 est integre via CheckTrendH4 qui autorise/bloque
   // L ajustement fin se fait via le scoreThreshold

   return MathMin(100, MathMax(0, score));
}

//+------------------------------------------------------------------+
//| Get Active Session                                               |
//+------------------------------------------------------------------+
string CSniperM15::GetActiveSession() {
   // FIX TIMEZONE (2026-04-05): TimeGMT() pour coherence avec VPS UTC
   // TimeCurrent() retourne heure serveur (UTC+2/+3), pas GMT
   MqlDateTime dt;
   TimeGMT(dt);
   int hour = dt.hour;
   
   if(hour >= 7 && hour < 9) return "LONDON_OPEN";
   if(hour >= 9 && hour < 12) return "LONDON";
   if(hour >= 12 && hour < 14) return "LONDON_NY_OVERLAP";
   if(hour >= 14 && hour < 17) return "NEW_YORK";
   if(hour >= 0 && hour < 7) return "ASIAN";
   
   return "OFF_HOURS";
}

//+------------------------------------------------------------------+
//| Get Session Boost                                                |
//+------------------------------------------------------------------+
int CSniperM15::GetSessionBoost(string session) {
   if(!m_boostSession) return 0;

   if(session == "LONDON_NY_OVERLAP") return 10;
   if(session == "LONDON_OPEN") return 7;
   if(session == "NEW_YORK" || session == "LONDON") return 5;
   if(session == "ASIAN") return 3;

   return 0;  // OFF_HOURS
}

//+------------------------------------------------------------------+
//| Check Spread                                                     |
//+------------------------------------------------------------------+
bool CSniperM15::CheckSpread() {
   long spread = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
   return (spread <= (long)(m_maxSpread * 10));
}

//+------------------------------------------------------------------+
//| MAIN ENTRY ANALYSIS                                              |
//+------------------------------------------------------------------+
SniperResultM15 CSniperM15::AnalyzeEntry(string direction, double confidence, string timingMode) {
   SniperResultM15 result;
   result.isValid = false;
   result.score = 0;
   result.reason = "";
   result.signalTime = TimeCurrent();
   result.activeSession = GetActiveSession();
   result.sessionBoost = GetSessionBoost(result.activeSession);
   
   // Safety checks
   if(!m_initialized) {
      result.reason = "Sniper not initialized";
      m_lastResult = result;
      return result;
   }
   
   if(!CheckSpread()) {
      result.reason = "Spread too high";
      m_lastResult = result;
      return result;
   }
   
   // Refresh data
   RefreshM15Data();
   DetectSwingPoints();
   
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   if(point <= 0) point = 0.00001;
   
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   double price = (direction == "BUY") ? ask : bid;
   
   // Step 1: Analyze Structure
   result.structure = AnalyzeStructure(direction);
   
   // Step 2: Detect Liquidity Sweep
   // PHASE 2 APPROCHE A (2026-04-14) : flag Enable_ICT_Liquidity (EA) injecte
   // via SetUseICTLiquidity() — bascule entre pivots 4/4 et niveaux ICT reels.
   if(m_useICTLiquidity && m_liquidity != NULL) {
      // NOUVELLE VERSION ICT (PDH/PDL/PWH/PWL/London/Asian/EQL)
      result.sweep = DetectLiquiditySweep_ICT(direction);
   } else {
      // ANCIENNE VERSION conservee (pivots 4/4) — rollback possible
      result.sweep = DetectLiquiditySweep(direction);
   }
   
   // SETUP-A (2026-04-04): BOS Direct si H4 forte + confidence elevee
   bool allowBOSDirect = false;
   if(!result.sweep.detected && m_requireSweep) {
      bool highConfidence = (confidence >= 75.0);
      bool h4Strong = CheckH4Structure(direction);
      if(highConfidence && h4Strong) {
         allowBOSDirect = true;
         // FIX SETUP-A (2026-04-04): Marquer le sweep comme valide par BOS Direct
         // Le gate EA verifie sweep.detected, on le met a true avec type special
         result.sweep.detected = true;
         result.sweep.sweepType = "BOS_DIRECT_BYPASS";
         result.sweep.reclaimed = true;
         result.sweep.barsSinceSweep = 0;
         Print("[SETUP-A] BOS Direct active: confidence=", DoubleToString(confidence, 0),
               "% H4 forte -> sweep marque comme valide");
      }
   }

   if(m_requireSweep && !result.sweep.detected && !allowBOSDirect) {
      result.reason = "No liquidity sweep detected";
      m_lastResult = result;
      return result;
   }
   
   if(result.sweep.detected && !result.sweep.reclaimed) {
      result.reason = "Sweep not reclaimed yet";
      m_lastResult = result;
      return result;
   }
   
   if(result.sweep.detected && result.sweep.barsSinceSweep > m_maxBarsAfterSweep) {
      result.reason = "Sweep too old (" + IntegerToString(result.sweep.barsSinceSweep) + " bars)";
      m_lastResult = result;
      return result;
   }
   
   // Step 3: Detect BOS
   // FIX ICT-B3: Passer le sweepBar pour garantir BOS apres sweep
   int sweepBarIndex = result.sweep.detected ? result.sweep.sweepBar : -1;
   result.bos = DetectBOS(direction, sweepBarIndex);
   
   if(m_requireBOS && !result.bos.detected) {
      result.reason = "No BOS detected";
      m_lastResult = result;
      return result;
   }
   
   if(result.bos.detected && !result.bos.confirmed) {
      result.reason = "BOS not confirmed";
      m_lastResult = result;
      return result;
   }
   
   if(result.bos.detected && result.bos.barsSinceBOS > m_maxBarsAfterBOS) {
      result.reason = "BOS too old (" + IntegerToString(result.bos.barsSinceBOS) + " bars)";
      m_lastResult = result;
      return result;
   }
   
   // Step 4: Analyze Pullback
   result.pullback = AnalyzePullback(direction, result.bos, timingMode);
   
   if(!result.pullback.mitigated) {
      result.reason = "No mitigation on M5 PD array";
      m_lastResult = result;
      return result;
   }
   
   if(result.pullback.mitigated && !result.pullback.chochM5) {
      result.reason = "Mitigated " + result.pullback.pdType + " but no CHoCH M5";
      m_lastResult = result;
      return result;
   }
   
   // Step 5: M5 Confirmation
   result.m5Confirm = CheckM5Confirmation(direction);
   
   // Step 6: Calculate Score
   result.score = CalculateScore(result);
   
   // Step 7: Calculate Trade Setup
   result.entryPrice = price;
   result.stopLoss = CalculateSL(direction, result.sweep);
   result.slPips = MathAbs(result.entryPrice - result.stopLoss) / (point * 10);
   
   // Validate
   if(result.score >= m_minScore) {
      result.isValid = true;
      result.reason = "VALID - Score " + IntegerToString(result.score);
   } else {
      result.reason = "Score too low (" + IntegerToString(result.score) + "/" + IntegerToString(m_minScore) + ")";
   }
   
   m_lastResult = result;
   return result;
}

//+------------------------------------------------------------------+
//| Print Analysis                                                   |
//+------------------------------------------------------------------+
void CSniperM15::PrintAnalysis(SniperResultM15 &result) {
   Print("â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—");
   Print("â•‘           SNIPER M15 ANALYSIS                             â•‘");
   Print("â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
   Print("  Valid: ", result.isValid ? "YES âœ…" : "NO âŒ");
   Print("  Score: ", result.score, "/100");
   Print("  Reason: ", result.reason);
   Print("â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€");
   Print("  Structure: ", EnumToString(result.structure));
   Print("  Sweep: ", result.sweep.detected ? "YES" : "NO", 
          result.sweep.detected ? " (bar " + IntegerToString(result.sweep.barsSinceSweep) + ")" : "");
   Print("  BOS: ", result.bos.detected ? result.bos.direction : "NONE",
          result.bos.detected ? " (bar " + IntegerToString(result.bos.barsSinceBOS) + ")" : "");
   Print("  Pullback: ", result.pullback.mitigated ? "MITIGATED" : "NO",
          " | PD: ", result.pullback.pdType,
          " | CHoCH M5: ", result.pullback.chochM5 ? "YES" : "NO");
   Print("  M5 Pattern: ", result.m5Confirm.patternName);
   Print("â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€");
   Print("  Entry: ", DoubleToString(result.entryPrice, 2));
   Print("  SL: ", DoubleToString(result.stopLoss, 2), " (", DoubleToString(result.slPips, 1), " pips)");
   Print("  Session: ", result.activeSession, " (+", result.sessionBoost, ")");
   Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
}
//+------------------------------------------------------------------+