#!/usr/bin/env python3
"""
GOLD ML PHASE 4 - CALENDAR MONITOR + ML BRIDGE
VPS Flask API pour données macro + thresholds ML optimisés
"""

from flask import Flask, jsonify, request
import sqlite3
import requests
import json
import os
from datetime import datetime, timedelta, timezone
import logging
from logging.handlers import RotatingFileHandler
import schedule
import time
import threading
import yfinance as yf

# ============================================================================
# CONFIGURATION
# ============================================================================
app = Flask(__name__)

from datetime import datetime, timezone

@app.route("/news_trading_signal/quick", methods=["GET"])
def news_trading_signal_quick():
    """
    Health endpoint required by VPS check & EA safety
    """
    return jsonify({
        "ok": True,
        "service": "gold_ml_monitor",
        "module": "news_trading_signal",
        "status": "available",
        "timestamp": datetime.now(timezone.utc).isoformat() + "Z"
    }), 200

# Paths
BASE_DIR = '/root/gold_ml_phase4'
DATABASE_PATH = os.path.join(BASE_DIR, 'gold_ml_database.db')
OPTIMAL_THRESHOLDS_PATH = os.path.join(BASE_DIR, 'optimal_thresholds.json')
LOG_PATH = os.path.join(BASE_DIR, 'calendar_monitor.log')

# API Configuration
CALENDAR_API_KEY = 'votre_cle_api_si_necessaire'
PORT = 5000

# Logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        RotatingFileHandler(LOG_PATH, maxBytes=10*1024*1024, backupCount=5),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# Global state
news_blackout_active = False
last_macro_update = None

# ============================================================================
# DATABASE INITIALIZATION
# ============================================================================
# ===== LIVE US10Y FETCH =====
def fetch_us10y_live():
    """Fetch live US10Y from yfinance"""
    try:
        ticker = yf.Ticker("^TNX")
        data = ticker.history(period="1d")
        if not data.empty:
            return round(float(data['Close'].iloc[-1]), 2)
    except Exception as e:
        logger.warning(f"US10Y fetch failed: {e}")
    return 4.35  # Fallback

def init_database():
    """Initialize SQLite database with all necessary tables"""
    conn = sqlite3.connect(DATABASE_PATH)
    cursor = conn.cursor()
    
    # Table automation_data (macro data)
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS automation_data (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            us10y_yield REAL,
            fed_target REAL,
            real_rate REAL,
            macro_score INTEGER,
            geo_score INTEGER,
            automation_level TEXT
        )
    ''')
    
    # Table market_data
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS market_data (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            Datetime TEXT NOT NULL,
            gold_close REAL,
            gold_volume INTEGER,
            dxy_close REAL,
            vix_level REAL
        )
    ''')
    
    # Table technical_indicators
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS technical_indicators (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            Datetime TEXT NOT NULL,
            gold_rsi REAL,
            gold_macd REAL,
            gold_ema20 REAL,
            gold_ema50 REAL,
            volume_ratio REAL,
            momentum_5h REAL
        )
    ''')
    
    # Table signals (for ML Bridge)
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS signals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            conviction_score REAL,
            signal_type TEXT,
            alert_sent INTEGER DEFAULT 0
        )
    ''')
    
    conn.commit()
    conn.close()
    logger.info("✅ Database initialized")

# ============================================================================
# ENDPOINT 1: /macro_data (EXISTANT - Déjà utilisé par EA)
# ============================================================================
@app.route('/macro_data', methods=['GET'])
def get_macro_data():
    """Return current macro economic data"""
    try:
        conn = sqlite3.connect(DATABASE_PATH)
        cursor = conn.cursor()
        
        # Get latest automation_data
        cursor.execute('''
            SELECT us10y_yield, fed_target, real_rate, macro_score, geo_score, timestamp
            FROM automation_data
            ORDER BY timestamp DESC
            LIMIT 1
        ''')
        
        row = cursor.fetchone()
        conn.close()
        
        if row:
            response = {
                'status': 'success',
                'us10y': fetch_us10y_live(),
                'inflation_target': row[1],
                'real_rate': round(fetch_us10y_live() - 2.45, 2),
                'macro_score': row[3],
                'geopolitical_score': row[4],
                'last_update': row[5],
                'timestamp': datetime.now().isoformat()
            }
            return jsonify(response), 200
        else:
            # Default values si pas de données
            return jsonify({
                'status': 'default',
                'us10y': fetch_us10y_live(),
                'inflation_target': 2.45,
                'real_rate': round(fetch_us10y_live() - 2.45, 2),
                'macro_score': 2,
                'geopolitical_score': 1,
                'message': 'Using default values'
            }), 200
            
    except Exception as e:
        logger.error(f"Error in /macro_data: {e}")
        return jsonify({'status': 'error', 'message': str(e)}), 500

