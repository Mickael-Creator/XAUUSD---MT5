//+------------------------------------------------------------------+
//| GoldML_LiquidityLevels.mqh                                       |
//| Phase 1 Approche A — Infrastructure niveaux ICT                  |
//|                                                                  |
//| Fournit les vrais niveaux de liquidite institutionnels :         |
//|   - PDH / PDL    (Previous Day High/Low)                         |
//|   - PWH / PWL    (Previous Week High/Low, 7 jours glissants)     |
//|   - Asian Range  (00:00-07:00 GMT)                               |
//|   - London Range (07:00-12:00 GMT)                               |
//|   - Equal Highs/Lows (wicks dans tolerance 0.03 x ATR M15,       |
//|                       max 3 de chaque, espacement >= 10 bougies, |
//|                       creux entre pivots >= 1.0 x ATR)           |
//|                                                                  |
//| Phase 1 : infrastructure seule, non branchee sur                 |
//| DetectLiquiditySweep. Activation via Enable_ICT_Liquidity        |
//| (flag EA), effective en Phase 2 lors de la reecriture du sweep.  |
//+------------------------------------------------------------------+
#property copyright "Gold ML System - Institutional Grade"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| STRUCT : Liquidity Level                                         |
//+------------------------------------------------------------------+
struct LiquidityLevel {
   double   price;      // Prix du niveau
   string   type;       // PDH/PDL/PWH/PWL/ASIAN_H/ASIAN_L/LONDON_H/LONDON_L/EQL_H/EQL_L
   datetime timestamp;  // Moment de formation
   bool     active;     // true tant que non sweepe
   double   strength;   // Force 0-100 (PWH/PWL=90, PDH/PDL=80, London=75, Asian=70, EQL=65)
};

//+------------------------------------------------------------------+
//| CLASS : CLiquidityLevels                                         |
//+------------------------------------------------------------------+
class CLiquidityLevels {
private:
   LiquidityLevel m_levels[];
   int            m_count;
   string         m_symbol;

   void AddLevel(LiquidityLevel &lvl);

public:
   CLiquidityLevels(string symbol);
   ~CLiquidityLevels();

   // Calcul
   void RefreshAllLevels();
   void CalculatePDH_PDL();
   void CalculatePWH_PWL();
   void CalculateAsianRange();
   void CalculateLondonRange();
   void DetectEqualHighsLows();

   // Acces
   int            GetLevelCount()    { return m_count; }
   LiquidityLevel GetLevel(int i)    { return m_levels[i]; }

   // Recherche du niveau le plus proche
   bool FindNearestBullishLevel(double currentPrice, double &level, string &type);
   bool FindNearestBearishLevel(double currentPrice, double &level, string &type);

   // Marquage post-sweep (Phase 2)
   void MarkLevelSwept(int index);
};

//+------------------------------------------------------------------+
//| Constructor                                                       |
//+------------------------------------------------------------------+
CLiquidityLevels::CLiquidityLevels(string symbol) {
   m_symbol = symbol;
   m_count  = 0;
   ArrayResize(m_levels, 0);
}

//+------------------------------------------------------------------+
//| Destructor                                                        |
//+------------------------------------------------------------------+
CLiquidityLevels::~CLiquidityLevels() {
   ArrayFree(m_levels);
}

//+------------------------------------------------------------------+
//| AddLevel — ajoute un niveau, deduplique a 1 pip pres             |
//| Cap absolu : 10 niveaux max (garde-fou anti-explosion)           |
//+------------------------------------------------------------------+
void CLiquidityLevels::AddLevel(LiquidityLevel &lvl) {
   if(m_count >= 10) {
      Print("[LIQ] Cap 10 niveaux atteint — ignore");
      return;
   }

   double pipSize = SymbolInfoDouble(m_symbol, SYMBOL_POINT) * 10.0;
   if(pipSize <= 0.0) pipSize = 0.01;

   for(int i = 0; i < m_count; i++) {
      if(MathAbs(m_levels[i].price - lvl.price) < pipSize * 1.0)
         return; // Doublon
   }

   ArrayResize(m_levels, m_count + 1);
   m_levels[m_count] = lvl;
   m_count++;
}

//+------------------------------------------------------------------+
//| CalculatePDH_PDL — Previous Day High/Low                         |
//+------------------------------------------------------------------+
void CLiquidityLevels::CalculatePDH_PDL() {
   double pdh = iHigh(m_symbol, PERIOD_D1, 1);
   double pdl = iLow(m_symbol,  PERIOD_D1, 1);

   if(pdh <= 0.0 || pdl <= 0.0) return;

   LiquidityLevel lvl;
   lvl.price     = pdh;
   lvl.type      = "PDH";
   lvl.timestamp = iTime(m_symbol, PERIOD_D1, 1);
   lvl.active    = true;
   lvl.strength  = 80.0;
   AddLevel(lvl);

   lvl.price     = pdl;
   lvl.type      = "PDL";
   lvl.timestamp = iTime(m_symbol, PERIOD_D1, 1);
   lvl.active    = true;
   lvl.strength  = 80.0;
   AddLevel(lvl);

   Print("[LIQ] PDH=", DoubleToString(pdh, 2),
         " PDL=", DoubleToString(pdl, 2));
}

