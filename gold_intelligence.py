#!/usr/bin/env python3
"""
Gold ML Intelligence System v2.0 — INSTITUTIONAL GRADE
=======================================================
Architecture :
  - Thread background unique qui rafraîchit TOUTES les données en continu
  - Cache en mémoire avec TTL par source + fallback multi-niveaux
  - Routes Flask lisent UNIQUEMENT le cache → réponse < 5ms, jamais de timeout
  - Retourne TOUJOURS HTTP 200 vers l'EA, même en cas d'erreur interne
  - Prix Gold via fallback chain robuste (Yahoo v8 → GLD proxy → cache stale)
  - Warm-up automatique au démarrage avant d'accepter les requêtes
"""

import os
import json
import time
import hmac
import hashlib
import logging
import logging.handlers
import sqlite3
import threading
import requests
import feedparser
from datetime import datetime, timedelta, timezone
import pandas as pd
from flask import Flask, jsonify, request, send_file
from threading import Lock, Event
from news_fetcher_v2 import fetch_forex_factory_news as fetch_news_v2
from news_trading_signal import NewsTradingAnalyzer, create_news_trading_endpoint
from claude_decision_engine import claude_engine
from python_sniper import python_sniper

# ═══════════════════════════════════════════════════════════════════════════════
# LOGGING
# ═══════════════════════════════════════════════════════════════════════════════

