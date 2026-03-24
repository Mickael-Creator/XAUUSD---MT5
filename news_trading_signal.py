"""
News Trading Signal Module v1.5
Institutional News Trading Logic for Gold

Strategy: Trade the REACTION, not the news itself
- Pre-news: Position for expected move based on COT + sentiment
- Post-news: Fade the spike if surprise contradicts positioning
"""

from datetime import datetime, timedelta
from typing import Dict, Any, Optional
from dataclasses import dataclass
from enum import Enum
import logging

logger = logging.getLogger(__name__)


class TimingMode(Enum):
    """Trading timing modes around news events"""
    BLACKOUT = "BLACKOUT"           # No trading, too close to news
    PRE_NEWS_SETUP = "PRE_NEWS_SETUP"   # Position before news
    POST_NEWS_ENTRY = "POST_NEWS_ENTRY"  # Fade the spike
    CLEAR = "CLEAR"                 # Normal trading, no imminent news


class EntryStrategy(Enum):
    """Entry strategy types"""
    WAIT = "WAIT"                   # Don't trade
    FADE_SPIKE = "FADE_SPIKE"       # Counter-trend after spike
    TREND_CONTINUATION = "TREND_CONTINUATION"  # Follow the move
    SCALP_REVERSAL = "SCALP_REVERSAL"  # Quick reversal play


@dataclass
class NewsImpactScore:
    """Calculated impact score for a news event"""
    event_name: str
    base_impact: str  # High, Medium, Low
    gold_relevance: float  # 0-1
    surprise_factor: float  # -1 to +1 (negative = worse than expected)
    time_to_event_hours: float
    composite_score: float  # 0-100


@dataclass
class NewsTradingSignal:
    """Complete news trading signal output"""
    timing_mode: TimingMode
    entry_bias: str  # BULLISH, BEARISH, NEUTRAL
    entry_strategy: EntryStrategy
    confidence: float  # 0-100
    
    # Timing details
    blackout_active: bool
    minutes_to_news: Optional[float]
    next_event: Optional[str]
    
    # Analysis components
    cot_bias: str
    sentiment_bias: str
    surprise_bias: str
    
    # Trade parameters (if entry allowed)
    suggested_direction: Optional[str]  # BUY, SELL, None
    position_size_factor: float  # 0.5 to 1.5
    
    # Risk parameters
    wider_stops: bool  # True if volatility expected
    take_profit_mode: str  # QUICK, NORMAL, EXTENDED
    
    # Reasoning
    reasoning: list


