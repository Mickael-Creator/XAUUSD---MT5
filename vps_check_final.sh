#!/usr/bin/env bash
# =============================================================================
# vps_check_final.sh — Gold ML VPS Health Check
# Services : goldml-api.service (port 5000) + gold_intelligence.service (port 5002)
# Usage    : bash vps_check_final.sh [--json]
# =============================================================================

set -uo pipefail

# ── Couleurs ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

JSON_MODE=false
[[ "${1:-}" == "--json" ]] && JSON_MODE=true

ERRORS=0
WARNINGS=0

# ── Helpers ───────────────────────────────────────────────────────────────────
service_status() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ok "Service $svc — ACTIVE"
        return 0
    else
        fail "Service $svc — INACTIVE"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
}

port_listen() {
    local port="$1" label="$2"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        ok "Port $port ($label) — LISTENING"
    else
        fail "Port $port ($label) — NOT LISTENING"
        ERRORS=$((ERRORS + 1))
    fi
}

http_check() {
    local url="$1" label="$2" expected_field="${3:-}"
    local http_code body
    body=$(curl -s -o /tmp/_vps_check_body -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    http_code="$body"
    body=$(cat /tmp/_vps_check_body 2>/dev/null || echo "")

    if [[ "$http_code" == "200" ]]; then
        if [[ -n "$expected_field" ]]; then
            if echo "$body" | grep -q "\"${expected_field}\""; then
                ok "HTTP $url — $http_code, field '$expected_field' present"
            else
                warn "HTTP $url — $http_code but field '$expected_field' missing in response"
                WARNINGS=$((WARNINGS + 1))
            fi
        else
            ok "HTTP $url — $http_code ($label)"
        fi
    else
        fail "HTTP $url — $http_code ($label)"
        ERRORS=$((ERRORS + 1))
    fi
}

# ── 1. Systemd services ───────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  1. SYSTEMD SERVICES"
echo "════════════════════════════════════════════════════════"

service_status "goldml-api.service"
service_status "gold_intelligence.service"
service_status "nginx"

# ── 2. Ports ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  2. PORTS"
echo "════════════════════════════════════════════════════════"

port_listen 5000 "goldml-api / backend_api.py"
port_listen 5002 "gold_intelligence.py"
port_listen 80   "nginx HTTP"
port_listen 443  "nginx HTTPS"

# ── 3. Health endpoints ───────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  3. HEALTH ENDPOINTS"
echo "════════════════════════════════════════════════════════"

http_check "http://localhost:5000/health"    "goldml-api legacy health"  "status"
http_check "http://localhost:5000/v1/health" "goldml-api v1 health"      "status"
http_check "http://localhost:5002/v1/health" "gold_intelligence health"  "status"

# ── 4. Internal data endpoints (used by gold_intelligence.py) ─────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  4. INTERNAL DATA ENDPOINTS (localhost)"
echo "════════════════════════════════════════════════════════"

http_check "http://localhost:5000/dxy_data"   "DXY feed"    "dxy_index"
http_check "http://localhost:5000/vix_data"   "VIX feed"    "vix_level"
http_check "http://localhost:5000/macro_data" "Macro feed"  "us10y"

# ── 5. Signal endpoint ────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  5. SIGNAL ENDPOINT"
echo "════════════════════════════════════════════════════════"

API_TOKEN="${API_TOKEN:-}"
if [[ -z "$API_TOKEN" ]]; then
    warn "API_TOKEN not set — skipping authenticated signal check"
    WARNINGS=$((WARNINGS + 1))
else
    SIG_BODY=$(curl -s --max-time 5 \
        -H "Authorization: Bearer ${API_TOKEN}" \
        "http://localhost:5002/news_trading_signal/quick" 2>/dev/null || echo "")

    if echo "$SIG_BODY" | grep -q '"can_trade"'; then
        DIRECTION=$(echo "$SIG_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('direction','?'))" 2>/dev/null || echo "?")
        CONFIDENCE=$(echo "$SIG_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('confidence','?'))" 2>/dev/null || echo "?")
        CAN_TRADE=$(echo "$SIG_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('can_trade','?'))" 2>/dev/null || echo "?")
        ok "Signal: direction=$DIRECTION confidence=$CONFIDENCE can_trade=$CAN_TRADE"
    else
        fail "Signal endpoint returned unexpected body"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ── 6. Signal freshness (cache age) ──────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  6. CACHE FRESHNESS"
echo "════════════════════════════════════════════════════════"

CACHE_BODY=$(curl -s --max-time 5 "http://localhost:5002/gold_intelligence/health" 2>/dev/null || echo "")
if echo "$CACHE_BODY" | grep -q '"signal_age_s"'; then
    AGE=$(echo "$CACHE_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('signal_age_s',999))" 2>/dev/null || echo "999")
    if [[ "$AGE" -le 60 ]]; then
        ok "Signal cache age: ${AGE}s (fresh)"
    elif [[ "$AGE" -le 300 ]]; then
        warn "Signal cache age: ${AGE}s (stale > 60s)"
        WARNINGS=$((WARNINGS + 1))
    else
        fail "Signal cache age: ${AGE}s (stale > 5min)"
        ERRORS=$((ERRORS + 1))
    fi
else
    warn "Could not read signal cache age from gold_intelligence"
    WARNINGS=$((WARNINGS + 1))
fi

# ── 7. Disk space ─────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  7. DISK SPACE"
echo "════════════════════════════════════════════════════════"

DISK_PCT=$(df /root 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
if [[ -n "$DISK_PCT" ]]; then
    if [[ "$DISK_PCT" -lt 80 ]]; then
        ok "Disk /root: ${DISK_PCT}% used"
    elif [[ "$DISK_PCT" -lt 90 ]]; then
        warn "Disk /root: ${DISK_PCT}% used (approaching limit)"
        WARNINGS=$((WARNINGS + 1))
    else
        fail "Disk /root: ${DISK_PCT}% used (CRITICAL)"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ── 8. No monitor_vps.sh in cron (doublon dangereux) ─────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  8. CRON SAFETY (doublon watchdog)"
echo "════════════════════════════════════════════════════════"

if crontab -l 2>/dev/null | grep -q "monitor_vps.sh"; then
    fail "monitor_vps.sh trouvé dans crontab — doublon avec Restart=always (supprimer avec: crontab -e)"
    ERRORS=$((ERRORS + 1))
else
    ok "monitor_vps.sh absent du crontab"
fi

# ── Résumé ────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  RÉSUMÉ"
echo "════════════════════════════════════════════════════════"

if [[ "$ERRORS" -eq 0 && "$WARNINGS" -eq 0 ]]; then
    echo -e "${GREEN}✓ Tout est nominal — 0 erreurs, 0 alertes${NC}"
elif [[ "$ERRORS" -eq 0 ]]; then
    echo -e "${YELLOW}⚠ $WARNINGS alerte(s) — aucune erreur critique${NC}"
else
    echo -e "${RED}✗ $ERRORS erreur(s), $WARNINGS alerte(s)${NC}"
fi

echo ""
exit "$ERRORS"