os.makedirs('/root/gold_ml_phase4/logs', exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s,%(msecs)03d - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    handlers=[
        logging.handlers.WatchedFileHandler('/root/gold_ml_phase4/logs/gold_intelligence.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

CONFIG = {
    "db_path": "/root/gold_ml_phase4/gold_intelligence.db",
    "local_api_base": "http://127.0.0.1:5000",
    "fear_greed_url": "https://api.alternative.me/fng/?limit=1",

    # TTL en secondes par source de données
    "ttl": {
        "gold_price":  30,    # Prix spot : 30s
        "macro":       300,   # US10Y / real_rate / DXY / VIX : 5 min
        "cot":         3600,  # COT : 1h (données hebdomadaires)
        "news":        120,   # News FF : 2 min
        "sentiment":   300,   # Fear & Greed : 5 min
        "geopolitics": 600,   # Géopolitique RSS : 10 min
        "signal":      30,    # Signal final calculé : 30s
    },
    # Marge pour le health check : TTL + grace → évite les faux DEGRADED
    # pendant le cycle de refresh séquentiel (sleep 10s + fetches ~5-10s)
    "health_grace_s": 20,

    # Valeurs de fallback institutionnelles (dernières valeurs connues fiables)
    "fallback": {
        "gold_price":  {"price": 4390.0,  "source": "fallback"},
        "dxy":         {"dxy_index": 96.1},
        "vix":         {"vix_level": 15.4},
        "macro":       {"us10y": 4.21, "real_rate": 1.8, "dxy": 96.1, "vix": 15.4, "cot": {}},
        "cot":         {"percentile": 50.0, "regime": "NEUTRAL", "net_positions": 0},
        "news":        {"events": [], "next_high_impact": None, "time_until_hours": None, "in_blackout": False},
        "sentiment":   {"fear_greed_index": 50, "fear_greed_label": "Neutral"},
        "geopolitics": {"tension_level": 5, "hot_zones_active": ["Ukraine", "Russia", "Gaza", "China"],
                        "recent_headlines": [], "safe_haven_demand": "MODERATE"},
        "signal":      {
            "can_trade": False, "direction": "NONE", "bias": "NEUTRAL",
            "confidence": 0, "size_factor": 1.0, "wider_stops": False,
            "tp_mode": "NORMAL", "blackout_minutes": 0, "timing_mode": "CLEAR",
            "gold_price": 4390.0, "source": "fallback", "error": None
        }
    },

    "rss_feeds": {
        "reuters_world": "https://www.rss.app/feeds/v1.1/tQfRuJjCsddPHNqF.json",
        "bbc_world":     "http://feeds.bbci.co.uk/news/world/rss.xml",
        "aljazeera":     "https://www.aljazeera.com/xml/rss/all.xml"
    },

    "geopolitical_keywords": {
        "high_impact":   ["war", "invasion", "nuclear", "sanctions", "attack", "military strike", "escalation"],
        "medium_impact": ["tension", "conflict", "missile", "troops", "border", "threat", "crisis"],
        "low_impact":    ["diplomatic", "talks", "summit", "negotiations", "relations"]
    },

    "hot_zones": ["israel", "gaza", "iran", "ukraine", "russia", "china",
                  "taiwan", "north korea", "middle east", "red sea"],

    "gold_impacting_news": ["FOMC", "Fed", "NFP", "Non-Farm", "CPI", "PPI",
                            "GDP", "Jobless", "Interest Rate", "Powell", "PCE"]
}

# ═══════════════════════════════════════════════════════════════════════════════
# CIRCUIT BREAKER — Protection contre les pertes consécutives
# ═══════════════════════════════════════════════════════════════════════════════

class CircuitBreaker:
    """
    Si les 3 derniers signaux can_trade=True montrent une chute de prix > 50 pips
    depuis le premier signal → force can_trade=False pendant 2 heures.
    Thread-safe.
    """
    MAX_HISTORY = 3
    PRICE_DROP_THRESHOLD_PIPS = 50.0   # 50 pips = $5.0 sur XAUUSD
    LOCKOUT_SECONDS = 2 * 3600         # 2 heures

    def __init__(self):
        self._lock = Lock()
        self._history = []        # list of {"price": float, "timestamp": datetime}
        self._locked_until = None  # datetime UTC when lockout expires

    def record_signal(self, gold_price: float):
        """Enregistre un signal can_trade=True avec son prix."""
        with self._lock:
            self._history.append({
                "price": gold_price,
                "timestamp": datetime.now(timezone.utc),
            })
            # Garder seulement les N derniers
            if len(self._history) > self.MAX_HISTORY:
                self._history = self._history[-self.MAX_HISTORY:]

    def check(self, current_price: float) -> tuple:
        """
        Retourne (is_locked: bool, reason: str).
        Vérifie :
        1. Lockout actif (2h après déclenchement)
        2. Chute de prix > 50 pips sur les 3 derniers signaux can_trade=True
        """
        with self._lock:
            now = datetime.now(timezone.utc)

            # Vérifier lockout actif
            if self._locked_until and now < self._locked_until:
                remaining = int((self._locked_until - now).total_seconds() / 60)
                return True, f"circuit_breaker_locked ({remaining}min remaining)"

            # Reset lockout expiré
            if self._locked_until and now >= self._locked_until:
                self._locked_until = None
                self._history.clear()
                logger.info("🔓 Circuit breaker lockout expired — reset")

            # Vérifier condition de déclenchement
            if len(self._history) >= self.MAX_HISTORY:
                first_price = self._history[0]["price"]
                drop_pips = (first_price - current_price) / 0.10  # XAUUSD: 1 pip = $0.10

                if drop_pips >= self.PRICE_DROP_THRESHOLD_PIPS:
                    self._locked_until = now + timedelta(seconds=self.LOCKOUT_SECONDS)
                    logger.warning(
                        f"🚨 CIRCUIT BREAKER TRIGGERED: {drop_pips:.1f} pips drop "
                        f"(${first_price:.2f} → ${current_price:.2f}) over last "
                        f"{self.MAX_HISTORY} can_trade signals. "
                        f"Locked until {self._locked_until.strftime('%H:%M UTC')}"
                    )
                    return True, f"circuit_breaker_triggered ({drop_pips:.0f} pips drop)"

            return False, ""

    def status(self) -> dict:
        """Retourne l'état du circuit breaker pour le health check."""
        with self._lock:
            now = datetime.now(timezone.utc)
            is_locked = self._locked_until is not None and now < self._locked_until
            return {
                "locked": is_locked,
                "locked_until": self._locked_until.isoformat() if self._locked_until else None,
                "history_count": len(self._history),
                "history": [
                    {"price": h["price"], "age_s": int((now - h["timestamp"]).total_seconds())}
                    for h in self._history
                ],
            }


circuit_breaker = CircuitBreaker()

# ═══════════════════════════════════════════════════════════════════════════════
# CACHE INSTITUTIONNEL — CŒUR DU SYSTÈME
# ═══════════════════════════════════════════════════════════════════════════════

class InstitutionalCache:
    """
    Cache thread-safe avec TTL individuel par source.
    Principe : les routes Flask NE FONT JAMAIS d'appels HTTP.
    Elles lisent uniquement ce cache, mis à jour par un thread background.
    """

    def __init__(self):
        self._lock = Lock()
        self._data = {}
        self._timestamps = {}
        # Pré-charger avec les fallbacks pour garantir une réponse immédiate
        for key, val in CONFIG["fallback"].items():
            self._data[key] = val
            self._timestamps[key] = 0  # Marqué comme expiré → sera rafraîchi

    def set(self, key: str, value: dict):
        with self._lock:
            self._data[key] = value
            self._timestamps[key] = time.time()

    def get_fresh(self, key: str):
        """Retourne la valeur si dans le TTL, None sinon"""
        with self._lock:
            ts = self._timestamps.get(key, 0)
            ttl = CONFIG["ttl"].get(key, 300)
            if (time.time() - ts) < ttl:
                return self._data.get(key)
            return None

    def get_best(self, key: str) -> dict:
        """
        Retourne la meilleure donnée disponible dans cet ordre :
        1. Cache frais (dans le TTL)
        2. Cache stale (expiré mais présent — mieux que rien)
        3. Fallback hardcodé
        """
        with self._lock:
            if key in self._data:
                val = self._data[key]
                # DataFrames / non-dict values: truthiness check would raise
                if val is not None and not (isinstance(val, dict) and not val):
                    return val
            return CONFIG["fallback"].get(key, {})

    def is_fresh(self, key: str) -> bool:
        with self._lock:
            ts = self._timestamps.get(key, 0)
            return (time.time() - ts) < CONFIG["ttl"].get(key, 300)

    def age_seconds(self, key: str) -> int:
        with self._lock:
            ts = self._timestamps.get(key, 0)
            if ts == 0:
                return 999999
            return int(time.time() - ts)

    def status(self, grace: int = 0) -> dict:
        """Retourne l'état de fraîcheur de toutes les clés — pour monitoring.
        grace: secondes supplémentaires tolérées avant de marquer stale.
        """
        with self._lock:
            now = time.time()
            result = {}
            for key in CONFIG["ttl"]:
                ts = self._timestamps.get(key, 0)
                ttl = CONFIG["ttl"].get(key, 300)
                age = 999999 if ts == 0 else int(now - ts)
                result[key] = {
                    "age_s":    age,
                    "ttl_s":    ttl,
                    "fresh":    (now - ts) < (ttl + grace),
                    "has_data": key in self._data and bool(self._data[key])
                }
            return result


# Instances globales
cache = InstitutionalCache()
app = Flask(__name__)
news_analyzer = NewsTradingAnalyzer()


# ═══════════════════════════════════════════════════════════════════════════════
# SÉCURITÉ — BEARER TOKEN + HMAC-SHA256
# ═══════════════════════════════════════════════════════════════════════════════

# Credentials chargés depuis les variables d'environnement — jamais hardcodés
_API_TOKEN   = os.environ.get('API_TOKEN', '')
_HMAC_SECRET = os.environ.get('HMAC_SECRET', '').encode('utf-8')

if not _API_TOKEN:
    logger.warning("⚠️  API_TOKEN not set — authenticated routes will reject all requests")
if not _HMAC_SECRET:
    logger.warning("⚠️  HMAC_SECRET not set — response signatures will be empty strings")


def _require_auth(f):
    """
    Décorateur Flask : vérifie l'en-tête Authorization: Bearer <API_TOKEN>.
    Retourne HTTP 401 si le token est absent ou invalide.
    Utilise hmac.compare_digest pour éviter les timing attacks.
    """
    from functools import wraps
    from flask import request

    @wraps(f)
    def decorated(*args, **kwargs):
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            logger.warning(
                f"UNAUTHORIZED: missing Bearer token | "
                f"IP={request.remote_addr} | PATH={request.path}"
            )
            return jsonify({"error": "Unauthorized", "detail": "Missing Bearer token"}), 401

        provided = auth_header[len('Bearer '):]
        if not _API_TOKEN or not hmac.compare_digest(provided, _API_TOKEN):
            logger.warning(
                f"UNAUTHORIZED: invalid token | "
                f"IP={request.remote_addr} | PATH={request.path}"
            )
            return jsonify({"error": "Unauthorized", "detail": "Invalid token"}), 401

        return f(*args, **kwargs)
    return decorated


def _sign_response(payload: dict) -> dict:
    """
    Ajoute une signature HMAC-SHA256 au payload JSON.
    La signature couvre la sérialisation JSON triée (hors champ 'signature').
    Retourne le payload avec le champ 'signature' ajouté.
    """
    if not _HMAC_SECRET:
        payload['signature'] = ''
        return payload
    body_bytes = json.dumps(
        payload, sort_keys=True, separators=(',', ':')
    ).encode('utf-8')
    payload['signature'] = hmac.new(_HMAC_SECRET, body_bytes, hashlib.sha256).hexdigest()
    return payload


# ═══════════════════════════════════════════════════════════════════════════════
# FETCHERS INDIVIDUELS — CHACUN AVEC FALLBACK CHAIN ROBUSTE
# ═══════════════════════════════════════════════════════════════════════════════

def _fetch_gold_price() -> dict:
    """
    Fallback chain prix gold :
    1. Yahoo Finance API v8 (GC=F) — directe, sans lib yfinance
    2. Yahoo Finance API v8 (XAUUSD=X) — forex pair
    3. GLD ETF proxy (×10.85 — ~1/10 oz gold, ajusté frais)
    4. IAU ETF proxy (×53.0 — ratio courant post-splits)
    5. Retourne le dernier cache stale
    """
    headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}

    # Source 1 : Yahoo v8 direct sur GC=F
    try:
        r = requests.get(
            "https://query1.finance.yahoo.com/v8/finance/chart/GC%3DF?interval=1m&range=1d",
            headers=headers, timeout=8
        )
        if r.status_code == 200:
            price = r.json()["chart"]["result"][0]["meta"]["regularMarketPrice"]
            if 1500 < price < 8000:
                return {"price": round(price, 2), "source": "yahoo_v8_gcf"}
    except Exception as e:
        logger.warning(f"Gold price source 1 (Yahoo GC=F) failed: {e}")

    # Source 2 : Yahoo v8 XAUUSD=X (forex pair)
    try:
        r = requests.get(
            "https://query1.finance.yahoo.com/v8/finance/chart/XAUUSD%3DX?interval=1m&range=1d",
            headers=headers, timeout=8
        )
        if r.status_code == 200:
            price = r.json()["chart"]["result"][0]["meta"]["regularMarketPrice"]
            if 1500 < price < 8000:
                return {"price": round(price, 2), "source": "yahoo_v8_xauusd"}
    except Exception as e:
        logger.warning(f"Gold price source 2 (Yahoo XAUUSD=X) failed: {e}")

    # Source 3 : GLD ETF proxy (~1/10 oz gold)
    try:
        r = requests.get(
            "https://query1.finance.yahoo.com/v8/finance/chart/GLD?interval=1m&range=1d",
            headers=headers, timeout=8
        )
        if r.status_code == 200:
            gld = r.json()["chart"]["result"][0]["meta"]["regularMarketPrice"]
            price = round(gld * 10.85, 2)
            if 1500 < price < 8000:
                return {"price": price, "source": "gld_proxy"}
    except Exception as e:
        logger.warning(f"Gold price source 3 (GLD proxy) failed: {e}")

    # Source 4 : IAU ETF proxy
    try:
        r = requests.get(
            "https://query1.finance.yahoo.com/v8/finance/chart/IAU?interval=1m&range=1d",
            headers=headers, timeout=8
        )
        if r.status_code == 200:
            iau = r.json()["chart"]["result"][0]["meta"]["regularMarketPrice"]
            price = round(iau * 53.0, 2)
            if 1500 < price < 8000:
                return {"price": price, "source": "iau_proxy"}
    except Exception as e:
        logger.warning(f"Gold price source 4 (IAU proxy) failed: {e}")

    # Toutes les sources ont échoué → retourner le cache stale
    stale = cache.get_best("gold_price")
    logger.warning(f"All gold price sources failed — using stale cache: ${stale.get('price')}")
    return {**stale, "source": "stale_cache"}


def _fetch_macro() -> dict:
    """Fetch macro data depuis le service local avec timeout court"""
    result = cache.get_best("macro").copy()  # Part du dernier connu

    try:
        r = requests.get(f"{CONFIG['local_api_base']}/macro_data", timeout=3)
        if r.status_code == 200:
            data = r.json()
            result["us10y"]     = data.get("us10y",     result.get("us10y"))
            result["real_rate"] = data.get("real_rate", result.get("real_rate"))
    except Exception as e:
        logger.warning(f"Macro fetch failed (using cache): {e}")

    try:
        r = requests.get(f"{CONFIG['local_api_base']}/dxy_data", timeout=3)
        if r.status_code == 200:
            result["dxy"] = r.json().get("dxy_index", result.get("dxy"))
    except Exception as e:
        logger.warning(f"DXY fetch failed (using cache): {e}")

    try:
        r = requests.get(f"{CONFIG['local_api_base']}/vix_data", timeout=3)
        if r.status_code == 200:
            result["vix"] = r.json().get("vix_level", result.get("vix"))
    except Exception as e:
        logger.warning(f"VIX fetch failed (using cache): {e}")

    return result


def _fetch_cot() -> dict:
    """Fetch COT data — TTL 1h car données hebdomadaires. Staleness check intégré."""
    try:
        r = requests.get(f"{CONFIG['local_api_base']}/cot_data", timeout=5)
        if r.status_code == 200:
            data = r.json()
            # Staleness check: si report_date > 14 jours, data probablement stale
            report_date = data.get("report_date", "")
            if report_date:
                try:
                    rd = datetime.strptime(report_date[:10], "%Y-%m-%d").replace(tzinfo=timezone.utc)
                    days_old = (datetime.now(timezone.utc) - rd).days
                    if days_old > 14:
                        logger.warning(
                            f"⚠️ COT data is {days_old} days old (report_date={report_date}). "
                            f"CFTC source may be stale — check manually!"
                        )
                except ValueError:
                    pass
            return {
                "percentile":     data.get("percentile_net") or data.get("cot_percentile") or data.get("percentile"),
                "regime":         data.get("sentiment"),
                "net_positions":  data.get("net_position"),
                "report_date":    report_date,
            }
    except Exception as e:
        logger.warning(f"COT fetch failed (using cache): {e}")
    return cache.get_best("cot")


def _fetch_news() -> dict:
    """Fetch news ForexFactory via module dédié"""
    try:
        return fetch_news_v2()
    except Exception as e:
        logger.warning(f"News fetch failed (using cache): {e}")
    return cache.get_best("news")


def _fetch_sentiment() -> dict:
    """Fetch Fear & Greed index"""
    try:
        r = requests.get(CONFIG["fear_greed_url"], timeout=8)
        if r.status_code == 200:
            data = r.json()
            if data.get("data"):
                fg = data["data"][0]
                return {
                    "fear_greed_index": int(fg.get("value", 50)),
                    "fear_greed_label": fg.get("value_classification", "Neutral")
                }
    except Exception as e:
        logger.warning(f"Sentiment fetch failed (using cache): {e}")
    return cache.get_best("sentiment")


def _fetch_geopolitics() -> dict:
    """Analyse RSS géopolitique — TTL 10min"""
    geo = {"tension_level": 0, "hot_zones_active": [], "recent_headlines": [], "safe_haven_demand": "LOW"}
    total_score = 0
    headlines = []
    active_zones = set()

    for source_name, feed_url in CONFIG["rss_feeds"].items():
        try:
            feed = feedparser.parse(feed_url)
            for entry in feed.entries[:20]:
                content = (entry.get("title", "") + " " + entry.get("summary", "")).lower()
                score = 0
                for kw in CONFIG["geopolitical_keywords"]["high_impact"]:
                    if kw in content: score += 3
                for kw in CONFIG["geopolitical_keywords"]["medium_impact"]:
                    if kw in content: score += 2
                for kw in CONFIG["geopolitical_keywords"]["low_impact"]:
                    if kw in content: score += 1
                for zone in CONFIG["hot_zones"]:
                    if zone in content:
                        active_zones.add(zone.title())
                        score += 1
                if score > 0:
                    total_score += score
                    headlines.append({"source": source_name, "title": entry.get("title", "")[:100], "score": score})
        except Exception as e:
            logger.warning(f"RSS {source_name} failed: {e}")

    geo["tension_level"]    = min(10, total_score // 5)
    geo["hot_zones_active"] = list(active_zones)[:5]
    geo["recent_headlines"] = sorted(headlines, key=lambda x: x["score"], reverse=True)[:5]
    geo["safe_haven_demand"] = "HIGH" if geo["tension_level"] >= 7 else "MODERATE" if geo["tension_level"] >= 4 else "LOW"
    logger.info(f"Geopolitics: tension={geo['tension_level']}, zones={geo['hot_zones_active']}")
    return geo


def _calculate_signal(macro: dict, cot: dict, news: dict,
                       sentiment: dict, geo: dict, gold_price: dict) -> dict:
    """
    Calcule le signal final de trading.
    Appelé uniquement depuis le thread background — jamais depuis une route Flask.
    """
    try:
        intel = {
            "macro":       macro,
            "cot":         cot,
            "news":        news,
            "fear_greed":  sentiment,
            "geopolitical": geo,
        }

        news_data = {
            "next_event":     news.get("next_event", {}),
            "hours_to_next":  news.get("hours_to_next"),
            "recent_results": news.get("recent_results", []),
            # Compatibilité avec les deux formats possible de news_fetcher
            "next_high_impact":  news.get("next_high_impact"),
            "time_until_hours":  news.get("time_until_hours"),
            "in_blackout":       news.get("in_blackout", False),
        }

        signal = news_analyzer.generate_signal(
            news_data=news_data,
            cot_data=cot,
            sentiment_data={"fear_greed": sentiment},
            geopolitical_data=geo,
            macro_data=macro,
        )

        can_trade = (
            not signal.blackout_active and
            signal.entry_strategy.value != "WAIT" and
            signal.confidence >= 50
        )

        return {
            "can_trade":        can_trade,
            "direction":        signal.suggested_direction or "NONE",
            "bias":             signal.entry_bias,
            "confidence":       round(signal.confidence, 0),
            "size_factor":      signal.position_size_factor,
            "wider_stops":      signal.wider_stops,
            "tp_mode":          signal.take_profit_mode,
            "blackout_minutes": int(round(signal.minutes_to_news, 0)) if signal.blackout_active else 0,
            "timing_mode":      signal.timing_mode.value,
            "gold_price":       gold_price.get("price"),
            "gold_source":      gold_price.get("source"),
            "timestamp":        datetime.now(timezone.utc).isoformat() + "Z",
            "error":            None,
        }

    except Exception as e:
        logger.error(f"Signal calculation failed: {e}", exc_info=True)
        # En cas d'erreur de calcul, retourner un signal neutre safe
        return {
            **CONFIG["fallback"]["signal"],
            "gold_price": gold_price.get("price", 4390.0),
            "timestamp":  datetime.now(timezone.utc).isoformat() + "Z",
            "error":      str(e),
        }


# ═══════════════════════════════════════════════════════════════════════════════
# THREAD BACKGROUND — SEUL RESPONSABLE DE TOUS LES APPELS HTTP
# ═══════════════════════════════════════════════════════════════════════════════

_warmup_done = Event()  # Signale que le cache est prêt avant d'accepter des requêtes


def _background_refresh_loop():
    """
    Thread unique qui orchestre le rafraîchissement du cache.
    Chaque source est rafraîchie selon son TTL propre.
    Les routes Flask ne font AUCUN appel HTTP — elles lisent uniquement ce cache.
    """
    logger.info("🔄 Background cache refresher started")
    iteration = 0

    while True:
        try:
            iteration += 1
            t_start = time.time()

            # === GOLD PRICE — toutes les 30s ===
            if not cache.is_fresh("gold_price"):
                data = _fetch_gold_price()
                cache.set("gold_price", data)
                logger.info(f"💰 Gold price: ${data['price']} ({data['source']})")

            # === MACRO + DXY + VIX — toutes les 5min ===
            if not cache.is_fresh("macro"):
                data = _fetch_macro()
                cache.set("macro", data)
                logger.info(f"📊 Macro: US10Y={data.get('us10y')} DXY={data.get('dxy')} VIX={data.get('vix')}")

            # === COT — toutes les 1h ===
            if not cache.is_fresh("cot"):
                data = _fetch_cot()
                cache.set("cot", data)
                logger.info(f"📈 COT: percentile={data.get('percentile')} regime={data.get('regime')}")

            # === NEWS — toutes les 2min ===
            if not cache.is_fresh("news"):
                data = _fetch_news()
                cache.set("news", data)

            # === SENTIMENT — toutes les 5min ===
            if not cache.is_fresh("sentiment"):
                data = _fetch_sentiment()
                cache.set("sentiment", data)
                logger.info(f"😨 Fear&Greed: {data.get('fear_greed_index')} ({data.get('fear_greed_label')})")

            # === GEOPOLITICS — toutes les 10min ===
            if not cache.is_fresh("geopolitics"):
                data = _fetch_geopolitics()
                cache.set("geopolitics", data)

            # === SIGNAL FINAL — toutes les 30s (suit gold_price) ===
            if not cache.is_fresh("signal"):
                signal = _calculate_signal(
                    macro=cache.get_best("macro"),
                    cot=cache.get_best("cot"),
                    news=cache.get_best("news"),
                    sentiment=cache.get_best("sentiment"),
                    geo=cache.get_best("geopolitics"),
                    gold_price=cache.get_best("gold_price"),
                )

                # === MARKET DATA (needed by both Claude ICT and Python Sniper) ===
                df_m15 = cache.get_best("market_data_m15") if cache.age_seconds("market_data_m15") < 1800 else None
                df_m5 = cache.get_best("market_data_m5") if cache.age_seconds("market_data_m5") < 1800 else None

                # === CLAUDE AI ENRICHMENT (+ ICT analysis) ===
                if claude_engine.is_enabled:
                    signal = claude_engine.enrich_signal(signal, context={
                        "macro": cache.get_best("macro"),
                        "cot": cache.get_best("cot"),
                        "sentiment": cache.get_best("sentiment"),
                        "geopolitics": cache.get_best("geopolitics"),
                        "candles_m15": df_m15,
                        "candles_m5": df_m5,
                    })

                # === PYTHON SNIPER ICT ANALYSIS (consultatif — ne bloque plus can_trade) ===
                if signal.get("can_trade") and df_m15 is not None and df_m5 is not None:
                    try:
                        sniper = python_sniper.analyze_entry(
                            direction=signal["direction"],
                            df_m15=df_m15,
                            df_m5=df_m5,
                            current_price=signal.get("gold_price", 0),
                            spread_pips=2.0,
                        )
                        signal["sniper_python_valid"] = sniper.valid
                        signal["sniper_python_score"] = sniper.score
                        signal["sniper_python_sl"] = sniper.sl
                        signal["sniper_python_tp"] = sniper.tp
                        signal["sniper_python_reason"] = sniper.reason
                        logger.info(
                            f"🔧 Python Sniper (consultatif): valid={sniper.valid} | "
                            f"score={sniper.score} | {sniper.reason}"
                        )
                    except Exception as e:
                        logger.error(f"❌ Python Sniper failed: {e}")
                        signal.setdefault("sniper_python_valid", False)
                        signal.setdefault("sniper_python_score", 0)
                        signal.setdefault("sniper_python_sl", 0.0)
                        signal.setdefault("sniper_python_tp", 0.0)
                        signal.setdefault("sniper_python_reason", f"error: {e}")
                else:
                    reason = "no_market_data" if (df_m15 is None or df_m5 is None) else "can_trade=false"
                    signal.setdefault("sniper_python_valid", False)
                    signal.setdefault("sniper_python_score", 0)
                    signal.setdefault("sniper_python_sl", 0.0)
                    signal.setdefault("sniper_python_tp", 0.0)
                    signal.setdefault("sniper_python_reason", reason)
                    if df_m15 is None or df_m5 is None:
                        logger.warning(
                            f"⚠️ Sniper skipped: M15 age={cache.age_seconds('market_data_m15')}s "
                            f"M5 age={cache.age_seconds('market_data_m5')}s"
                        )

                # === CLAUDE ICT SNIPER — gate can_trade ===
                # Ensure sniper_* fields always exist for EA compatibility
                signal.setdefault("sniper_valid", False)
                signal.setdefault("sniper_score", 0)
                signal.setdefault("sniper_sl", 0.0)
                signal.setdefault("sniper_tp", 0.0)
                signal.setdefault("sniper_reason", "")
                sniper_claude_valid = signal.get("sniper_claude_valid", False)
                if signal.get("can_trade") and not sniper_claude_valid:
                    signal["can_trade"] = False
                    logger.info(
                        f"🎯 Claude ICT: sniper_valid=False | "
                        f"ict_score={signal.get('ict_score', 0)} | "
                        f"{signal.get('ict_reason', 'no ICT data')}"
                    )
                elif signal.get("can_trade") and sniper_claude_valid:
                    # Use Claude ICT SL/TP if available, else keep originals
                    ict_sl = signal.get("ict_sl", 0)
                    ict_tp = signal.get("ict_tp", 0)
                    if ict_sl > 0:
                        signal["sniper_sl"] = ict_sl
                    if ict_tp > 0:
                        signal["sniper_tp"] = ict_tp
                    signal["sniper_valid"] = True
                    signal["sniper_score"] = signal.get("ict_score", 0)
                    signal["sniper_reason"] = signal.get("ict_reason", "Claude ICT")
                    logger.info(
                        f"🎯 Claude ICT: sniper_valid=True | "
                        f"ict_score={signal.get('ict_score', 0)} | "
                        f"sl={ict_sl} tp={ict_tp} | {signal.get('ict_reason', '')}"
                    )

                # === CIRCUIT BREAKER — 3 signaux can_trade + chute 50 pips → lockout 2h ===
                current_price = signal.get("gold_price", 0)
                if signal.get("can_trade") and current_price > 0:
                    # Enregistrer ce signal can_trade=True
                    circuit_breaker.record_signal(current_price)
                    # Vérifier si le circuit breaker doit bloquer
                    cb_locked, cb_reason = circuit_breaker.check(current_price)
                    if cb_locked:
                        signal["can_trade"] = False
                        signal["circuit_breaker"] = cb_reason
                        logger.warning(f"🚨 Circuit breaker: {cb_reason}")
                else:
                    # Vérifier si un lockout est toujours actif même si can_trade est déjà False
                    cb_locked, cb_reason = circuit_breaker.check(current_price if current_price > 0 else 0)
                    if cb_locked:
                        signal["circuit_breaker"] = cb_reason

                cache.set("signal", signal)
                logger.info(
                    f"🎯 Signal: {signal['direction']} | "
                    f"conf={signal['confidence']}% | "
                    f"timing={signal['timing_mode']} | "
                    f"can_trade={signal['can_trade']} | "
                    f"cb={signal.get('circuit_breaker', 'ok')} | "
                    f"ict={signal.get('ict_score', 0)} | "
                    f"gold=${signal['gold_price']}"
                )

            # Warm-up terminé après le premier cycle complet
            if not _warmup_done.is_set():
                _warmup_done.set()
                logger.info("✅ Cache warm-up complete — API ready to serve")

            elapsed = time.time() - t_start
            if iteration % 100 == 0:
                logger.info(f"💓 Heartbeat: {iteration} cycles | last cycle: {elapsed:.2f}s")

        except Exception as e:
            logger.error(f"❌ Background refresh error: {e}", exc_info=True)
            if not _warmup_done.is_set():
                _warmup_done.set()  # Ne pas bloquer le démarrage en cas d'erreur

        time.sleep(10)  # Cycle toutes les 10s — chaque source se rafraîchit selon son TTL


def start_background_refresher():
    """Lance le thread background en daemon"""
    t = threading.Thread(target=_background_refresh_loop, daemon=True, name="CacheRefresher")
    t.start()

    # Attendre que le warm-up soit terminé (max 30s)
    logger.info("⏳ Waiting for cache warm-up...")
    warmed = _warmup_done.wait(timeout=30)
    if warmed:
        logger.info("✅ System ready")
    else:
        logger.warning("⚠️ Warm-up timeout — serving with fallback data")


# ═══════════════════════════════════════════════════════════════════════════════
# DATABASE
# ═══════════════════════════════════════════════════════════════════════════════

def init_db():
    conn = sqlite3.connect(CONFIG["db_path"])
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS intelligence_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT, gold_bias TEXT, confidence INTEGER,
        recommendation TEXT, data_json TEXT
    )''')
    c.execute('''CREATE TABLE IF NOT EXISTS news_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event_name TEXT, currency TEXT, impact TEXT,
        event_time TEXT, actual TEXT, forecast TEXT,
        previous TEXT, scraped_at TEXT
    )''')
    c.execute('''CREATE TABLE IF NOT EXISTS geopolitical_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source TEXT, headline TEXT, zone TEXT,
        impact_score INTEGER, published_at TEXT, scraped_at TEXT
    )''')
    conn.commit()
    conn.close()
    logger.info("Database initialized")


# ═══════════════════════════════════════════════════════════════════════════════
# FLASK ROUTES — LISENT UNIQUEMENT LE CACHE, ZÉRO APPEL HTTP
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/news_trading_signal/quick', methods=['GET'])
@_require_auth
def news_trading_signal_quick():
    """
    Route principale pour l'EA MT5 (legacy path).
    Lecture pure du cache — réponse garantie < 5ms.
    Protégée par Bearer token. Réponse signée HMAC-SHA256.
    """
    signal = _sign_response(dict(cache.get_best("signal")))
    return jsonify(signal), 200


@app.route('/v1/news_trading_signal/quick', methods=['GET'])
@_require_auth
def news_trading_signal_quick_v1():
    """
    Route versionnée v1 — identique à /news_trading_signal/quick.
    Permet la migration progressive des EAs vers les endpoints versionnés.
    Protégée par Bearer token. Réponse signée HMAC-SHA256.
    """
    signal = _sign_response(dict(cache.get_best("signal")))
    return jsonify(signal), 200


@app.route('/v1/market_data', methods=['POST'])
@_require_auth
def market_data_v1():
    """
    Reçoit les bougies M15/M5 depuis l'EA MT5.
    Stocke en cache sous forme de DataFrame pandas.
    """
    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "Invalid JSON"}), 400

    result = {}
    for tf in ("m15", "m5"):
        bars = data.get(tf, [])
        if bars:
            df = pd.DataFrame(bars, columns=["t", "o", "h", "l", "c", "v"])
            cache.set(f"market_data_{tf}", df)
        result[f"bars_{tf}"] = len(bars)

    logger.info(f"📊 Market data: M15={result['bars_m15']} bars M5={result['bars_m5']} bars")

    return jsonify({"status": "ok", **result}), 200


@app.route('/v1/health', methods=['GET'])
def health_v1():
    """
    Health check versionné — non authentifié, pour les monitors externes.
    Retourne l'état du cache et le statut global du service.
    """
    grace = CONFIG["health_grace_s"]
    status = cache.status(grace=grace)
    all_fresh = all(v["fresh"] for v in status.values())

    # Market data — optionnel (pas encore envoyé par l'EA au démarrage)
    market = {}
    for tf in ("m15", "m5"):
        key = f"market_data_{tf}"
        age = cache.age_seconds(key)
        has = age < 999999
        market[key] = {"age_s": age, "has_data": has, "fresh": has and age < 60}

    return jsonify({
        "status":       "healthy" if all_fresh else "degraded",
        "warmup_done":  _warmup_done.is_set(),
        "signal_age_s": cache.age_seconds("signal"),
        "market_data":  market,
        "circuit_breaker": circuit_breaker.status(),
        "timestamp":    datetime.now(timezone.utc).isoformat() + "Z",
    }), 200


@app.route('/news_trading_signal', methods=['GET'])
def news_trading_signal():
    """Route complète avec tous les détails pour debug/monitoring"""
    signal  = cache.get_best("signal")
    macro   = cache.get_best("macro")
    cot     = cache.get_best("cot")
    news    = cache.get_best("news")
    geo     = cache.get_best("geopolitics")
    sent    = cache.get_best("sentiment")

    return jsonify({
        **signal,
        "macro":       macro,
        "cot":         cot,
        "news":        news,
        "geopolitics": geo,
        "sentiment":   sent,
        "cache_status": cache.status(),
    }), 200


@app.route('/gold_intelligence', methods=['GET'])
def get_gold_intelligence():
    """Rapport d'intelligence complet"""
    return jsonify({
        "timestamp":   datetime.now(timezone.utc).isoformat() + "Z",
        "gold_price":  cache.get_best("gold_price"),
        "macro":       cache.get_best("macro"),
        "cot":         cache.get_best("cot"),
        "news":        cache.get_best("news"),
        "geopolitics": cache.get_best("geopolitics"),
        "sentiment":   cache.get_best("sentiment"),
        "signal":      cache.get_best("signal"),
        "cache_status": cache.status(),
    }), 200


@app.route('/gold_intelligence/quick', methods=['GET'])
def get_quick_intelligence():
    """Version légère pour monitoring rapide"""
    signal = cache.get_best("signal")
    return jsonify({
        "timestamp":   datetime.now(timezone.utc).isoformat() + "Z",
        "gold_bias":   signal.get("bias", "NEUTRAL"),
        "confidence":  signal.get("confidence", 0),
        "timing_mode": signal.get("timing_mode", "CLEAR"),
        "direction":   signal.get("direction", "NONE"),
        "can_trade":   signal.get("can_trade", False),
        "gold_price":  signal.get("gold_price"),
    }), 200


@app.route('/gold_intelligence/health', methods=['GET'])
def health_check():
    """Health check avec état détaillé du cache"""
    grace = CONFIG["health_grace_s"]
    status = cache.status(grace=grace)
    all_fresh = all(v["fresh"] for v in status.values())
    signal = cache.get_best("signal")

    return jsonify({
        "status":        "healthy" if all_fresh else "degraded",
        "cache_status":  status,
        "signal_age_s":  cache.age_seconds("signal"),
        "gold_price":    cache.get_best("gold_price"),
        "last_signal":   signal.get("direction"),
        "warmup_done":   _warmup_done.is_set(),
        "timestamp":     datetime.now(timezone.utc).isoformat() + "Z",
    }), 200


@app.route('/gold_intelligence/news', methods=['GET'])
def get_news():
    return jsonify(cache.get_best("news")), 200


@app.route('/gold_intelligence/geopolitics', methods=['GET'])
def get_geopolitics():
    return jsonify(cache.get_best("geopolitics")), 200


# Compatibilité avec les autres modules qui appellent get_full_intelligence()
def get_full_intelligence() -> dict:
    """Retourne toutes les données depuis le cache — compatible avec l'ancienne API"""
    sentiment = cache.get_best("sentiment")
    fear_greed = {
        "value":          sentiment.get("fear_greed_index", 50),
        "classification": sentiment.get("fear_greed_label", "Neutral")
    }
    return {
        "macro":       cache.get_best("macro"),
        "vix":         {"vix_level": cache.get_best("macro").get("vix")},
        "cot":         cache.get_best("cot"),
        "dxy":         {"dxy_index": cache.get_best("macro").get("dxy")},
        "news":        cache.get_best("news"),
        "geopolitical": cache.get_best("geopolitics"),
        "fear_greed":  fear_greed,
    }


@app.route('/tmp/ea_download', methods=['GET'])
def ea_download():
    """Téléchargement du fichier EA MT5 compilé avec les modifications sniper."""
    ea_path = "/tmp/Gold_News_Institutional_EA_FINAL.mq5"
    if not os.path.exists(ea_path):
        return jsonify({"error": "EA file not found"}), 404
    return send_file(ea_path, as_attachment=True,
                     download_name="Gold_News_Institutional_EA_FINAL.mq5")


@app.route('/tmp/bridge_download', methods=['GET'])
def bridge_download():
    """Téléchargement du fichier GoldML_DataBridge.mqh."""
    path = "/tmp/GoldML_DataBridge_FINAL.mqh"
    if not os.path.exists(path):
        return jsonify({"error": "file not found"}), 404
    return send_file(path, as_attachment=True,
                     download_name="GoldML_DataBridge.mqh")


# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    logger.info("=" * 60)
    logger.info("  Gold ML Intelligence System v2.0 — INSTITUTIONAL")
    logger.info("=" * 60)

    # Init DB
    init_db()

    # Démarrer le refresher background et attendre le warm-up
    start_background_refresher()

    logger.info("🚀 Starting Flask on port 5002...")
    app.run(host="0.0.0.0", port=5002, debug=False, threaded=True)
