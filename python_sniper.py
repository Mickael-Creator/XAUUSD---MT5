#!/usr/bin/env python3
"""
Python Sniper M15 — ICT Entry Analysis
========================================
Port exact de CSniperM15::AnalyzeEntry() du MQL5.

Architecture :
  - M15 = Primary timeframe (structure, BOS, pullback)
  - M5  = Confirmation (PD Arrays + CHoCH timing)
  - SL  = Based on M15 swing structure

Convention DataFrame :
  Colonnes : t, o, h, l, c, v
  Index 0  = oldest bar, index -1 = most recent (standard pandas)
  Internement, les algos convertissent en "series" (0 = most recent)
"""

import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional

import numpy as np
import pandas as pd

logger = logging.getLogger(__name__)

# XAUUSD: 1 pip = 0.10 (point = 0.01)
POINT = 0.01
PIP = POINT * 10  # 0.10


# ═══════════════════════════════════════════════════════════════════════════════
# DATA STRUCTURES
# ═══════════════════════════════════════════════════════════════════════════════

@dataclass
class SwingPoint:
    price: float
    bar_index: int  # 0 = most recent
    is_high: bool
    broken: bool = False
    swept: bool = False


@dataclass
class LiquiditySweep:
    detected: bool = False
    sweep_level: float = 0.0
    sweep_price: float = 0.0
    sweep_bar: int = -1
    reclaimed: bool = False
    bars_since: int = 999
    sweep_type: str = "NONE"


@dataclass
class BreakOfStructure:
    detected: bool = False
    bos_level: float = 0.0
    bos_price: float = 0.0
    bos_bar: int = -1
    direction: str = "NONE"
    confirmed: bool = False
    bars_since: int = 999


@dataclass
class PDArray:
    found: bool = False
    pd_type: str = "NONE"  # FVG / OB
    zone_high: float = 0.0
    zone_low: float = 0.0
    created_bar: int = -1
    strength: float = 0.0


@dataclass
class PullbackZone:
    in_zone: bool = False
    mitigated: bool = False
    pd_type: str = "NONE"
    pd_strength: float = 0.0
    choch_m5: bool = False
    bos_m5: bool = False
    zone_high: float = 0.0
    zone_low: float = 0.0
    optimal_entry: float = 0.0


@dataclass
class M5Confirmation:
    has_pattern: bool = False
    pattern_name: str = "NONE"
    pattern_score: float = 0.0
    candle_confirm: bool = False


@dataclass
class SniperResult:
    valid: bool = False
    score: int = 0
    entry: float = 0.0
    sl: float = 0.0
    tp: float = 0.0
    sl_pips: float = 0.0
    rr: float = 0.0
    pd_type: str = "NONE"
    reason: str = ""
    session: str = ""
    htf_bias: str = "NEUTRAL"
    in_ote: bool = False


# ═══════════════════════════════════════════════════════════════════════════════
# 1. SWING DETECTOR
# ═══════════════════════════════════════════════════════════════════════════════

class SwingDetector:
    """Detect swing highs and lows on OHLC data (series order: 0=most recent)."""

    @staticmethod
    def find_swing_highs(h: np.ndarray, lookback: int = 4) -> list[SwingPoint]:
        """h is in series order (0=most recent). lookback = bars each side."""
        n = len(h)
        swings = []
        end = min(n - lookback, n - lookback - 1)
        for i in range(lookback, n - lookback):
            is_swing = True
            for j in range(1, lookback + 1):
                if i - j < 0 or i + j >= n:
                    is_swing = False
                    break
                if h[i] <= h[i - j] or h[i] <= h[i + j]:
                    is_swing = False
                    break
            if is_swing:
                swings.append(SwingPoint(price=h[i], bar_index=i, is_high=True))
        return swings

    @staticmethod
    def find_swing_lows(l: np.ndarray, lookback: int = 4) -> list[SwingPoint]:
        """l is in series order (0=most recent). lookback = bars each side."""
        n = len(l)
        swings = []
        for i in range(lookback, n - lookback):
            is_swing = True
            for j in range(1, lookback + 1):
                if i - j < 0 or i + j >= n:
                    is_swing = False
                    break
                if l[i] >= l[i - j] or l[i] >= l[i + j]:
                    is_swing = False
                    break
            if is_swing:
                swings.append(SwingPoint(price=l[i], bar_index=i, is_high=False))
        return swings


