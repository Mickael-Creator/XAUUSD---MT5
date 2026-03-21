#!/usr/bin/env python3
"""
Gold ML Backend v4.1 - WITH VIX ENDPOINTS
Avec double vérification port + délais augmentés
"""
from flask import Flask, jsonify
import json
import os
import sys
import time
import logging
import threading
import subprocess
import sqlite3
import signal as sig
import socket
from datetime import datetime

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
# API ENDPOINTS
# ============================================================

@app.route('/health', methods=['GET'])
def health():
    signal_age = None
    signal_exists = False
    
    if os.path.exists(SIGNAL_FILE_API):
        signal_exists = True
        signal_age = int(time.time() - os.path.getmtime(SIGNAL_FILE_API))
    
    return jsonify({
        "status": "healthy",
        "service": "gold_ml_backend",
        "version": "4.1",
        "uptime_seconds": int(time.time() - START_TIME),
        "signal_exists": signal_exists,
        "signal_age_seconds": signal_age,
        "signal_refresh_count": signal_refresh_count,
        "bridge_success": bridge_success_count,
        "bridge_fails": bridge_fail_count,
        "last_bridge_success": last_bridge_success.isoformat() if last_bridge_success else None,
        "timestamp": datetime.now().isoformat()
    })

@app.route('/api/macro', methods=['GET'])
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
    
    return jsonify({
        "us10y": round(us10y, 3),
        "inflation_target": inflation_target,
        "real_rate": round(real_rate, 3),
        "macro_score": macro_score,
        "timestamp": datetime.now().isoformat()
    })

@app.route('/api/dxy', methods=['GET'])
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
    
    return jsonify({
        "dxy_value": round(dxy_value, 2),
        "correlation": -0.67,
        "timestamp": datetime.now().isoformat()
    })

@app.route('/api/news/status', methods=['GET'])
def news():
    return jsonify({
        "is_blackout": False,
        "next_event": None,
        "timestamp": datetime.now().isoformat()
    })

# ============================================================
# VIX ENDPOINT
# ============================================================
@app.route('/api/vix', methods=['GET'])
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
    
    return jsonify({
        "vix_level": round(vix_value, 2),
        "vix_change_24h": round(vix_change, 2),
        "volatility_regime": regime,
        "timestamp": datetime.now().isoformat()
    })


# ============================================================
# MARKET CONTEXT ENDPOINT
# ============================================================
@app.route('/api/market_context', methods=['GET'])
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
    
    return jsonify({
        "vix_level": round(vix_value, 2),
        "vix_regime": vix_regime,
        "dxy_index": round(dxy_value, 2),
        "us10y": round(us10y_value, 3),
        "real_rate": round(real_rate, 3),
        "context_score": context_score,
        "recommendation": recommendation,
        "timestamp": datetime.now().isoformat()
    })


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
    logging.info("║     GOLD ML BACKEND v4.1 - WITH VIX ENDPOINTS            ║")
    logging.info("║              WITH ROBUST PORT CHECKING                    ║")
    logging.info("╚═══════════════════════════════════════════════════════════╝")
    logging.info("")
    logging.info(f"📊 Bridge: {BRIDGE_SCRIPT}")
    logging.info(f"📁 Signal (MT5): {SIGNAL_FILE_ORIGINAL}")
    logging.info(f"📁 Signal (API): {SIGNAL_FILE_API}")
    logging.info(f"💾 Database: {DB_PATH}")
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
