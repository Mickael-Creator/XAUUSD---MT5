#!/usr/bin/env python3
"""
News Fetcher v2.0 - Multi-source avec fallback
Sources: ForexFactory (primaire) + Backup
Cache intelligent pour éviter rate limits
"""

import logging
import requests
from datetime import datetime, timezone
from threading import Lock
import time
import random

logger = logging.getLogger(__name__)

NEWS_CONFIG = {
    "cache_ttl_minutes": 30,
    "forexfactory_url": "https://nfs.faireconomy.media/ff_calendar_thisweek.json",
    "user_agents": [
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
    ],
    "news_gold_impact": {
        "Nonfarm Payrolls": {"direction": "BEARISH", "weight": 10},
        "Non-Farm Employment": {"direction": "BEARISH", "weight": 10},
        "Unemployment Rate": {"direction": "BULLISH", "weight": 8},
        "Average Hourly Earnings": {"direction": "BEARISH", "weight": 6},
        "ADP": {"direction": "BEARISH", "weight": 7},
        "Jobless Claims": {"direction": "BULLISH", "weight": 5},
        "CPI": {"direction": "BULLISH", "weight": 9},
        "Core CPI": {"direction": "BULLISH", "weight": 9},
        "PPI": {"direction": "BULLISH", "weight": 7},
        "PCE": {"direction": "BULLISH", "weight": 8},
        "Federal Funds Rate": {"direction": "BEARISH", "weight": 10},
        "FOMC": {"direction": "NEUTRAL", "weight": 10},
        "Powell": {"direction": "NEUTRAL", "weight": 9},
        "GDP": {"direction": "BEARISH", "weight": 8},
        "Retail Sales": {"direction": "BEARISH", "weight": 7},
        "Consumer Confidence": {"direction": "BEARISH", "weight": 6},
        "ISM Manufacturing": {"direction": "BEARISH", "weight": 7},
        "ISM Services": {"direction": "BEARISH", "weight": 6},
        "PMI": {"direction": "BEARISH", "weight": 6},
    }
}

_news_cache = {"data": None, "last_update": None, "source": None}
_cache_lock = Lock()

def get_random_headers():
    return {
        "User-Agent": random.choice(NEWS_CONFIG["user_agents"]),
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "en-US,en;q=0.9",
    }

def parse_number(value_str):
    if not value_str or value_str in ['', '-', 'N/A', None]:
        return None
    value_str = str(value_str).strip().upper()
    multiplier = 1
    if 'K' in value_str:
        multiplier = 1000
        value_str = value_str.replace('K', '')
    elif 'M' in value_str:
        multiplier = 1000000
        value_str = value_str.replace('M', '')
    elif 'B' in value_str:
        multiplier = 1000000000
        value_str = value_str.replace('B', '')
    value_str = value_str.replace('%', '').replace(',', '').strip()
    try:
        return float(value_str) * multiplier
    except ValueError:
        return None

def calculate_surprise(actual, forecast):
    if actual is None or forecast is None or forecast == 0:
        return None
    return ((actual - forecast) / abs(forecast)) * 100

def get_gold_impact(event_name, surprise_percent):
    if surprise_percent is None:
        return "NEUTRAL", 0
    config = None
    for news_key, news_config in NEWS_CONFIG["news_gold_impact"].items():
        if news_key.lower() in event_name.lower():
            config = news_config
            break
    if not config or config["direction"] == "NEUTRAL":
        return "NEUTRAL", 0
    weight = config["weight"]
    if config["direction"] == "BEARISH":
        if surprise_percent > 0:
            return "BEARISH", -min(10, abs(surprise_percent) / 10 * weight)
        else:
            return "BULLISH", min(10, abs(surprise_percent) / 10 * weight)
    else:
        if surprise_percent > 0:
            return "BULLISH", min(10, abs(surprise_percent) / 10 * weight)
        else:
            return "BEARISH", -min(10, abs(surprise_percent) / 10 * weight)

def fetch_forexfactory():
    try:
        time.sleep(random.uniform(0.5, 1.5))
        resp = requests.get(NEWS_CONFIG["forexfactory_url"], headers=get_random_headers(), timeout=15)
        if resp.status_code != 200:
            return None
        try:
            events = resp.json()
        except:
            return None
        if not isinstance(events, list):
            return None
        return process_events(events, "ForexFactory")
    except Exception as e:
        logger.error(f"ForexFactory error: {e}")
        return None

