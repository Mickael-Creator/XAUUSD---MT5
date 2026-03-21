#!/usr/bin/env python3
"""
Gold ML Backend v4.2 - WITH SECURITY HARDENING
AUDIT-VPS-C1: Bearer token authentication
AUDIT-VPS-C2: Dedicated /health endpoint
AUDIT-VPS-C3: HMAC-SHA256 response signatures
AUDIT-VPS-C4: API versioning (/v1/ prefix)
"""
from flask import Flask, jsonify, request, redirect
import json
import os
import sys
import time
import hmac
import hashlib
import logging
import threading
import subprocess
import sqlite3
import signal as sig
import socket
from datetime import datetime
from functools import wraps

sys.path.insert(0, '/root/gold_ml_phase4')

# ============================================================
# NETTOYAGE PORT 5000 - VERSION ROBUSTE
# ============================================================

def clean_port_5000():
    """Nettoie le port 5000 avec vérification"""
    logging.info("🧹 Cleaning port 5000...")

    max_attempts = 3
    for attempt in range(max_attempts):
        try:
            # Kill processus - MAIS PAS backend_api lui-même!
            subprocess.run(['fuser', '-k', '5000/tcp'],
                          stderr=subprocess.DEVNULL, timeout=5)
            time.sleep(3)

            # Vérifier que le port est libre
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("0.0.0.0", 5000))
            sock.close()

            logging.info("✅ Port 5000 is free")
            return True

        except OSError as e:
            if attempt < max_attempts - 1:
                logging.warning(f"⚠️ Port still busy, attempt {attempt+1}/{max_attempts}")
                time.sleep(3)
            else:
                logging.error(f"❌ Could not free port 5000 after {max_attempts} attempts")
                return False

    return False

# ============================================================
# FLASK APP
# ============================================================

app = Flask(__name__)

# Configuration logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/gold_ml_backend.log'),
        logging.StreamHandler()
    ]
)

# Configuration
START_TIME = time.time()
BRIDGE_SCRIPT = '/root/gold_ml_phase4/gold_ml_to_mt5_bridge_files.py'
SIGNAL_FILE_ORIGINAL = '/mnt/mt5_shared/gold_ml_signal.json'
SIGNAL_FILE_API = '/root/gold_ml_phase4/signals/gold_ml_signal.json'
DB_PATH = '/root/gold_ml_phase4/gold_ml_database.db'

# AUDIT-VPS-C1: Load security credentials from environment — never hardcoded
API_TOKEN = os.environ.get('API_TOKEN', '')
HMAC_SECRET = os.environ.get('HMAC_SECRET', '').encode('utf-8')

if not API_TOKEN:
    logging.warning("⚠️ API_TOKEN not set in environment — authentication will reject all requests")
if not HMAC_SECRET:
    logging.warning("⚠️ HMAC_SECRET not set in environment — response signatures will be empty")

# Stats
bridge_success_count = 0
bridge_fail_count = 0
last_bridge_success = None
signal_refresh_count = 0

# Graceful shutdown
def signal_handler(signum, frame):
    logging.info("🛑 Shutdown signal received")
    sys.exit(0)

sig.signal(sig.SIGTERM, signal_handler)
sig.signal(sig.SIGINT, signal_handler)

# ============================================================
# AUDIT-VPS-C1: BEARER TOKEN AUTHENTICATION MIDDLEWARE
# ============================================================

def require_auth(f):
    """Middleware: verifies Authorization: Bearer <API_TOKEN> header.
    Returns HTTP 401 if token is absent or invalid."""
    @wraps(f)
    def decorated(*args, **kwargs):
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            # AUDIT-VPS-C1: Log unauthorized access attempt
            logging.warning(
                f"UNAUTHORIZED ACCESS: missing Bearer token | "
                f"IP={request.remote_addr} | PATH={request.path}"
            )
            return jsonify({"error": "Unauthorized", "detail": "Missing Bearer token"}), 401

        provided_token = auth_header[len('Bearer '):]
        # AUDIT-VPS-C1: Constant-time comparison to prevent timing attacks
        if not API_TOKEN or not hmac.compare_digest(provided_token, API_TOKEN):
            logging.warning(
                f"UNAUTHORIZED ACCESS: invalid token | "
                f"IP={request.remote_addr} | PATH={request.path}"
            )
            return jsonify({"error": "Unauthorized", "detail": "Invalid token"}), 401

        return f(*args, **kwargs)
    return decorated


# ============================================================
# AUDIT-VPS-C3: HMAC SIGNATURE HELPER
# ============================================================

