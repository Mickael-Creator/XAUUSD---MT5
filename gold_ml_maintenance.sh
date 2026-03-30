#!/usr/bin/env bash
# =============================================================================
# gold_ml_maintenance.sh — Gold ML Routine Maintenance
# Services : goldml-api.service (port 5000) + gold_intelligence.service (port 5002)
# Usage    : bash gold_ml_maintenance.sh
# Cron     : 0 3 * * 0  /root/gold_ml_phase4/gold_ml_maintenance.sh >> /var/log/gold_ml_maintenance.log 2>&1
# =============================================================================

set -euo pipefail

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG_DIR="/root/gold_ml_phase4/logs"
DB_PATH="/root/gold_ml_phase4/gold_intelligence.db"
SIGNALS_DIR="/root/gold_ml_phase4/signals"

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Gold ML Maintenance — ${TIMESTAMP}"
echo "════════════════════════════════════════════════════════"

# ── 1. Rotation des logs applicatifs (> 50 MB → archive + truncate) ───────────
echo ""
echo "[ 1/6 ] Rotation des logs applicatifs"

rotate_log() {
    local logfile="$1"
    if [[ -f "$logfile" ]]; then
        local size
        size=$(du -sm "$logfile" 2>/dev/null | cut -f1)
        if [[ "$size" -gt 50 ]]; then
            local archive="${logfile}.$(date '+%Y%m%d_%H%M%S').gz"
            gzip -c "$logfile" > "$archive"
            truncate -s 0 "$logfile"
            echo "  Rotated: $logfile → $archive (était ${size}MB)"
        else
            echo "  OK: $logfile (${size}MB, pas de rotation)"
        fi
    fi
}

rotate_log "${LOG_DIR}/gold_intelligence.log"
rotate_log "/var/log/gold_ml_backend.log"
rotate_log "/var/log/nginx/goldml_api_access.log"

# Garder les archives de moins de 30 jours, supprimer les plus vieilles
find "${LOG_DIR}" -name "*.gz" -mtime +30 -delete 2>/dev/null && echo "  Archives > 30j supprimées" || true

# ── 2. Nettoyage des signaux obsolètes ───────────────────────────────────────
echo ""
echo "[ 2/6 ] Nettoyage des fichiers signal obsolètes"

if [[ -d "$SIGNALS_DIR" ]]; then
    OLD_COUNT=$(find "$SIGNALS_DIR" -name "*.json" -mtime +7 2>/dev/null | wc -l)
    find "$SIGNALS_DIR" -name "*.json" -mtime +7 -delete 2>/dev/null || true
    echo "  $OLD_COUNT fichiers signal > 7j supprimés"
else
    echo "  Dossier signals absent — skip"
fi

# ── 3. Vacuum de la base SQLite ───────────────────────────────────────────────
echo ""
echo "[ 3/6 ] Vacuum SQLite (gold_intelligence.db)"

if [[ -f "$DB_PATH" ]]; then
    SIZE_BEFORE=$(du -sm "$DB_PATH" | cut -f1)
    sqlite3 "$DB_PATH" "VACUUM;" 2>/dev/null && \
        echo "  Vacuum OK (avant: ${SIZE_BEFORE}MB → après: $(du -sm "$DB_PATH" | cut -f1)MB)" || \
        echo "  Vacuum échoué (DB peut être verrouillée)"
else
    echo "  DB absente — skip"
fi

# ── 4. Vérification de l'état des services ────────────────────────────────────
echo ""
echo "[ 4/6 ] État des services systemd"

check_service() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        local uptime
        uptime=$(systemctl show "$svc" --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2 || echo "inconnu")
        echo "  OK: $svc — ACTIVE (depuis: $uptime)"
    else
        echo "  FAIL: $svc — INACTIVE — tentative de redémarrage"
        systemctl start "$svc" 2>/dev/null && \
            echo "  Redémarrage $svc OK" || \
            echo "  Redémarrage $svc ÉCHEC — intervention manuelle requise"
    fi
}

check_service "goldml-api.service"
check_service "gold_intelligence.service"
check_service "nginx"

# ── 5. Vérification du cron (doublon watchdog) ────────────────────────────────
echo ""
echo "[ 5/6 ] Vérification cron (doublon monitor_vps.sh)"

if crontab -l 2>/dev/null | grep -q "monitor_vps.sh"; then
    echo "  WARN: monitor_vps.sh présent dans crontab — doublon avec Restart=always"
    echo "        Supprimer avec: crontab -e"
else
    echo "  OK: monitor_vps.sh absent du crontab"
fi

# ── 6. Espace disque ──────────────────────────────────────────────────────────
echo ""
echo "[ 6/6 ] Espace disque"

DISK_PCT=$(df /root 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
DISK_AVAIL=$(df -h /root 2>/dev/null | awk 'NR==2{print $4}')
echo "  /root: ${DISK_PCT}% utilisé, ${DISK_AVAIL} disponible"
if [[ "$DISK_PCT" -gt 85 ]]; then
    echo "  WARN: espace disque critique (> 85%)"
fi

# ── Résumé ────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Maintenance terminée — $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════════════════"
echo ""