//+------------------------------------------------------------------+
//| CalculatePWH_PWL — High/Low sur 7 jours glissants                |
//+------------------------------------------------------------------+
void CLiquidityLevels::CalculatePWH_PWL() {
   double pwHigh = 0.0;
   double pwLow  = 999999.0;

   for(int i = 1; i <= 7; i++) {
      double h = iHigh(m_symbol, PERIOD_D1, i);
      double l = iLow(m_symbol,  PERIOD_D1, i);

      if(h > pwHigh)            pwHigh = h;
      if(l > 0.0 && l < pwLow)  pwLow  = l;
   }

   if(pwHigh <= 0.0 || pwLow >= 999999.0) return;

   LiquidityLevel lvl;
   lvl.price     = pwHigh;
   lvl.type      = "PWH";
   lvl.timestamp = iTime(m_symbol, PERIOD_D1, 7);
   lvl.active    = true;
   lvl.strength  = 90.0;
   AddLevel(lvl);

   lvl.price     = pwLow;
   lvl.type      = "PWL";
   lvl.timestamp = iTime(m_symbol, PERIOD_D1, 7);
   lvl.active    = true;
   lvl.strength  = 90.0;
   AddLevel(lvl);

   Print("[LIQ] PWH=", DoubleToString(pwHigh, 2),
         " PWL=", DoubleToString(pwLow, 2));
}

//+------------------------------------------------------------------+
//| CalculateAsianRange — 00:00-07:00 GMT                            |
//+------------------------------------------------------------------+
void CLiquidityLevels::CalculateAsianRange() {
   double asianHigh = 0.0;
   double asianLow  = 999999.0;
   bool   found     = false;

   for(int i = 1; i < 100; i++) {
      datetime t = iTime(m_symbol, PERIOD_M15, i);
      if(t <= 0) break;

      // Conversion heure serveur -> GMT (coherent avec DetectLondonRangeSetup)
      datetime tGMT = t - (TimeCurrent() - TimeGMT());
      MqlDateTime dt;
      TimeToStruct(tGMT, dt);
      int hour = dt.hour;

      if(hour >= 0 && hour < 7) {
         double h = iHigh(m_symbol, PERIOD_M15, i);
         double l = iLow(m_symbol,  PERIOD_M15, i);
         if(h > asianHigh)            asianHigh = h;
         if(l > 0.0 && l < asianLow)  asianLow  = l;
         found = true;
      }
      else if(hour >= 7 && found) break;
   }

   if(!found || asianHigh <= 0.0 || asianLow >= 999999.0) return;

   double pipSize = SymbolInfoDouble(m_symbol, SYMBOL_POINT) * 10.0;
   if(pipSize <= 0.0) pipSize = 0.01;
   double rangeSize = (asianHigh - asianLow) / pipSize;

   // FIX 2026-04-17: cap dynamique = 2 x ATR D1 (defaut 150 pips si ATR indispo)
   // Ancien filtre fixe 10-80 pips rejettait toutes les sessions Gold volatiles
   double maxRange = 150.0;
   int hATR_D1 = iATR(m_symbol, PERIOD_D1, 14);
   if(hATR_D1 != INVALID_HANDLE) {
      double atrD1[];
      ArraySetAsSeries(atrD1, true);
      if(CopyBuffer(hATR_D1, 0, 0, 1, atrD1) >= 1 && atrD1[0] > 0.0) {
         double atrPips = atrD1[0] / pipSize;
         maxRange = atrPips * 2.0;
      }
      IndicatorRelease(hATR_D1);
   }

   if(rangeSize < 10.0 || rangeSize > maxRange) {
      Print("[LIQ] Asian range hors bornes (", DoubleToString(rangeSize, 0),
            " pips) — cap=", DoubleToString(maxRange, 0),
            " pips (2 x ATR D1) — niveaux non ajoutes");
      return;
   }

   LiquidityLevel lvl;
   lvl.price     = asianHigh;
   lvl.type      = "ASIAN_H";
   lvl.timestamp = TimeCurrent();
   lvl.active    = true;
   lvl.strength  = 70.0;
   AddLevel(lvl);

   lvl.price     = asianLow;
   lvl.type      = "ASIAN_L";
   lvl.timestamp = TimeCurrent();
   lvl.active    = true;
   lvl.strength  = 70.0;
   AddLevel(lvl);

   Print("[LIQ] Asian Range: H=", DoubleToString(asianHigh, 2),
         " L=", DoubleToString(asianLow, 2),
         " Size=", DoubleToString(rangeSize, 0), " pips");
}

