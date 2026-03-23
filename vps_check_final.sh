#!/usr/bin/env bash
# =============================================================================
# vps_check_final.sh — Gold ML VPS Health Check
# Services : gold-ml-monitor.service (port 5000) + gold_intelligence.service (port 5002)
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
    local state
    state=$(systemctl show -p ActiveState --value "$svc" 2>/dev/null || echo "unknown")
    if [[ "$state" == "active" ]]; then
        ok "Service $svc — ACTIVE"
        return 0
    else
        fail "Service $svc — ${state^^} (état: $state)"
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

service_status "gold-ml-monitor.service"
service_status "gold_intelligence.service"

# ── 2. Ports ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  2. PORTS"
echo "════════════════════════════════════════════════════════"

port_listen 5000 "gold-ml-monitor / gunicorn"
port_listen 5002 "gold_intelligence.py"

# ── 3. Health endpoints ───────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  3. HEALTH ENDPOINTS"
echo "════════════════════════════════════════════════════════"

http_check "http://localhost:5000/health" "goldml-api health" "status"

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

# Vérification port 5002
if ss -tlnp 2>/dev/null | grep -q ":5002 "; then
    ok "Port 5002 (gold_intelligence) — LISTENING"
else
    fail "Port 5002 (gold_intelligence) — NOT LISTENING"
    ERRORS=$((ERRORS + 1))
fi

SIG_BODY=$(curl -s --max-time 10 \
    "http://localhost:5002/gold_intelligence/quick" 2>/dev/null || echo "")

if [[ -z "$SIG_BODY" ]]; then
    warn "Signal endpoint timeout (port 5002 not responding — may need restart)"
    WARNINGS=$((WARNINGS + 1))
elif echo "$SIG_BODY" | grep -q '"can_trade"'; then
    DIRECTION=$(echo "$SIG_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('direction','?'))" 2>/dev/null || echo "?")
    CONFIDENCE=$(echo "$SIG_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('confidence','?'))" 2>/dev/null || echo "?")
    CAN_TRADE=$(echo "$SIG_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('can_trade','?'))" 2>/dev/null || echo "?")
    GOLD_PRICE=$(echo "$SIG_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('gold_price','?'))" 2>/dev/null || echo "?")
    ok "Signal: direction=$DIRECTION confidence=$CONFIDENCE can_trade=$CAN_TRADE gold=\$${GOLD_PRICE}"
    echo ""
    echo -e "  📊 ${YELLOW}Gold Price${NC}: \$${GOLD_PRICE}"
    echo -e "  📈 ${YELLOW}Confidence${NC}: ${CONFIDENCE}"
    echo -e "  🧭 ${YELLOW}Direction${NC} : ${DIRECTION}"
    echo -e "  🔁 ${YELLOW}Can Trade${NC} : ${CAN_TRADE}"
else
    fail "Signal endpoint returned unexpected body: $(echo "$SIG_BODY" | head -c 120)"
    ERRORS=$((ERRORS + 1))
fi

# ── 6. Signal freshness (cache age) ──────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  6. CACHE FRESHNESS"
echo "════════════════════════════════════════════════════════"

CACHE_BODY=$(curl -s --max-time 10 "http://localhost:5002/gold_intelligence/health" 2>/dev/null || echo "")
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

# ── 9. VPS HEALTH ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  9. VPS HEALTH"
echo "════════════════════════════════════════════════════════"

# Uptime
UPTIME_STR=$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | sed 's/,.*load.*//')
ok "Uptime: $UPTIME_STR"

# Mémoire utilisée
MEM_INFO=$(free -h 2>/dev/null | awk '/^Mem:/{printf "used %s / %s (%s free)", $3, $2, $4}')
MEM_PCT=$(free 2>/dev/null | awk '/^Mem:/{printf "%.0f", $3/$2*100}')
if [[ -n "$MEM_PCT" ]]; then
    if [[ "$MEM_PCT" -lt 80 ]]; then
        ok "Mémoire: $MEM_INFO (${MEM_PCT}%)"
    elif [[ "$MEM_PCT" -lt 90 ]]; then
        warn "Mémoire: $MEM_INFO (${MEM_PCT}%) — attention"
        WARNINGS=$((WARNINGS + 1))
    else
        fail "Mémoire: $MEM_INFO (${MEM_PCT}%) — CRITIQUE"
        ERRORS=$((ERRORS + 1))
    fi
else
    warn "Impossible de lire la mémoire"
    WARNINGS=$((WARNINGS + 1))
fi

# Taille des logs systemd (journalctl)
JOURNAL_USAGE=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]i?B?' | head -1 || echo "N/A")
if [[ "$JOURNAL_USAGE" != "N/A" ]]; then
    ok "Journalctl disk usage: $JOURNAL_USAGE"
else
    warn "Impossible de lire la taille des journaux systemd"
    WARNINGS=$((WARNINGS + 1))
fi

# Taille de /var/log/
VARLOG_SIZE=$(du -sh /var/log/ 2>/dev/null | awk '{print $1}')
if [[ -n "$VARLOG_SIZE" ]]; then
    ok "/var/log/ size: $VARLOG_SIZE"
else
    warn "Impossible de lire la taille de /var/log/"
    WARNINGS=$((WARNINGS + 1))
fi

# Vérification logrotate actif
LOGROTATE_OK=false
if systemctl is-active logrotate.timer &>/dev/null; then
    ok "Logrotate timer: actif (systemd timer)"
    LOGROTATE_OK=true
elif [[ -f /etc/cron.daily/logrotate ]]; then
    ok "Logrotate: actif (cron.daily)"
    LOGROTATE_OK=true
elif crontab -l 2>/dev/null | grep -q "logrotate"; then
    ok "Logrotate: actif (crontab utilisateur)"
    LOGROTATE_OK=true
fi

if [[ "$LOGROTATE_OK" == false ]]; then
    warn "Logrotate: aucune rotation automatique détectée — risque de saturation disque"
    WARNINGS=$((WARNINGS + 1))
fi

# Dernière exécution logrotate
LAST_LOGROTATE=$(ls -lt /var/lib/logrotate/status 2>/dev/null | awk '{print $6, $7, $8}')
if [[ -n "$LAST_LOGROTATE" ]]; then
    ok "Dernier logrotate status: $LAST_LOGROTATE"
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
