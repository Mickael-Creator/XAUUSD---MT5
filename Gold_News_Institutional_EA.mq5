//+------------------------------------------------------------------+
//|                    Gold_News_Institutional_EA.mq5                |
//|                 INSTITUTIONAL NEWS TRADING SYSTEM                |
//|                                                                  |
//|  LOGIC:                                                          |
//|  1. API donne la DIRECTION (basÃ©e sur COT + Sentiment + GÃ©o)     |
//|  2. API donne le TIMING (BLACKOUT, PRE_NEWS, POST_NEWS, CLEAR)   |
//|  3. API donne le SIZE_FACTOR (ajustement position)               |
//|  4. Sniper SMC trouve le POINT D'ENTRÃ‰E prÃ©cis                   |
//|                                                                  |
//|  STRATÃ‰GIE INSTITUTIONNELLE:                                     |
//|  - BLACKOUT: Ne pas trader (30min avant/15min aprÃ¨s news)        |
//|  - PRE_NEWS_SETUP: Position prudente (0.5x) si alignÃ©           |
//|  - POST_NEWS_ENTRY: FADE THE SPIKE - Entrer contre le retail    |
//|  - CLEAR: Trading normal selon le biais                          |
//+------------------------------------------------------------------+
#property copyright "Gold ML Institutional System"
#property version   "2.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

// Modules
#include "GoldML_ICT_Detector.mqh"
#include "GoldML_SniperEntry_M15.mqh"
#include "GoldML_PositionManager_V2.mqh"
#include "GoldML_QualityFilters.mqh"
// AUDIT-C1: Robust JSON parser replaces fragile StringFind approach
#include "GoldML_JsonParser.mqh"
// PHASE 1 APPROCHE A (2026-04-14): Infrastructure niveaux ICT
#include "GoldML_LiquidityLevels.mqh"

CTrade trade;
CPositionInfo posInfo;
CSniperM15* g_sniper = NULL;
CPositionManagerV2* g_posMgr = NULL;
CQualityFilters* g_filters = NULL;
// PHASE 1 APPROCHE A: infrastructure niveaux ICT (non branchee Phase 1)
CLiquidityLevels* g_liquidity = NULL;

//+------------------------------------------------------------------+
//| API CONFIGURATION                                                 |
//+------------------------------------------------------------------+
input group "â•â•â• API NEWS TRADING â•â•â•"
// AUDIT-VPS-C4: Default URL updated to versioned endpoint
input string API_News_URL = "http://86.48.5.126:5002/v1/news_trading_signal/quick";
input string API_MarketData_URL = "http://86.48.5.126:5002/v1/market_data";
input int    API_Timeout = 5000;
input int    API_Refresh_Seconds = 30;
// AUDIT-VPS-C1: Bearer token for API authentication — set in EA inputs, never hardcode
input string API_Auth_Token = "";  // Set to your API_TOKEN value

//+------------------------------------------------------------------+
//| TRADING RULES                                                     |
//+------------------------------------------------------------------+
input group "â•â•â• TRADING RULES â•â•â•"
input double Min_Confidence = 60.0;        // Minimum confidence pour trader
input bool   Allow_PreNews_Trading = true; // Autoriser trades prÃ©-news (prudent)
input bool   Allow_PostNews_Fade = true;   // Autoriser fade post-news
// 2026-04-15: Bidirectional trading flag
// true  = EA trade BUY et SELL selon pipeline ICT local (VPS = confidence+timing only)
// false = EA trade uniquement dans le sens du signal VPS (rollback comportement original)
input bool   Allow_Counter_Signal_Trading = true;

//+------------------------------------------------------------------+
//| SNIPER ENTRY SETTINGS (M15 Principal + M5 Confirmation)           |
//+------------------------------------------------------------------+
input group "â•â•â• SNIPER ENTRY (SMC M15) â•â•â•"
input int    Sniper_Swing_Lookback = 24;   // M15: 24 bars = 6 heures
input int    Sniper_Min_Swing_Bars = 4;    // M15: Plus de stabilitÃ©
input double Sniper_Fib_Entry_Min = 0.50;
input double Sniper_Fib_Entry_Max = 0.786;    // ICT Golden Pocket
input double Sniper_Fib_Optimal = 0.618;
input int    Sniper_Max_Bars_After_BOS = 12;  // M15: 12 bars = 3 heures
input int    Sniper_Max_Bars_After_Sweep = 20; // M15: Plus de temps
input bool   Sniper_Require_Sweep = true;
input bool   Sniper_Require_BOS = true;
input double Sniper_Min_RR = 2.0;
input int    Sniper_Min_Score = 55;        // Abaissé après recalibrage scoring
// FIX 2026-04-17: defaut 4.5 -> 7.0 pips (FTMO XAUUSD spread reel 50-65 points = 5-6.5 pips)
// Spread FTMO XAUUSD observe : 50-65 points
// Ne pas descendre sous 6.5 (risque de blocage)
// Ne pas monter au-dessus de 10 (spread anormal)
input double Sniper_Max_Spread = 7.0;      // FTMO XAUUSD : seuil 7 pips = marge securite
input double Sniper_SL_Buffer_Pips = 3.0;  // M15: Buffer plus large
input double Sniper_SL_Min_Pips = 25.0;    // M15: SL minimum (evite stop hunts news)
input double Sniper_SL_Max_Pips = 45.0;    // M15: SL max (partial TP toujours viable)
input bool   Use_M5_Confirmation = true;   // Confirmation pattern M5

//+------------------------------------------------------------------+
//| POSITION MANAGEMENT                                               |
//+------------------------------------------------------------------+
input group "â•â•â• POSITION MANAGEMENT â•â•â•"
input bool   Enable_Partial_TP = true;
// IMPROVE 6 (2026-04-03): Partial TP a 40% au lieu de 50%
// Recommandation trader institutionnel : garder plus sur le runner (60% reste)
input double Partial_Percent = 40.0;
input double Partial_At_RR = 1.0;
input bool   Move_To_BE_After_Partial = true;
input double BE_Buffer_Pips = 3.0;          // 3 pips > spread XAUUSD (2-3 pips)
input bool   Enable_Trailing = true;
input double Trail_ATR_Mult = 1.5;

//+------------------------------------------------------------------+
//| RISK MANAGEMENT FTMO                                              |
//+------------------------------------------------------------------+
input group "â•â•â• RISK MANAGEMENT FTMO â•â•â•"
// AUDIT-C4: Dynamic sizing by risk % replaces fixed lot size
input double Risk_Percent    = 1.0;   // % of equity risked per trade (default 1%)
input double Max_Risk_Percent = 2.0;  // Hard cap on risk % per trade
// AUDIT-C4: DEPRECATED — kept for backwards compatibility only; ignored when Risk_Percent > 0
input double Base_Lot_Size = 0.10;    // DEPRECATED: use Risk_Percent instead
input int    Magic_Number = 888892;
input double Max_Daily_Loss_EUR = 400.0;
input double Max_Daily_Trades = 6;
input double FTMO_Daily_DD_Limit = 4.5;    // % - arrÃªt Ã  4.5% (avant 5%)
// FIX C3 (2026-04-03): Balance initiale FTMO pour calcul DD total
input double FTMO_Initial_Balance = 10000.0;  // Taille du compte FTMO challenge 10K
input double FTMO_Total_DD_Limit = 9.0;       // % - arret a 9% (limite FTMO 10%)

//+------------------------------------------------------------------+
//| TEST MODE (B1 Fix 2026-04-14)                                     |
//+------------------------------------------------------------------+
input group "=== TEST MODE ==="
// B1 Fix (2026-04-14): Lot force via input au lieu de hardcode (ancien lots=0.01).
// Mettre a 0.0 pour desactiver et utiliser le calcul dynamique Risk_Percent.
input double Phase_Test_Force_Lot = 0.01;   // 0.0 = desactive (utilise Risk_Percent)

//+------------------------------------------------------------------+
//| SESSION FILTER                                                    |
//+------------------------------------------------------------------+
input group "â•â•â• SESSION â•â•â•"
input bool   Enable_Session_Filter = true;
// FIX 2026-04-17: defauts 07:00-18:00 -> 00:00-21:00 (session etendue)
// Capture les Judas Swings nocturnes et la session asiatique :
//   - Judas Swing Asian (00:00-07:00 GMT)
//   - London Open       (07:00-16:00 GMT)
//   - NY Session        (13:00-21:00 GMT)
// Modifier si besoin via inputs MT5
input string Session_Start = "00:00";
input string Session_End   = "21:00";


//+------------------------------------------------------------------+
//| LOCAL MODE (Trading autonome quand API silencieuse)               |
//+------------------------------------------------------------------+
input group "=== LOCAL MODE ==="
input bool   Enable_Local_Mode        = true;   // Activer mode local quand API silencieuse
input double Local_Min_Confidence     = 55.0;   // Confidence minimum en mode local (0-100)
input double Local_Size_Factor        = 0.7;    // Taille position reduite en mode local
input int    Local_Max_Daily_Trades   = 3;      // Max trades locaux par jour

//+------------------------------------------------------------------+
//| ICT LIQUIDITY (PHASE 1 APPROCHE A)                                |
//+------------------------------------------------------------------+
input group "=== ICT LIQUIDITY (PHASE 1) ==="
// Phase 1 : infrastructure seule — niveaux calcules et disponibles
// mais pas encore branches sur DetectLiquiditySweep (Phase 2).
// PHASE 2 APPROCHE A (2026-04-14) : activation par defaut — DetectLiquiditySweep_ICT
// consomme les vrais niveaux PDH/PDL/PWH/PWL/London/Asian/EQL au lieu des pivots 4/4.
input bool   Enable_ICT_Liquidity = true;  // ON = sweep ICT | OFF = pivots 4/4 (rollback)

//+------------------------------------------------------------------+
//| DISPLAY                                                           |
//+------------------------------------------------------------------+
input group "â•â•â• DISPLAY â•â•â•"
input bool   Enable_Dashboard = true;
input bool   Enable_Alerts = true;

//+------------------------------------------------------------------+
//| NEWS SIGNAL STRUCTURE (from API)                                  |
//+------------------------------------------------------------------+
struct NewsSignal {
   bool     can_trade;        // Master switch
   string   direction;        // BUY / SELL / NONE
   string   bias;             // BULLISH / BEARISH / NEUTRAL
   double   confidence;       // 0-100
   double   size_factor;      // 0.0 - 1.5
   string   timing_mode;      // CLEAR / BLACKOUT / PRE_NEWS_SETUP / POST_NEWS_ENTRY
   string   tp_mode;          // QUICK / NORMAL / EXTENDED
   bool     wider_stops;      // true = SL Ã— 1.3
   int      blackout_minutes; // Minutes restantes si blackout
   bool     is_valid;
   datetime last_update;
   // CLEANUP (2026-04-03): sniper_* supprimés — champs jamais alimentés par l'API VPS
};


