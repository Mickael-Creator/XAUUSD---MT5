#!/usr/bin/env python3
"""
FRED Data Service — Real Macro Data for Gold Trading
=====================================================
Sources:
  - DFII10  → 10-Year Real Yield (TIPS)
  - T10YIE  → 10-Year Breakeven Inflation Rate
  - EFFR    → Effective Federal Funds Rate
  - T10Y2Y  → 10-Year minus 2-Year Treasury Spread (Yield Curve)

API: FRED (Federal Reserve Economic Data)
Key: Free at https://fred.stlouisfed.org/docs/api/api_key.html
Stored in /etc/goldml/.env as FRED_API_KEY
"""

import os
import time
import logging
import requests
from threading import Lock
from dotenv import load_dotenv

logger = logging.getLogger(__name__)

# Load FRED API key from /etc/goldml/.env
load_dotenv("/etc/goldml/.env")
FRED_API_KEY = os.environ.get("FRED_API_KEY", "")

if not FRED_API_KEY:
    logger.warning("⚠️ FRED_API_KEY not set in /etc/goldml/.env — FRED service disabled")

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

FRED_CONFIG = {
    "base_url": "https://api.stlouisfed.org/fred/series/observations",
    "cache_ttl": 3600,  # 1 hour — FRED data updates daily at most
    "timeout": 10,
    "series": {
        "DFII10": {
            "description": "10-Year Real Yield (TIPS)",
            "fallback": 1.8,
        },
        "T10YIE": {
            "description": "10-Year Breakeven Inflation Rate",
            "fallback": 2.3,
        },
        "EFFR": {
            "description": "Effective Federal Funds Rate",
            "fallback": 5.33,
        },
        "T10Y2Y": {
            "description": "10-Year minus 2-Year Treasury Spread (Yield Curve)",
            "fallback": 0.5,
        },
    },
}


# ═══════════════════════════════════════════════════════════════════════════════
# FRED DATA MANAGER
# ═══════════════════════════════════════════════════════════════════════════════

class FREDDataManager:
    """
    Fetches and caches FRED economic data series.
    Thread-safe with per-series TTL caching.
    """

    def __init__(self):
        self._lock = Lock()
        self._cache = {}       # {series_id: {"value": float, "date": str}}
        self._timestamps = {}  # {series_id: time.time()}

    def _is_fresh(self, series_id: str) -> bool:
        ts = self._timestamps.get(series_id, 0)
        return (time.time() - ts) < FRED_CONFIG["cache_ttl"]

    def _fetch_series(self, series_id: str) -> dict | None:
        """Fetch latest observation for a FRED series."""
        if not FRED_API_KEY:
            return None

        try:
            params = {
                "series_id": series_id,
                "api_key": FRED_API_KEY,
                "file_type": "json",
                "sort_order": "desc",
                "limit": 1,
            }
            r = requests.get(
                FRED_CONFIG["base_url"],
                params=params,
                timeout=FRED_CONFIG["timeout"],
            )
            if r.status_code != 200:
                logger.warning(f"[FRED] {series_id} HTTP {r.status_code}")
                return None

            data = r.json()
            observations = data.get("observations", [])
            if not observations:
                logger.warning(f"[FRED] {series_id} no observations returned")
                return None

            obs = observations[0]
            value_str = obs.get("value", ".")
            if value_str == ".":
                logger.warning(f"[FRED] {series_id} value is '.' (missing data)")
                return None

            value = round(float(value_str), 4)
            date = obs.get("date", "")
            logger.info(f"[FRED] {series_id} = {value} (date={date})")
            return {"value": value, "date": date}

        except Exception as e:
            logger.warning(f"[FRED] {series_id} fetch error: {e}")
            return None

    def get(self, series_id: str) -> float:
        """
        Get latest value for a FRED series.
        Returns cached value if fresh, otherwise fetches.
        Falls back to hardcoded default if unavailable.
        """
        with self._lock:
            if self._is_fresh(series_id) and series_id in self._cache:
                return self._cache[series_id]["value"]

        # Fetch outside lock to avoid blocking
        result = self._fetch_series(series_id)

        with self._lock:
            if result:
                self._cache[series_id] = result
                self._timestamps[series_id] = time.time()
                return result["value"]

            # Return cached stale if available
            if series_id in self._cache:
                logger.info(f"[FRED] {series_id} using stale cache")
                return self._cache[series_id]["value"]

            # Final fallback
            fallback = FRED_CONFIG["series"].get(series_id, {}).get("fallback", 0.0)
            logger.warning(f"[FRED] {series_id} using fallback: {fallback}")
            return fallback

    def get_all(self) -> dict:
        """Fetch all configured series, return as dict."""
        return {
            "real_yield_tips": self.get("DFII10"),
            "breakeven_inflation": self.get("T10YIE"),
            "fed_funds_rate": self.get("EFFR"),
            "yield_curve_10y2y": self.get("T10Y2Y"),
        }

    def status(self) -> dict:
        """Return cache status for health monitoring."""
        now = time.time()
        result = {}
        for series_id in FRED_CONFIG["series"]:
            ts = self._timestamps.get(series_id, 0)
            age = 999999 if ts == 0 else int(now - ts)
            result[series_id] = {
                "age_s": age,
                "fresh": self._is_fresh(series_id),
                "has_data": series_id in self._cache,
                "value": self._cache.get(series_id, {}).get("value"),
                "date": self._cache.get(series_id, {}).get("date"),
            }
        return result


# ═══════════════════════════════════════════════════════════════════════════════
# SINGLETON
# ═══════════════════════════════════════════════════════════════════════════════

fred_manager = FREDDataManager()


# Convenience functions
def get_tips_yield() -> float:
    """Get 10-Year Real Yield (TIPS) — replaces US10Y - 2.45 hack."""
    return fred_manager.get("DFII10")


def get_breakeven_inflation() -> float:
    """Get 10-Year Breakeven Inflation Rate."""
    return fred_manager.get("T10YIE")


def get_fed_funds_rate() -> float:
    """Get Effective Federal Funds Rate."""
    return fred_manager.get("EFFR")


def get_yield_curve_10y2y() -> float:
    """Get 10-Year minus 2-Year Treasury Spread (Yield Curve)."""
    return fred_manager.get("T10Y2Y")


# ═══════════════════════════════════════════════════════════════════════════════
# STANDALONE TEST
# ═══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    print("Testing FRED Data Service...")
    print(f"  FRED_API_KEY set: {bool(FRED_API_KEY)}")

    data = fred_manager.get_all()
    print(f"\n  Real Yield (TIPS):      {data['real_yield_tips']:.4f}%")
    print(f"  Breakeven Inflation:    {data['breakeven_inflation']:.4f}%")
    print(f"  Fed Funds Rate:         {data['fed_funds_rate']:.4f}%")
    print(f"  Yield Curve (10Y-2Y):   {data['yield_curve_10y2y']:.4f}%")

    print(f"\n  Cache status: {fred_manager.status()}")