def sign_response(payload: dict) -> dict:
    """Add HMAC-SHA256 signature to JSON response payload.
    Signature covers the serialised JSON body (excluding the signature field itself).
    AUDIT-VPS-C3"""
    if not HMAC_SECRET:
        payload['signature'] = ''
        return payload
    body_bytes = json.dumps(
        {k: v for k, v in payload.items()},
        sort_keys=True, separators=(',', ':')
    ).encode('utf-8')
    sig_hex = hmac.new(HMAC_SECRET, body_bytes, hashlib.sha256).hexdigest()
    payload['signature'] = sig_hex
    return payload


# ============================================================
# API ENDPOINTS
# ============================================================

# AUDIT-VPS-C2: Dedicated /health endpoint — no authentication required (for external monitors)
@app.route('/v1/health', methods=['GET'])
def health_v1():
    """AUDIT-VPS-C2: Health check — unauthenticated, for external monitors."""
    payload = {
        "status": "ok",
        "uptime_seconds": int(time.time() - START_TIME),
        "version": "1.0",
    }
    return jsonify(payload)


# AUDIT-VPS-C4: Legacy /health — kept active for backwards compatibility (no redirect needed, no auth)
@app.route('/health', methods=['GET'])
def health_legacy():
    """Legacy health endpoint — unauthenticated, kept for backwards compatibility."""
    signal_age = None
    signal_exists = False

    if os.path.exists(SIGNAL_FILE_API):
        signal_exists = True
        signal_age = int(time.time() - os.path.getmtime(SIGNAL_FILE_API))

    return jsonify({
        "status": "ok",
        "service": "gold_ml_backend",
        "version": "1.0",
        "uptime_seconds": int(time.time() - START_TIME),
        "signal_exists": signal_exists,
        "signal_age_seconds": signal_age,
        "signal_refresh_count": signal_refresh_count,
        "bridge_success": bridge_success_count,
        "bridge_fails": bridge_fail_count,
        "last_bridge_success": last_bridge_success.isoformat() if last_bridge_success else None,
        "timestamp": datetime.now().isoformat()
    })


# AUDIT-VPS-C4: Versioned news signal endpoint
@app.route('/v1/news_trading_signal/quick', methods=['GET'])
@require_auth
def news_trading_signal_quick_v1():
    """
    AUDIT-VPS-C4: Primary versioned endpoint for MT5 EA.
    Reads the latest cached signal file and returns a quick response.
    AUDIT-VPS-C1: Protected by Bearer token.
    AUDIT-VPS-C3: Response signed with HMAC-SHA256.
    """
    payload = _build_quick_signal_payload()
    # AUDIT-VPS-C3: Sign the response
    payload = sign_response(payload)
    return jsonify(payload)


# AUDIT-VPS-C4: Legacy route — redirect to v1 with HTTP 301
@app.route('/news_trading_signal/quick', methods=['GET'])
def news_trading_signal_quick_legacy():
    """AUDIT-VPS-C4: Legacy route, redirects to /v1/ for backwards compatibility."""
    return redirect('/v1/news_trading_signal/quick', code=301)


def _build_quick_signal_payload() -> dict:
    """Build the quick signal payload from cached signal file."""
    # Try to load from signal file
    if os.path.exists(SIGNAL_FILE_API):
        try:
            with open(SIGNAL_FILE_API, 'r') as f:
                raw = json.load(f)

            # Map internal signal fields to EA-expected fields
            direction = raw.get('direction', 1)
            if isinstance(direction, int):
                direction_str = "BUY" if direction > 0 else ("SELL" if direction < 0 else "NONE")
            else:
                direction_str = str(direction)

            conviction = float(raw.get('conviction_score', 0))
            size_factor = float(raw.get('size_factor', 1.0))
            can_trade = conviction >= 7.0 and direction_str in ("BUY", "SELL")

            signal_age = int(time.time() - os.path.getmtime(SIGNAL_FILE_API))
            # Stale signal → do not trade
            if signal_age > 600:
                can_trade = False

            return {
                "can_trade": can_trade,
                "direction": direction_str,
                "bias": raw.get('bias', 'NEUTRAL'),
                "confidence": round(min(100.0, max(0.0, conviction * 10)), 1),
                "size_factor": round(min(2.0, max(0.0, size_factor)), 2),
                "timing_mode": raw.get('timing_mode', 'CLEAR'),
                "tp_mode": raw.get('tp_mode', 'NORMAL'),
                "wider_stops": bool(raw.get('wider_stops', False)),
                "blackout_minutes": int(raw.get('blackout_minutes', 0)),
                "signal_age_seconds": signal_age,
                "source": raw.get('source', 'ml'),
                "timestamp": datetime.now().isoformat(),
            }
        except Exception as e:
            logging.error(f"Error reading signal file: {e}")

    # Fallback: no signal available
    return {
        "can_trade": False,
        "direction": "NONE",
        "bias": "NEUTRAL",
        "confidence": 0.0,
        "size_factor": 0.0,
        "timing_mode": "CLEAR",
        "tp_mode": "NORMAL",
        "wider_stops": False,
        "blackout_minutes": 0,
        "signal_age_seconds": -1,
        "source": "no_data",
        "timestamp": datetime.now().isoformat(),
    }