//+------------------------------------------------------------------+
//| LOCAL SIGNAL STRUCTURE (calculated locally when API silent)       |
//+------------------------------------------------------------------+
struct LocalSignal {
   string   direction;    // BUY / SELL / NONE
   double   confidence;   // 0-100
   string   source;       // Always "LOCAL"
};

//+------------------------------------------------------------------+
//| LONDON RANGE SIGNAL (Setup C - London Open Breakout)             |
//+------------------------------------------------------------------+
struct LondonRangeSignal {
   bool     detected;
   string   direction;
   double   rangeHigh;
   double   rangeLow;
   double   breakLevel;
   double   confidence;
};


//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
NewsSignal g_Signal;
datetime g_LastAPICall = 0;
// CLEANUP (2026-04-03): g_LastMarketPush supprimé — orphelin de PushMarketData

// Position state
bool g_InPosition = false;
ulong g_Ticket = 0;
string g_CurrentDirection = "";

// Daily stats
datetime g_DayStart = 0;
double g_DayStartBalance = 0;  // FIX C-9.1 (2026-04-03): Balance début de journée FTMO
int g_TradesToday = 0;
int g_LocalTradesToday = 0;  // Compteur trades en mode local

// FIX A3+A4 (2026-04-04): Handles locaux caches (OnInit au lieu de chaque tick)
int g_hLocalEMA20 = INVALID_HANDLE;
int g_hLocalEMA50 = INVALID_HANDLE;
int g_hLocalATR   = INVALID_HANDLE;
double g_DailyPnL = 0;

// FIX C3 (2026-04-05): Derniere confidence API valide pour proteger ManagePosition si VPS down
double g_LastValidConfidence = 60.0;

// Sniper result cache
SniperResultM15 g_LastSniper;

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                             |
//+------------------------------------------------------------------+
int OnInit() {
   Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
   Print("   GOLD INSTITUTIONAL NEWS TRADING EA v2.1");
   Print("   M15 Entry + M5 Confirmation + ICT PD Arrays");
   Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
   
   // CORRECTION 1: Validation Symbol
   if(_Symbol != "XAUUSD" && _Symbol != "XAUUSD.i" && _Symbol != "GOLD") {
      Print("âš ï¸ WARNING: EA optimized for XAUUSD, running on ", _Symbol);
   }
   
   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(10);
   
   // Initialize signal
   ResetSignal();
   
   // CORRECTION 2: Initialize Sniper M15 avec gestion d'erreur amÃ©liorÃ©e
   g_sniper = new CSniperM15(_Symbol);
   if(g_sniper == NULL) {
      Print("âŒ Failed to create Sniper M15 object");
      return INIT_FAILED;
   }
   
   if(!g_sniper.Initialize(
         Sniper_Swing_Lookback, Sniper_Min_Swing_Bars,
         Sniper_Fib_Entry_Min, Sniper_Fib_Entry_Max, Sniper_Fib_Optimal,
         Sniper_Max_Bars_After_BOS, Sniper_Max_Bars_After_Sweep,
         Sniper_Require_Sweep, Sniper_Require_BOS,
         Sniper_Min_RR, Sniper_Min_Score, Sniper_Max_Spread,
         true, 10,  // Session boost (max 10 for overlap)
         Sniper_SL_Buffer_Pips, Sniper_SL_Min_Pips, Sniper_SL_Max_Pips,
         Use_M5_Confirmation)) {
      Print("âŒ Sniper M15 initialization failed");
      delete g_sniper;
      g_sniper = NULL;
      return INIT_FAILED;
   }
   Print("âœ… Sniper M15 initialized (M15 + M5 + ICT)");
   
   // CORRECTION 3: Initialize Position Manager avec validation
   g_posMgr = new CPositionManagerV2(_Symbol, Magic_Number);
   if(g_posMgr == NULL) {
      Print("âŒ Failed to create Position Manager object");
      return INIT_FAILED;
   }
   
   if(!g_posMgr.Initialize(
         Enable_Partial_TP, Partial_Percent, Partial_At_RR,
         Move_To_BE_After_Partial, BE_Buffer_Pips,
         Enable_Trailing, true, Trail_ATR_Mult,
         0.5, 10, true, 4.0, 200, 0.3,
         0.3, 0.5, 0.7, 0.9)) {
      Print("âŒ Position Manager initialization failed");
      delete g_posMgr;
      g_posMgr = NULL;
      return INIT_FAILED;
   }
   Print("âœ… Position Manager initialized");
   
   // CORRECTION 4: Initialize Quality Filters avec validation
   g_filters = new CQualityFilters(_Symbol, Magic_Number);
   if(g_filters == NULL) {
      Print("âŒ Failed to create Quality Filters object");
      return INIT_FAILED;
   }
   
   if(!g_filters.Initialize(
         true, 30, 30,          // Cooldown (after loss=30min, after win=0)
         true, 0.5, 12,        // Range
         true, 4, 10, 5,       // Consecutive: losses=4, wins=10, sameDir=5
         true, 30.0, 5,        // Same level
         true, (int)Max_Daily_Trades, Max_Daily_Loss_EUR, 300.0,
         Enable_Session_Filter, Session_Start, Session_End, false)) {
      Print("âŒ Quality Filters initialization failed");
      delete g_filters;
      g_filters = NULL;
      return INIT_FAILED;
   }
   Print("âœ… Quality Filters initialized");

   // PHASE 1 APPROCHE A (2026-04-14): Infrastructure niveaux ICT
   // Creee meme quand Enable_ICT_Liquidity=false pour valider les logs
   // Phase 2 branchera g_liquidity sur DetectLiquiditySweep()
   g_liquidity = new CLiquidityLevels(_Symbol);
   if(g_liquidity != NULL) {
      g_liquidity.RefreshAllLevels();
      Print("[LIQ] Infrastructure liquidite ICT initialisee — niveaux: ",
            g_liquidity.GetLevelCount(),
            " | flag Enable_ICT_Liquidity=", Enable_ICT_Liquidity ? "ON" : "OFF");
   } else {
      Print("[LIQ] WARNING: echec allocation CLiquidityLevels");
   }

   // PHASE 2 APPROCHE A (2026-04-14) : injecter niveaux ICT + flag dans le Sniper
   // (Enable_ICT_Liquidity est un input EA, non visible depuis GoldML_SniperEntry_M15.mqh)
   if(g_liquidity != NULL && g_sniper != NULL) {
      g_sniper.SetLiquidity(g_liquidity);
      g_sniper.SetUseICTLiquidity(Enable_ICT_Liquidity);
      Print("[PHASE2] g_liquidity passe au Sniper | ICT sweep=",
            Enable_ICT_Liquidity ? "ON" : "OFF");
   }

   // CORRECTION 5: Initial API fetch avec meilleure gestion d'erreur
   if(FetchNewsSignal()) {
      Print("âœ… API connected - Signal: ", g_Signal.direction, 
            " | Confidence: ", DoubleToString(g_Signal.confidence, 0), "%",
            " | Timing: ", g_Signal.timing_mode);
   } else {
      Print("âš ï¸ API not available - Will retry (this is normal on first start)");
   }
   
   // DISABLED: CSniperM15 now analyses candles locally — VPS push no longer needed
   // PushMarketData();

   g_DayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);  // FIX C-9.1
   
   // FIX A3+A4: Handles locaux crees une fois dans OnInit
   g_hLocalEMA20 = iMA(_Symbol, PERIOD_M15, 20, 0, MODE_EMA, PRICE_CLOSE);
   g_hLocalEMA50 = iMA(_Symbol, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
   g_hLocalATR   = iATR(_Symbol, PERIOD_M15, 14);
   if(g_hLocalEMA20 == INVALID_HANDLE || g_hLocalEMA50 == INVALID_HANDLE ||
      g_hLocalATR == INVALID_HANDLE)
      Print("WARNING: Local signal handles invalides");
   else
      Print("Local signal handles initialises");

   //================================================================
   // LOG E (2026-04-17) : SUMMARY DEMARRAGE EA
   // Recapitulatif config pour debug rapide
   //================================================================
   Print("== GOLD INSTITUTIONAL EA - CONFIG ==");
   Print("  Version: v2.1 | Compte: ", AccountInfoInteger(ACCOUNT_LOGIN));
   Print("  Balance: ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
         " | Equity: ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("  Session: ", Session_Start, " - ", Session_End, " GMT");
   Print("  Max Spread: ", DoubleToString(Sniper_Max_Spread, 1), " pips");
   Print("  Risk: ", DoubleToString(Risk_Percent, 1), "%",
         " | Test Lot: ", DoubleToString(Phase_Test_Force_Lot, 2));
   Print("  ICT Liquidity: ", Enable_ICT_Liquidity ? "ON" : "OFF",
         " | DEAL v2: ON | Bidirectionnel: ",
         Allow_Counter_Signal_Trading ? "ON" : "OFF");
   Print("  Min Score: ", Sniper_Min_Score,
         " | Max SL: ", DoubleToString(Sniper_SL_Max_Pips, 0), " pips",
         " | Reclaim: 8 bougies | Scan sweep: 96 bougies (24h)");
   Print("====================================");

   Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
   Print("   READY - Waiting for signals...");
   Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
   
   // Timer pour refresh API mÃªme sans ticks
   EventSetTimer(60);
   Print("â±ï¸ Timer initialized: API health check every 60s");
   
   // AUDIT-C5: Resync open positions and daily stats on restart
   SyncOpenPositions();
   RecalcDailyStats();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   EventKillTimer();
   
   // FIX A3+A4: Release handles locaux
   if(g_hLocalEMA20 != INVALID_HANDLE) { IndicatorRelease(g_hLocalEMA20); g_hLocalEMA20 = INVALID_HANDLE; }
   if(g_hLocalEMA50 != INVALID_HANDLE) { IndicatorRelease(g_hLocalEMA50); g_hLocalEMA50 = INVALID_HANDLE; }
   if(g_hLocalATR   != INVALID_HANDLE) { IndicatorRelease(g_hLocalATR);   g_hLocalATR   = INVALID_HANDLE; }
   
   // CORRECTION 6: Cleanup sÃ©curisÃ©
   if(g_sniper != NULL) {
      delete g_sniper;
      g_sniper = NULL;
   }
   if(g_posMgr != NULL) {
      delete g_posMgr;
      g_posMgr = NULL;
   }
   if(g_filters != NULL) {
      delete g_filters;
      g_filters = NULL;
   }
   // PHASE 1 APPROCHE A: cleanup infrastructure ICT
   if(g_liquidity != NULL) {
      delete g_liquidity;
      g_liquidity = NULL;
   }

   Comment("");
   
   // CORRECTION 7: Logs de raison de dÃ©sinit
   string reasonText = "";
   switch(reason) {
      case REASON_PROGRAM:     reasonText = "Program terminated"; break;
      case REASON_REMOVE:      reasonText = "EA removed from chart"; break;
      case REASON_RECOMPILE:   reasonText = "EA recompiled"; break;
      case REASON_CHARTCHANGE: reasonText = "Chart symbol/period changed"; break;
      case REASON_CHARTCLOSE:  reasonText = "Chart closed"; break;
      case REASON_PARAMETERS:  reasonText = "Input parameters changed"; break;
      case REASON_ACCOUNT:     reasonText = "Account changed"; break;
      case REASON_TEMPLATE:    reasonText = "Template changed"; break;
      case REASON_INITFAILED:  reasonText = "Initialization failed"; break;
      case REASON_CLOSE:       reasonText = "Terminal closed"; break;
      default:                 reasonText = "Unknown reason (" + IntegerToString(reason) + ")";
   }
   
   Print("EA stopped - Reason: ", reasonText);
}

//+------------------------------------------------------------------+
//| EXPERT TICK FUNCTION                                              |
//+------------------------------------------------------------------+
void OnTick() {
   // M3 Fix (2026-04-14): Reset journalier base sur TimeGMT() au lieu de TimeCurrent().
   // Ancien bug: reset a minuit serveur (UTC+2/+3 FTMO), pas a la cloture CME 22:00 GMT.
   MqlDateTime gmtNow;
   TimeGMT(gmtNow);
   static int lastResetDay = -1;
   if(gmtNow.day != lastResetDay) {
      Print("=============== NEW TRADING DAY (GMT) ===============");
      lastResetDay = gmtNow.day;
      g_DayStart = TimeGMT();
      g_TradesToday = 0;
      g_LocalTradesToday = 0;
      g_DailyPnL = 0;
      g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      Print("[DAY-RESET] Nouveau jour GMT - Balance de reference: ",
            DoubleToString(g_DayStartBalance, 2));

      // Reset filters daily counters
      if(g_filters != NULL) {
         g_filters.ResetDaily();
      }
      // Refresh niveaux ICT a chaque nouveau jour GMT
      if(g_liquidity != NULL) {
         g_liquidity.RefreshAllLevels();
         Print("[LIQ] Niveaux ICT refreshed (nouveau jour GMT) - actifs: ",
               g_liquidity.GetLevelCount());
      }
   }

   // M2 Fix (2026-04-14): Refresh Asian Range a 07:00 GMT (fin session Asian).
   static int lastAsianRefreshDay = -1;
   if(gmtNow.hour == 7 && gmtNow.min == 0 &&
      lastAsianRefreshDay != gmtNow.day) {
      if(g_liquidity != NULL) {
         g_liquidity.RefreshAllLevels();
         lastAsianRefreshDay = gmtNow.day;
         Print("[LIQ] Refresh 07:00 GMT - Asian Range complet");
      }
   }

   // M2 Fix (2026-04-14): Refresh London Range a 12:00 GMT (range fige).
   static int lastLondonRefreshDay = -1;
   if(gmtNow.hour == 12 && gmtNow.min == 0 &&
      lastLondonRefreshDay != gmtNow.day) {
      if(g_liquidity != NULL) {
         g_liquidity.RefreshAllLevels();
         lastLondonRefreshDay = gmtNow.day;
         Print("[LIQ] Refresh 12:00 GMT - London Range complet");
      }
   }

   //================================================================
   // LOG A (2026-04-17) : DIAGNOSTIC SYNTHESE TOUTES LES 60s
   // Permet de comprendre en temps reel l'etat global du systeme
   //================================================================
   static datetime lastDiagLog = 0;
   if(TimeCurrent() - lastDiagLog >= 60) {
      lastDiagLog = TimeCurrent();

      double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(pt <= 0.0) pt = 0.01;
      double spreadPips = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                           SymbolInfoDouble(_Symbol, SYMBOL_BID)) / (pt * 10.0);

      string sessStatus = "?";
      if(g_filters != NULL) sessStatus = g_filters.IsInSession() ? "OPEN" : "CLOSED";

      string h4Status = "?";
      if(g_filters != NULL) {
         int h4s = g_filters.GetLastH4Score();
         if(h4s > 0)         h4Status = "BULLISH";
         else if(h4s < -10)  h4Status = "BEARISH";
         else                h4Status = "RANGING";
      }

      double ddPct = 0.0;
      if(g_DayStartBalance > 0.0)
         ddPct = (g_DayStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) /
                 g_DayStartBalance * 100.0;

      Print("== DIAGNOSTIC ==");
      Print("  Gold: ", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), 2),
            " | Spread: ", DoubleToString(spreadPips, 1), " pips",
            " | Session: ", sessStatus);
      Print("  Signal VPS: ", g_Signal.direction, " ",
            DoubleToString(g_Signal.confidence, 0), "%",
            " | H4: ", h4Status);
      Print("  Niveaux ICT: ", g_liquidity != NULL ?
            IntegerToString(g_liquidity.GetLevelCount()) : "0",
            " | Position: ", g_InPosition ? "ACTIVE" : "NONE");
      Print("  Trades: ", g_TradesToday, "/", (int)Max_Daily_Trades,
            " | PnL jour: ", DoubleToString(g_DailyPnL, 2), " EUR",
            " | DD: ", DoubleToString(ddPct, 2), "%");
      Print("================");
   }

   // FTMO Safety check
   if(!CheckFTMOLimits()) {
      if(Enable_Dashboard) UpdateDashboard();
      return;
   }
   
   // Manage existing position
   if(g_InPosition) {
      ManagePosition();
      if(Enable_Dashboard) UpdateDashboard();
      return;
   }
   
   // CORRECTION 9: Weekend guard amÃ©liorÃ©
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) {
      return;  // Weekend
   }
   if(dt.day_of_week == 5 && dt.hour >= 22) {
      return;  // Friday after 22:00
   }
   
   // CORRECTION 10: Validation avant refresh API
   if((TimeCurrent() - g_LastAPICall) >= API_Refresh_Seconds) {
      if(!FetchNewsSignal()) {
         // Log silencieux, pas de spam
         static datetime lastWarning = 0;
         if(TimeCurrent() - lastWarning > 300) {  // Max 1 warning / 5 min
            Print("âš ï¸ API fetch failed - will retry");
            lastWarning = TimeCurrent();
         }
      }
   }

   // DISABLED: CSniperM15 now analyses candles locally — VPS push no longer needed
   // if((TimeCurrent() - g_LastMarketPush) >= API_Refresh_Seconds) {
   //    PushMarketData();
   // }

   // Check for entry
   CheckEntry();

   if(Enable_Dashboard) UpdateDashboard();
}