# ============================================================================
# ENDPOINT 2: /news_status (EXISTANT - Déjà utilisé par EA)
# ============================================================================
@app.route('/news_status', methods=['GET'])
def get_news_status():
    """Return current news blackout status"""
    global news_blackout_active
    
    return jsonify({
        'status': 'success',
        'blackout_active': news_blackout_active,
        'timestamp': datetime.now().isoformat()
    }), 200

# ============================================================================
# ENDPOINT 3: /optimal_thresholds ✨ NOUVEAU
# ============================================================================
@app.route('/optimal_thresholds', methods=['GET'])
def get_optimal_thresholds():
    """
    Return ML-optimized conviction thresholds
    Read from optimal_thresholds.json generated by ML pipeline
    """
    try:
        # Check if ML optimization file exists
        if os.path.exists(OPTIMAL_THRESHOLDS_PATH):
            with open(OPTIMAL_THRESHOLDS_PATH, 'r') as f:
                data = json.load(f)
            
            # Extract thresholds
            thresholds = data.get('optimal_thresholds', {})
            optimization_date = data.get('optimization_date', 'unknown')
            improvement = data.get('improvement', {})
            validation = data.get('validation_results', {})
            
            response = {
                'status': 'success',
                'thresholds': {
                    'slam': float(thresholds.get('slam', 8.6)),
                    'high': float(thresholds.get('high', 6.37)),
                    'scalp': float(thresholds.get('scalp', 5.95))
                },
                'optimization_date': optimization_date,
                'sharpe_improvement': float(improvement.get('sharpe_pct', 0.0)),
                'total_trades': int(validation.get('total_trades', 0)),
                'win_rate': float(validation.get('win_rate', 0.0)),
                'version': 'ML_OPTIMIZED',
                'last_check': datetime.now().isoformat()
            }
            
            logger.info(f"✅ Thresholds served: SLAM={response['thresholds']['slam']:.2f}, "
                       f"HIGH={response['thresholds']['high']:.2f}, "
                       f"SCALP={response['thresholds']['scalp']:.2f}")
            
            return jsonify(response), 200
        else:
            # Fallback sur valeurs par défaut si ML pas encore run
            logger.warning("⚠️ optimal_thresholds.json not found, using defaults")
            
            response = {
                'status': 'default',
                'thresholds': {
                    'slam': 8.6,
                    'high': 6.37,
                    'scalp': 5.95
                },
                'optimization_date': 'never',
                'sharpe_improvement': 0.0,
                'total_trades': 0,
                'win_rate': 0.0,
                'version': 'DEFAULT',
                'message': 'ML optimization not yet run - using baseline thresholds'
            }
            
            return jsonify(response), 200
            
    except Exception as e:
        logger.error(f"❌ Error in /optimal_thresholds: {e}")
        
        # Return defaults même en cas d'erreur
        return jsonify({
            'status': 'error',
            'thresholds': {
                'slam': 8.6,
                'high': 6.37,
                'scalp': 5.95
            },
            'message': str(e),
            'version': 'FALLBACK'
        }), 200

# ============================================================================
# ENDPOINT 4: /health (pour monitoring)
# ============================================================================
@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    return jsonify({
        'status': 'healthy',
        'service': 'Gold ML Calendar Monitor',
        'version': '4.0',
        'timestamp': datetime.now().isoformat(),
        'database': 'connected' if os.path.exists(DATABASE_PATH) else 'missing',
        'ml_thresholds': 'available' if os.path.exists(OPTIMAL_THRESHOLDS_PATH) else 'not_optimized'
    }), 200