# ═══════════════════════════════════════════════════════════════════════════════
# 2. LIQUIDITY SWEEP DETECTOR
# ═══════════════════════════════════════════════════════════════════════════════

class LiquiditySweepDetector:
    """Detect liquidity sweeps of swing points on M15."""

    @staticmethod
    def detect_sweep(h: np.ndarray, l: np.ndarray, c: np.ndarray,
                     direction: str, swings: list[SwingPoint],
                     max_bars: int = 20) -> LiquiditySweep:
        sweep = LiquiditySweep()
        n = len(c)

        if direction == "BUY":
            for sp in swings:
                level = sp.price
                max_j = min(sp.bar_index, max_bars)
                for j in range(max_j):
                    if j >= n:
                        break
                    if l[j] < level and c[j] > level:
                        sweep.detected = True
                        sweep.sweep_level = level
                        sweep.sweep_price = l[j]
                        sweep.sweep_bar = j
                        sweep.reclaimed = True
                        sweep.bars_since = j
                        sweep.sweep_type = "LOW_SWEEP"
                        return sweep
        else:  # SELL
            for sp in swings:
                level = sp.price
                max_j = min(sp.bar_index, max_bars)
                for j in range(max_j):
                    if j >= n:
                        break
                    if h[j] > level and c[j] < level:
                        sweep.detected = True
                        sweep.sweep_level = level
                        sweep.sweep_price = h[j]
                        sweep.sweep_bar = j
                        sweep.reclaimed = True
                        sweep.bars_since = j
                        sweep.sweep_type = "HIGH_SWEEP"
                        return sweep
        return sweep


# ═══════════════════════════════════════════════════════════════════════════════
# 3. BOS DETECTOR
# ═══════════════════════════════════════════════════════════════════════════════

class BOSDetector:
    """Detect Break of Structure on M15."""

    @staticmethod
    def detect_bos(c: np.ndarray, direction: str,
                   swings: list[SwingPoint], max_age: int = 20) -> BreakOfStructure:
        bos = BreakOfStructure()
        n = len(c)

        if direction == "BUY":
            for sp in swings:
                level = sp.price
                max_j = min(sp.bar_index, max_age + 5)
                for j in range(max_j):
                    if j >= n or j + 1 >= n:
                        break
                    if c[j] > level and c[j + 1] <= level:
                        bos.detected = True
                        bos.bos_level = level
                        bos.bos_price = c[j]
                        bos.bos_bar = j
                        bos.direction = "BULLISH"
                        bos.confirmed = True
                        bos.bars_since = j
                        return bos
        else:  # SELL
            for sp in swings:
                level = sp.price
                max_j = min(sp.bar_index, max_age + 5)
                for j in range(max_j):
                    if j >= n or j + 1 >= n:
                        break
                    if c[j] < level and c[j + 1] >= level:
                        bos.detected = True
                        bos.bos_level = level
                        bos.bos_price = c[j]
                        bos.bos_bar = j
                        bos.direction = "BEARISH"
                        bos.confirmed = True
                        bos.bars_since = j
                        return bos
        return bos


# ═══════════════════════════════════════════════════════════════════════════════
# 4. ICT ARRAY DETECTOR
# ═══════════════════════════════════════════════════════════════════════════════