//+------------------------------------------------------------------+
//| TIMER FUNCTION - API health check sans ticks                      |
//+------------------------------------------------------------------+
void OnTimer() {
   // Skip si en position (OnTick gÃ¨re dÃ©jÃ )
   if(g_InPosition) return;
   
   // Skip weekend
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return;
   
   // CORRECTION 11: Refresh API avec throttling
   if((TimeCurrent() - g_LastAPICall) >= API_Refresh_Seconds) {
      // Silencieux sauf si succÃ¨s
      if(FetchNewsSignal()) {
         static string lastMode = "";
         // Ne print que si timing_mode change
         if(g_Signal.timing_mode != lastMode) {
            Print("ðŸ”„ Timer: API OK - ", g_Signal.direction, 
                  " | Confidence: ", g_Signal.confidence, 
                  "% | Timing: ", g_Signal.timing_mode);
            lastMode = g_Signal.timing_mode;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| FETCH NEWS SIGNAL FROM API                                        |
//+------------------------------------------------------------------+
bool FetchNewsSignal() {
   // AUDIT-VPS-C1: Include Bearer token if configured
   string headers = "Content-Type: application/json\r\n";
   if(StringLen(API_Auth_Token) > 0)
      headers += "Authorization: Bearer " + API_Auth_Token + "\r\n";
   string result_headers;
   char post_data[];
   char result_data[];
   
   ResetLastError();
   
   // CORRECTION 12: Gestion WebRequest amÃ©liorÃ©e
   int res = WebRequest("GET", API_News_URL, headers, API_Timeout, 
                        post_data, result_data, result_headers);
   
   g_LastAPICall = TimeCurrent();
   
   if(res == -1) {
      int err = GetLastError();
      if(err == 4014) {
         // Log une seule fois
         static bool warned = false;
         if(!warned) {
            Print("âš ï¸ Add URL to MT5: Tools > Options > Expert Advisors");
            Print("   URL: ", API_News_URL);
            warned = true;
         }
      }
      g_Signal.is_valid = false;
      return false;
   }
   
   if(res != 200) {
      static int lastError = 0;
      if(res != lastError) {  // Log seulement si erreur change
         Print("âŒ API HTTP Error: ", res);
         lastError = res;
      }
      g_Signal.is_valid = false;
      return false;
   }
   
   string json = CharArrayToString(result_data, 0, WHOLE_ARRAY, CP_UTF8);
   if(StringLen(json) == 0) {
      g_Signal.is_valid = false;
      return false;
   }
   
   // Parse JSON
   return ParseSignalJSON(json);
}

// CLEANUP (2026-04-03): PushMarketData() supprimé — dead code, jamais appelé

//+------------------------------------------------------------------+
//| PARSE JSON RESPONSE                                               |
//+------------------------------------------------------------------+
bool ParseSignalJSON(string json) {
   if(StringLen(json) < 10) {
      Print("WARNING ParseSignalJSON: JSON too short");
      return false;
   }

   // AUDIT-C1: Use CJsonParser — robust, whitespace/space-tolerant, handles null values
   CJsonParser parser;
   if(!parser.Parse(json)) {
      Print("WARNING ParseSignalJSON: CJsonParser failed to parse JSON");
      return false;
   }

   // AUDIT-VPS-C3: Log HMAC signature if present (full verification requires MQL5 native HMAC lib)
   string signature = "";
   if(parser.GetString("signature", signature) && StringLen(signature) > 0) {
      Print("[AUDIT-C1] Response signature present: ", StringSubstr(signature, 0, 16), "...");
   }

   // can_trade géré localement par QualityFilters (circuit breaker EA)
   // Le circuit breaker Python VPS est désactivé pour éviter le double blocage
   g_Signal.can_trade = true;

   // direction
   string direction = "NONE";
   parser.GetString("direction", direction);
   g_Signal.direction = direction;

   // bias
   string bias = "NEUTRAL";
   parser.GetString("bias", bias);
   g_Signal.bias = bias;

   // confidence
   double confidence = 0;
   parser.GetDouble("confidence", confidence);
   if(confidence < 0) confidence = 0;
   if(confidence > 100) confidence = 100;
   g_Signal.confidence = confidence;

   // size_factor
   double sizeFactor = 1.0;
   if(!parser.GetDouble("size_factor", sizeFactor) || sizeFactor <= 0)
      sizeFactor = 1.0;
   if(sizeFactor > 2.0) sizeFactor = 2.0;
   g_Signal.size_factor = sizeFactor;

   // timing_mode
   string timingMode = "CLEAR";
   parser.GetString("timing_mode", timingMode);
   if(timingMode != "CLEAR" &&
      timingMode != "BLACKOUT" &&
      timingMode != "PRE_NEWS_SETUP" &&
      timingMode != "POST_NEWS_ENTRY") {
      timingMode = "CLEAR";  // Default safe
   }
   g_Signal.timing_mode = timingMode;

   // tp_mode
   string tpMode = "NORMAL";
   parser.GetString("tp_mode", tpMode);
   if(tpMode != "QUICK" && tpMode != "NORMAL" && tpMode != "EXTENDED")
      tpMode = "NORMAL";
   g_Signal.tp_mode = tpMode;

   // wider_stops — AUDIT-C1: GetBool handles all spacing variants
   bool widerStops = false;
   parser.GetBool("wider_stops", widerStops);
   g_Signal.wider_stops = widerStops;

   // blackout_minutes — parsed manually to stay silent when field is null or absent.
   // The API sends 0 (integer) in CLEAR mode and the actual minute count in BLACKOUT
   // mode. Using GetInt would trigger a JsonParser WARNING on null, so we read the
   // raw JSON directly: find the key, skip whitespace, reject "null", parse the int.
   int blackoutMin = 0;
   {
      int bkIdx = StringFind(json, "\"blackout_minutes\"");
      if(bkIdx >= 0)
      {
         int colonIdx = StringFind(json, ":", bkIdx);
         if(colonIdx >= 0)
         {
            int vStart = colonIdx + 1;
            while(vStart < StringLen(json) &&
                  StringGetCharacter(json, vStart) == ' ') vStart++;
            // Only parse when the value is a digit (not "null" or missing)
            ushort firstChar = StringGetCharacter(json, vStart);
            if(firstChar >= '0' && firstChar <= '9')
               blackoutMin = (int)StringToInteger(StringSubstr(json, vStart, 10));
         }
      }
   }
   if(blackoutMin < 0) blackoutMin = 0;
   g_Signal.blackout_minutes = blackoutMin;

   // CLEANUP (2026-04-03): bloc assignation sniper_* supprimé — dead code

   g_Signal.is_valid    = true;
   g_Signal.last_update = TimeCurrent();

   // FIX C3 (2026-04-05): Sauvegarder derniere confidence valide pour ManagePosition
   // Si le VPS tombe, ManagePosition utilisera cette valeur au lieu de 0
   if(g_Signal.confidence >= 60.0)
      g_LastValidConfidence = g_Signal.confidence;

   return true;
}

//+------------------------------------------------------------------+
//| SETUP-C: Detect London Open Range Breakout                        |
//| Range 07:00-09:00 GMT, cassure apres 09:00 avec volume           |
//+------------------------------------------------------------------+
LondonRangeSignal DetectLondonRangeSetup() {
   LondonRangeSignal setup;
   setup.detected = false;
   setup.direction = "NONE";
   setup.confidence = 0;
   setup.rangeHigh = 0;
   setup.rangeLow = 0;
   setup.breakLevel = 0;

   // FIX TIMEZONE (2026-04-04): Utiliser TimeGMT() au lieu de TimeCurrent()
   // TimeCurrent() retourne l'heure du serveur MT5 (UTC+2 ou UTC+3 chez FTMO)
   // TimeGMT() retourne l'heure GMT reelle, independante du broker
   MqlDateTime dt;
   TimeGMT(dt);
   int hour = dt.hour;

   // Fenetre d'entree : 09:00-11:00 GMT (TimeGMT)
   if(hour < 9 || hour >= 11) return setup;

   double high[], low[], close[];
   datetime times[];
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(times, true);

   int bars = 20;
   if(CopyHigh(_Symbol,  PERIOD_M15, 0, bars, high)  < bars) return setup;
   if(CopyLow(_Symbol,   PERIOD_M15, 0, bars, low)   < bars) return setup;
   if(CopyClose(_Symbol, PERIOD_M15, 0, bars, close) < bars) return setup;
   if(CopyTime(_Symbol,  PERIOD_M15, 0, bars, times) < bars) return setup;

   double rangeHigh = 0, rangeLow = 999999;
   int rangeCount = 0;

   // FIX TIMEZONE: Calculer l'offset serveur→GMT une seule fois
   int serverGMTOffset = (int)((TimeCurrent() - TimeGMT()) / 3600);

   for(int i = 1; i < bars; i++) {
      MqlDateTime bdt;
      TimeToStruct(times[i], bdt);
      // Convertir heure serveur en GMT
      int gmtHour = bdt.hour - serverGMTOffset;
      if(gmtHour < 0) gmtHour += 24;
      if(gmtHour >= 24) gmtHour -= 24;
      if(gmtHour >= 7 && gmtHour < 9) {
         if(high[i] > rangeHigh) rangeHigh = high[i];
         if(low[i]  < rangeLow)  rangeLow  = low[i];
         rangeCount++;
      }
   }

   if(rangeCount < 4 || rangeHigh <= rangeLow) return setup;

   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(pt <= 0) pt = 0.01;
   double rangeSize = (rangeHigh - rangeLow) / (pt * 10);

   // Range valide : entre 15 et 60 pips
   if(rangeSize < 15 || rangeSize > 60) return setup;

   // Cassure haussiere : close[1] > rangeHigh (bougie fermee)
   if(close[1] > rangeHigh && close[2] <= rangeHigh) {
      setup.detected   = true;
      setup.direction  = "BUY";
      setup.rangeHigh  = rangeHigh;
      setup.rangeLow   = rangeLow;
      setup.breakLevel = rangeHigh;

      double volRatio = (double)iVolume(_Symbol, PERIOD_M15, 1) /
                        MathMax(1.0, (double)iVolume(_Symbol, PERIOD_M15, 5));
      setup.confidence = MathMin(100.0, 50 + (volRatio * 25) +
                         (rangeSize > 25 ? 10 : 0) + (rangeSize > 40 ? 15 : 0));
   }
   // Cassure baissiere : close[1] < rangeLow
   else if(close[1] < rangeLow && close[2] >= rangeLow) {
      setup.detected   = true;
      setup.direction  = "SELL";
      setup.rangeHigh  = rangeHigh;
      setup.rangeLow   = rangeLow;
      setup.breakLevel = rangeLow;

      double volRatio = (double)iVolume(_Symbol, PERIOD_M15, 1) /
                        MathMax(1.0, (double)iVolume(_Symbol, PERIOD_M15, 5));
      setup.confidence = MathMin(100.0, 50 + (volRatio * 25) +
                         (rangeSize > 25 ? 10 : 0) + (rangeSize > 40 ? 15 : 0));
   }

   if(setup.detected) {
      Print("[SETUP-C] London Range: ",
            DoubleToString(rangeLow, 2), "-", DoubleToString(rangeHigh, 2),
            " (", DoubleToString(rangeSize, 0), " pips)",
            " Break: ", setup.direction,
            " Conf: ", DoubleToString(setup.confidence, 0), "%");
   }

   return setup;
}

//+------------------------------------------------------------------+
//| GET LOCAL SIGNAL (H4 Structure + EMA M15 + Session + ATR)         |
//| Calcule direction et confidence localement quand API silencieuse  |
//+------------------------------------------------------------------+
LocalSignal GetLocalSignal() {
   LocalSignal local;
   local.direction  = "NONE";
   local.confidence = 0;
   local.source     = "LOCAL";

   // === 1. STRUCTURE H4 (40 pts max) ===
   double h4High[], h4Low[];
   ArraySetAsSeries(h4High, true);
   ArraySetAsSeries(h4Low, true);

   if(CopyHigh(_Symbol, PERIOD_H4, 1, 50, h4High) < 50) return local;
   if(CopyLow(_Symbol,  PERIOD_H4, 1, 50, h4Low)  < 50) return local;

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

   if(shC < 2 || slC < 2) return local;

   bool h4Bullish = (swH[0] > swH[1] && swL[0] > swL[1]);
   bool h4Bearish = (swH[0] < swH[1] && swL[0] < swL[1]);

   double h4Score = 0;
   string h4Dir   = "NONE";

   if(h4Bullish)      { h4Dir = "BUY";  h4Score = 40; }
   else if(h4Bearish) { h4Dir = "SELL"; h4Score = 40; }
   else {
      if(swH[0] > swH[1])      { h4Dir = "BUY";  h4Score = 15; }
      else if(swL[0] < swL[1]) { h4Dir = "SELL"; h4Score = 15; }
      else return local;
   }

   // === 2. EMA M15 (25 pts max) - FIX A3+A4: handles globaux ===
   double emaScore = 0;
   if(g_hLocalEMA20 != INVALID_HANDLE && g_hLocalEMA50 != INVALID_HANDLE) {
      double ema20[], ema50[];
      ArraySetAsSeries(ema20, true);
      ArraySetAsSeries(ema50, true);
      if(CopyBuffer(g_hLocalEMA20, 0, 0, 3, ema20) >= 3 &&
         CopyBuffer(g_hLocalEMA50, 0, 0, 3, ema50) >= 3) {

         double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

         if(h4Dir == "BUY"  && price > ema20[0] && ema20[0] > ema50[0]) emaScore = 25;
         else if(h4Dir == "SELL" && price < ema20[0] && ema20[0] < ema50[0]) emaScore = 25;
         else if(h4Dir == "BUY"  && price > ema50[0]) emaScore = 10;
         else if(h4Dir == "SELL" && price < ema50[0]) emaScore = 10;
      }
   }

   // === 3. SESSION (15 pts max) ===
   // FIX TIMEZONE (2026-04-05): TimeGMT() au lieu de TimeCurrent()
   // TimeCurrent() = heure serveur MT5 (UTC+2 ou UTC+3 chez FTMO)
   // TimeGMT() = heure GMT reelle, coherente avec le VPS (UTC)
   MqlDateTime dt;
   TimeGMT(dt);
   int hour = dt.hour;

   double sessionScore = 0;
   if(hour >= 12 && hour < 14)      sessionScore = 15;
   else if(hour >= 7  && hour < 9)  sessionScore = 12;
   else if(hour >= 9  && hour < 12) sessionScore = 10;
   else if(hour >= 14 && hour < 17) sessionScore = 10;
   else                              sessionScore = 3;

   // === 4. VOLATILITE ATR M15 (10 pts max) - FIX A3+A4: handle global ===
   double atrScore = 0;
   if(g_hLocalATR != INVALID_HANDLE) {
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(g_hLocalATR, 0, 0, 3, atr) >= 3) {
         double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         if(pt <= 0) pt = 0.01;
         double atrPips = atr[0] / (pt * 10);
         if(atrPips >= 20)      atrScore = 10;
         else if(atrPips >= 15) atrScore = 7;
         else if(atrPips >= 10) atrScore = 4;
         else                   atrScore = 0;
      }
   }

   // === 5. API BIAS RESIDUEL (10 pts max) ===
   double apiBoost = 0;
   if(g_Signal.is_valid) {
      if(g_Signal.bias == "BULLISH" && h4Dir == "BUY")        apiBoost = 10;
      else if(g_Signal.bias == "BEARISH" && h4Dir == "SELL")   apiBoost = 10;
      else if(g_Signal.bias != "NEUTRAL")                      apiBoost = 5;
      if(g_Signal.confidence >= 40 && g_Signal.confidence < 60) apiBoost += 5;
      if(apiBoost > 10) apiBoost = 10;
   }

   // === TOTAL: h4(40) + ema(25) + session(15) + atr(10) + api(10) = 100 max ===
   double total = h4Score + emaScore + sessionScore + atrScore + apiBoost;

   local.direction  = h4Dir;
   local.confidence = MathMin(100.0, total);

   Print("[LOCAL] H4:", h4Score, " EMA:", emaScore,
         " Ses:", sessionScore, " ATR:", atrScore,
         " API:", apiBoost, " = ", DoubleToString(local.confidence, 0),
         "% Dir:", local.direction);

   return local;
}

//+------------------------------------------------------------------+
//| CHECK ENTRY CONDITIONS (Dual-mode: API + Local)                   |
//+------------------------------------------------------------------+
void CheckEntry() {

   // LOG B (2026-04-17) : tracer la raison exacte de chaque rejet
   // Deduplication : on ne log que si le motif change (anti-spam tick)
   static string lastRejectReason = "";
   #define REJECT(rsn) { string _rj=rsn; if(_rj!=lastRejectReason){Print("[REJECT] ",_rj);lastRejectReason=_rj;} return; }

   // === DETERMINER LA SOURCE DU SIGNAL ===
   string direction;
   double confidence;
   string signalSource;
   string timingMode;
   double sizeFactor;
   string tpMode;
   bool   widerStops;

   // PRIORITE 1 : Signal API fort (comportement identique a l'actuel)
   // 2026-04-15: Filtre directionnel assoupli — accepte toute direction != NONE
   // (l'ancien filtre bloquait SELL quand le VPS envoyait BUY en permanence).
   bool apiHasSignal = (g_Signal.is_valid &&
                        g_Signal.confidence >= Min_Confidence &&
                        (g_Signal.direction != "NONE") &&
                        g_Signal.timing_mode != "BLACKOUT" &&
                        (TimeCurrent() - g_Signal.last_update) <= 300);

   if(apiHasSignal) {
      direction    = g_Signal.direction;
      confidence   = g_Signal.confidence;
      signalSource = "API";
      timingMode   = g_Signal.timing_mode;
      sizeFactor   = g_Signal.size_factor;
      tpMode       = g_Signal.tp_mode;
      widerStops   = g_Signal.wider_stops;
   }
   // PRIORITE 2 : Mode local (quand API silencieuse, timing CLEAR)
   else if(Enable_Local_Mode) {
      // Bloquer si BLACKOUT API (meme sans signal fort)
      if(g_Signal.is_valid && g_Signal.timing_mode == "BLACKOUT")
         REJECT("BLACKOUT API actif (mode LOCAL)");

      // Limiter les trades locaux journaliers
      if(g_LocalTradesToday >= Local_Max_Daily_Trades)
         REJECT("Local trades epuises " + IntegerToString(g_LocalTradesToday) + "/" + IntegerToString(Local_Max_Daily_Trades));

      // SETUP-C: London Range Breakout (priorite sur signal local classique)
      LondonRangeSignal londonRange = DetectLondonRangeSetup();
      if(londonRange.detected && londonRange.confidence >= 60) {
         direction    = londonRange.direction;
         confidence   = londonRange.confidence;
         signalSource = "LONDON_RANGE";
         timingMode   = "CLEAR";
         sizeFactor   = Local_Size_Factor;
         tpMode       = "NORMAL";
         widerStops   = false;
      } else {
         // Signal local classique (H4 + EMA)
         LocalSignal local = GetLocalSignal();
         if(local.direction == "NONE" || local.confidence < Local_Min_Confidence)
            REJECT("LOCAL signal absent ou conf<" + DoubleToString(Local_Min_Confidence,0) + "%");

         direction    = local.direction;
         confidence   = local.confidence;
         signalSource = "LOCAL";
         timingMode   = "CLEAR";
         sizeFactor   = Local_Size_Factor;
         tpMode       = "NORMAL";
         widerStops   = false;
      }
   }
   else {
      REJECT("API muet et Enable_Local_Mode=false");
   }

   //================================================================
   // TIMING MODE GATE
   //================================================================
   if(timingMode == "BLACKOUT")
      REJECT("Timing BLACKOUT");
   if(timingMode == "PRE_NEWS_SETUP"  && !Allow_PreNews_Trading)
      REJECT("PRE_NEWS_SETUP non autorise");
   if(timingMode == "POST_NEWS_ENTRY" && !Allow_PostNews_Fade)
      REJECT("POST_NEWS_ENTRY non autorise");

   //================================================================
   // CONFIDENCE GATE (API uniquement)
   //================================================================
   if(signalSource == "API" && confidence < Min_Confidence)
      REJECT("API confidence " + DoubleToString(confidence,0) + "% < " + DoubleToString(Min_Confidence,0) + "%");

   //================================================================
   // DIRECTION GATE
   //================================================================
   if(direction != "BUY" && direction != "SELL")
      REJECT("Direction invalide: " + direction);

   //================================================================
   // CONFLICT DETECTOR (VPS macro vs ICT/LOCAL technical)
   // 2026-04-15: Si VPS dit BUY mais pipeline ICT/LOCAL dit SELL
   // (ou inverse), on accepte le trade en reduisant la taille.
   // Si Allow_Counter_Signal_Trading = false, on bloque le trade (rollback).
   //
   // P1 FIX (2026-04-15): Au lieu de cumuler conflictFactor * dealFactor
   // (micro-trades 0.175 lot), on applique MIN(conflictFactor, dealFactor)
   // plus tard (section DEAL v2) -> prend la contrainte la plus restrictive
   // sans les multiplier.
   //================================================================
   bool signalConflict = false;
   if(g_Signal.direction == "BUY"  && direction == "SELL") signalConflict = true;
   if(g_Signal.direction == "SELL" && direction == "BUY")  signalConflict = true;

   Print("[ENTRY] Direction ICT: ", direction,
         " | VPS: ", g_Signal.direction,
         " | Conflict: ", (signalConflict ? "YES" : "NO"));

   double conflictFactor = 1.0;
   if(signalConflict) {
      if(!Allow_Counter_Signal_Trading) {
         REJECT("Allow_Counter=false | VPS=" + g_Signal.direction + " ICT=" + direction);
      }
      conflictFactor = 0.5;
      Print("[CONFLICT] VPS=", g_Signal.direction,
            " ICT=", direction,
            " -> conflictFactor = 0.5 (combine via MIN avec DEAL)");
   }

   //================================================================
   // QUALITY FILTERS
   //================================================================
   if(g_filters != NULL) {
      double price = (direction == "BUY")
                     ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                     : SymbolInfoDouble(_Symbol, SYMBOL_BID);

      // B2 Fix (2026-04-14): Propager la confidence effective selon la source.
      // Ancien bug: g_Signal.confidence=0 en LOCAL/LONDON_RANGE -> DEAL v2 branche <60%.
      double effectiveConfidence;
      if(signalSource == "LOCAL")             effectiveConfidence = confidence;     // local.confidence
      else if(signalSource == "LONDON_RANGE") effectiveConfidence = 65.0;            // plancher DEAL
      else                                    effectiveConfidence = g_Signal.confidence;

      FilterResult fr = g_filters.CheckAllFilters(direction, price, timingMode, effectiveConfidence);
      if(!fr.passed) {
         REJECT("[" + signalSource + "] QualityFilter: " + fr.blockReason);
      }
   }

   //================================================================
   // SNIPER M15 ENTRY
   //================================================================
   if(g_sniper == NULL)
      REJECT("Sniper M15 NULL");

   int scoreThreshold = Sniper_Min_Score;
   if(timingMode   == "POST_NEWS_ENTRY") scoreThreshold = 50;
   if(signalSource == "LOCAL")           scoreThreshold = 60;

   g_LastSniper = g_sniper.AnalyzeEntry(direction, confidence, timingMode);

   if(g_LastSniper.score < scoreThreshold)
      REJECT("Score " + IntegerToString(g_LastSniper.score) + "<" + IntegerToString(scoreThreshold) + " (" + g_LastSniper.reason + ")");
   // OPTIM-1+2 (2026-04-04): Gates adaptes par source de signal
   bool sweepRequired = (signalSource != "LONDON_RANGE");
   // OPTIM-2: Mode Local haute confidence (>=65%) : sweep non requis
   if(signalSource == "LOCAL" && confidence >= 65.0) sweepRequired = false;
   if(sweepRequired && !g_LastSniper.sweep.detected)
      REJECT("Sweep ICT requis mais NON detecte");
   // OPTIM-1: London Range n'exige pas BOS ni pullback stricts
   if(signalSource != "LONDON_RANGE" && !g_LastSniper.bos.detected)
      REJECT("BOS requis mais NON detecte");
   if(signalSource != "LONDON_RANGE" && !g_LastSniper.pullback.inZone)
      REJECT("Pullback PD array NON valide");

   // Log
   Print("======================================================");
   Print("  SIGNAL SOURCE: ", signalSource);
   Print("  Direction: ", direction,
         " | Confidence: ", DoubleToString(confidence, 1), "%");
   if(signalSource == "LOCAL") {
      Print("  Local mode: size=", DoubleToString(sizeFactor, 1),
            "x score>=", scoreThreshold,
            " local_trades=", g_LocalTradesToday, "/", Local_Max_Daily_Trades);
   } else {
      Print("  Timing: ", timingMode,
            " | Size: ", DoubleToString(sizeFactor, 2), "x",
            " | TP: ", tpMode);
   }
   Print("  Sniper Score: ", g_LastSniper.score);
   Print("  Sweep: ", g_LastSniper.sweep.detected ? "YES" : "NO",
         " | BOS: ", g_LastSniper.bos.detected ? g_LastSniper.bos.direction : "NONE",
         " | PD: ", g_LastSniper.pullback.pdType,
         " | CHoCH: ", g_LastSniper.pullback.chochM5 ? "YES" : "NO");
   Print("======================================================");

   //================================================================
   // DEAL v2 + CONFLICT : MIN(conflictFactor, dealFactor) au lieu de cumul
   // P1 FIX (2026-04-15): evite micro-trades H4 bullish + conflit
   // (avant: 0.7 * 0.5 * 0.5 = 0.175 | apres: 0.7 * MIN(0.5, 0.5) = 0.35)
   //================================================================
   double dealSizeFactor = 1.0;
   bool   dealEnabled    = (g_filters != NULL && g_filters.IsEnableDEAL());
   if(dealEnabled) {
      dealSizeFactor = g_filters.GetH4SizeFactor();
      if(dealSizeFactor <= 0.0) {
         REJECT("DEAL v2 sizeFactor=0 (H4 contre direction)");
      }
   }

   double reductionFactor = MathMin(conflictFactor, dealSizeFactor);
   Print("[SIZE] base=", DoubleToString(sizeFactor, 2), "x",
         " | conflict=", DoubleToString(conflictFactor, 2), "x",
         " | DEAL=", DoubleToString(dealSizeFactor, 2), "x",
         " | MIN=", DoubleToString(reductionFactor, 2), "x",
         " -> final=", DoubleToString(sizeFactor * reductionFactor, 2), "x");
   sizeFactor *= reductionFactor;

   //================================================================
   // EXECUTE TRADE (override temporaire g_Signal pour les parametres)
   //================================================================
   double savedSizeFactor  = g_Signal.size_factor;
   string savedTpMode      = g_Signal.tp_mode;
   bool   savedWiderStops  = g_Signal.wider_stops;

   g_Signal.size_factor = sizeFactor;
   g_Signal.tp_mode     = tpMode;
   g_Signal.wider_stops = widerStops;

   ExecuteTrade(direction);

   // Restaurer g_Signal
   g_Signal.size_factor = savedSizeFactor;
   g_Signal.tp_mode     = savedTpMode;
   g_Signal.wider_stops = savedWiderStops;

   // FIX LOCAL-COUNT (2026-04-04): Incrementer seulement si trade reellement ouvert
   if((signalSource == "LOCAL" || signalSource == "LONDON_RANGE") && g_InPosition)
      g_LocalTradesToday++;

   // Trade execute -> reset du dernier motif de rejet (changement d'etat)
   lastRejectReason = "";
   #undef REJECT
}

//+------------------------------------------------------------------+
//| EXECUTE TRADE                                                     |
//+------------------------------------------------------------------+
void ExecuteTrade(string direction) {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // CORRECTION 19: Validation point
   if(point <= 0) {
      Print("ExecuteTrade: Invalid point (", point, ")");
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // CORRECTION 20: Validation prices
   if(ask <= 0 || bid <= 0) {
      Print("ExecuteTrade: Invalid prices (ask:", ask, " bid:", bid, ")");
      return;
   }

   // Get SL from local Sniper M15 analysis
   double entry = (direction == "BUY") ? ask : bid;
   double slPips = g_LastSniper.slPips;

   // CORRECTION 21: Validation SL — clamp within FTMO-safe range
   if(slPips < Sniper_SL_Min_Pips) slPips = Sniper_SL_Min_Pips;
   if(slPips > Sniper_SL_Max_Pips) slPips = Sniper_SL_Max_Pips;

   // Apply wider stops if indicated
   if(g_Signal.wider_stops) {
      slPips *= 1.3;
   }

   // ---------------------------------------------------------------
   // AUDIT-C4: Dynamic lot sizing from Risk_Percent
   // ---------------------------------------------------------------
   double lots = 0;
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lotStep <= 0) lotStep = 0.01;

   // Clamp risk to safety cap
   double effectiveRisk = Risk_Percent;
   if(effectiveRisk <= 0) effectiveRisk = 1.0;
   if(effectiveRisk > Max_Risk_Percent) effectiveRisk = Max_Risk_Percent;

   double equity       = AccountInfoDouble(ACCOUNT_EQUITY);
   double tickValue    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(equity > 0 && tickValue > 0 && tickSize > 0 && slPips > 0) {
      // AUDIT-C4: Deprecation warning for Base_Lot_Size
      if(Base_Lot_Size != 0.10) {
         Print("[AUDIT-C4] WARNING: Base_Lot_Size is deprecated. Use Risk_Percent instead.");
      }

      double riskAmount = equity * (effectiveRisk / 100.0) * g_Signal.size_factor;
      lots = riskAmount / (slPips * (tickValue / tickSize));

      // AUDIT-C4: Log the calculation for audit trail
      Print("[AUDIT-C4] Lot calc: equity=", DoubleToString(equity, 2),
            " risk%=", DoubleToString(effectiveRisk, 2),
            " risk_amount=", DoubleToString(riskAmount, 2),
            " SL_pips=", DoubleToString(slPips, 1),
            " raw_lots=", DoubleToString(lots, 4));
   } else {
      // Fallback to Base_Lot_Size if equity/tick data unavailable
      Print("[AUDIT-C4] WARNING: falling back to Base_Lot_Size (equity or tick data unavailable)");
      lots = Base_Lot_Size * g_Signal.size_factor;
   }

   // Normalize and clamp
   lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   // DEAL v2: Log du lot calcule avant override test
   Print("[DEAL-v2] Pre-test lots=", DoubleToString(lots, 4),
         " (sizeFactor=", DoubleToString(g_Signal.size_factor, 2), "x)");

   // B1 Fix (2026-04-14): Lot force via input Phase_Test_Force_Lot
   // Mettre Phase_Test_Force_Lot=0.0 en LIVE pour utiliser Risk_Percent
   if(Phase_Test_Force_Lot > 0.0) {
      lots = NormalizeDouble(Phase_Test_Force_Lot, 2);
      Print("[TEST-MODE] Lot force a ", DoubleToString(lots, 2),
            " (Phase_Test_Force_Lot)");
   }

   // P4 FIX (2026-04-15): Re-clamp apres override Phase_Test_Force_Lot
   // pour eviter lot < minLot du broker (ex: input 0.005 avec minLot 0.01)
   if(lots < minLot) {
      Print("[LOT] Ajuste au minimum broker: ", DoubleToString(lots, 2),
            " -> ", DoubleToString(minLot, 2));
      lots = minLot;
   }
   if(lots > maxLot) lots = maxLot;

   // P4b FIX (2026-04-15): Alignement lotStep apres override
   // (ex: input 0.015 avec lotStep 0.01 -> 0.01). Reutilise les variables
   // lotStep/minLot/maxLot declarees ligne 1220-1222 (pas de redeclaration).
   if(lotStep > 0) {
      double alignedLots = MathFloor(lots / lotStep) * lotStep;
      alignedLots = NormalizeDouble(alignedLots, 2);
      if(MathAbs(alignedLots - lots) > 1e-8) {
         Print("[LOT] Alignement lotStep=", DoubleToString(lotStep, 2),
               " -> lots=", DoubleToString(alignedLots, 2));
      }
      lots = alignedLots;
   }

   // Re-clamp final apres alignement (lotStep peut avoir ramene sous minLot)
   if(lots < minLot) {
      Print("[LOT] Ajuste au minimum broker apres alignement: ",
            DoubleToString(minLot, 2));
      lots = minLot;
   }
   if(lots > maxLot) {
      Print("[LOT] Ajuste au maximum broker: ", DoubleToString(maxLot, 2));
      lots = maxLot;
   }

   Print("[AUDIT-C4] Final lots: ", DoubleToString(lots, 2));

   // ---------------------------------------------------------------
   // AUDIT-C4: Margin check before sending order
   // ---------------------------------------------------------------
   double marginRequired = 0;
   ENUM_ORDER_TYPE orderType = (direction == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double checkPrice = (direction == "BUY") ? ask : bid;

   if(OrderCalcMargin(orderType, _Symbol, lots, checkPrice, marginRequired)) {
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double marginSafe = freeMargin * 0.8;  // 80% safety threshold
      if(marginRequired > marginSafe) {
         Print("[AUDIT-C4] BLOCKED: insufficient margin. Required=",
               DoubleToString(marginRequired, 2),
               " Available(80%)=", DoubleToString(marginSafe, 2));
         return;
      }
   } else {
      Print("[AUDIT-C4] WARNING: OrderCalcMargin failed — proceeding without margin check");
   }

   // Calculate TP based on tp_mode
   double tpRR = 2.0;  // FIX M1 (2026-04-03): NORMAL 1.5->2.0 pour ICT news
   if(g_Signal.tp_mode == "QUICK") tpRR = 1.0;
   else if(g_Signal.tp_mode == "EXTENDED") tpRR = 3.0;  // FIX M1: 2.5->3.0

   double tpPips = slPips * tpRR;

   // Calculate prices
   double sl, tp;
   if(direction == "BUY") {
      entry = ask;
      sl = entry - slPips * point * 10;
      tp = entry + tpPips * point * 10;
   } else {
      entry = bid;
      sl = entry + slPips * point * 10;
      tp = entry - tpPips * point * 10;
   }

   // CORRECTION 22: Normalize SL/TP
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl    = NormalizeDouble(sl, digits);
   tp    = NormalizeDouble(tp, digits);
   entry = NormalizeDouble(entry, digits);

   // CORRECTION 28: Validate SL/TP are on the correct side of entry price
   // BUY: SL must be below entry, TP must be above entry
   // SELL: SL must be above entry, TP must be below entry
   if(direction == "BUY") {
      if(sl >= entry) {
         Print("[SAFETY] BLOCKED: BUY order with SL (", DoubleToString(sl, digits),
               ") >= entry (", DoubleToString(entry, digits), ") — SL must be BELOW entry for BUY");
         return;
      }
      if(tp <= entry) {
         Print("[SAFETY] BLOCKED: BUY order with TP (", DoubleToString(tp, digits),
               ") <= entry (", DoubleToString(entry, digits), ") — TP must be ABOVE entry for BUY");
         return;
      }
   } else {
      if(sl <= entry) {
         Print("[SAFETY] BLOCKED: SELL order with SL (", DoubleToString(sl, digits),
               ") <= entry (", DoubleToString(entry, digits), ") — SL must be ABOVE entry for SELL");
         return;
      }
      if(tp >= entry) {
         Print("[SAFETY] BLOCKED: SELL order with TP (", DoubleToString(tp, digits),
               ") >= entry (", DoubleToString(entry, digits), ") — TP must be BELOW entry for SELL");
         return;
      }
   }

   // Build comment
   string comment = StringFormat("GML_%s_%s_%.0f",
                                  g_Signal.timing_mode,
                                  direction,
                                  g_Signal.confidence);

   // Log
   Print("===========================================================");
   Print("   EXECUTING TRADE");
   Print("===========================================================");
   Print("   Timing Mode: ", g_Signal.timing_mode);
   Print("   Direction: ", direction);
   Print("   Confidence: ", DoubleToString(g_Signal.confidence, 0), "%");
   Print("   Size Factor: ", DoubleToString(g_Signal.size_factor, 2), "x");
   Print("   Lots: ", DoubleToString(lots, 2));
   Print("   Entry: ", DoubleToString(entry, digits));
   Print("   SL: ", DoubleToString(sl, digits), " (", DoubleToString(slPips, 1), " pips)");
   Print("   TP: ", DoubleToString(tp, digits), " (", DoubleToString(tpPips, 1), " pips)");
   Print("   RR: 1:", DoubleToString(tpRR, 1));
   Print("   Sniper M15 Score: ", g_LastSniper.score);
   Print("   M5 Pattern: ", g_LastSniper.m5Confirm.patternName);
   Print("===========================================================");

   // IMPROVE 2 (2026-04-03): Retry execution avec deviation croissante
   // Pendant les news, le slippage peut atteindre 5-15 pips sur XAUUSD
   // 3 tentatives : 10 pts -> 30 pts -> 50 pts de deviation
   bool success = false;
   int deviations[] = {10, 30, 50};

   for(int attempt = 0; attempt < 3 && !success; attempt++) {
      trade.SetDeviationInPoints(deviations[attempt]);

      // Rafraichir les prix a chaque tentative
      double retryAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double retryBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(direction == "BUY") {
         success = trade.Buy(lots, _Symbol, retryAsk, sl, tp, comment);
      } else {
         success = trade.Sell(lots, _Symbol, retryBid, sl, tp, comment);
      }

      if(!success) {
         Print("Tentative ", attempt + 1, " echouee (deviation=",
               deviations[attempt], " pts) : ", trade.ResultRetcode(),
               " - ", trade.ResultRetcodeDescription());
         if(attempt < 2) Sleep(500); // Attendre 500ms avant retry
      } else {
         Print("Trade execute a la tentative ", attempt + 1,
               " avec deviation=", deviations[attempt], " pts");
      }
   }

   // Restaurer la deviation par defaut
   trade.SetDeviationInPoints(10);

   if(success) {
      g_Ticket = trade.ResultOrder();
      g_InPosition = true;
      g_CurrentDirection = direction;
      g_TradesToday++;

      Print("TRADE OPENED - Ticket: ", g_Ticket);

      // FIX C1 (2026-04-03): Charger la position dans le PositionManager
      // Active le partial TP, breakeven et trailing stop
      if(g_posMgr != NULL) {
         g_posMgr.LoadPosition(g_Ticket, g_Signal.timing_mode);
         Print("PositionManager loaded for ticket: ", g_Ticket);
      }

      if(g_filters != NULL) {
         g_filters.RecordTradeOpen(g_Ticket, direction, entry);
      }

      if(Enable_Alerts) {
         Alert("Gold Institutional: ", direction, " @ ", DoubleToString(entry, 2),
               " | Mode: ", g_Signal.timing_mode,
               " | Conf: ", DoubleToString(g_Signal.confidence, 0), "%");
      }
   } else {
      // CORRECTION 23: Better error handling
      int error = GetLastError();
      string errorDesc = "";
      switch(error) {
         case 10004: errorDesc = "Trade server busy"; break;
         case 10006: errorDesc = "No connection"; break;
         case 10013: errorDesc = "Invalid request"; break;
         case 10014: errorDesc = "Invalid volume"; break;
         case 10015: errorDesc = "Invalid price"; break;
         case 10016: errorDesc = "Invalid stops"; break;
         case 10018: errorDesc = "Market closed"; break;
         case 10019: errorDesc = "Not enough money"; break;
         case 10021: errorDesc = "Order too many"; break;
         default:    errorDesc = "Unknown error";
      }
      Print("TRADE FAILED - Error: ", error, " (", errorDesc, ")");
   }
}

//+------------------------------------------------------------------+
//| MANAGE POSITION                                                   |
//+------------------------------------------------------------------+
void ManagePosition() {
   // CORRECTION 24: Validation ticket existe
   if(g_Ticket == 0) {
      Print("âš ï¸ ManagePosition: Invalid ticket (0)");
      g_InPosition = false;
      return;
   }
   
   // Check if position still exists
   if(!PositionSelectByTicket(g_Ticket)) {
      ClosePositionHandler();
      return;
   }
   
   // CORRECTION 25: Validation Position Manager
   if(g_posMgr == NULL) {
      Print("âš ï¸ ManagePosition: Position Manager is NULL");
      return;
   }
   
   // Use Position Manager
   // FIX N1 (2026-04-03): Distinguer partial TP d'une fermeture totale
   // EXIT_TP_PARTIAL = action intermédiaire, 50% de la position reste ouverte
   // Les autres codes = fermeture totale réelle
   // FIX C3 (2026-04-05): Utiliser derniere confidence valide si VPS down
   // Evite fermeture prematuree d'un trade gagnant quand VPS devient indisponible
   double conviction = g_Signal.is_valid ?
                       g_Signal.confidence / 10.0 :
                       g_LastValidConfidence / 10.0;
   ENUM_EXIT_REASON exitCode = g_posMgr.ManagePosition(conviction,
                                                        g_Signal.is_valid &&
                                                        g_Signal.timing_mode == "BLACKOUT");

   if(exitCode == EXIT_TP_PARTIAL) {
      Print("✅ Partial TP exécuté — suivi actif sur position restante (BE + trailing)");
      return;  // Position toujours ouverte et gérée
   }

   if(exitCode != EXIT_UNKNOWN) {
      ClosePositionHandler();
      return;
   }
}

//+------------------------------------------------------------------+
//| Close Position Handler (Version CorrigÃ©e)                        |
//+------------------------------------------------------------------+
void ClosePositionHandler() {
   double profit = 0;
   double closePrice = 0;
   
   // CORRECTION 26: Attendre MAJ historique
   Sleep(100);
   
   // MÃ©thode 1: Chercher dans l'historique par position ID
   if(HistorySelectByPosition(g_Ticket)) {
      int totalDeals = HistoryDealsTotal();
      for(int i = totalDeals - 1; i >= 0; i--) {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket > 0) {
            // VÃ©rifier que c'est bien un deal d'OUT (fermeture)
            ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
            if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_INOUT) {
               profit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
               profit += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
               profit += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
               closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
            }
         }
      }
   }
   
   // MÃ©thode 2: Si profit toujours 0, chercher dans l'historique rÃ©cent
   if(profit == 0 && closePrice == 0) {
      datetime fromTime = TimeCurrent() - 3600;  // DerniÃ¨re heure
      datetime toTime = TimeCurrent() + 60;
      
      if(HistorySelect(fromTime, toTime)) {
         int totalDeals = HistoryDealsTotal();
         for(int i = totalDeals - 1; i >= 0; i--) {
            ulong dealTicket = HistoryDealGetTicket(i);
            if(dealTicket > 0) {
               // VÃ©rifier le magic number
               long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
               if(dealMagic == Magic_Number) {
                  ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
                  if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_INOUT) {
                     profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
                     profit += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
                     profit += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
                     closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
                     break;
                  }
               }
            }
         }
      }
   }
   
   // Mettre Ã  jour les stats
   g_DailyPnL += profit;
   
   // Enregistrer dans Quality Filters
   if(g_filters != NULL) {
      g_filters.RecordTradeClose(g_Ticket, profit, closePrice);
   }
   
   // Log
   Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
   Print("   POSITION CLOSED");
   if(profit > 0) {
      Print("   Result: WIN âœ…");
   } else if(profit < 0) {
      Print("   Result: LOSS âŒ");
   } else {
      Print("   Result: BREAKEVEN âš–ï¸");
   }
   Print("   P&L: ", DoubleToString(profit, 2), " EUR");
   Print("   Daily Total: ", DoubleToString(g_DailyPnL, 2), " EUR");
   Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
   
   // FIX M-2.1 (2026-04-03): Réinitialiser le PositionManager proprement
   if(g_posMgr != NULL) {
      g_posMgr.UnloadPosition();
   }

   // Reset position state
   g_InPosition = false;
   g_Ticket = 0;
   g_CurrentDirection = "";
}

//+------------------------------------------------------------------+
//| CHECK FTMO LIMITS                                                 |
//+------------------------------------------------------------------+
bool CheckFTMOLimits() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // CORRECTION 27: Protection division par zÃ©ro
   if(balance <= 0) {
      Print("âŒ CheckFTMOLimits: Invalid balance (", balance, ")");
      return false;
   }
   
   // FIX C-9.1 (2026-04-03): DD journalier FTMO correct
   // Méthode FTMO officielle : (balance_début_jour - equity_courante) / balance_début_jour
   // Inclut toutes les pertes réalisées ET non-réalisées de la journée
   if(g_DayStartBalance > 0) {
      double ftmoDailyDD = ((g_DayStartBalance - equity) / g_DayStartBalance) * 100.0;
      if(ftmoDailyDD >= FTMO_Daily_DD_Limit) {
         Print("FTMO DAILY DD ATTEINT: ", DoubleToString(ftmoDailyDD, 2),
               "% — Ref: ", DoubleToString(g_DayStartBalance, 2),
               " Equity: ", DoubleToString(equity, 2));
         return false;
      }
   }

   // Limite trades journaliers
   if(g_TradesToday >= Max_Daily_Trades) {
      return false;
   }

   // FIX C3 (2026-04-03): Verification du drawdown TOTAL FTMO (limite 10%, arret a 9%)
   if(FTMO_Initial_Balance > 0) {
      double totalDD = ((FTMO_Initial_Balance - equity) / FTMO_Initial_Balance) * 100.0;
      if(totalDD >= FTMO_Total_DD_Limit) {
         Print("FTMO DD TOTAL ATTEINT: ", DoubleToString(totalDD, 2), "% — Trading bloqué");
         return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| RESET SIGNAL                                                      |
//+------------------------------------------------------------------+
void ResetSignal() {
   g_Signal.can_trade = false;
   g_Signal.direction = "NONE";
   g_Signal.bias = "NEUTRAL";
   g_Signal.confidence = 0;
   g_Signal.size_factor = 1.0;
   g_Signal.timing_mode = "CLEAR";
   g_Signal.tp_mode = "NORMAL";
   g_Signal.wider_stops = false;
   g_Signal.blackout_minutes = 0;
   g_Signal.is_valid = false;
   g_Signal.last_update = 0;
}

//+------------------------------------------------------------------+
//| UPDATE DASHBOARD - Version CorrigÃ©e                              |
//+------------------------------------------------------------------+
void UpdateDashboard() {
   string line1 = "=== GOLD INSTITUTIONAL NEWS EA v2.1 ===";
   
   // Signal status
   string sigStatus = "";
   if(!g_Signal.is_valid) {
      sigStatus = "Signal: [X] No Data";
   } else {
      string arrow = "-";
      if(g_Signal.direction == "BUY") arrow = "[â†‘BUY]";
      else if(g_Signal.direction == "SELL") arrow = "[â†“SELL]";
      
      sigStatus = StringFormat("Signal: %s %.0f%% | Size: %.2fx",
                               arrow, g_Signal.confidence, g_Signal.size_factor);
   }
   
   // Timing status
   string timingStatus = "";
   string timingIcon = "[OK]";
   if(g_Signal.timing_mode == "BLACKOUT") timingIcon = "[ðŸ›‘STOP]";
   else if(g_Signal.timing_mode == "PRE_NEWS_SETUP") timingIcon = "[â³WAIT]";
   else if(g_Signal.timing_mode == "POST_NEWS_ENTRY") timingIcon = "[ðŸŽ¯GO]";
   
   timingStatus = StringFormat("Timing: %s %s", timingIcon, g_Signal.timing_mode);
   
   if(g_Signal.timing_mode == "BLACKOUT" && g_Signal.blackout_minutes > 0) {
      timingStatus += " (" + IntegerToString(g_Signal.blackout_minutes) + "min)";
   }
   
   // Position status
   string posStatus = g_InPosition ? 
      StringFormat("Position: %s #%d", g_CurrentDirection, g_Ticket) :
      "Position: None";
   
   // Sniper M15 status
   string sniperStatus = "";
   if(g_LastSniper.score > 0) {
      sniperStatus = StringFormat("Sniper M15: %d/100 | PD: %s | M5: %s",  // FIX N2 (2026-04-03)
                                   g_LastSniper.score,
                                   g_LastSniper.pullback.pdType,
                                   g_LastSniper.m5Confirm.patternName);
   } else {
      sniperStatus = "Sniper M15: Waiting...";
   }
   
   // P&L
   string pnlStatus = StringFormat("P&L: %.2f EUR | Trades: %d/%d", 
                                    g_DailyPnL, g_TradesToday, (int)Max_Daily_Trades);
   
   // Local mode status
   string localStatus = StringFormat("Local: %d/%d trades | Mode: %s",
                                      g_LocalTradesToday,
                                      Local_Max_Daily_Trades,
                                      Enable_Local_Mode ? "ON" : "OFF");

   // PHASE 2 APPROCHE A (2026-04-14) : statut liquidite ICT
   string liqStatus = StringFormat("ICT Liquidity: %s | Niveaux: %d",
                                    Enable_ICT_Liquidity ? "ON" : "OFF",
                                    g_liquidity != NULL ? g_liquidity.GetLevelCount() : 0);

   Comment(line1 + "\n\n" +
           sigStatus + "\n" +
           timingStatus + "\n" +
           posStatus + "\n" +
           sniperStatus + "\n" +
           pnlStatus + "\n" +
           localStatus + "\n" +
           liqStatus);
}

// FIX N3 (2026-04-03): ExtractString() et ExtractDouble() supprimés (dead code, remplacé par CJsonParser)

//+------------------------------------------------------------------+
//| KEYBOARD HANDLER                                                  |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam) {
   if(id != CHARTEVENT_KEYDOWN) return;
   
   if(lparam == 'I') {  // Info
      Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
      Print("   CURRENT STATUS");
      Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
      Print("   Signal Valid: ", g_Signal.is_valid);
      Print("   Can Trade: ", g_Signal.can_trade);
      Print("   Direction: ", g_Signal.direction);
      Print("   Bias: ", g_Signal.bias);
      Print("   Confidence: ", g_Signal.confidence, "%");
      Print("   Size Factor: ", g_Signal.size_factor);
      Print("   Timing: ", g_Signal.timing_mode);
      Print("   TP Mode: ", g_Signal.tp_mode);
      Print("   Wider Stops: ", g_Signal.wider_stops);
      Print("   Position: ", g_InPosition ? g_CurrentDirection : "None");
      Print("   Daily P&L: â‚¬", g_DailyPnL);
      Print("   Trades Today: ", g_TradesToday, "/", (int)Max_Daily_Trades);
      
      // Sniper info
      if(g_LastSniper.score > 0) {
         Print("   â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€");
         Print("   Last Sniper M15 Analysis:");
         Print("   Score: ", g_LastSniper.score);
         Print("   Valid: ", g_LastSniper.isValid ? "YES" : "NO");
         Print("   PD Array: ", g_LastSniper.pullback.pdType);
         Print("   CHoCH M5: ", g_LastSniper.pullback.chochM5 ? "YES" : "NO");
      }
      
      Print("â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•");
   }
   else if(lparam == 'U') {  // Force update
      Print("ðŸ”„ Force API update...");
      if(FetchNewsSignal()) {
         Print("âœ… Updated - Direction: ", g_Signal.direction, 
               " | Timing: ", g_Signal.timing_mode,
               " | Confidence: ", g_Signal.confidence, "%");
      } else {
         Print("âŒ Update failed");
      }
   }
   else if(lparam == 'S') {  // Sniper analysis
      if(g_sniper != NULL && g_Signal.direction != "NONE") {
         Print("ðŸ” Running Sniper M15 analysis for ", g_Signal.direction, "...");
         SniperResultM15 result = g_sniper.AnalyzeEntry(g_Signal.direction, g_Signal.confidence, g_Signal.timing_mode);
         g_sniper.PrintAnalysis(result);
      } else {
         Print("âš ï¸ Cannot run sniper: No valid signal direction");
      }
   }
   else if(lparam == 'F') {  // Filters status
      if(g_filters != NULL) {
         g_filters.PrintStatus();
      }
   }
}

//+------------------------------------------------------------------+
//| SYNC OPEN POSITIONS ON RESTART                                    |
//| AUDIT-C5: Restore g_InPosition state if EA restarts with a live  |
//|           position already open on the account.                  |
//+------------------------------------------------------------------+
void SyncOpenPositions() {
   // FIX C-9.1: Initialiser balance du jour si pas encore fait
   if(g_DayStartBalance <= 0)
      g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   // P3 FIX (2026-04-15): Detection mode HEDGE vs NETTING pour audit FTMO.
   // En HEDGE, PositionsTotal peut contenir plusieurs positions sur le meme
   // symbole -> le break ci-dessous n'en reprend qu'UNE. Les autres restent
   // orphelines (non gerees par g_posMgr). Le flux normal (g_InPosition gate)
   // empeche d'OUVRIR une 2e position, mais si une position manuelle existe
   // deja au demarrage, elle ne sera pas suivie. Log explicite pour alerte.
   ENUM_ACCOUNT_MARGIN_MODE marginMode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) {
      Print("[ACCOUNT] Mode HEDGE detecte - 1 seule position sera reprise");
   } else if(marginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING) {
      Print("[ACCOUNT] Mode NETTING detecte - position unique garantie");
   } else {
      Print("[ACCOUNT] Mode EXCHANGE detecte");
   }

   int total = PositionsTotal();
   for(int i = 0; i < total; i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(!PositionSelectByTicket(ticket)) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != Magic_Number) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != _Symbol) continue;

      // AUDIT-C5: Found a managed position — restore state
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      string tradeType = (posType == POSITION_TYPE_BUY) ? "BUY" : "SELL";

      g_InPosition       = true;
      g_Ticket           = ticket;
      g_CurrentDirection = tradeType;

      // Resume Position Manager management of this position
      if(g_posMgr != NULL) {
         g_posMgr.LoadPosition(ticket, tradeType);

         // FIX C-2.1 (2026-04-03): Détecter si partial TP déjà exécuté avant le restart
         double currentVolume = PositionGetDouble(POSITION_VOLUME);
         double entryVolume = 0.0;

         if(HistorySelectByPosition(ticket)) {
            for(int d = 0; d < HistoryDealsTotal(); d++) {
               ulong dealTicket = HistoryDealGetTicket(d);
               if(dealTicket > 0) {
                  ENUM_DEAL_ENTRY de = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
                  if(de == DEAL_ENTRY_IN) {
                     entryVolume += HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
                  }
               }
            }
         }

         // Si le volume actuel est inférieur à 90% du volume d'entrée → partial TP déjà exécuté
         if(entryVolume > 0 && currentVolume < entryVolume * 0.90) {
            g_posMgr.SetPartialDone(true);
            Print("[FIX C-2.1] Partial TP détecté au restart — Entry: ",
                  DoubleToString(entryVolume, 2), " Current: ", DoubleToString(currentVolume, 2));
         }
      }

      Print("[AUDIT-C5] Resumed management of position #", ticket,
            " | Direction: ", tradeType);
      break;  // Only one position expected at a time
   }
}