class NewsTradingAnalyzer:
    """
    Analyzes news events and generates trading signals
    Based on institutional news trading principles
    """
    
    # Blackout windows (minutes before/after high impact news)
    BLACKOUT_BEFORE_HIGH = 30
    BLACKOUT_AFTER_HIGH = 15
    BLACKOUT_BEFORE_MEDIUM = 15
    BLACKOUT_AFTER_MEDIUM = 10
    
    # Gold-relevant news types and their typical impact
    GOLD_NEWS_RELEVANCE = {
        # Fed & Monetary Policy (Highest impact on Gold)
        'FOMC': 1.0,
        'Fed': 0.95,
        'Interest Rate': 1.0,
        'Powell': 0.95,
        'Monetary Policy': 0.9,
        
        # Inflation (Direct Gold driver)
        'CPI': 0.95,
        'PPI': 0.85,
        'PCE': 0.9,
        'Inflation': 0.9,
        
        # Employment (Fed decision driver)
        'NFP': 0.9,
        'Non-Farm': 0.9,
        'Unemployment': 0.85,
        'Jobless': 0.8,
        'Employment': 0.8,
        
        # GDP & Growth
        'GDP': 0.75,
        'Retail Sales': 0.7,
        'ISM': 0.65,
        'PMI': 0.6,
        
        # Treasury & Dollar (Inverse correlation)
        'Treasury': 0.8,
        'Yield': 0.75,
        'Dollar': 0.7,
        'DXY': 0.7,
        
        # Safe Haven triggers
        'Geopolitical': 0.85,
        'War': 0.9,
        'Crisis': 0.85,
        'Sanctions': 0.8,
    }
    
    # Surprise interpretation for Gold
    # Positive surprise (better than expected) generally bearish for Gold
    # Negative surprise (worse than expected) generally bullish for Gold
    # Balanced: 9 bearish-Gold events vs 9 bullish-Gold events
    SURPRISE_GOLD_IMPACT = {
        # Strong economy = less safe haven demand = bearish Gold (9 events)
        'NFP': -1,         # Better jobs = bearish Gold
        'GDP': -1,
        'Retail Sales': -1,
        'ISM': -1,
        'PMI': -1,
        'Employment': -1,
        'Interest Rate': -1,
        'FOMC': -1,        # Hawkish surprise = bearish Gold
        'Fed': -1,

        # Bullish Gold drivers = safe haven / inflation / debasement (9 events)
        'CPI': 1,          # Higher inflation = bullish Gold (hedge)
        'PPI': 1,
        'PCE': 1,
        'Inflation': 1,
        'Unemployment': 1, # Rising unemployment = dovish Fed = bullish Gold
        'Jobless': 1,
        'War': 1,          # Geopolitical escalation = safe haven demand
        'Geopolitical': 1,
        'Deficit': 1,      # Surprise deficit increase = currency debasement concern
    }
    
    def __init__(self):
        self.logger = logging.getLogger(__name__)
    
    def calculate_news_impact(
        self,
        event_name: str,
        impact_level: str,
        actual: Optional[float],
        forecast: Optional[float],
        previous: Optional[float],
        time_to_event_hours: float
    ) -> NewsImpactScore:
        """Calculate composite impact score for a news event"""
        
        # Base impact multiplier
        impact_multipliers = {
            'High': 1.0,
            'Medium': 0.6,
            'Low': 0.3
        }
        base_mult = impact_multipliers.get(impact_level, 0.3)
        
        # Gold relevance
        gold_relevance = 0.3  # Default low relevance
        for keyword, relevance in self.GOLD_NEWS_RELEVANCE.items():
            if keyword.lower() in event_name.lower():
                gold_relevance = max(gold_relevance, relevance)
                break
        
        # Surprise factor (-1 to +1)
        surprise_factor = 0.0
        if actual is not None and forecast is not None and forecast != 0:
            raw_surprise = (actual - forecast) / abs(forecast)
            # Clamp to -1 to +1
            surprise_factor = max(-1, min(1, raw_surprise))
        
        # Composite score (0-100)
        time_factor = max(0, 1 - (time_to_event_hours / 24))  # Closer = higher
        composite = (
            base_mult * 40 +
            gold_relevance * 30 +
            abs(surprise_factor) * 20 +
            time_factor * 10
        )
        
        return NewsImpactScore(
            event_name=event_name,
            base_impact=impact_level,
            gold_relevance=gold_relevance,
            surprise_factor=surprise_factor,
            time_to_event_hours=time_to_event_hours,
            composite_score=min(100, composite)
        )
    
    def determine_timing_mode(
        self,
        minutes_to_news: Optional[float],
        impact_level: str,
        news_passed: bool = False
    ) -> TimingMode:
        """Determine current timing mode based on news proximity"""
        
        if minutes_to_news is None:
            return TimingMode.CLEAR
        
        if impact_level == 'High':
            blackout_before = self.BLACKOUT_BEFORE_HIGH
            blackout_after = self.BLACKOUT_AFTER_HIGH
        elif impact_level == 'Medium':
            blackout_before = self.BLACKOUT_BEFORE_MEDIUM
            blackout_after = self.BLACKOUT_AFTER_MEDIUM
        else:
            return TimingMode.CLEAR  # Low impact = no blackout
        
        if news_passed:
            # After news
            if minutes_to_news <= blackout_after:
                return TimingMode.BLACKOUT
            elif minutes_to_news <= 60:  # Within 1 hour after
                return TimingMode.POST_NEWS_ENTRY
            else:
                return TimingMode.CLEAR
        else:
            # Before news
            if minutes_to_news <= blackout_before:
                return TimingMode.BLACKOUT
            elif minutes_to_news <= 120:  # 2 hours before
                return TimingMode.PRE_NEWS_SETUP
            else:
                return TimingMode.CLEAR
    
    def calculate_surprise_bias(
        self,
        event_name: str,
        surprise_factor: float
    ) -> str:
        """Determine Gold bias from news surprise"""
        
        # Threshold lowered from 10% to 4% — most real economic surprises (NFP, CPI)
        # fall in the 1-5% range; 10% was too strict and muted all surprise signals
        if abs(surprise_factor) < 0.04:
            return "NEUTRAL"
        
        # Find impact direction for this event type
        impact_direction = 0
        for keyword, direction in self.SURPRISE_GOLD_IMPACT.items():
            if keyword.lower() in event_name.lower():
                impact_direction = direction
                break
        
        # Calculate final bias
        # surprise_factor > 0 = better than expected
        # impact_direction = -1 means better = bearish Gold
        gold_impact = surprise_factor * impact_direction
        
        if gold_impact > 0.1:
            return "BULLISH"
        elif gold_impact < -0.1:
            return "BEARISH"
        return "NEUTRAL"
    
    def generate_signal(
        self,
        news_data: Dict[str, Any],
        cot_data: Dict[str, Any],
        sentiment_data: Dict[str, Any],
        geopolitical_data: Dict[str, Any],
        macro_data: Optional[Dict[str, Any]] = None,
    ) -> NewsTradingSignal:
        """
        Generate complete news trading signal

        Args:
            news_data: From news_fetcher_v2 (upcoming + recent events)
            cot_data: COT positioning data
            sentiment_data: Fear & Greed, market sentiment
            geopolitical_data: Geopolitical tension data
            macro_data: Macro indicators — must include 'dxy' and 'vix'
        """

        if macro_data is None:
            macro_data = {}

        reasoning = []

        # ═══════════════════════════════════════════════════════════
        # 1. ANALYZE NEWS TIMING
        # ═══════════════════════════════════════════════════════════

        next_event = news_data.get('next_event', {})
        recent_events = news_data.get('recent_results', [])

        # Get timing to next event
        minutes_to_news = None
        hours_to_news = news_data.get('hours_to_next')
        if hours_to_news is not None:
            minutes_to_news = hours_to_news * 60

        event_name = next_event.get('event', 'Unknown')
        impact_level = next_event.get('impact', 'Low')

        # Determine timing mode
        timing_mode = self.determine_timing_mode(
            minutes_to_news,
            impact_level,
            news_passed=False
        )

        # Check for recent high-impact results (post-news opportunity)
        post_news_opportunity = None
        for event in recent_events:
            if event.get('impact') == 'High' and event.get('actual') is not None:
                hours_since = event.get('hours_since', 999)
                if hours_since <= 1:  # Within last hour
                    post_news_opportunity = event
                    timing_mode = TimingMode.POST_NEWS_ENTRY
                    break

        if hours_to_news is not None:
            reasoning.append(f"Timing: {timing_mode.value} (next: {event_name} in {hours_to_news:.1f}h)")
        else:
            reasoning.append(f"Timing: {timing_mode.value} (no imminent news)")

        # ═══════════════════════════════════════════════════════════
        # 2. ANALYZE COT POSITIONING  [weight: 30 pts]
        # ═══════════════════════════════════════════════════════════

        cot_percentile = cot_data.get('percentile', cot_data.get('percentile_net', 50))
        cot_regime = cot_data.get('regime', cot_data.get('sentiment', 'NEUTRAL'))

        if cot_percentile >= 70:
            cot_bias = "BULLISH"
        elif cot_percentile <= 30:
            cot_bias = "BEARISH"
        else:
            cot_bias = "NEUTRAL"

        reasoning.append(f"COT: {cot_bias} ({cot_percentile:.0f}% percentile, {cot_regime})")

        # ═══════════════════════════════════════════════════════════
        # 3. ANALYZE MARKET SENTIMENT  [weight: 20 pts]
        # ═══════════════════════════════════════════════════════════

        fear_greed = sentiment_data.get('fear_greed', {})
        fg_value = fear_greed.get('value', 50)
        fg_classification = fear_greed.get('classification', 'Neutral')

        # Extreme fear = bullish for Gold (safe haven)
        # Extreme greed = bearish for Gold
        if fg_value <= 30:
            sentiment_bias = "BULLISH"
        elif fg_value >= 70:
            sentiment_bias = "BEARISH"
        else:
            sentiment_bias = "NEUTRAL"

        reasoning.append(f"Sentiment: {sentiment_bias} (F&G: {fg_value} - {fg_classification})")

        # ═══════════════════════════════════════════════════════════
        # 4. ANALYZE DXY  [weight: 25 pts — inverse correlation Gold]
        # ═══════════════════════════════════════════════════════════

        dxy = macro_data.get('dxy', 101.5)  # Neutral mid-range default

        if dxy > 104:
            dxy_bias = "BEARISH"   # Strong dollar → pressure on Gold
        elif dxy < 101:
            dxy_bias = "BULLISH"   # Weak dollar → supports Gold
        else:
            dxy_bias = "NEUTRAL"   # 101–104: transition zone

        reasoning.append(f"DXY: {dxy_bias} ({dxy:.1f})")

        # ═══════════════════════════════════════════════════════════
        # 5. ANALYZE VIX  [weight: 20 pts — risk-off proxy]
        # ═══════════════════════════════════════════════════════════

        vix = macro_data.get('vix', 18.0)  # Neutral mid-range default

        if vix > 25:
            vix_bias = "BULLISH"   # High fear → safe haven demand for Gold
        elif vix < 15:
            vix_bias = "BEARISH"   # Complacency → risk-on, Gold less attractive
        else:
            vix_bias = "NEUTRAL"   # 15–25: transition zone

        reasoning.append(f"VIX: {vix_bias} ({vix:.1f})")

        # ═══════════════════════════════════════════════════════════
        # 6. ANALYZE US10Y / REAL RATE  [weight: 15 pts]
        #    Negative real yield → Gold attractive (no opportunity cost)
        #    High positive real yield → Gold unattractive
        # ═══════════════════════════════════════════════════════════

        # Use real_rate (us10y − inflation_target) if available,
        # fall back to nominal us10y with a rough 2.5% inflation assumption
        real_rate = macro_data.get('real_rate')
        if real_rate is None:
            us10y = macro_data.get('us10y', 4.0)
            real_rate = us10y - 2.5  # rough inflation proxy

        if real_rate < 0:
            us10y_bias = "BULLISH"   # Negative real yield → Gold becomes attractive
        elif real_rate > 2.0:
            us10y_bias = "BEARISH"   # High real yield → opportunity cost too high
        else:
            us10y_bias = "NEUTRAL"   # 0–2.0%: transition zone

        reasoning.append(f"RealRate: {us10y_bias} ({real_rate:.2f}%)")

        # ═══════════════════════════════════════════════════════════
        # 7. ANALYZE GEOPOLITICAL RISK  [weight: 15 pts]
        # ═══════════════════════════════════════════════════════════

        geo_tension = geopolitical_data.get('tension_level', 5)
        geo_zones = geopolitical_data.get('active_zones', [])

        # High tension = bullish Gold (safe haven)
        if geo_tension >= 8:
            geo_bias = "BULLISH"
            reasoning.append(f"Geopolitical: BULLISH (tension {geo_tension}/10, zones: {', '.join(geo_zones[:3])})")
        elif geo_tension <= 3:
            geo_bias = "BEARISH"
            reasoning.append(f"Geopolitical: BEARISH (low tension {geo_tension}/10)")
        else:
            geo_bias = "NEUTRAL"
            reasoning.append(f"Geopolitical: NEUTRAL (tension {geo_tension}/10)")

        # ═══════════════════════════════════════════════════════════
        # 8. ANALYZE SURPRISE (if post-news)  [weight: 25 pts]
        # ═══════════════════════════════════════════════════════════

        surprise_bias = "NEUTRAL"
        if post_news_opportunity:
            actual = post_news_opportunity.get('actual')
            forecast = post_news_opportunity.get('forecast')
            event = post_news_opportunity.get('event', '')

            if actual is not None and forecast is not None:
                surprise_pct = ((actual - forecast) / abs(forecast)) * 100 if forecast != 0 else 0
                surprise_bias = self.calculate_surprise_bias(event, surprise_pct / 100)
                reasoning.append(f"Surprise: {surprise_bias} ({event}: {actual} vs {forecast}, {surprise_pct:+.1f}%)")

        # ═══════════════════════════════════════════════════════════
        # 9. COMBINE BIASES → ENTRY DECISION
        #
        # Weights (total possible without surprise = 120 pts):
        #   COT          30 pts  (institutional positioning, J-3 lag)
        #   DXY          20 pts  (real-time inverse correlation)
        #   Fear & Greed 20 pts  (contrarian sentiment)
        #   VIX          20 pts  (risk-off proxy)
        #   US10Y/Real   15 pts  (opportunity cost for holding Gold)
        #   Geopolitical 15 pts  (requires confirmation from ≥1 other)
        #   Surprise     25 pts  (POST_NEWS mode only)
        # ═══════════════════════════════════════════════════════════

        bias_scores = {'BULLISH': 0, 'BEARISH': 0}

        # COT — 30 pts
        if cot_bias == "BULLISH":
            bias_scores['BULLISH'] += 30
        elif cot_bias == "BEARISH":
            bias_scores['BEARISH'] += 30

        # DXY — 20 pts (reduced from 25: US10Y now covers part of the USD signal)
        if dxy_bias == "BULLISH":
            bias_scores['BULLISH'] += 20
        elif dxy_bias == "BEARISH":
            bias_scores['BEARISH'] += 20

        # Fear & Greed — 20 pts
        if sentiment_bias == "BULLISH":
            bias_scores['BULLISH'] += 20
        elif sentiment_bias == "BEARISH":
            bias_scores['BEARISH'] += 20

        # VIX — 20 pts
        if vix_bias == "BULLISH":
            bias_scores['BULLISH'] += 20
        elif vix_bias == "BEARISH":
            bias_scores['BEARISH'] += 20

        # US10Y / Real Rate — 15 pts
        if us10y_bias == "BULLISH":
            bias_scores['BULLISH'] += 15
        elif us10y_bias == "BEARISH":
            bias_scores['BEARISH'] += 15

        # Geopolitical — 15 pts, requires confirmation from ≥1 other indicator
        # to prevent a single geo event from unilaterally overriding all others
        other_bullish = any(b == "BULLISH" for b in [cot_bias, dxy_bias, sentiment_bias, vix_bias, us10y_bias])
        other_bearish = any(b == "BEARISH" for b in [cot_bias, dxy_bias, sentiment_bias, vix_bias, us10y_bias])
        if geo_bias == "BULLISH" and other_bullish:
            bias_scores['BULLISH'] += 15
        elif geo_bias == "BEARISH" and other_bearish:
            bias_scores['BEARISH'] += 15

        # Surprise — 25 pts, POST_NEWS only
        if timing_mode == TimingMode.POST_NEWS_ENTRY:
            if surprise_bias == "BULLISH":
                bias_scores['BULLISH'] += 25
            elif surprise_bias == "BEARISH":
                bias_scores['BEARISH'] += 25

        # Determine final bias (minimum 15 pt margin to avoid noise trades)
        if bias_scores['BULLISH'] > bias_scores['BEARISH'] + 15:
            entry_bias = "BULLISH"
        elif bias_scores['BEARISH'] > bias_scores['BULLISH'] + 15:
            entry_bias = "BEARISH"
        else:
            entry_bias = "NEUTRAL"

        # ── Count aligned indicators ────────────────────────────────
        # An indicator is "aligned" when it agrees with the winning direction.
        # 6 base indicators; surprise only counts in POST_NEWS mode.
        winning_bias = entry_bias if entry_bias != "NEUTRAL" else (
            "BULLISH" if bias_scores['BULLISH'] >= bias_scores['BEARISH'] else "BEARISH"
        )
        aligned_count = sum([
            cot_bias == winning_bias,
            dxy_bias == winning_bias,
            sentiment_bias == winning_bias,
            vix_bias == winning_bias,
            us10y_bias == winning_bias,
            geo_bias == winning_bias,
            timing_mode == TimingMode.POST_NEWS_ENTRY and surprise_bias == winning_bias,
        ])

        # ── Confidence — tiered by number of aligned indicators ─────
        #   6 base indicators (+ 1 surprise in POST_NEWS = 7 max)
        #   1 aligned  → max 45%
        #   2 aligned  → max 60%
        #   3 aligned  → max 73%
        #   4 aligned  → max 83%
        #   5 aligned  → max 92%
        #   6+ aligned → max 98% (near-perfect consensus)
        confidence_caps = {1: 45.0, 2: 60.0, 3: 73.0, 4: 83.0, 5: 92.0}
        max_confidence = confidence_caps.get(aligned_count, 98.0 if aligned_count >= 6 else 45.0)

        total_score = bias_scores['BULLISH'] + bias_scores['BEARISH']
        if total_score > 0:
            raw_confidence = (max(bias_scores['BULLISH'], bias_scores['BEARISH']) / total_score) * 100
        else:
            raw_confidence = 50.0

        confidence = min(raw_confidence, max_confidence)

        reasoning.append(
            f"Scores — BULL:{bias_scores['BULLISH']} BEAR:{bias_scores['BEARISH']} "
            f"| aligned={aligned_count} | cap={max_confidence:.0f}%"
        )
        
        # ═══════════════════════════════════════════════════════════
        # 10. DETERMINE ENTRY STRATEGY
        # ═══════════════════════════════════════════════════════════
        
        blackout_active = timing_mode == TimingMode.BLACKOUT
        
        if blackout_active:
            entry_strategy = EntryStrategy.WAIT
            suggested_direction = None
            position_size_factor = 0.0
        elif timing_mode == TimingMode.POST_NEWS_ENTRY:
            # Post-news: Fade the spike
            entry_strategy = EntryStrategy.FADE_SPIKE
            if entry_bias == "BULLISH":
                suggested_direction = "BUY"
            elif entry_bias == "BEARISH":
                suggested_direction = "SELL"
            else:
                suggested_direction = None
            position_size_factor = 0.75  # Reduced size for reversal
        elif timing_mode == TimingMode.PRE_NEWS_SETUP:
            # Pre-news: Trend continuation if aligned
            if confidence >= 60 and entry_bias != "NEUTRAL":
                entry_strategy = EntryStrategy.TREND_CONTINUATION
                suggested_direction = "BUY" if entry_bias == "BULLISH" else "SELL"
                position_size_factor = 0.5  # Small size before news
            else:
                entry_strategy = EntryStrategy.WAIT
                suggested_direction = None
                position_size_factor = 0.0
        else:
            # Clear: Normal trading
            if entry_bias == "BULLISH":
                entry_strategy = EntryStrategy.TREND_CONTINUATION
                suggested_direction = "BUY"
            elif entry_bias == "BEARISH":
                entry_strategy = EntryStrategy.TREND_CONTINUATION
                suggested_direction = "SELL"
            else:
                entry_strategy = EntryStrategy.WAIT
                suggested_direction = None
            position_size_factor = 1.0
        
        # Adjust position size by confidence
        if confidence >= 80:
            position_size_factor *= 1.2
        elif confidence < 60:
            position_size_factor *= 0.7
        
        position_size_factor = min(1.5, max(0, position_size_factor))
        
        # ═══════════════════════════════════════════════════════════
        # 11. RISK PARAMETERS
        # ═══════════════════════════════════════════════════════════
        
        # Wider stops if high impact news nearby
        wider_stops = (
            timing_mode in [TimingMode.PRE_NEWS_SETUP, TimingMode.POST_NEWS_ENTRY] and
            impact_level == 'High'
        )
        
        # Take profit mode
        if timing_mode == TimingMode.POST_NEWS_ENTRY:
            take_profit_mode = "QUICK"  # Fast exit on reversal
        elif geo_tension >= 8:
            take_profit_mode = "EXTENDED"  # Let winners run in crisis
        else:
            take_profit_mode = "NORMAL"
        
        reasoning.append(f"Final: {entry_bias} bias, {confidence:.0f}% confidence")
        
        return NewsTradingSignal(
            timing_mode=timing_mode,
            entry_bias=entry_bias,
            entry_strategy=entry_strategy,
            confidence=confidence,
            blackout_active=blackout_active,
            minutes_to_news=minutes_to_news,
            next_event=event_name if hours_to_news and hours_to_news < 24 else None,
            cot_bias=cot_bias,
            sentiment_bias=sentiment_bias,
            surprise_bias=surprise_bias,
            suggested_direction=suggested_direction,
            position_size_factor=round(position_size_factor, 2),
            wider_stops=wider_stops,
            take_profit_mode=take_profit_mode,
            reasoning=reasoning
        )
    
    def to_dict(self, signal: NewsTradingSignal) -> Dict[str, Any]:
        """Convert signal to JSON-serializable dict"""
        return {
            'timing_mode': signal.timing_mode.value,
            'entry_bias': signal.entry_bias,
            'entry_strategy': signal.entry_strategy.value,
            'confidence': round(signal.confidence, 1),
            'blackout_active': signal.blackout_active,
            'minutes_to_news': round(signal.minutes_to_news, 1) if signal.minutes_to_news else None,
            'next_event': signal.next_event,
            'analysis': {
                'cot_bias': signal.cot_bias,
                'sentiment_bias': signal.sentiment_bias,
                'surprise_bias': signal.surprise_bias
            },
            'trade_params': {
                'direction': signal.suggested_direction,
                'size_factor': signal.position_size_factor,
                'wider_stops': signal.wider_stops,
                'tp_mode': signal.take_profit_mode
            },
            'reasoning': signal.reasoning,
            'timestamp': datetime.utcnow().isoformat()
        }