class ICTArrayDetector:
    """Find FVG and OB on M5 data. Arrays in series order (0=most recent)."""

    @staticmethod
    def find_fvg(h: np.ndarray, l: np.ndarray, direction: str,
                 lookback: int = 80) -> PDArray:
        pd_arr = PDArray()
        n = len(h)
        if n < 5:
            return pd_arr

        max_bar = min(lookback, n - 2)
        for i in range(2, max_bar + 1):
            if i - 1 < 0 or i + 1 >= n:
                continue
            if direction == "BUY":
                top = l[i - 1]
                bot = h[i + 1]
                gap = top - bot
                if gap > PIP:  # > 1 pip
                    pd_arr.found = True
                    pd_arr.pd_type = "FVG"
                    pd_arr.zone_high = top
                    pd_arr.zone_low = bot
                    pd_arr.created_bar = i
                    pd_arr.strength = min(100.0, (gap / PIP) * 2.0)
                    return pd_arr
            else:  # SELL
                bot = h[i - 1]
                top = l[i + 1]
                gap = top - bot
                if gap > PIP:
                    pd_arr.found = True
                    pd_arr.pd_type = "FVG"
                    pd_arr.zone_high = top
                    pd_arr.zone_low = bot
                    pd_arr.created_bar = i
                    pd_arr.strength = min(100.0, (gap / PIP) * 2.0)
                    return pd_arr
        return pd_arr

    @staticmethod
    def find_ob(o: np.ndarray, c: np.ndarray, h: np.ndarray, l: np.ndarray,
                direction: str, atr: float, lookback: int = 80,
                atr_mult: float = 1.2) -> PDArray:
        pd_arr = PDArray()
        n = len(c)
        if n < 5 or atr <= 0:
            return pd_arr

        max_bar = min(lookback, n - 2)
        min_displacement = atr_mult * atr

        for i in range(1, max_bar + 1):
            ob = i + 1
            if ob >= n:
                continue
            body = abs(c[i] - o[i])
            is_bull = c[i] > o[i]
            is_bear = c[i] < o[i]

            if direction == "BUY":
                if is_bull and body >= min_displacement:
                    if c[ob] < o[ob]:  # preceding candle is bearish
                        pd_arr.found = True
                        pd_arr.pd_type = "OB"
                        pd_arr.zone_high = h[ob]
                        pd_arr.zone_low = l[ob]
                        pd_arr.created_bar = ob
                        pd_arr.strength = min(100.0, (body / atr) * 30.0)
                        return pd_arr
            else:  # SELL
                if is_bear and body >= min_displacement:
                    if c[ob] > o[ob]:  # preceding candle is bullish
                        pd_arr.found = True
                        pd_arr.pd_type = "OB"
                        pd_arr.zone_high = h[ob]
                        pd_arr.zone_low = l[ob]
                        pd_arr.created_bar = ob
                        pd_arr.strength = min(100.0, (body / atr) * 30.0)
                        return pd_arr
        return pd_arr

    @staticmethod
    def is_mitigated(price: float, zone: PDArray) -> bool:
        if not zone.found:
            return False
        if zone.zone_high <= zone.zone_low:
            return False
        return zone.zone_low <= price <= zone.zone_high


# ═══════════════════════════════════════════════════════════════════════════════
# 5. CHoCH DETECTOR (M5)
# ═══════════════════════════════════════════════════════════════════════════════