# ============================================================================
# BACKGROUND TASKS
# ============================================================================
def update_macro_data():
    """Update macro data in database (runs every hour)"""
    try:
        logger.info("📊 Macro data update check")
        
        conn = sqlite3.connect(DATABASE_PATH)
        cursor = conn.cursor()
        
        cursor.execute('''
            INSERT INTO automation_data (timestamp, us10y_yield, fed_target, real_rate, macro_score, geo_score, automation_level)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ''', (
            datetime.now().isoformat(),
            fetch_us10y_live(),
            2.45,
            round(fetch_us10y_live() - 2.45, 2),
            2,
            1,
            '90%'
        ))
        
        conn.commit()
        conn.close()
        
        logger.info("✅ Macro data updated")
        
    except Exception as e:
        logger.error(f"❌ Error updating macro data: {e}")

def check_news_events():
    """Check for high-impact news events"""
    global news_blackout_active
    
    try:
        current_hour = datetime.now().hour
        current_minute = datetime.now().minute
        
        # Blackout pendant les annonces importantes
        if current_hour == 14 and current_minute >= 30:
            if not news_blackout_active:
                news_blackout_active = True
                logger.warning("🚨 NEWS BLACKOUT ACTIVATED")
        elif current_hour == 15 and current_minute >= 30:
            if news_blackout_active:
                news_blackout_active = False
                logger.info("✅ NEWS BLACKOUT DEACTIVATED")
        else:
            news_blackout_active = False
            
    except Exception as e:
        logger.error(f"❌ Error checking news: {e}")

def schedule_tasks():
    """Schedule background tasks"""
    schedule.every(1).hours.do(update_macro_data)
    schedule.every(5).minutes.do(check_news_events)
    
    while True:
        schedule.run_pending()
        time.sleep(60)