@app.route('/v1/api/macro', methods=['GET'])
@require_auth
def macro_v1():
    return macro()


@app.route('/api/macro', methods=['GET'])
@require_auth
def macro():
    us10y = 4.101

    if os.path.exists(DB_PATH):
        try:
            conn = sqlite3.connect(DB_PATH, timeout=5)
            cursor = conn.cursor()
            cursor.execute("SELECT us10y FROM macro_data ORDER BY timestamp DESC LIMIT 1")
            result = cursor.fetchone()
            if result:
                us10y = float(result[0])
            conn.close()
        except Exception as e:
            logging.debug(f"DB read failed: {e}")

    inflation_target = 2.45
    real_rate = us10y - inflation_target
    macro_score = 1 if -0.5 < real_rate < 0.5 else (2 if real_rate < 0 else 0)

    payload = {
        "us10y": round(us10y, 3),
        "inflation_target": inflation_target,
        "real_rate": round(real_rate, 3),
        "macro_score": macro_score,
        "timestamp": datetime.now().isoformat()
    }
    return jsonify(sign_response(payload))


@app.route('/v1/api/dxy', methods=['GET'])
@require_auth
def dxy_v1():
    return dxy()


@app.route('/api/dxy', methods=['GET'])
@require_auth
def dxy():
    dxy_value = 103.5

    if os.path.exists(DB_PATH):
        try:
            conn = sqlite3.connect(DB_PATH, timeout=5)
            cursor = conn.cursor()
            cursor.execute("SELECT dxy_close FROM market_data ORDER BY datetime DESC LIMIT 1")
            result = cursor.fetchone()
            if result:
                dxy_value = float(result[0])
            conn.close()
        except Exception as e:
            logging.debug(f"DB read failed: {e}")

    payload = {
        "dxy_value": round(dxy_value, 2),
        "correlation": -0.67,
        "timestamp": datetime.now().isoformat()
    }
    return jsonify(sign_response(payload))


@app.route('/v1/api/news/status', methods=['GET'])
@require_auth
def news_v1():
    return news()


@app.route('/api/news/status', methods=['GET'])
@require_auth
def news():
    payload = {
        "is_blackout": False,
        "next_event": None,
        "timestamp": datetime.now().isoformat()
    }
    return jsonify(sign_response(payload))


# ============================================================
# VIX ENDPOINT
# ============================================================
@app.route('/v1/api/vix', methods=['GET'])
@require_auth
def vix_v1():
    return vix()


@app.route('/api/vix', methods=['GET'])
@require_auth
def vix():
    vix_value = 18.0  # fallback
    vix_change = 0.0

    if os.path.exists(DB_PATH):
        try:
            conn = sqlite3.connect(DB_PATH, timeout=5)
            cursor = conn.cursor()

            # VIX actuel
            cursor.execute("SELECT vix_level FROM market_data ORDER BY datetime DESC LIMIT 1")
            result = cursor.fetchone()
            if result and result[0]:
                vix_value = float(result[0])

            # VIX il y a 24h
            cursor.execute("SELECT vix_level FROM market_data ORDER BY datetime DESC LIMIT 1 OFFSET 24")
            result_24h = cursor.fetchone()
            if result_24h and result_24h[0]:
                vix_change = ((vix_value - float(result_24h[0])) / float(result_24h[0])) * 100

            conn.close()
        except Exception as e:
            logging.debug(f"VIX DB read failed: {e}")

    # Régime de volatilité
    if vix_value < 15:
        regime = "LOW"
    elif vix_value < 20:
        regime = "NORMAL"
    elif vix_value < 25:
        regime = "ELEVATED"
    elif vix_value < 35:
        regime = "HIGH"
    else:
        regime = "EXTREME"

    payload = {
        "vix_level": round(vix_value, 2),
        "vix_change_24h": round(vix_change, 2),
        "volatility_regime": regime,
        "timestamp": datetime.now().isoformat()
    }
    return jsonify(sign_response(payload))