class CHoCHDetector:
    """Detect Change of Character on M5 via pivot break."""

    @staticmethod
    def _is_pivot_high(h: np.ndarray, i: int, left: int = 2, right: int = 2) -> bool:
        n = len(h)
        if i + left >= n or i - right < 0:
            return False
        for k in range(1, left + 1):
            if i + k >= n or h[i] <= h[i + k]:
                return False
        for k in range(1, right + 1):
            if i - k < 0 or h[i] <= h[i - k]:
                return False
        return True

    @staticmethod
    def _is_pivot_low(l: np.ndarray, i: int, left: int = 2, right: int = 2) -> bool:
        n = len(l)
        if i + left >= n or i - right < 0:
            return False
        for k in range(1, left + 1):
            if i + k >= n or l[i] >= l[i + k]:
                return False
        for k in range(1, right + 1):
            if i - k < 0 or l[i] >= l[i - k]:
                return False
        return True

    @classmethod
    def _find_recent_pivot_high(cls, h: np.ndarray, lookback: int = 20) -> Optional[tuple]:
        n = len(h)
        left, right = 2, 2
        if n < left + right + 1:
            return None
        max_i = min(lookback, n - right - 1)
        start_i = left + 1
        if start_i > max_i:
            return None
        for i in range(start_i, max_i + 1):
            if cls._is_pivot_high(h, i, left, right):
                return (h[i], i)
        return None

    @classmethod
    def _find_recent_pivot_low(cls, l: np.ndarray, lookback: int = 20) -> Optional[tuple]:
        n = len(l)
        left, right = 2, 2
        if n < left + right + 1:
            return None
        max_i = min(lookback, n - right - 1)
        start_i = left + 1
        if start_i > max_i:
            return None
        for i in range(start_i, max_i + 1):
            if cls._is_pivot_low(l, i, left, right):
                return (l[i], i)
        return None

    @classmethod
    def detect_choch(cls, o: np.ndarray, c: np.ndarray,
                     h: np.ndarray, l: np.ndarray,
                     direction: str, atr: float,
                     lookback: int = 20) -> tuple:
        """Returns (choch: bool, bos_m5: bool)"""
        n = len(c)
        if n < 10:
            return (False, False)

        if direction == "BUY":
            result = cls._find_recent_pivot_high(h, lookback)
            if result is None:
                return (False, False)
            pivot, _ = result
            if n < 2:
                return (False, False)
            if c[1] > pivot:
                rng = h[1] - l[1]
                bos_m5 = (atr > 0 and rng >= 1.2 * atr)
                return (True, bos_m5)
        else:  # SELL
            result = cls._find_recent_pivot_low(l, lookback)
            if result is None:
                return (False, False)
            pivot, _ = result
            if n < 2:
                return (False, False)
            if c[1] < pivot:
                rng = h[1] - l[1]
                bos_m5 = (atr > 0 and rng >= 1.2 * atr)
                return (True, bos_m5)

        return (False, False)


# ═══════════════════════════════════════════════════════════════════════════════
# M5 PATTERN DETECTOR
# ═══════════════════════════════════════════════════════════════════════════════

class M5PatternDetector:
    """Detect candlestick patterns on M5 (series order: 0=most recent)."""

    @staticmethod
    def detect(o: np.ndarray, c: np.ndarray,
               h: np.ndarray, l: np.ndarray,
               direction: str) -> M5Confirmation:
        confirm = M5Confirmation()
        n = len(c)
        if n < 3:
            return confirm

        body1 = abs(c[1] - o[1])
        range1 = h[1] - l[1]
        if range1 <= 0:
            return confirm

        if direction == "BUY":
            lower_wick = min(o[1], c[1]) - l[1]
            upper_wick = h[1] - max(o[1], c[1])
            # Pin bar
            if lower_wick > body1 * 2 and lower_wick > upper_wick * 2 and c[1] > o[1]:
                confirm.has_pattern = True
                confirm.pattern_name = "PIN_BAR"
                confirm.pattern_score = 90
            # Bullish engulfing
            elif (c[2] < o[2] and c[1] > o[1] and c[1] > o[2] and o[1] < c[2]):
                confirm.has_pattern = True
                confirm.pattern_name = "ENGULFING"
                confirm.pattern_score = 85
            # Rejection
            elif c[1] > o[1] and (h[1] - c[1]) < body1 * 0.3:
                confirm.has_pattern = True
                confirm.pattern_name = "REJECTION"
                confirm.pattern_score = 75
        else:  # SELL
            upper_wick = h[1] - max(o[1], c[1])
            lower_wick = min(o[1], c[1]) - l[1]
            # Pin bar
            if upper_wick > body1 * 2 and upper_wick > lower_wick * 2 and c[1] < o[1]:
                confirm.has_pattern = True
                confirm.pattern_name = "PIN_BAR"
                confirm.pattern_score = 90
            # Bearish engulfing
            elif (c[2] > o[2] and c[1] < o[1] and c[1] < o[2] and o[1] > c[2]):
                confirm.has_pattern = True
                confirm.pattern_name = "ENGULFING"
                confirm.pattern_score = 85
            # Rejection
            elif c[1] < o[1] and (c[1] - l[1]) < body1 * 0.3:
                confirm.has_pattern = True
                confirm.pattern_name = "REJECTION"
                confirm.pattern_score = 75

        if not confirm.has_pattern:
            confirm.pattern_score = 40

        # Candle confirmation
        if n > 1:
            if direction == "BUY":
                confirm.candle_confirm = (c[1] > o[1])
            else:
                confirm.candle_confirm = (c[1] < o[1])
            if confirm.candle_confirm:
                confirm.pattern_score += 10

        return confirm