//+------------------------------------------------------------------+
//| CalculateLondonRange — 07:00-12:00 GMT, fige apres 12:00 GMT     |
//+------------------------------------------------------------------+
void CLiquidityLevels::CalculateLondonRange() {
   MqlDateTime now;
   TimeGMT(now);
   if(now.hour < 12) return; // Range pas encore complet

   double londonHigh = 0.0;
   double londonLow  = 999999.0;
   bool   found      = false;

   for(int i = 1; i < 60; i++) {
      datetime t = iTime(m_symbol, PERIOD_M15, i);
      if(t <= 0) break;

      datetime tGMT = t - (TimeCurrent() - TimeGMT());
      MqlDateTime dt;
      TimeToStruct(tGMT, dt);
      int hour = dt.hour;

      if(hour >= 7 && hour < 12) {
         double h = iHigh(m_symbol, PERIOD_M15, i);
         double l = iLow(m_symbol,  PERIOD_M15, i);
         if(h > londonHigh)             londonHigh = h;
         if(l > 0.0 && l < londonLow)   londonLow  = l;
         found = true;
      }
   }

   if(!found || londonHigh <= 0.0 || londonLow >= 999999.0) return;

   LiquidityLevel lvl;
   lvl.price     = londonHigh;
   lvl.type      = "LONDON_H";
   lvl.timestamp = TimeCurrent();
   lvl.active    = true;
   lvl.strength  = 75.0;
   AddLevel(lvl);

   lvl.price     = londonLow;
   lvl.type      = "LONDON_L";
   lvl.timestamp = TimeCurrent();
   lvl.active    = true;
   lvl.strength  = 75.0;
   AddLevel(lvl);

   Print("[LIQ] London Range: H=", DoubleToString(londonHigh, 2),
         " L=", DoubleToString(londonLow, 2));
}