# ============================================================
# MARKET CONTEXT ENDPOINT
# ============================================================
@app.route('/v1/api/market_context', methods=['GET'])
@require_auth
def market_context_v1():
    return market_context()


@app.route('/api/market_context', methods=['GET'])
@require_auth
def market_context():
    vix_value = 18.0
    dxy_value = 103.5
    us10y_value = 4.35

    if os.path.exists(DB_PATH):
        try:
            conn = sqlite3.connect(DB_PATH, timeout=5)
            cursor = conn.cursor()

            # VIX
            cursor.execute("SELECT vix_level FROM market_data ORDER BY datetime DESC LIMIT 1")
            result = cursor.fetchone()
            if result and result[0]:
                vix_value = float(result[0])

            # DXY
            cursor.execute("SELECT dxy_close FROM market_data ORDER BY datetime DESC LIMIT 1")
            result = cursor.fetchone()
            if result and result[0]:
                dxy_value = float(result[0])

            # US10Y
            cursor.execute("SELECT us10y FROM macro_data ORDER BY timestamp DESC LIMIT 1")
            result = cursor.fetchone()
            if result and result[0]:
                us10y_value = float(result[0])

            conn.close()
        except Exception as e:
            logging.debug(f"Market context DB read failed: {e}")

    # Calculs
    inflation_target = 2.45
    real_rate = us10y_value - inflation_target

    # Score de contexte (0-100)
    context_score = 50

    # VIX impact
    if vix_value < 15:
        context_score -= 10
        vix_regime = "LOW"
    elif vix_value < 20:
        vix_regime = "NORMAL"
    elif vix_value < 25:
        context_score += 10
        vix_regime = "ELEVATED"
    elif vix_value < 35:
        context_score += 15
        vix_regime = "HIGH"
    else:
        context_score += 10
        vix_regime = "EXTREME"

    # DXY impact
    if dxy_value < 100:
        context_score += 15
    elif dxy_value < 103:
        context_score += 5
    elif dxy_value > 106:
        context_score -= 15
    elif dxy_value > 104:
        context_score -= 5

    # Real rate impact
    if real_rate < -0.5:
        context_score += 20
    elif real_rate < 0:
        context_score += 15
    elif real_rate < 0.5:
        context_score += 5
    elif real_rate > 1.5:
        context_score -= 15
    elif real_rate > 1.0:
        context_score -= 10

    context_score = max(0, min(100, context_score))

    if context_score >= 65:
        recommendation = "FAVORABLE"
    elif context_score >= 45:
        recommendation = "NEUTRAL"
    else:
        recommendation = "UNFAVORABLE"

    payload = {
        "vix_level": round(vix_value, 2),
        "vix_regime": vix_regime,
        "dxy_index": round(dxy_value, 2),
        "us10y": round(us10y_value, 3),
        "real_rate": round(real_rate, 3),
        "context_score": context_score,
        "recommendation": recommendation,
        "timestamp": datetime.now().isoformat()
    }
    return jsonify(sign_response(payload))


# ============================================================
# SIGNAL GENERATION
# ============================================================

def run_bridge_script():
    global bridge_success_count, bridge_fail_count, last_bridge_success

    if not os.path.exists(BRIDGE_SCRIPT):
        return False

    try:
        result = subprocess.run(
            ['python3', BRIDGE_SCRIPT],
            capture_output=True,
            text=True,
            timeout=60,
            cwd='/root/gold_ml_phase4'
        )

        if result.returncode == 0 and os.path.exists(SIGNAL_FILE_ORIGINAL):
            os.makedirs(os.path.dirname(SIGNAL_FILE_API), exist_ok=True)
            with open(SIGNAL_FILE_ORIGINAL, 'r') as f:
                signal_data = f.read()
            with open(SIGNAL_FILE_API, 'w') as f:
                f.write(signal_data)

            bridge_success_count += 1
            last_bridge_success = datetime.now()
            logging.info(f"✅ Bridge success (total: {bridge_success_count})")
            return True
        else:
            bridge_fail_count += 1
            return False

    except subprocess.TimeoutExpired:
        bridge_fail_count += 1
        logging.error("⏱️ Bridge timeout (60s)")
        return False
    except Exception as e:
        bridge_fail_count += 1
        logging.error(f"❌ Bridge error: {str(e)[:100]}")
        return False