# ============================================================================
# ENDPOINT: /dxy_data - DXY Index & Correlation
# ============================================================================
@app.route('/dxy_data', methods=['GET'])
def get_dxy_data():
    """Return current DXY Index and Gold/DXY correlation"""
    try:
        conn = sqlite3.connect(DATABASE_PATH)
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT dxy_value, dxy_change_pct, timestamp
            FROM dxy_data
            ORDER BY timestamp DESC
            LIMIT 1
        ''')
        
        dxy_row = cursor.fetchone()
        
        if dxy_row:
            dxy_value = dxy_row[0]
            dxy_change = dxy_row[1] if dxy_row[1] is not None else 0.0
            dxy_timestamp = dxy_row[2]
            
            correlation = calculate_correlation_from_db(cursor)
            conn.close()
            
            response = {
                'status': 'success',
                'dxy_index': dxy_value,
                'dxy_change_pct': dxy_change,
                'gold_dxy_correlation': correlation,
                'last_update': dxy_timestamp,
                'timestamp': datetime.now().isoformat()
            }
            
            return jsonify(response), 200
        else:
            conn.close()
            return jsonify({
                'status': 'default',
                'dxy_index': 103.5,
                'dxy_change_pct': 0.0,
                'gold_dxy_correlation': -0.65,
                'message': 'Using default DXY values (no data yet)'
            }), 200
            
    except Exception as e:
        logger.error(f"Error in /dxy_data: {e}")
        return jsonify({
            'status': 'error',
            'message': str(e),
            'dxy_index': 103.5,
            'gold_dxy_correlation': -0.65
        }), 500

def calculate_correlation_from_db(cursor):
    """Calculate Gold/DXY correlation from database"""
    try:
        cursor.execute('''
            SELECT dxy_value
            FROM dxy_data
            ORDER BY timestamp DESC
            LIMIT 20
        ''')
        dxy_values = [row[0] for row in cursor.fetchall()]
        
        cursor.execute('''
            SELECT gold_close
            FROM market_data
            WHERE gold_close IS NOT NULL
            ORDER BY Datetime DESC
            LIMIT 20
        ''')
        gold_values = [row[0] for row in cursor.fetchall()]
        
        if len(dxy_values) < 10 or len(gold_values) < 10:
            return -0.65
        
        try:
            import numpy as np
            min_len = min(len(dxy_values), len(gold_values))
            dxy_array = np.array(dxy_values[:min_len])
            gold_array = np.array(gold_values[:min_len])
            correlation = np.corrcoef(dxy_array, gold_array)[0, 1]
            correlation = max(-1.0, min(1.0, correlation))
            return round(correlation, 3)
        except ImportError:
            return -0.65
            
    except Exception as e:
        logger.error(f"Error calculating correlation: {e}")
        return -0.65

# ============================================================================
# ENDPOINT: /dxy_status - DXY Fetcher Status
# ============================================================================
@app.route('/dxy_status', methods=['GET'])
def get_dxy_status():
    """Return DXY fetcher status and statistics"""
    try:
        conn = sqlite3.connect(DATABASE_PATH)
        cursor = conn.cursor()
        
        cursor.execute('SELECT COUNT(*) FROM dxy_data')
        total_records = cursor.fetchone()[0]
        
        cursor.execute('''
            SELECT dxy_value, timestamp
            FROM dxy_data
            ORDER BY timestamp DESC
            LIMIT 1
        ''')
        latest = cursor.fetchone()
        
        cursor.execute('''
            SELECT timestamp
            FROM dxy_data
            ORDER BY timestamp ASC
            LIMIT 1
        ''')
        oldest = cursor.fetchone()
        
        conn.close()
        
        if latest:
            last_update = datetime.fromisoformat(latest[1])
            time_diff = (datetime.now() - last_update).total_seconds() / 60
            status = "online" if time_diff < 30 else "stale"
            
            return jsonify({
                'status': 'success',
                'fetcher_status': status,
                'total_records': total_records,
                'latest_dxy': latest[0],
                'last_update': latest[1],
                'first_record': oldest[0] if oldest else None,
                'minutes_since_update': round(time_diff, 1)
            }), 200
        else:
            return jsonify({
                'status': 'no_data',
                'message': 'DXY fetcher not started yet'
            }), 200
            
    except Exception as e:
        logger.error(f"Error in /dxy_status: {e}")
        return jsonify({'status': 'error', 'message': str(e)}), 500
# =====================================================
# ENDPOINT 6: /h4_signal (NOUVEAU pour v4.0)
# =====================================================
@app.route('/h4_signal', methods=['GET'])
def get_h4_signal():
    """Return H4 analysis for bonus calculation"""
    try:
        conn = sqlite3.connect(DATABASE_PATH)
        cursor = conn.cursor()
        
        # Get last 12 H1 candles (equivalent to 3 H4 candles)
        cursor.execute('''
            SELECT m.gold_close, t.gold_rsi, t.gold_macd, 
                   t.gold_ema20, t.gold_ema50
            FROM market_data m
            JOIN technical_indicators t ON m.Datetime = t.Datetime
            ORDER BY m.Datetime DESC
            LIMIT 12
        ''')
        
        rows = cursor.fetchall()
        conn.close()
        
        if not rows or len(rows) < 12:
            return jsonify({
                'status': 'default',
                'h4_score': 0.5,
                'h4_status': 'NEUTRAL',
                'h4_rsi': 50.0,
                'h4_macd': 0.0,
                'message': 'Insufficient H4 data - using defaults',
                'timestamp': datetime.now().isoformat()
            }), 200
        
        # Calculate H4 indicators (average of last 12 H1 candles)
        valid_rsi = [r[1] for r in rows if r[1] is not None]
        valid_macd = [r[2] for r in rows if r[2] is not None]
        
        h4_rsi = sum(valid_rsi) / len(valid_rsi) if valid_rsi else 50.0
        h4_macd = sum(valid_macd) / len(valid_macd) if valid_macd else 0.0
        h4_ema20 = rows[0][3] if rows[0][3] else 0
        h4_ema50 = rows[0][4] if rows[0][4] else 0
        h4_price = rows[0][0] if rows[0][0] else 0
        
        # Calculate H4 score (0-1.0)
        score = 0.0
        
        # RSI H4 (0-0.3)
        if 50 < h4_rsi < 70:
            score += 0.3
        elif 40 < h4_rsi < 60:
            score += 0.15
        
        # MACD H4 (0-0.3)
        if h4_macd > 0:
            score += 0.3
        elif h4_macd > -0.5:
            score += 0.15
        
        # EMA H4 (0-0.4)
        if h4_price > h4_ema20 and h4_ema20 > h4_ema50:
            score += 0.4
        elif h4_price > h4_ema20:
            score += 0.2
        
        # Determine status
        if score >= 0.7:
            h4_status = "BULLISH"
        elif score >= 0.4:
            h4_status = "NEUTRAL"
        else:
            h4_status = "BEARISH"
        
        response = {
            'status': 'success',
            'h4_score': round(score, 2),
            'h4_status': h4_status,
            'h4_rsi': round(h4_rsi, 2),
            'h4_macd': round(h4_macd, 4),
            'h4_ema20': round(h4_ema20, 2),
            'h4_ema50': round(h4_ema50, 2),
            'h4_price': round(h4_price, 2),
            'data_points': len(rows),
            'timestamp': datetime.now().isoformat()
        }
        
        logger.info(f"✅ H4 signal: {h4_status} (score: {score:.2f})")
        return jsonify(response), 200
        
    except Exception as e:
        logger.error(f"❌ Error in /h4_signal: {e}")
        return jsonify({
            'status': 'error',
            'h4_score': 0.5,
            'h4_status': 'NEUTRAL',
            'h4_rsi': 50.0,
            'h4_macd': 0.0,
            'message': str(e),
            'timestamp': datetime.now().isoformat()
        }), 500
# =====================================================
# ENDPOINT 7: /server_time (Timezone management)
# =====================================================
@app.route('/server_time', methods=['GET'])
def get_server_time():
    """Return server time with timezone info for MT5 sync"""
    try:
        # UTC time
        utc_now = datetime.now(timezone.utc)
        
        # Server local time (VPS)
        local_now = datetime.now()
        
        # Calculate offset between server and UTC
        offset_seconds = (local_now - utc_now.replace(tzinfo=None)).total_seconds()
        server_offset_hours = int(offset_seconds / 3600)
        
        # Broker offset (configurable - default +2 for most EU brokers)
        broker_offset_hours = 3
        
        # Calculate broker time
        broker_time = utc_now + timedelta(hours=broker_offset_hours)
        
        # Correction needed to convert VPS time to broker time
        correction_hours = broker_offset_hours - server_offset_hours
        
        response = {
            'status': 'success',
            'utc_time': utc_now.isoformat() + 'Z',
            'server_time': local_now.isoformat(),
            'broker_time': broker_time.isoformat(),
            'server_offset_hours': server_offset_hours,
            'broker_offset_hours': broker_offset_hours,
            'correction_hours': correction_hours,
            'timestamp': datetime.now().isoformat()
        }
        
        logger.info(f"⏰ Time sync: UTC={utc_now.strftime('%H:%M')}, Server={local_now.strftime('%H:%M')}, Broker={broker_time.strftime('%H:%M')}, Correction={correction_hours}h")
        return jsonify(response), 200
        
    except Exception as e:
        logger.error(f"❌ Error in /server_time: {e}")
        return jsonify({
            'status': 'error',
            'message': str(e),
            'timestamp': datetime.now().isoformat()
        }), 500

# ================================================================
# ENDPOINT 8: /vix_data - VIX Level & Volatility Regime
# ================================================================
@app.route('/vix_data', methods=['GET'])
def get_vix_data():
    """Return current VIX level and volatility regime"""
    try:
        conn = sqlite3.connect(DATABASE_PATH)
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT vix_level, Datetime
            FROM market_data
            WHERE vix_level IS NOT NULL
            ORDER BY Datetime DESC
            LIMIT 1
        ''')
        latest = cursor.fetchone()
        
        cursor.execute('''
            SELECT vix_level
            FROM market_data
            WHERE vix_level IS NOT NULL
            ORDER BY Datetime DESC
            LIMIT 1 OFFSET 24
        ''')
        previous = cursor.fetchone()
        
        conn.close()
        
        if latest and latest[0]:
            vix_level = float(latest[0])
            vix_timestamp = latest[1]
            
            vix_change_24h = 0.0
            if previous and previous[0]:
                vix_change_24h = ((vix_level - float(previous[0])) / float(previous[0])) * 100
            
            if vix_level < 15:
                regime = "LOW"
            elif vix_level < 20:
                regime = "NORMAL"
            elif vix_level < 25:
                regime = "ELEVATED"
            elif vix_level < 35:
                regime = "HIGH"
            else:
                regime = "EXTREME"
            
            return jsonify({
                'status': 'success',
                'vix_level': round(vix_level, 2),
                'vix_change_24h': round(vix_change_24h, 2),
                'volatility_regime': regime,
                'last_update': vix_timestamp,
                'timestamp': datetime.now().isoformat()
            }), 200
        
        else:
            return jsonify({
                'status': 'default',
                'vix_level': 18.0,
                'vix_change_24h': 0.0,
                'volatility_regime': 'NORMAL',
                'timestamp': datetime.now().isoformat()
            }), 200
            
    except Exception as e:
        logger.error(f"Error in /vix_data: {e}")
        return jsonify({
            'status': 'error',
            'vix_level': 18.0,
            'volatility_regime': 'NORMAL',
            'message': str(e)
        }), 500