//+------------------------------------------------------------------+
//| RECALCULATE DAILY STATS ON RESTART                               |
//| AUDIT-C5: Prevent g_TradesToday/g_DailyPnL resetting to zero    |
//|           when EA restarts mid-day.                              |
//+------------------------------------------------------------------+
void RecalcDailyStats() {
   datetime dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   datetime dayEnd   = dayStart + 86400;  // +24h

   if(!HistorySelect(dayStart, dayEnd)) {
      Print("[AUDIT-C5] RecalcDailyStats: HistorySelect failed");
      return;
   }

   int    tradesCount = 0;
   double totalPnL    = 0;
   int    totalDeals  = HistoryDealsTotal();

   for(int i = 0; i < totalDeals; i++) {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      if(dealMagic != Magic_Number) continue;

      string dealSym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      if(dealSym != _Symbol) continue;

      ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

      if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_INOUT) {
         // Count as a completed trade
         tradesCount++;
         totalPnL += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         totalPnL += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
         totalPnL += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      }
   }

   g_TradesToday = tradesCount;
   g_DailyPnL    = totalPnL;

   Print("[AUDIT-C5] Daily stats restored: trades=", tradesCount,
         " PnL=", DoubleToString(totalPnL, 2));

   // AUDIT-C5: Sync Quality Filters daily counters if the method is available
   // (CQualityFilters does not expose SetDailyStats — counters are managed internally
   //  via RecordTradeOpen/Close. Calling ResetDaily + re-recording would risk
   //  mismatching filter state, so we only sync the global counters above.)
}

//+------------------------------------------------------------------+