# ═══════════════════════════════════════════════════════════════════════════════
# 6. SNIPER SCORER
# ═══════════════════════════════════════════════════════════════════════════════

class SniperScorer:
    """Exact scoring from MQL5 CalculateScore()."""

    @staticmethod
    def calculate(structure_aligned: bool,
                  sweep: LiquiditySweep,
                  bos: BreakOfStructure,
                  pullback: PullbackZone,
                  m5_confirm: M5Confirmation,
                  session_boost: int,
                  use_m5_confirm: bool = True,
                  htf_bias_score: int = 0,
                  ote_score: int = 0) -> int:
        score = 0

        # Structure alignment (20 pts)
        if structure_aligned:
            score += 20
        else:
            score += 10

        # HTF Bias H4 (+20 aligned, -20 opposed, 0 neutral/unavailable)
        score += htf_bias_score

        # Liquidity sweep (25 pts)
        if sweep.detected and sweep.reclaimed:
            score += 25
            if sweep.bars_since <= 5:
                score += 5

        # BOS (25 pts)
        if bos.detected and bos.confirmed:
            score += 25
            if bos.bars_since <= 5:
                score += 5

        # Pullback / PD Array (max 25 pts)
        if pullback.mitigated:
            score += 15
            if pullback.pd_type in ("FVG", "OB"):
                score += 5
            if pullback.choch_m5:
                score += 10
            if pullback.bos_m5:
                score += 5

        # OTE Fibonacci (15 pts if price in 61.8%-78.6% retracement)
        score += ote_score

        # M5 Confirmation (15 pts max)
        if use_m5_confirm:
            score += int(m5_confirm.pattern_score * 0.15)
        else:
            score += 10

        # Session boost
        score += session_boost

        return max(0, min(100, score))


# ═══════════════════════════════════════════════════════════════════════════════
# SESSION HELPER
# ═══════════════════════════════════════════════════════════════════════════════

def _get_session() -> tuple:
    """Returns (session_name, session_boost) based on current UTC hour.
    MQL5 server time ~ UTC+2 (CET). Using UTC and shifting +2."""
    hour = (datetime.now(timezone.utc).hour + 2) % 24

    if 7 <= hour < 9:
        return ("LONDON_OPEN", 10)
    if 9 <= hour < 12:
        return ("LONDON", 5)
    if 12 <= hour < 14:
        return ("LONDON_NY_OVERLAP", 15)
    if 14 <= hour < 17:
        return ("NEW_YORK", 5)
    if 0 <= hour < 7:
        return ("ASIAN", 0)
    return ("OFF_HOURS", 0)


# ═══════════════════════════════════════════════════════════════════════════════
# HELPER: DataFrame → series arrays (0=most recent)
# ═══════════════════════════════════════════════════════════════════════════════

def _to_series(df: pd.DataFrame) -> tuple:
    """Convert DataFrame (oldest first) to reversed numpy arrays (newest first)."""
    o = df["o"].values[::-1].copy()
    h = df["h"].values[::-1].copy()
    l = df["l"].values[::-1].copy()
    c = df["c"].values[::-1].copy()
    return o, h, l, c