# ═══════════════════════════════════════════════════════════════════════════════
# FLASK ENDPOINT INTEGRATION
# ═══════════════════════════════════════════════════════════════════════════════

def create_news_trading_endpoint(app, get_full_intelligence):
    """
    Add /news_trading_signal endpoint to Flask app
    
    Args:
        app: Flask application
        get_full_intelligence: Function that returns all intelligence data
    """
    from flask import jsonify
    
    analyzer = NewsTradingAnalyzer()
    
    @app.route('/news_trading_signal', methods=['GET'])
    def news_trading_signal():
        """
        Returns news trading signal with entry recommendation
        
        Response:
        {
            "timing_mode": "CLEAR|BLACKOUT|PRE_NEWS_SETUP|POST_NEWS_ENTRY",
            "entry_bias": "BULLISH|BEARISH|NEUTRAL",
            "entry_strategy": "WAIT|FADE_SPIKE|TREND_CONTINUATION|SCALP_REVERSAL",
            "confidence": 0-100,
            "blackout_active": true/false,
            "trade_params": {
                "direction": "BUY|SELL|null",
                "size_factor": 0.0-1.5,
                "wider_stops": true/false,
                "tp_mode": "QUICK|NORMAL|EXTENDED"
            },
            ...
        }
        """
        try:
            # Get all intelligence data
            intel = get_full_intelligence()
            
            # Extract components
            news_data = {
                'next_event': intel.get('news', {}).get('next_event', {}),
                'hours_to_next': intel.get('news', {}).get('hours_to_next'),
                'recent_results': intel.get('news', {}).get('recent_results', [])
            }
            
            cot_data = intel.get('cot', {})
            
            sentiment_data = {
                'fear_greed': intel.get('fear_greed', {})
            }
            
            geopolitical_data = intel.get('geopolitical', {})
            
            # Generate signal
            signal = analyzer.generate_signal(
                news_data=news_data,
                cot_data=cot_data,
                sentiment_data=sentiment_data,
                geopolitical_data=geopolitical_data
            )
            
            return jsonify(analyzer.to_dict(signal))
            
        except Exception as e:
            logger.error(f"Error generating news trading signal: {e}")
            return jsonify({
                'error': str(e),
                'timing_mode': 'CLEAR',
                'entry_bias': 'NEUTRAL',
                'entry_strategy': 'WAIT',
                'confidence': 0,
                'blackout_active': False,
                'trade_params': {
                    'direction': None,
                    'size_factor': 0,
                    'wider_stops': False,
                    'tp_mode': 'NORMAL'
                }
            }), 500
    
    return app
