"""
COT Data Service for Gold ML Trading System
Fetches CFTC Commitment of Traders data for Gold Futures (GC)
Add this to your existing VPS Flask app
"""

import requests
import pandas as pd
from datetime import datetime, timedelta
from flask import jsonify
import json
import os
import sqlite3

# ============================================================
# COT DATA FETCHER
# ============================================================

class COTDataManager:
    """
    Manages COT data fetching, storage, and percentile calculation
    Data source: CFTC via Quandl/NASDAQ Data Link or direct CFTC
    """
    
    def __init__(self, db_path="cot_data.db"):
        self.db_path = db_path
        self.gold_code = "088691"  # CFTC code for Gold
        self.history_weeks = 52
        self.last_fetch = None
        self.cache = None
        self.cache_duration = 3600 * 6  # 6 hours cache
        
        self._init_database()
    
    def _init_database(self):
        """Initialize SQLite database for COT history"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS cot_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                report_date TEXT UNIQUE,
                managed_money_long REAL,
                managed_money_short REAL,
                managed_money_net REAL,
                commercial_long REAL,
                commercial_short REAL,
                commercial_net REAL,
                open_interest REAL,
                fetch_date TEXT
            )
        ''')
        
        conn.commit()
        conn.close()
        print("[COT] Database initialized")
    
    def fetch_cot_data(self):
        """
        Fetch latest COT data from CFTC
        Returns processed data with percentile calculations
        """
        
        # Check cache first
        if self.cache and self.last_fetch:
            if (datetime.now() - self.last_fetch).total_seconds() < self.cache_duration:
                return self.cache
        
        try:
            # Method 1: CFTC Socrata Open Data API (free, reliable)
            data = self._fetch_from_cftc_socrata()

            if data is None:
                # Method 2: Fallback to direct CFTC text file (slower)
                data = self._fetch_from_cftc_direct()
            
            if data is None:
                # Method 3: Use last known data from database
                data = self._get_last_from_db()
            
            if data:
                self._save_to_db(data)
                self.cache = data
                self.last_fetch = datetime.now()
                
            return data
            
        except Exception as e:
            print(f"[COT] Fetch error: {e}")
            return self._get_last_from_db()
    
    def _fetch_from_cftc_socrata(self):
        """
        Fetch from CFTC Socrata Open Data API with fallback chain:
        1. Legacy Futures Only (jun7-fc8e) — primary, noncomm positions
        2. Disaggregated Futures (6dca-aqww) — managed money positions
        3. Legacy Combined (kh3c-gbw2) — backup noncomm positions
        Staleness detection: skip dataset if report_date > 14 days old.
        """
        # Try each dataset in order
        datasets = [
            ("jun7-fc8e", "Legacy Futures Only", "noncomm_positions_long_all", "noncomm_positions_short_all",
             "comm_positions_long_all", "comm_positions_short_all"),
            ("6dca-aqww", "Disaggregated Futures", "m_money_positions_long_all", "m_money_positions_short_all",
             "prod_merc_positions_long_all", "prod_merc_positions_short_all"),
            ("kh3c-gbw2", "Legacy Combined", "noncomm_positions_long_all", "noncomm_positions_short_all",
             "comm_positions_long_all", "comm_positions_short_all"),
        ]

        for ds_id, ds_name, long_key, short_key, comm_long_key, comm_short_key in datasets:
            result = self._try_cftc_dataset(ds_id, ds_name, long_key, short_key, comm_long_key, comm_short_key)
            if result:
                return result

        print("[COT] All 3 CFTC Socrata datasets failed")
        return None

    def _try_cftc_dataset(self, dataset_id, dataset_name, long_key, short_key, comm_long_key, comm_short_key):
        """Try fetching COT gold data from a specific CFTC Socrata dataset."""
        try:
            url = f"https://publicreporting.cftc.gov/resource/{dataset_id}.json"
            params = {
                "$where": "commodity_name = 'GOLD'",
                "$order": "report_date_as_yyyy_mm_dd DESC",
                "$limit": self.history_weeks
            }

            response = requests.get(url, params=params, timeout=30)

            if response.status_code != 200:
                print(f"[COT] {dataset_name} ({dataset_id}) returned {response.status_code}")
                return None

            data = response.json()

            if not data:
                print(f"[COT] {dataset_name} ({dataset_id}) returned empty data")
                return None

            latest = data[0]
            report_date = latest.get('report_date_as_yyyy_mm_dd', '')[:10]

            # Staleness detection: skip if data is more than 14 days old
            try:
                rd = datetime.strptime(report_date, "%Y-%m-%d")
                days_old = (datetime.now() - rd).days
                if days_old > 14:
                    print(f"[COT] ⚠️ {dataset_name} data is {days_old} days old (report_date={report_date}) — trying next source")
                    return None
            except ValueError:
                pass

            mm_long = int(float(latest.get(long_key, 0)))
            mm_short = int(float(latest.get(short_key, 0)))
            mm_net = mm_long - mm_short

            comm_long = int(float(latest.get(comm_long_key, 0)))
            comm_short = int(float(latest.get(comm_short_key, 0)))
            comm_net = comm_long - comm_short

            oi = int(float(latest.get('open_interest_all', 0)))
            oi_change = int(float(latest.get('change_in_open_interest_all', 0)))

            # Calculate change from previous week
            mm_net_change = 0
            if len(data) > 1:
                prev = data[1]
                prev_long = int(float(prev.get(long_key, 0)))
                prev_short = int(float(prev.get(short_key, 0)))
                mm_net_change = mm_net - (prev_long - prev_short)

            # Calculate percentile from history
            historical_nets = []
            for row in data:
                net = int(float(row.get(long_key, 0))) - int(float(row.get(short_key, 0)))
                historical_nets.append(net)

            percentile = self._calculate_percentile(mm_net, historical_nets)

            print(f"[COT] {dataset_name} OK: date={report_date}, net={mm_net:+,}, percentile={percentile:.1f}%")

            return {
                "managed_money_long": mm_long,
                "managed_money_short": mm_short,
                "managed_money_net": mm_net,
                "managed_money_net_change": mm_net_change,
                "commercial_long": comm_long,
                "commercial_short": comm_short,
                "commercial_net": comm_net,
                "open_interest": oi,
                "open_interest_change": oi_change,
                "percentile_net": percentile,
                "report_date": report_date,
                "historical_net": historical_nets[:10],
                "source": f"CFTC_{dataset_name.replace(' ', '_').upper()}",
                "fetch_time": datetime.now().isoformat()
            }

        except Exception as e:
            print(f"[COT] {dataset_name} ({dataset_id}) error: {e}")
            return None
    
    def _fetch_from_cftc_direct(self):
        """
        Fetch directly from CFTC Legacy Futures Only text report (backup method)
        Format: comma-separated with fixed column positions
        """
        try:
            url = "https://www.cftc.gov/dea/newcot/deafut.txt"
            response = requests.get(url, timeout=60)

            if response.status_code != 200:
                print(f"[COT] CFTC direct returned {response.status_code}")
                return None

            lines = response.text.split('\n')

            # Find Gold COMEX line - market code 088691
            gold_lines = []
            header_line = None
            for i, line in enumerate(lines):
                if "GOLD" in line.upper() and "EXCHANGE" in line.upper():
                    header_line = line
                elif "088691" in line and header_line and "GOLD" in header_line.upper():
                    gold_lines.append(line)
                    break
                elif line.strip() == '':
                    header_line = None

            if not gold_lines:
                print("[COT] Gold data not found in CFTC text file")
                return None

            # Parse CSV-like format
            # Legacy format columns (comma-separated):
            # The data line contains positions after the header
            parts = [p.strip() for p in gold_lines[0].split(',')]

            # Try to extract basic data - positions vary by format
            # Fallback: use Socrata API data structure as reference
            print(f"[COT] CFTC direct: found Gold line with {len(parts)} fields")

            # Return None to fall through to database fallback
            # The Socrata API is the reliable primary source
            return None

        except Exception as e:
            print(f"[COT] CFTC direct error: {e}")
            return None
    
    def _find_column(self, columns, possible_names):
        """Find column index by possible names"""
        for i, col in enumerate(columns):
            col_lower = col.lower().replace(" ", "_")
            for name in possible_names:
                if name.lower() in col_lower:
                    return i
        return None
    
    def _calculate_percentile(self, value, history):
        """Calculate percentile of value within history"""
        if not history:
            return 50.0
        
        below_count = sum(1 for h in history if h < value)
        return (below_count / len(history)) * 100
    
    def _save_to_db(self, data):
        """Save COT data to database"""
        try:
            conn = sqlite3.connect(self.db_path)
            cursor = conn.cursor()
            
            cursor.execute('''
                INSERT OR REPLACE INTO cot_history 
                (report_date, managed_money_long, managed_money_short, managed_money_net,
                 commercial_long, commercial_short, commercial_net, open_interest, fetch_date)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (
                data.get("report_date"),
                data.get("managed_money_long", 0),
                data.get("managed_money_short", 0),
                data.get("managed_money_net", 0),
                data.get("commercial_long", 0),
                data.get("commercial_short", 0),
                data.get("commercial_net", 0),
                data.get("open_interest", 0),
                datetime.now().isoformat()
            ))
            
            conn.commit()
            conn.close()
            
        except Exception as e:
            print(f"[COT] DB save error: {e}")
    
    def _get_last_from_db(self):
        """Get last known COT data from database"""
        try:
            conn = sqlite3.connect(self.db_path)
            cursor = conn.cursor()
            
            cursor.execute('''
                SELECT * FROM cot_history 
                ORDER BY report_date DESC 
                LIMIT 1
            ''')
            
            row = cursor.fetchone()
            
            if not row:
                return self._get_fallback()
            
            # Get historical data for percentile
            cursor.execute('''
                SELECT managed_money_net FROM cot_history 
                ORDER BY report_date DESC 
                LIMIT ?
            ''', (self.history_weeks,))
            
            historical = [r[0] for r in cursor.fetchall()]
            conn.close()
            
            mm_net = row[4]  # managed_money_net column
            percentile = self._calculate_percentile(mm_net, historical)
            
            return {
                "managed_money_long": row[2],
                "managed_money_short": row[3],
                "managed_money_net": row[4],
                "managed_money_net_change": 0,
                "commercial_long": row[5],
                "commercial_short": row[6],
                "commercial_net": row[7],
                "open_interest": row[8],
                "open_interest_change": 0,
                "percentile_net": percentile,
                "report_date": row[1],
                "historical_net": historical[:10],
                "source": "DATABASE",
                "fetch_time": datetime.now().isoformat()
            }
            
        except Exception as e:
            print(f"[COT] DB read error: {e}")
            return self._get_fallback()
    
    def _get_fallback(self):
        """Return neutral fallback data"""
        return {
            "managed_money_long": 0,
            "managed_money_short": 0,
            "managed_money_net": 0,
            "managed_money_net_change": 0,
            "commercial_net": 0,
            "open_interest": 0,
            "open_interest_change": 0,
            "percentile_net": 50.0,
            "report_date": datetime.now().strftime("%Y-%m-%d"),
            "historical_net": [],
            "source": "FALLBACK",
            "fetch_time": datetime.now().isoformat()
        }
    
    def get_regime(self, percentile):
        """Determine regime from percentile"""
        if percentile < 20:
            return "VERY_BULLISH"
        elif percentile < 40:
            return "BULLISH"
        elif percentile > 80:
            return "VERY_BEARISH"
        elif percentile > 60:
            return "BEARISH"
        else:
            return "NEUTRAL"


# ============================================================
# FLASK ENDPOINT
# ============================================================

# Initialize manager (do this once when app starts)
cot_manager = COTDataManager()


def register_cot_routes(app):
    """Register COT endpoints with Flask app"""
    
    @app.route('/cot_data', methods=['GET'])
    def get_cot_data():
        """
        Returns COT data for Gold futures
        
        Response format:
        {
            "managed_money_long": 250000,
            "managed_money_short": 80000,
            "managed_money_net": 170000,
            "managed_money_net_change": 5000,
            "commercial_net": -150000,
            "open_interest": 500000,
            "percentile_net": 65.5,
            "report_date": "2025-12-02",
            "regime": "BEARISH",
            "source": "QUANDL"
        }
        """
        try:
            data = cot_manager.fetch_cot_data()
            
            if data:
                # Add regime to response
                data["regime"] = cot_manager.get_regime(data.get("percentile_net", 50))
                return jsonify(data)
            else:
                return jsonify({"error": "No COT data available"}), 500
                
        except Exception as e:
            return jsonify({"error": str(e)}), 500
    
    @app.route('/cot_status', methods=['GET'])
    def get_cot_status():
        """Returns COT service status"""
        return jsonify({
            "service": "COT Data Service",
            "status": "online",
            "last_fetch": cot_manager.last_fetch.isoformat() if cot_manager.last_fetch else None,
            "cache_valid": cot_manager.cache is not None,
            "history_weeks": cot_manager.history_weeks
        })
    
    @app.route('/cot_history', methods=['GET'])
    def get_cot_history():
        """Returns historical COT data"""
        try:
            conn = sqlite3.connect(cot_manager.db_path)
            cursor = conn.cursor()
            
            cursor.execute('''
                SELECT report_date, managed_money_net, percentile_net 
                FROM cot_history 
                ORDER BY report_date DESC 
                LIMIT 52
            ''')
            
            rows = cursor.fetchall()
            conn.close()
            
            history = []
            for row in rows:
                history.append({
                    "date": row[0],
                    "net": row[1],
                    "percentile": cot_manager._calculate_percentile(row[1], [r[1] for r in rows])
                })
            
            return jsonify({"history": history})
            
        except Exception as e:
            return jsonify({"error": str(e)}), 500


# ============================================================
# INTEGRATION WITH EXISTING APP
# ============================================================

"""
To integrate with your existing VPS Flask app, add:

1. In your main app.py:

    from cot_service import register_cot_routes, cot_manager
    
    # After creating Flask app
    register_cot_routes(app)

2. Set environment variable for Quandl API key:
    
    export QUANDL_API_KEY="your_free_api_key"
    
    Get free key at: https://data.nasdaq.com/sign-up

3. The endpoint will be available at:
    
    http://your-vps-ip:5000/cot_data

4. COT data updates weekly (Friday for Tuesday positions)
   The service caches data for 6 hours to avoid excessive API calls
"""


# ============================================================
# STANDALONE TEST
# ============================================================

if __name__ == "__main__":
    # Test the COT fetcher
    print("Testing COT Data Manager...")
    
    manager = COTDataManager()
    data = manager.fetch_cot_data()
    
    if data:
        print(f"\nCOT Data Retrieved:")
        print(f"  Managed Money Net: {data.get('managed_money_net', 0):,.0f}")
        print(f"  Net Change: {data.get('managed_money_net_change', 0):,.0f}")
        print(f"  Percentile: {data.get('percentile_net', 0):.1f}%")
        print(f"  Regime: {manager.get_regime(data.get('percentile_net', 50))}")
        print(f"  Report Date: {data.get('report_date')}")
        print(f"  Source: {data.get('source')}")
    else:
        print("Failed to fetch COT data")