def _calc_ema(values: np.ndarray, period: int) -> float:
    """Calculate EMA on series array (0=most recent). Returns EMA at bar 0."""
    n = len(values)
    if n < period:
        return float(np.mean(values[:n]))
    k = 2.0 / (period + 1)
    ema = float(np.mean(values[n - period:]))  # SMA seed from oldest bars
    for i in range(n - period - 1, -1, -1):  # walk toward most recent
        ema = values[i] * k + ema * (1 - k)
    return ema


def _calc_htf_bias(c_h4: np.ndarray, ema_fast: int = 20, ema_slow: int = 50) -> str:
    """Determine H4 bias from EMA20/EMA50 crossover. Returns BULLISH/BEARISH/NEUTRAL."""
    n = len(c_h4)
    if n < ema_slow:
        return "NEUTRAL"
    fast = _calc_ema(c_h4, ema_fast)
    slow = _calc_ema(c_h4, ema_slow)
    diff_pips = (fast - slow) / PIP
    if diff_pips > 2.0:
        return "BULLISH"
    if diff_pips < -2.0:
        return "BEARISH"
    return "NEUTRAL"


def _calc_atr(h: np.ndarray, l: np.ndarray, c: np.ndarray, period: int = 14) -> float:
    """Calculate ATR from series arrays. Returns ATR at bar 1 (last closed)."""
    n = len(h)
    if n < period + 2:
        return (h[1] - l[1]) if n > 1 else 1.0

    tr_values = []
    for i in range(1, period + 1):
        if i + 1 < n:
            tr = max(h[i] - l[i], abs(h[i] - c[i + 1]), abs(l[i] - c[i + 1]))
        else:
            tr = h[i] - l[i]
        tr_values.append(tr)
    return sum(tr_values) / len(tr_values) if tr_values else 1.0


# ═══════════════════════════════════════════════════════════════════════════════
# 7. PYTHON SNIPER M15
# ═══════════════════════════════════════════════════════════════════════════════