# ================================================================
# ENDPOINT 9: /market_context - Full Market Context
# ================================================================
@app.route('/market_context', methods=['GET'])
def get_market_context():
    """Return comprehensive market context for gold trading"""
    try:
        conn = sqlite3.connect(DATABASE_PATH)
        cursor = conn.cursor()
        
        cursor.execute('SELECT vix_level FROM market_data WHERE vix_level IS NOT NULL ORDER BY Datetime DESC LIMIT 1')
        vix_row = cursor.fetchone()
        vix_level = float(vix_row[0]) if vix_row and vix_row[0] else 18.0
        
        cursor.execute('SELECT dxy_close FROM market_data WHERE dxy_close IS NOT NULL ORDER BY Datetime DESC LIMIT 1')
        dxy_row = cursor.fetchone()
        dxy_index = float(dxy_row[0]) if dxy_row and dxy_row[0] else 103.5
        
        cursor.execute('SELECT us10y_yield, fed_target, real_rate FROM automation_data ORDER BY timestamp DESC LIMIT 1')
        macro_row = cursor.fetchone()
        
        if macro_row:
            us10y = float(macro_row[0]) if macro_row[0] else 4.35
            real_rate = float(macro_row[2]) if macro_row[2] else 1.9
        else:
            us10y = 4.35
            real_rate = 1.9
        
        conn.close()
        
        if vix_level < 15:
            vix_regime = "LOW"
        elif vix_level < 20:
            vix_regime = "NORMAL"
        elif vix_level < 25:
            vix_regime = "ELEVATED"
        elif vix_level < 35:
            vix_regime = "HIGH"
        else:
            vix_regime = "EXTREME"
        
        context_score = 50
        
        if vix_level < 15:
            context_score -= 10
        elif vix_level >= 20 and vix_level < 25:
            context_score += 10
        elif vix_level >= 25 and vix_level < 35:
            context_score += 15
        
        if dxy_index < 100:
            context_score += 15
        elif dxy_index < 103:
            context_score += 5
        elif dxy_index > 106:
            context_score -= 15
        elif dxy_index > 104:
            context_score -= 5
        
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
            'status': 'success',
            'vix_level': round(vix_level, 2),
            'vix_regime': vix_regime,
            'dxy_index': round(dxy_index, 2),
            'us10y': round(us10y, 3),
            'real_rate': round(real_rate, 3),
            'context_score': context_score,
            'recommendation': recommendation,
            'timestamp': datetime.now().isoformat()
        }), 200
        
    except Exception as e:
        logger.error(f"Error in /market_context: {e}")
        return jsonify({
            'status': 'error',
            'context_score': 50,
            'recommendation': 'NEUTRAL',
            'message': str(e)
        }), 500