def process_events(events, source):
    result = {
        "events": [], "events_with_results": [], "upcoming_events": [],
        "next_high_impact": None, "time_until_hours": None, "in_blackout": False,
        "cumulative_impact": 0, "dominant_direction": "NEUTRAL",
        "source": source, "fetch_time": datetime.now(timezone.utc).isoformat()
    }
    now = datetime.now(timezone.utc)
    bullish_score = bearish_score = 0
    
    for event in events:
        if event.get("country") != "USD":
            continue
        impact = event.get("impact", "").lower()
        title = event.get("title", "")
        is_known = any(kw.lower() in title.lower() for kw in NEWS_CONFIG["news_gold_impact"].keys())
        if impact != "high" and not is_known:
            continue
        
        actual = parse_number(event.get("actual"))
        forecast = parse_number(event.get("forecast"))
        
        event_time_str = event.get("date", "")
        try:
            event_time = datetime.fromisoformat(event_time_str.replace("Z", "+00:00")).replace(tzinfo=None)
            time_diff_hours = (event_time - now).total_seconds() / 3600
        except:
            continue
        
        surprise = calculate_surprise(actual, forecast)
        direction, impact_score = get_gold_impact(title, surprise)
        
        event_info = {
            "name": title, "time": event_time_str, "time_diff_hours": round(time_diff_hours, 2),
            "actual": event.get("actual"), "forecast": event.get("forecast"), "previous": event.get("previous"),
            "surprise_percent": round(surprise, 2) if surprise else None,
            "gold_direction": direction, "gold_impact_score": round(impact_score, 2) if impact_score else 0,
            "has_result": actual is not None
        }
        result["events"].append(event_info)
        
        if actual is not None:
            result["events_with_results"].append(event_info)
            if time_diff_hours > -24:
                if direction == "BULLISH":
                    bullish_score += abs(impact_score) if impact_score else 0
                elif direction == "BEARISH":
                    bearish_score += abs(impact_score) if impact_score else 0
        elif time_diff_hours > -0.5:
            result["upcoming_events"].append(event_info)
            if -0.25 < time_diff_hours < 0.5:
                result["in_blackout"] = True
            if time_diff_hours > 0 and (result["next_high_impact"] is None or time_diff_hours < result["time_until_hours"]):
                result["next_high_impact"] = title
                result["time_until_hours"] = round(time_diff_hours, 2)
    
    result["cumulative_impact"] = round(bullish_score - bearish_score, 2)
    result["dominant_direction"] = "BULLISH" if bullish_score > bearish_score + 2 else ("BEARISH" if bearish_score > bullish_score + 2 else "NEUTRAL")
    result["events_with_results"].sort(key=lambda x: x["time"], reverse=True)
    result["upcoming_events"].sort(key=lambda x: x.get("time_diff_hours", 999))
    
    return result

def fetch_news_data(force_refresh=False):
    global _news_cache
    with _cache_lock:
        if not force_refresh and _news_cache["data"] is not None:
            cache_age = (datetime.now(timezone.utc) - _news_cache["last_update"]).total_seconds() / 60
            if cache_age < NEWS_CONFIG["cache_ttl_minutes"]:
                return _news_cache["data"]
    
    data = fetch_forexfactory()
    if data is None:
        if _news_cache["data"] is not None:
            logger.warning("Using stale cache")
            return _news_cache["data"]
        return {"events": [], "events_with_results": [], "upcoming_events": [], 
                "next_high_impact": None, "time_until_hours": None, "in_blackout": False,
                "source": "FALLBACK", "fetch_time": datetime.now(timezone.utc).isoformat()}
    
    with _cache_lock:
        _news_cache["data"] = data
        _news_cache["last_update"] = datetime.now(timezone.utc)
    return data

def fetch_forex_factory_news():
    """Drop-in replacement pour gold_intelligence.py"""
    data = fetch_news_data()
    return {
        "events": data.get("upcoming_events", [])[:5],
        "next_high_impact": data.get("next_high_impact"),
        "time_until_hours": data.get("time_until_hours"),
        "in_blackout": data.get("in_blackout", False),
        "events_with_results": data.get("events_with_results", [])[:5],
        "cumulative_impact": data.get("cumulative_impact", 0),
        "dominant_direction": data.get("dominant_direction", "NEUTRAL"),
        "source": data.get("source", "Unknown")
    }

if __name__ == "__main__":
    import logging
    logging.basicConfig(level=logging.INFO)
    print("Testing news fetcher...")
    data = fetch_news_data(force_refresh=True)
    print(f"Source: {data.get('source')}")
    print(f"Events: {len(data.get('events', []))}")
    print(f"Blackout: {data.get('in_blackout')}")
    print(f"Next: {data.get('next_high_impact')}")