class PythonSniperM15:
    """
    Port exact de CSniperM15::AnalyzeEntry() du MQL5.
    Utilise des DataFrames pandas au lieu des tableaux MQL5.
    """

    # Default settings matching MQL5 EA inputs
    SWING_LOOKBACK = 4
    MAX_BARS_AFTER_BOS = 20
    MAX_BARS_AFTER_SWEEP = 20
    SL_BUFFER = 3.0   # pips
    SL_MIN = 20.0      # pips
    SL_MAX = 60.0      # pips
    MIN_RR = 2.0
    MIN_SCORE = 60
    MAX_SPREAD = 5.0   # pips
    USE_M5_CONFIRM = True

    def analyze_entry(self, direction: str, df_m15: pd.DataFrame,
                      df_m5: pd.DataFrame, current_price: float,
                      spread_pips: float = 2.0,
                      df_h4: pd.DataFrame = None) -> SniperResult:
        result = SniperResult()
        session_name, session_boost = _get_session()
        result.session = session_name

        # === Safety checks ===
        if df_m15 is None or len(df_m15) < 20:
            result.reason = "Insufficient M15 data"
            return result

        if df_m5 is None or len(df_m5) < 20:
            result.reason = "Insufficient M5 data"
            return result

        if spread_pips > self.MAX_SPREAD:
            result.reason = "Spread too high"
            return result

        # === Convert to series arrays (0=most recent) ===
        o15, h15, l15, c15 = _to_series(df_m15)
        o5, h5, l5, c5 = _to_series(df_m5)

        # === HTF Bias H4 (optional — graceful if df_h4 is None) ===
        htf_bias = "NEUTRAL"
        htf_bias_score = 0
        if df_h4 is not None and len(df_h4) >= 50:
            _, _, _, c_h4 = _to_series(df_h4)
            htf_bias = _calc_htf_bias(c_h4)
            if direction == "BUY" and htf_bias == "BULLISH":
                htf_bias_score = 20
            elif direction == "SELL" and htf_bias == "BEARISH":
                htf_bias_score = 20
            elif direction == "BUY" and htf_bias == "BEARISH":
                htf_bias_score = -20
            elif direction == "SELL" and htf_bias == "BULLISH":
                htf_bias_score = -20
        result.htf_bias = htf_bias

        # === Step 1: Detect swing points on M15 ===
        swing_highs = SwingDetector.find_swing_highs(h15, self.SWING_LOOKBACK)
        swing_lows = SwingDetector.find_swing_lows(l15, self.SWING_LOOKBACK)

        if len(swing_highs) < 2 or len(swing_lows) < 2:
            result.reason = "Insufficient swing points"
            return result

        # === Structure analysis ===
        structure_aligned = False
        if direction == "BUY":
            hh = swing_highs[0].price > swing_highs[1].price
            hl = swing_lows[0].price > swing_lows[1].price
            structure_aligned = (hh and hl)
        else:
            lh = swing_highs[0].price < swing_highs[1].price
            ll = swing_lows[0].price < swing_lows[1].price
            structure_aligned = (lh and ll)

        # === OTE Fibonacci (61.8%-78.6% retracement of last swing) ===
        ote_score = 0
        in_ote = False
        if direction == "BUY" and swing_highs and swing_lows:
            sh = swing_highs[0].price
            sl_level = swing_lows[0].price
            swing_range = sh - sl_level
            if swing_range > PIP:
                ote_low = sh - swing_range * 0.786
                ote_high = sh - swing_range * 0.618
                if ote_low <= current_price <= ote_high:
                    ote_score = 15
                    in_ote = True
        elif direction == "SELL" and swing_highs and swing_lows:
            sh = swing_highs[0].price
            sl_level = swing_lows[0].price
            swing_range = sh - sl_level
            if swing_range > PIP:
                ote_low = sl_level + swing_range * 0.618
                ote_high = sl_level + swing_range * 0.786
                if ote_low <= current_price <= ote_high:
                    ote_score = 15
                    in_ote = True
        result.in_ote = in_ote

        # === Step 2: Detect Liquidity Sweep ===
        target_swings = swing_lows if direction == "BUY" else swing_highs
        sweep = LiquiditySweepDetector.detect_sweep(
            h15, l15, c15, direction, target_swings, self.MAX_BARS_AFTER_SWEEP
        )

        if sweep.detected and not sweep.reclaimed:
            result.reason = "Sweep not reclaimed yet"
            return result
        if sweep.detected and sweep.bars_since > self.MAX_BARS_AFTER_SWEEP:
            result.reason = f"Sweep too old ({sweep.bars_since} bars)"
            return result

        # === Step 3: Detect BOS ===
        bos_swings = swing_highs if direction == "BUY" else swing_lows
        bos = BOSDetector.detect_bos(c15, direction, bos_swings, self.MAX_BARS_AFTER_BOS)

        if not bos.detected:
            result.reason = "No BOS detected"
            return result
        if bos.detected and not bos.confirmed:
            result.reason = "BOS not confirmed"
            return result
        if bos.detected and bos.bars_since > self.MAX_BARS_AFTER_BOS:
            result.reason = f"BOS too old ({bos.bars_since} bars)"
            return result

        # === Step 4: Analyze Pullback (PD Arrays on M5) ===
        atr_m5 = _calc_atr(h5, l5, c5)

        fvg = ICTArrayDetector.find_fvg(h5, l5, direction, lookback=80)
        ob = ICTArrayDetector.find_ob(o5, c5, h5, l5, direction, atr_m5, lookback=80)

        # Select best PD array (priority: mitigated > closest)
        pd = PDArray()
        if fvg.found and ICTArrayDetector.is_mitigated(current_price, fvg):
            pd = fvg
        elif ob.found and ICTArrayDetector.is_mitigated(current_price, ob):
            pd = ob
        elif fvg.found and not ob.found:
            pd = fvg
        elif ob.found and not fvg.found:
            pd = ob
        elif fvg.found and ob.found:
            mid_f = (fvg.zone_high + fvg.zone_low) / 2
            mid_o = (ob.zone_high + ob.zone_low) / 2
            pd = fvg if abs(current_price - mid_f) <= abs(current_price - mid_o) else ob

        pullback = PullbackZone()
        if pd.found:
            pullback.zone_high = pd.zone_high
            pullback.zone_low = pd.zone_low
            pullback.optimal_entry = (pd.zone_high + pd.zone_low) / 2
            pullback.pd_type = pd.pd_type
            pullback.pd_strength = pd.strength

            # Mitigation check
            pullback.mitigated = ICTArrayDetector.is_mitigated(current_price, pd)

            if pullback.mitigated:
                # CHoCH / BOS M5
                choch, bos_m5 = CHoCHDetector.detect_choch(
                    o5, c5, h5, l5, direction, atr_m5, lookback=60
                )
                pullback.choch_m5 = choch
                pullback.bos_m5 = bos_m5
                pullback.in_zone = pullback.mitigated and pullback.choch_m5

        if not pullback.mitigated:
            result.reason = "No mitigation on M5 PD array"
            return result

        # CHoCH M5 is now a scoring bonus (+10 pts in scorer), not a hard gate.
        # Trades can proceed without CHoCH M5 but with a lower score.

        # === Step 5: M5 Confirmation ===
        m5_confirm = M5PatternDetector.detect(o5, c5, h5, l5, direction)

        # === Step 6: Calculate Score ===
        score = SniperScorer.calculate(
            structure_aligned=structure_aligned,
            sweep=sweep,
            bos=bos,
            pullback=pullback,
            m5_confirm=m5_confirm,
            session_boost=session_boost,
            use_m5_confirm=self.USE_M5_CONFIRM,
            htf_bias_score=htf_bias_score,
            ote_score=ote_score,
        )

        # === Step 7: Calculate SL/TP ===
        sl = self._calculate_sl(direction, current_price, sweep, swing_highs, swing_lows)
        sl_pips = abs(current_price - sl) / PIP

        # TP based on RR
        tp = 0.0
        rr = 0.0
        if sl_pips > 0:
            tp_distance = sl_pips * self.MIN_RR * PIP
            if direction == "BUY":
                tp = current_price + tp_distance
            else:
                tp = current_price - tp_distance
            rr = self.MIN_RR

        # === Validate ===
        result.entry = current_price
        result.sl = round(sl, 2)
        result.tp = round(tp, 2)
        result.sl_pips = round(sl_pips, 1)
        result.rr = rr
        result.pd_type = pullback.pd_type
        result.score = score

        if score >= self.MIN_SCORE:
            result.valid = True
            result.reason = f"VALID - Score {score}"
        else:
            result.reason = f"Score too low ({score}/{self.MIN_SCORE})"

        return result

    def _calculate_sl(self, direction: str, price: float,
                      sweep: LiquiditySweep,
                      swing_highs: list[SwingPoint],
                      swing_lows: list[SwingPoint]) -> float:
        sl = 0.0
        buffer = self.SL_BUFFER * PIP  # Convert pips to price

        if sweep.detected and sweep.reclaimed:
            if direction == "BUY":
                sl = sweep.sweep_price - buffer
            else:
                sl = sweep.sweep_price + buffer
        else:
            if direction == "BUY" and swing_lows:
                sl = swing_lows[0].price - buffer
            elif direction == "SELL" and swing_highs:
                sl = swing_highs[0].price + buffer

        # Enforce min/max
        sl_pips = abs(price - sl) / PIP
        if sl_pips < self.SL_MIN:
            if direction == "BUY":
                sl = price - self.SL_MIN * PIP
            else:
                sl = price + self.SL_MIN * PIP
        if sl_pips > self.SL_MAX:
            if direction == "BUY":
                sl = price - self.SL_MAX * PIP
            else:
                sl = price + self.SL_MAX * PIP

        return sl


# ═══════════════════════════════════════════════════════════════════════════════
# SINGLETON
# ═══════════════════════════════════════════════════════════════════════════════

python_sniper = PythonSniperM15()