# ============================================================================
# MAIN
# ============================================================================
if __name__ == '__main__':
    logger.info("="*60)
    logger.info("🚀 GOLD ML CALENDAR MONITOR V4.0 - STARTING")
    logger.info("="*60)
    
    # Initialize database
    init_database()
    
    # Start background tasks in separate thread
    scheduler_thread = threading.Thread(target=schedule_tasks, daemon=True)
    scheduler_thread.start()
    logger.info("✅ Background tasks started")
    
    # Check if ML thresholds exist
    if os.path.exists(OPTIMAL_THRESHOLDS_PATH):
        logger.info(f"✅ ML thresholds file found: {OPTIMAL_THRESHOLDS_PATH}")
    else:
        logger.warning(f"⚠️ ML thresholds not found - will use defaults")
        logger.info(f"💡 Run ML pipeline to generate: python3 RUN_ALL_PIPELINE.py")
    
    # Start Flask API
    logger.info(f"🌐 Starting Flask API on port {PORT}")
    logger.info("📡 Available endpoints:")
    logger.info("   - GET /health")
    logger.info("   - GET /macro_data")
    logger.info("   - GET /news_status")
    logger.info("   - GET /optimal_thresholds ✨")
    
    app.run(host='0.0.0.0', port=PORT, debug=False)