//+------------------------------------------------------------------+
//| DetectEqualHighsLows — wicks egaux (tolerance 0.03 x ATR)        |
//| Max 3 de chaque cote, espacement >= 10 bougies M15, creux 1.0xATR|
//+------------------------------------------------------------------+
void CLiquidityLevels::DetectEqualHighsLows() {
   int hATR = iATR(m_symbol, PERIOD_M15, 14);
   if(hATR == INVALID_HANDLE) return;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR, 0, 0, 3, atr) < 3) {
      IndicatorRelease(hATR);
      return;
   }
   double atrVal    = atr[0];
   // FIX 2026-04-17: tolerance 0.03 -> 0.05 x ATR (plus permissif equal wicks)
   double tolerance = atrVal * 0.05;
   IndicatorRelease(hATR);

   if(atrVal <= 0.0 || tolerance <= 0.0) return;

   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows,  true);

   if(CopyHigh(m_symbol, PERIOD_M15, 1, 100, highs) < 100) return;
   if(CopyLow(m_symbol,  PERIOD_M15, 1, 100, lows)  < 100) return;

   const int MAX_EQL      = 3;     // max 3 Equal Highs + 3 Equal Lows
   // FIX 2026-04-17: gap 10 -> 20 bougies M15 (5h) entre 2 EQL meme cote
   const int MIN_BAR_GAP  = 20;
   int    foundBarsH[];
   int    foundBarsL[];
   int    nHigh = 0;
   int    nLow  = 0;
   int    equalHighCount = 0;      // compteur strict double-ceinture
   int    equalLowCount  = 0;
   ArrayResize(foundBarsH, MAX_EQL);
   ArrayResize(foundBarsL, MAX_EQL);

   // Equal Highs
   for(int i = 5; i < 95 && nHigh < MAX_EQL; i++) {
      for(int j = i + 3; j < 100; j++) {
         if(MathAbs(highs[i] - highs[j]) <= tolerance) {
            double minBetween = 999999.0;
            for(int k = i + 1; k < j; k++)
               if(lows[k] < minBetween) minBetween = lows[k];

            // FIX 2026-04-17: creux significatif 1.0 -> 1.5 x ATR (filtre plus exigeant)
            if(highs[i] - minBetween > atrVal * 1.5) {
               // Espacement temporel minimum vs Equal Highs deja trouves
               bool tooClose = false;
               for(int n = 0; n < nHigh; n++)
                  if(MathAbs(foundBarsH[n] - i) < MIN_BAR_GAP) {
                     tooClose = true;
                     break;
                  }
               if(tooClose) { break; }

               if(equalHighCount >= 3) break; // garde stricte
               double candidate = (highs[i] + highs[j]) / 2.0;
               LiquidityLevel lvl;
               lvl.price     = candidate;
               lvl.type      = "EQL_H";
               lvl.timestamp = iTime(m_symbol, PERIOD_M15, i);
               lvl.active    = true;
               lvl.strength  = 65.0;
               AddLevel(lvl);
               equalHighCount++;
               foundBarsH[nHigh++] = i;
               Print("[LIQ] Equal High detecte: ",
                     DoubleToString(candidate, 2));
               break; // un seul par zone
            }
         }
      }
   }

   // Equal Lows
   for(int i = 5; i < 95 && nLow < MAX_EQL; i++) {
      for(int j = i + 3; j < 100; j++) {
         if(MathAbs(lows[i] - lows[j]) <= tolerance) {
            double maxBetween = 0.0;
            for(int k = i + 1; k < j; k++)
               if(highs[k] > maxBetween) maxBetween = highs[k];

            // FIX 2026-04-17: sommet significatif 1.0 -> 1.5 x ATR
            if(maxBetween - lows[i] > atrVal * 1.5) {
               bool tooClose = false;
               for(int n = 0; n < nLow; n++)
                  if(MathAbs(foundBarsL[n] - i) < MIN_BAR_GAP) {
                     tooClose = true;
                     break;
                  }
               if(tooClose) { break; }

               if(equalLowCount >= 3) break; // garde stricte
               double candidate = (lows[i] + lows[j]) / 2.0;
               LiquidityLevel lvl;
               lvl.price     = candidate;
               lvl.type      = "EQL_L";
               lvl.timestamp = iTime(m_symbol, PERIOD_M15, i);
               lvl.active    = true;
               lvl.strength  = 65.0;
               AddLevel(lvl);
               equalLowCount++;
               foundBarsL[nLow++] = i;
               Print("[LIQ] Equal Low detecte: ",
                     DoubleToString(candidate, 2));
               break;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| RefreshAllLevels — reset + recalcul complet                      |
//+------------------------------------------------------------------+
void CLiquidityLevels::RefreshAllLevels() {
   m_count = 0;
   ArrayResize(m_levels, 0);

   CalculatePDH_PDL();
   CalculatePWH_PWL();
   CalculateAsianRange();
   CalculateLondonRange();
   // FIX 2026-04-17: REACTIVE avec parametres stricts
   //   - tolerance 0.05 x ATR (vs 0.03)
   //   - gap minimum 20 bougies (vs 10)
   //   - creux/sommet 1.5 x ATR (vs 1.0)
   //   - max 3 EQL_H + 3 EQL_L
   // Cap absolu m_count <= 10 niveaux toujours actif (AddLevel)
   DetectEqualHighsLows();

   // LOG D (2026-04-17) : detail des niveaux ICT actifs apres refresh
   Print("== NIVEAUX ICT ACTIFS ==");
   for(int i = 0; i < m_count; i++) {
      Print("  [", m_levels[i].type, "] ",
            DoubleToString(m_levels[i].price, 2),
            " | Force: ", DoubleToString(m_levels[i].strength, 0),
            " | Actif: ", m_levels[i].active ? "OUI" : "NON");
   }
   Print("== Total: ", m_count, " niveaux ==");
}

//+------------------------------------------------------------------+
//| FindNearestBullishLevel — niveau de support le plus proche       |
//+------------------------------------------------------------------+
bool CLiquidityLevels::FindNearestBullishLevel(double currentPrice,
                                                double &level,
                                                string &type) {
   double closest     = 0.0;
   string closestType = "";

   for(int i = 0; i < m_count; i++) {
      if(!m_levels[i].active) continue;
      if(m_levels[i].price >= currentPrice) continue;

      if(m_levels[i].price > closest) {
         closest     = m_levels[i].price;
         closestType = m_levels[i].type;
      }
   }

   if(closest <= 0.0) return false;

   level = closest;
   type  = closestType;
   return true;
}

//+------------------------------------------------------------------+
//| FindNearestBearishLevel — niveau de resistance le plus proche    |
//+------------------------------------------------------------------+
bool CLiquidityLevels::FindNearestBearishLevel(double currentPrice,
                                                double &level,
                                                string &type) {
   double closest     = 999999.0;
   string closestType = "";

   for(int i = 0; i < m_count; i++) {
      if(!m_levels[i].active) continue;
      if(m_levels[i].price <= currentPrice) continue;

      if(m_levels[i].price < closest) {
         closest     = m_levels[i].price;
         closestType = m_levels[i].type;
      }
   }

   if(closest >= 999999.0) return false;

   level = closest;
   type  = closestType;
   return true;
}

//+------------------------------------------------------------------+
//| MarkLevelSwept — marque un niveau comme consomme (Phase 2)       |
//+------------------------------------------------------------------+
void CLiquidityLevels::MarkLevelSwept(int index) {
   if(index < 0 || index >= m_count) return;
   m_levels[index].active = false;
}
//+------------------------------------------------------------------+
