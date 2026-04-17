//+------------------------------------------------------------------+
//| GoldML_ICT_Detector.mqh                                         |
//| ICT Microstructure Detector (M15 context + M5 timing)            |
//|                                                                  |
//| Purpose: provide reusable detection for:                          |
//|  - CHoCH / BOS (M15 & M5)                                         |
//|  - PD Arrays: FVG / Order Block (M5)                              |
//|  - Mitigation + reaction checks                                   |
//|                                                                  |
//| Notes: Designed for XAUUSD fast execution around news.            |
//| This is NOT a full SMC engine; it focuses on robust, code-friendly |
//| primitives that reduce "too early" entries.                       |
//+------------------------------------------------------------------+
#property strict
#property copyright "Gold ML System - Institutional Grade"
#property version   "1.10"

// -----------------------------
// Helpers / types
// -----------------------------
enum ENUM_ICT_PD_TYPE
{
  ICT_PD_NONE = 0,
  ICT_PD_FVG  = 1,
  ICT_PD_OB   = 2
};

struct ICT_PDArray
{
  bool      found;
  ENUM_ICT_PD_TYPE type;
  double    zoneHigh;
  double    zoneLow;
  datetime  createdTime;
  int       createdBar;     // bar index in the series array (0=current)
  double    strength;       // 0..100 (heuristic)
  string    name;           // "FVG" / "OB"
};

struct ICT_Shift
{
  bool     choch;           // change of character detected
  bool     bos;             // break of structure (continuation) detected
  double   breakLevel;      // level that was broken
  datetime time;
  int      bar;
};

//+------------------------------------------------------------------+
//| ICT DETECTOR CLASS                                               |
//+------------------------------------------------------------------+
class CICT_Detector
{
private:
   string   m_symbol;
   
   // Internal pivot detection methods
   bool IsPivotHigh(const double &high[], int i, int left, int right);
   bool IsPivotLow(const double &low[], int i, int left, int right);
   bool FindRecentPivotHigh(const double &high[], int lookback, double &pivot, int &barIndex, int left, int right);
   bool FindRecentPivotLow(const double &low[], int lookback, double &pivot, int &barIndex, int left, int right);
   
public:
   CICT_Detector(string symbol);
   ~CICT_Detector();
   
   // Public detection methods
   bool FindLatestFVG(const string direction,
                      const double &high[], const double &low[],
                      const datetime &time[],
                      int lookbackBars,
                      ICT_PDArray &outPd);
   
   bool FindLatestOB(const string direction,
                     const double &open[], const double &close[],
                     const double &high[], const double &low[],
                     const datetime &time[],
                     const double atr,
                     int lookbackBars,
                     double atrMult,
                     ICT_PDArray &outPd);
   
   // FIX P2 (2026-04-17) : tolerance optionnelle (typiquement 0.1 x ATR M5)
   bool IsMitigated(const double price, const ICT_PDArray &pd, const double tolerance = 0.0);
   
   ICT_Shift DetectShiftM5(const string direction,
                           const double &open[], const double &close[],
                           const double &high[], const double &low[],
                           const datetime &time[],
                           int lookbackBars,
                           const double atr);
};

//+------------------------------------------------------------------+
//| Constructor                                                       |
//+------------------------------------------------------------------+
CICT_Detector::CICT_Detector(string symbol)
{
   m_symbol = symbol;
}

//+------------------------------------------------------------------+
//| Destructor                                                        |
//+------------------------------------------------------------------+
CICT_Detector::~CICT_Detector()
{
   // Cleanup if needed
}