# ===========================================================================
# ENDPOINT 10: /cot_data - COT Report Data
# ===========================================================================

# COT cache to avoid hitting CFTC API on every request
_cot_cache = {'data': None, 'fetched_at': None}
_COT_CACHE_SECONDS = 3600 * 6  # 6 hours

def _fetch_cot_from_cftc():
    """
    Fetch fresh COT data from CFTC Socrata Open Data API.
    Fallback chain: Legacy Futures Only → Disaggregated Futures → Legacy Combined.
    Staleness detection: alerte si report_date > 14 jours.
    """
    import requests as req

    # --- Source 1: Legacy Futures Only (jun7-fc8e) - primary ---
    result = _try_cftc_dataset(req, "jun7-fc8e", "Legacy Futures Only",
                                long_key='noncomm_positions_long_all',
                                short_key='noncomm_positions_short_all')
    if result:
        return result

    # --- Source 2: Disaggregated Futures (6dca-aqww) - Managed Money ---
    result = _try_cftc_dataset(req, "6dca-aqww", "Disaggregated Futures",
                                long_key='m_money_positions_long_all',
                                short_key='m_money_positions_short_all')
    if result:
        return result

    # --- Source 3: Legacy Combined (kh3c-gbw2) ---
    result = _try_cftc_dataset(req, "kh3c-gbw2", "Legacy Combined",
                                long_key='noncomm_positions_long_all',
                                short_key='noncomm_positions_short_all')
    if result:
        return result

    logger.error("[COT] All 3 CFTC datasets failed — no fresh COT data available")
    return None


def _try_cftc_dataset(req, dataset_id, dataset_name, long_key, short_key):
    """Try fetching COT gold data from a specific CFTC Socrata dataset."""
    try:
        url = f"https://publicreporting.cftc.gov/resource/{dataset_id}.json"
        params = {
            "$where": "commodity_name = 'GOLD'",
            "$order": "report_date_as_yyyy_mm_dd DESC",
            "$limit": 52
        }
        resp = req.get(url, params=params, timeout=30)
        if resp.status_code != 200:
            logger.warning(f"[COT] {dataset_name} ({dataset_id}) returned HTTP {resp.status_code}")
            return None
        data = resp.json()
        if not data:
            logger.warning(f"[COT] {dataset_name} ({dataset_id}) returned empty data")
            return None

        latest = data[0]
        long_pos = int(float(latest.get(long_key, 0)))
        short_pos = int(float(latest.get(short_key, 0)))
        net_position = long_pos - short_pos
        total_oi = int(float(latest.get('open_interest_all', 0)))
        report_date = latest.get('report_date_as_yyyy_mm_dd', '')[:10]

        # Staleness detection
        try:
            rd = datetime.strptime(report_date, "%Y-%m-%d")
            days_old = (datetime.now() - rd).days
            if days_old > 14:
                logger.warning(
                    f"⚠️ [COT] {dataset_name} data is {days_old} days old "
                    f"(report_date={report_date}) — trying next source"
                )
                return None  # Force fallback to next dataset
        except ValueError:
            pass

        # Net change vs previous week
        net_change = 0
        if len(data) > 1:
            prev = data[1]
            prev_net = int(float(prev.get(long_key, 0))) - int(float(prev.get(short_key, 0)))
            net_change = net_position - prev_net

        # Percentile from 52-week history
        historical_nets = []
        for row in data:
            net = int(float(row.get(long_key, 0))) - int(float(row.get(short_key, 0)))
            historical_nets.append(net)
        below = sum(1 for h in historical_nets if h < net_position)
        percentile_net = round((below / len(historical_nets)) * 100, 1) if historical_nets else 50.0

        # Save to DB for other consumers
        try:
            conn = sqlite3.connect(DATABASE_PATH)
            cursor = conn.cursor()
            cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='cot_data'")
            if cursor.fetchone():
                cursor.execute('''
                    INSERT OR REPLACE INTO cot_data
                    (report_date, net_position, net_change, long_positions,
                     short_positions, total_oi, timestamp)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                ''', (report_date, net_position, net_change, long_pos,
                      short_pos, total_oi, datetime.now().isoformat()))
                conn.commit()
            conn.close()
        except Exception as db_err:
            logger.warning(f"[COT] DB save failed: {db_err}")

        logger.info(f"[COT] {dataset_name} OK: date={report_date}, net={net_position:+,}, pct={percentile_net:.1f}%")
        return {
            'long_pos': long_pos,
            'short_pos': short_pos,
            'net_position': net_position,
            'net_change': net_change,
            'total_oi': total_oi,
            'report_date': report_date,
            'percentile_net': percentile_net,
            'source': f'CFTC_{dataset_name.replace(" ", "_").upper()}'
        }

    except Exception as e:
        logger.error(f"[COT] {dataset_name} ({dataset_id}) error: {e}")
        return None