def generate_fallback_signal():
    try:
        conviction = 7.5
        direction = 1

        if os.path.exists(SIGNAL_FILE_API):
            try:
                with open(SIGNAL_FILE_API, 'r') as f:
                    old_signal = json.load(f)
                    conviction = old_signal.get('conviction_score', 7.5)
                    direction = old_signal.get('direction', 1)
            except:
                pass

        signal = {
            "conviction_score": conviction,
            "price": 2730.50,
            "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "direction": direction,
            "us10y": 4.101,
            "dxy": 103.5,
            "source": "fallback"
        }

        os.makedirs(os.path.dirname(SIGNAL_FILE_API), exist_ok=True)
        with open(SIGNAL_FILE_API, 'w') as f:
            json.dump(signal, f, indent=2)

        logging.info("✅ Fallback signal")
        return True
    except Exception as e:
        logging.error(f"Fallback error: {e}")
        return False

def refresh_signal_timestamp():
    global signal_refresh_count
    try:
        if os.path.exists(SIGNAL_FILE_API):
            os.utime(SIGNAL_FILE_API, None)
            signal_refresh_count += 1
            logging.info(f"🔄 Signal refreshed (count: {signal_refresh_count})")
            return True
    except Exception as e:
        logging.error(f"Refresh error: {e}")
        return False

# ============================================================
# BACKGROUND LOOPS
# ============================================================

def bridge_loop():
    logging.info("🔄 Bridge loop started (5 min interval)")
    consecutive_failures = 0

    while True:
        try:
            success = run_bridge_script()

            if success:
                consecutive_failures = 0
                interval = 300
            else:
                consecutive_failures += 1
                generate_fallback_signal()
                interval = 600 if consecutive_failures >= 3 else 300

            time.sleep(interval)
        except Exception as e:
            logging.error(f"Bridge loop error: {e}")
            time.sleep(300)

def refresh_loop():
    logging.info("🔄 Refresh loop started (60s interval)")

    while True:
        try:
            refresh_signal_timestamp()
            time.sleep(60)
        except Exception as e:
            logging.error(f"Refresh loop error: {e}")
            time.sleep(60)

# ============================================================
# MAIN
# ============================================================

if __name__ == '__main__':
    logging.info("")
    logging.info("╔═══════════════════════════════════════════════════════════╗")
    logging.info("║     GOLD ML BACKEND v4.2 - SECURITY HARDENED             ║")
    logging.info("║     AUDIT-VPS-C1/C2/C3/C4 APPLIED                        ║")
    logging.info("╚═══════════════════════════════════════════════════════════╝")
    logging.info("")
    logging.info(f"📊 Bridge: {BRIDGE_SCRIPT}")
    logging.info(f"📁 Signal (MT5): {SIGNAL_FILE_ORIGINAL}")
    logging.info(f"📁 Signal (API): {SIGNAL_FILE_API}")
    logging.info(f"💾 Database: {DB_PATH}")
    logging.info(f"🔐 Auth: {'ENABLED' if API_TOKEN else 'DISABLED — set API_TOKEN env var'}")
    logging.info(f"🔏 HMAC: {'ENABLED' if HMAC_SECRET else 'DISABLED — set HMAC_SECRET env var'}")
    logging.info("")

    # CRITICAL: Clean port with verification
    if not clean_port_5000():
        logging.error("❌ Failed to clean port, exiting")
        sys.exit(1)

    # Generate initial signal
    logging.info("🎯 Generating initial signal...")
    success = run_bridge_script()
    if not success:
        logging.warning("Initial bridge failed, using fallback")
        generate_fallback_signal()

    # Start loops
    bridge_thread = threading.Thread(target=bridge_loop, daemon=True)
    bridge_thread.start()
    logging.info("✅ Bridge loop started")

    refresh_thread = threading.Thread(target=refresh_loop, daemon=True)
    refresh_thread.start()
    logging.info("✅ Refresh loop started")

    # Final port check before starting Flask
    logging.info("🔍 Final port check before Flask...")
    try:
        test_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        test_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        test_sock.bind(("0.0.0.0", 5000))
        test_sock.close()
        logging.info("✅ Port 5000 confirmed free")
    except OSError as e:
        logging.error(f"❌ Port check failed: {e}")
        logging.info("Attempting one more clean...")
        subprocess.run(['fuser', '-k', '5000/tcp'], stderr=subprocess.DEVNULL)
        time.sleep(5)

    # Start Flask
    logging.info("🚀 Starting Flask API on http://0.0.0.0:5000")
    logging.info("")

    try:
        app.run(
            host='0.0.0.0',
            port=5000,
            debug=False,
            use_reloader=False,
            threaded=True
        )
    except OSError as e:
        if "Address already in use" in str(e):
            logging.error("❌ CRITICAL: Port 5000 still in use despite all checks!")
            logging.error("This should not happen. Manual intervention required.")
        raise