//+------------------------------------------------------------------+
//| Pivot High Detection                                             |
//+------------------------------------------------------------------+
bool CICT_Detector::IsPivotHigh(const double &high[], int i, int left=2, int right=2)
{
   int n = ArraySize(high);
   
   // CORRECTION 1: VÃ©rifier les limites du tableau
   if(i + left >= n || i - right < 0) return false;
   
   // VÃ©rifier gauche
   for(int k=1; k<=left; k++) {
      if(i+k >= n) return false;  // CORRECTION 2: Double-check
      if(high[i] <= high[i+k]) return false;
   }
   
   // VÃ©rifier droite
   for(int k=1; k<=right; k++) {
      if(i-k < 0) return false;   // CORRECTION 3: Double-check
      if(high[i] <= high[i-k]) return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Pivot Low Detection                                              |
//+------------------------------------------------------------------+
bool CICT_Detector::IsPivotLow(const double &low[], int i, int left=2, int right=2)
{
   int n = ArraySize(low);
   
   // CORRECTION 4: VÃ©rifier les limites du tableau
   if(i + left >= n || i - right < 0) return false;
   
   // VÃ©rifier gauche
   for(int k=1; k<=left; k++) {
      if(i+k >= n) return false;
      if(low[i] >= low[i+k]) return false;
   }
   
   // VÃ©rifier droite
   for(int k=1; k<=right; k++) {
      if(i-k < 0) return false;
      if(low[i] >= low[i-k]) return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Find Recent Pivot High                                           |
//+------------------------------------------------------------------+
bool CICT_Detector::FindRecentPivotHigh(const double &high[], int lookback, 
                                         double &pivot, int &barIndex, 
                                         int left=2, int right=2)
{
   pivot = 0; 
   barIndex = -1;
   
   int n = ArraySize(high);
   if(n < left + right + 1) return false;  // CORRECTION 5: Minimum bars nÃ©cessaires
   
   // CORRECTION 6: Calculer maxI correctement
   int maxI = MathMin(lookback, n - right - 1);
   int startI = left + 1;  // CORRECTION 7: Ne pas commencer trop tÃ´t
   
   if(startI > maxI) return false;
   
   for(int i=startI; i<=maxI; i++)
   {
      if(IsPivotHigh(high, i, left, right))
      {
         pivot = high[i];
         barIndex = i;
         return true;  // Premier pivot trouvÃ© (plus rÃ©cent)
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Find Recent Pivot Low                                            |
//+------------------------------------------------------------------+
bool CICT_Detector::FindRecentPivotLow(const double &low[], int lookback, 
                                        double &pivot, int &barIndex, 
                                        int left=2, int right=2)
{
   pivot = 0; 
   barIndex = -1;
   
   int n = ArraySize(low);
   if(n < left + right + 1) return false;
   
   int maxI = MathMin(lookback, n - right - 1);
   int startI = left + 1;
   
   if(startI > maxI) return false;
   
   for(int i=startI; i<=maxI; i++)
   {
      if(IsPivotLow(low, i, left, right))
      {
         pivot = low[i];
         barIndex = i;
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Find Latest FVG                                                   |
//+------------------------------------------------------------------+
bool CICT_Detector::FindLatestFVG(const string direction,
                                   const double &high[], const double &low[],
                                   const datetime &time[],
                                   int lookbackBars,
                                   ICT_PDArray &outPd)
{
   // Reset output
   outPd.found = false;
   outPd.type = ICT_PD_NONE;
   outPd.zoneHigh = 0;
   outPd.zoneLow  = 0;
   outPd.createdBar = -1;
   outPd.createdTime = 0;
   outPd.strength = 0;
   outPd.name = "NONE";

   int n = ArraySize(high);
   if(n < 5) return false;  // Minimum 5 bars pour FVG (aligned with OB minimum)

   // CORRECTION 8: Limites correctes pour FVG (besoin i-1 et i+1)
   int maxBar = MathMin(lookbackBars, n - 2);
   
   // Scanner depuis la structure la plus rÃ©cente fermÃ©e: i=2 (car besoin i-1)
   for(int i=2; i<=maxBar; i++)
   {
      // CORRECTION 9: VÃ©rifier que les indices sont valides
      if(i-1 < 0 || i+1 >= n) continue;
      
      if(direction == "BUY")
      {
         // FVG bullish: low[i-1] > high[i+1]
         // top = low[i-1]  -> upper bound of gap (more recent bar's low)
         // bot = high[i+1] -> lower bound of gap (older bar's high)
         // top > bot is guaranteed by the entry condition above
         double top = low[i-1];
         double bot = high[i+1];
         
         // CORRECTION 10: Validation du gap
         double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
         if(point == 0) point = 0.00001;  // Fallback
         
         if(top > bot && (top - bot) > point * 10)  // Gap significatif (>1 pip)
         {
            outPd.found = true;
            outPd.type  = ICT_PD_FVG;
            outPd.zoneHigh = top;
            outPd.zoneLow  = bot;
            outPd.createdBar = i;
            outPd.createdTime = time[i];
            outPd.name = "FVG";
            
            // CORRECTION 11: Calcul strength amÃ©liorÃ©
            double gap = top - bot;
            double gapPips = gap / (point * 10);
            outPd.strength = MathMin(100.0, gapPips * 2.0);  // 50 pips = 100 strength
            
            return true;
         }
      }
      else // SELL
      {
         // FVG bearish: high[i-1] < low[i+1]
         // bot = high[i-1] -> lower bound of gap (more recent bar's high)
         // top = low[i+1]  -> upper bound of gap (older bar's low)
         // Intentionally mirrored vs BUY — source bars differ by design.
         // top > bot is guaranteed by the entry condition above
         double bot = high[i-1];
         double top = low[i+1];
         
         double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
         if(point == 0) point = 0.00001;
         
         if(top > bot && (top - bot) > point * 10)
         {
            outPd.found = true;
            outPd.type  = ICT_PD_FVG;
            outPd.zoneHigh = top;
            outPd.zoneLow  = bot;
            outPd.createdBar = i;
            outPd.createdTime = time[i];
            outPd.name = "FVG";
            
            double gap = top - bot;
            double point2 = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
            double gapPips = gap / (point2 * 10);
            outPd.strength = MathMin(100.0, gapPips * 2.0);
            
            return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Find Latest Order Block                                          |
//+------------------------------------------------------------------+
bool CICT_Detector::FindLatestOB(const string direction,
                                  const double &open[], const double &close[],
                                  const double &high[], const double &low[],
                                  const datetime &time[],
                                  const double atr,
                                  int lookbackBars,
                                  double atrMult,
                                  ICT_PDArray &outPd)
{
   // Reset output
   outPd.found = false;
   outPd.type = ICT_PD_NONE;
   outPd.zoneHigh = 0;
   outPd.zoneLow = 0;
   outPd.createdBar = -1;
   outPd.createdTime = 0;
   outPd.strength = 0;
   outPd.name = "NONE";

   int n = ArraySize(close);
   if(n < 5) return false;
   
   // CORRECTION 12: Validation ATR
   if(atr <= 0) {
      Print("âš ï¸ ICT Detector: ATR invalide (", atr, ")");
      return false;
   }

   int maxBar = MathMin(lookbackBars, n - 2);

   // Scanner depuis i=1 (derniÃ¨re bougie fermÃ©e)
   for(int i=1; i<=maxBar; i++)
   {
      // CORRECTION 13: VÃ©rifier l'indice suivant
      int ob = i + 1;
      if(ob >= n) continue;
      
      double body = MathAbs(close[i] - open[i]);
      bool isBull = (close[i] > open[i]);
      bool isBear = (close[i] < open[i]);

      // CORRECTION 14: Validation displacement minimum
      double minDisplacement = atrMult * atr;

      if(direction == "BUY")
      {
         if(isBull && body >= minDisplacement)
         {
            // VÃ©rifier que la bougie prÃ©cÃ©dente est bearish
            if(close[ob] < open[ob])
            {
               outPd.found = true;
               outPd.type  = ICT_PD_OB;
               outPd.zoneHigh = high[ob];
               outPd.zoneLow  = low[ob];
               outPd.createdBar = ob;
               outPd.createdTime = time[ob];
               outPd.name = "OB";
               
               // CORRECTION 15: Strength basÃ©e sur ratio body/ATR
               double bodyATR_Ratio = body / atr;
               outPd.strength = MathMin(100.0, bodyATR_Ratio * 30.0);
               
               return true;
            }
         }
      }
      else // SELL
      {
         if(isBear && body >= minDisplacement)
         {
            // VÃ©rifier que la bougie prÃ©cÃ©dente est bullish
            if(close[ob] > open[ob])
            {
               outPd.found = true;
               outPd.type  = ICT_PD_OB;
               outPd.zoneHigh = high[ob];
               outPd.zoneLow  = low[ob];
               outPd.createdBar = ob;
               outPd.createdTime = time[ob];
               outPd.name = "OB";
               
               double bodyATR_Ratio = body / atr;
               outPd.strength = MathMin(100.0, bodyATR_Ratio * 30.0);
               
               return true;
            }
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Is Mitigated                                                      |
//+------------------------------------------------------------------+
bool CICT_Detector::IsMitigated(const double price, const ICT_PDArray &pd, const double tolerance)
{
   if(!pd.found) return false;

   // CORRECTION 16: Validation des limites de zone
   if(pd.zoneHigh <= pd.zoneLow) return false;

   // P2 (2026-04-17) : tolerance 0.1 x ATR pour eviter de rater une mitigation
   // marginale (prix juste au-dessus/dessous de la zone par 0.2-0.5 pip).
   const double tol = (tolerance > 0.0) ? tolerance : 0.0;
   return (price >= pd.zoneLow - tol && price <= pd.zoneHigh + tol);
}

//+------------------------------------------------------------------+
//| Detect Shift M5 (CHoCH/BOS)                                      |
//+------------------------------------------------------------------+
ICT_Shift CICT_Detector::DetectShiftM5(const string direction,
                                        const double &open[], const double &close[],
                                        const double &high[], const double &low[],
                                        const datetime &time[],
                                        int lookbackBars,
                                        const double atr)
{
   ICT_Shift s;
   s.choch = false;
   s.bos = false;
   s.breakLevel = 0;
   s.time = 0;
   s.bar = -1;

   int n = ArraySize(close);
   if(n < 10) return s;  // Minimum 10 bars pour dÃ©tecter shift
   
   // CORRECTION 17: Validation des donnÃ©es
   if(ArraySize(high) != n || ArraySize(low) != n || ArraySize(time) != n) {
      Print("âš ï¸ ICT Detector: Tailles d'array incohÃ©rentes");
      return s;
   }

   double pivot = 0;
   int pivBar = -1;

   // FIX P1 (2026-04-17) : CHoCH valide sur les 3 dernieres bougies fermees
   // au lieu de close[1] uniquement (etait trop restrictif : ratait CHoCH
   // formes 1-2 bougies plus tot pendant l'attente d'un tick).
   const int CHOCH_BARS = 3;

   if(direction == "BUY")
   {
      // CHoCH: break au-dessus du pivot high rÃ©cent
      if(!FindRecentPivotHigh(high, lookbackBars, pivot, pivBar, 2, 2)) return s;

      // CORRECTION 18: VÃ©rifier que close[1] existe
      if(n < 2) return s;

      // P1 : scanner close[1..3], retourner le plus recent
      for(int k = 1; k <= CHOCH_BARS && k < n; k++)
      {
         if(close[k] > pivot)
         {
            s.choch = true;
            s.breakLevel = pivot;
            s.time = time[k];
            s.bar = k;

            // CORRECTION 19: Validation range
            double rng = high[k] - low[k];
            if(rng < 0) rng = 0;  // SÃ©curitÃ©

            // BOS si impulsif (range > 1.2 ATR)
            if(atr > 0 && rng >= 1.2 * atr) {
               s.bos = true;
            }
            break; // CHoCH le plus recent retenu
         }
      }
   }
   else // SELL
   {
      // CHoCH: break en-dessous du pivot low rÃ©cent
      if(!FindRecentPivotLow(low, lookbackBars, pivot, pivBar, 2, 2)) return s;

      if(n < 2) return s;

      for(int k = 1; k <= CHOCH_BARS && k < n; k++)
      {
         if(close[k] < pivot)
         {
            s.choch = true;
            s.breakLevel = pivot;
            s.time = time[k];
            s.bar = k;

            double rng = high[k] - low[k];
            if(rng < 0) rng = 0;

            if(atr > 0 && rng >= 1.2 * atr) {
               s.bos = true;
            }
            break;
         }
      }
   }

   return s;
}

//+------------------------------------------------------------------+