@app.route('/cot_data', methods=['GET'])
def get_cot_data():
    """Return latest COT (Commitment of Traders) data for Gold"""
    try:
        global _cot_cache
        now = datetime.now()

        # Use cache if fresh enough
        if (_cot_cache['data'] and _cot_cache['fetched_at'] and
                (now - _cot_cache['fetched_at']).total_seconds() < _COT_CACHE_SECONDS):
            cached = _cot_cache['data']
        else:
            # Fetch fresh data from CFTC
            cached = _fetch_cot_from_cftc()
            if cached:
                _cot_cache = {'data': cached, 'fetched_at': now}
                logger.info(f"[COT] Fresh data fetched: date={cached['report_date']}")
            else:
                # Fallback to DB
                conn = sqlite3.connect(DATABASE_PATH)
                cursor = conn.cursor()
                cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='cot_data'")
                if cursor.fetchone():
                    cursor.execute('''
                        SELECT net_position, net_change, long_positions, short_positions,
                               total_oi, report_date, timestamp
                        FROM cot_data ORDER BY timestamp DESC LIMIT 1
                    ''')
                    row = cursor.fetchone()
                    if row:
                        cached = {
                            'long_pos': row[2], 'short_pos': row[3],
                            'net_position': row[0], 'net_change': row[1],
                            'total_oi': row[4], 'report_date': row[5],
                            'percentile_net': 50.0
                        }
                conn.close()

        if not cached:
            return jsonify({
                'status': 'no_data',
                'message': 'No COT data available',
                'net_position': 0, 'net_change': 0,
                'long_pct': 50.0, 'percentile_net': 50.0,
                'short_pct': 50.0, 'sentiment': 'NEUTRAL',
                'timestamp': now.isoformat()
            }), 200

        long_pos = cached['long_pos']
        short_pos = cached['short_pos']
        total = long_pos + short_pos if (long_pos + short_pos) > 0 else 1
        long_pct = round((long_pos / total) * 100, 1)
        short_pct = round((short_pos / total) * 100, 1)
        percentile_net = cached.get('percentile_net', long_pct)

        # Determine sentiment
        if long_pct > 60:
            sentiment = "VERY_BULLISH"
        elif long_pct > 55:
            sentiment = "BULLISH"
        elif long_pct < 40:
            sentiment = "VERY_BEARISH"
        elif long_pct < 45:
            sentiment = "BEARISH"
        else:
            sentiment = "NEUTRAL"

        return jsonify({
            'status': 'success',
            'net_position': cached['net_position'],
            'net_change': cached['net_change'],
            'long_positions': long_pos,
            'short_positions': short_pos,
            'long_pct': long_pct,
            'percentile_net': percentile_net,
            'short_pct': short_pct,
            'total_oi': cached['total_oi'],
            'sentiment': sentiment,
            'report_date': cached['report_date'],
            'timestamp': now.isoformat()
        }), 200

    except Exception as e:
        logger.error(f"Error in /cot_data: {e}")
        return jsonify({
            'status': 'error',
            'message': str(e),
            'net_position': 0,
            'sentiment': 'NEUTRAL'
        }), 500

