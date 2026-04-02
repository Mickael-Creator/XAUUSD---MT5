#!/usr/bin/env bash
# ============================================================
#  GoldML Daily Dashboard — check_goldml.sh
#  One-command health check with color-coded output
# ============================================================
set -euo pipefail

# --- Must run as root (auto-escalate via sudo) ---------------
if [ "$(whoami)" != "root" ]; then
    exec sudo "$0" "$@"
fi

# --- Colors & symbols ----------------------------------------
R='\033[0;31m'   G='\033[0;32m'   Y='\033[0;33m'
B='\033[0;34m'   C='\033[0;36m'   W='\033[1;37m'
DIM='\033[2m'    BOLD='\033[1m'   RST='\033[0m'

ok="${G}✔${RST}"  ko="${R}✘${RST}"  warn="${Y}⚠${RST}"

line()  { printf "${DIM}%-60s${RST}\n" | tr ' ' '─'; }
hdr()   { printf "\n${BOLD}${B}━━ %s ${RST}\n" "$1"; line; }
field() { printf "  ${C}%-22s${RST} %b\n" "$1" "$2"; }

# --- Config --------------------------------------------------
TOKEN="GoldML_2026_SecureToken_XK9!!!"
BASE="http://localhost:5002"
ALERT_LOG="/var/log/goldml_alerts.log"
INTEL_LOG="/root/gold_ml_phase4/logs/gold_intelligence.log"

# ============================================================
#  1. Service Status
# ============================================================
hdr "1 · SERVICE gold_intelligence"

if systemctl is-active --quiet gold_intelligence.service 2>/dev/null; then
    field "Status" "${ok} ${G}active (running)${RST}"
    uptime_raw=$(systemctl show gold_intelligence.service --property=ActiveEnterTimestamp --value 2>/dev/null || true)
    if [[ -n "$uptime_raw" ]]; then
        up_epoch=$(date -d "$uptime_raw" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        up_secs=$(( now_epoch - up_epoch ))
        up_h=$(( up_secs / 3600 ))
        up_m=$(( (up_secs % 3600) / 60 ))
        field "Uptime" "${up_h}h ${up_m}m"
    fi
else
    field "Status" "${ko} ${R}DOWN / CRASHED${RST}"
    # Show last journal lines for diagnosis
    journalctl -u gold_intelligence.service -n 3 --no-pager 2>/dev/null | while IFS= read -r l; do
        printf "  ${DIM}%s${RST}\n" "$l"
    done
fi

pid=$(pgrep -f "gold_intelligence.py" 2>/dev/null | head -1 || true)
if [[ -n "$pid" ]]; then
    mem=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.0f", $1/1024}')
    cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | xargs)
    field "PID / Mem / CPU" "${pid}  /  ${mem} MB  /  ${cpu}%"
fi

# ============================================================
#  2. Signal (Claude + Sniper)
# ============================================================
hdr "2 · SIGNAL ACTUEL"

sig=$(curl -sf -H "Authorization: Bearer ${TOKEN}" "${BASE}/v1/news_trading_signal/quick" 2>/dev/null || echo "")

if [[ -z "$sig" ]]; then
    field "Signal" "${ko} ${R}Unreachable${RST}"
else
    val()  { echo "$sig" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$1','—'))" 2>/dev/null; }

    dir=$(val direction)
    conf=$(val confidence)
    bias=$(val bias)
    can=$(val can_trade)
    price=$(val gold_price)
    timing=$(val timing_mode)
    tp_mode=$(val tp_mode)
    ts=$(val timestamp)
    error=$(val error)

    # Direction color
    case "$dir" in
        BUY)  dir_c="${G}${BOLD}▲ BUY${RST}" ;;
        SELL) dir_c="${R}${BOLD}▼ SELL${RST}" ;;
        *)    dir_c="${Y}— ${dir}${RST}" ;;
    esac

    # Confidence color
    conf_int=${conf%.*}
    if   (( conf_int >= 70 )); then conf_c="${G}${conf}%${RST}"
    elif (( conf_int >= 50 )); then conf_c="${Y}${conf}%${RST}"
    else                            conf_c="${R}${conf}%${RST}"
    fi

    # can_trade color
    [[ "$can" == "True" ]] && can_c="${ok} ${G}Yes${RST}" || can_c="${ko} ${R}No${RST}"

    field "Direction"  "$dir_c"
    field "Confidence" "$conf_c"
    field "Bias"       "$bias"
    field "Can Trade"  "$can_c"
    field "Gold Price"  "\$${price}"
    field "Timing"     "${timing} / TP=${tp_mode}"
    field "Timestamp"  "${DIM}${ts}${RST}"
    [[ "$error" != "None" && "$error" != "—" ]] && field "Error" "${R}${error}${RST}"

    # --- Claude enrichment ---
    printf "\n  ${W}Claude Enrichment${RST}\n"
    claude_en=$(val claude_enriched)
    [[ "$claude_en" == "True" ]] && field "Enriched" "${ok} ${G}Yes${RST}" || field "Enriched" "${ko} ${R}No${RST}"
    field "Quality"       "$(val claude_signal_quality)"
    field "Confidence Adj" "$(val claude_confidence_adj)"
    field "Commentary"    "${DIM}$(val claude_commentary)${RST}"

    risks=$(echo "$sig" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for r in d.get('claude_risk_flags',[]):
    print(f'    ${Y}⚡ {r}${RST}')
" 2>/dev/null || true)
    if [[ -n "$risks" ]]; then
        printf "  ${C}%-22s${RST}\n" "Risk Flags"
        echo -e "$risks"
    fi

    # --- Sniper --- LOCAL to EA since 2026-04-02
    printf "\n  ${W}Sniper ICT${RST}\n"
    field "Mode"      "${ok} ${G}LOCAL (CSniperM15 dans EA MT5)${RST}"
    field "Moved on"  "2026-04-02 — sniper_* fields removed from VPS"
    field "Analysis"  "Sweep + BOS + Fib + M5 pattern"
    field "Min score" "60/100"
fi

# ============================================================
#  3. Market Data Age
# ============================================================
hdr "3 · MARKET DATA (M15 / M5)"

health=$(curl -sf "${BASE}/v1/health" 2>/dev/null || echo "")

if [[ -z "$health" ]]; then
    field "Health endpoint" "${ko} ${R}Unreachable${RST}"
else
    for tf in m15 m5; do
        key="market_data_${tf}"
        age=$(echo "$health" | python3 -c "import sys,json; print(json.load(sys.stdin)['market_data']['${key}']['age_s'])" 2>/dev/null || echo "?")
        has=$(echo "$health" | python3 -c "import sys,json; print(json.load(sys.stdin)['market_data']['${key}']['has_data'])" 2>/dev/null || echo "?")

        if [[ "$has" != "True" ]]; then
            field "${tf^^}" "${ko} ${R}No data${RST}"
        elif [[ "$age" == "?" ]]; then
            field "${tf^^}" "${warn} ${Y}Unknown${RST}"
        else
            if   (( age < 120  )); then age_c="${ok} ${G}${age}s${RST}"
            elif (( age < 600  )); then age_c="${warn} ${Y}${age}s${RST}"
            else                        age_c="${ko} ${R}${age}s (stale)${RST}"
            fi
            field "${tf^^} age" "$age_c"
        fi
    done
fi

# ============================================================
#  4. Claude Tokens & Cost (last 24h)
# ============================================================
hdr "4 · CLAUDE TOKENS (last 24h)"

if [[ -f "$INTEL_LOG" ]]; then
    since=$(date -d '24 hours ago' '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
    # Extract token lines from today/yesterday
    token_lines=$(grep "Tokens: in=" "$INTEL_LOG" 2>/dev/null | grep "^${since}\|^$(date '+%Y-%m-%d')" || true)

    if [[ -z "$token_lines" ]]; then
        # Fallback: take all token lines from file (may span multiple days)
        token_lines=$(grep "Tokens: in=" "$INTEL_LOG" 2>/dev/null | tail -200 || true)
    fi

    if [[ -n "$token_lines" ]]; then
        stats=$(echo "$token_lines" | python3 -c "
import sys, re
calls = 0; t_in = 0; t_out = 0; t_cost = 0.0
for line in sys.stdin:
    m = re.search(r'in=(\d+)\s+out=(\d+)\s+\|\s+~\\\$([0-9.]+)', line)
    if m:
        calls += 1
        t_in  += int(m.group(1))
        t_out += int(m.group(2))
        t_cost += float(m.group(3))
print(f'{calls}|{t_in}|{t_out}|{t_cost:.4f}')
" 2>/dev/null || echo "")

        if [[ -n "$stats" ]]; then
            IFS='|' read -r calls t_in t_out t_cost <<< "$stats"
            field "API Calls" "${calls}"
            field "Input tokens"  "${t_in}"
            field "Output tokens" "${t_out}"

            cost_f=$(echo "$t_cost" | awk '{printf "%.4f", $1}')
            if (( $(echo "$t_cost > 1.0" | bc -l 2>/dev/null || echo 0) )); then
                cost_c="${R}\$${cost_f}${RST}"
            elif (( $(echo "$t_cost > 0.3" | bc -l 2>/dev/null || echo 0) )); then
                cost_c="${Y}\$${cost_f}${RST}"
            else
                cost_c="${G}\$${cost_f}${RST}"
            fi
            field "Est. cost" "$cost_c"
        else
            field "Tokens" "${DIM}Parse error${RST}"
        fi
    else
        field "Tokens" "${DIM}No Claude calls in last 24h${RST}"
    fi
else
    field "Log" "${warn} ${Y}${INTEL_LOG} not found${RST}"
fi

# ============================================================
#  5. Active Alerts (goldml_alerts.log)
# ============================================================
hdr "5 · ALERTES ACTIVES"

if [[ -f "$ALERT_LOG" ]]; then
    today=$(date '+%Y-%m-%d')
    today_alerts=$(grep "^${today}" "$ALERT_LOG" 2>/dev/null || true)

    if [[ -z "$today_alerts" ]]; then
        field "Today" "${ok} ${G}No alerts${RST}"
    else
        crit_n=$(echo "$today_alerts" | grep -c "CRITICAL" || true)
        err_n=$(echo "$today_alerts" | grep -c "ERROR" || true)
        warn_n=$(echo "$today_alerts" | grep -c "WARNING" || true)

        (( crit_n > 0 )) && field "CRITICAL" "${ko} ${R}${crit_n}${RST}"
        (( err_n  > 0 )) && field "ERROR"    "${warn} ${Y}${err_n}${RST}"
        (( warn_n > 0 )) && field "WARNING"  "${DIM}${warn_n}${RST}"

        # Show last 5 alerts
        printf "\n  ${DIM}Last alerts:${RST}\n"
        echo "$today_alerts" | tail -5 | while IFS= read -r l; do
            if   echo "$l" | grep -q "CRITICAL"; then color="$R"
            elif echo "$l" | grep -q "ERROR";    then color="$Y"
            else                                       color="$DIM"
            fi
            printf "  ${color}%s${RST}\n" "$l"
        done
    fi
else
    field "Alert log" "${warn} ${Y}${ALERT_LOG} not found${RST}"
fi

# ============================================================
#  6. Health Check Complet
# ============================================================
hdr "6 · HEALTH CHECK COMPLET"

if [[ -n "$health" ]]; then
    status=$(echo "$health" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "?")
    warmup=$(echo "$health" | python3 -c "import sys,json; print(json.load(sys.stdin)['warmup_done'])" 2>/dev/null || echo "?")
    sig_age=$(echo "$health" | python3 -c "import sys,json; print(json.load(sys.stdin)['signal_age_s'])" 2>/dev/null || echo "?")

    if [[ "$status" == "healthy" ]]; then
        field "Status" "${ok} ${G}HEALTHY${RST}"
    else
        field "Status" "${ko} ${R}${status^^}${RST}"
    fi

    [[ "$warmup" == "True" ]] && field "Warmup" "${ok} ${G}Done${RST}" || field "Warmup" "${warn} ${Y}In progress${RST}"

    if [[ "$sig_age" != "?" ]]; then
        if   (( sig_age < 60  )); then sa_c="${ok} ${G}${sig_age}s${RST}"
        elif (( sig_age < 120 )); then sa_c="${warn} ${Y}${sig_age}s${RST}"
        else                           sa_c="${ko} ${R}${sig_age}s (stale)${RST}"
        fi
        field "Signal age" "$sa_c"
    fi
else
    field "Health" "${ko} ${R}Endpoint unreachable${RST}"
fi

# --- Footer --------------------------------------------------
printf "\n${DIM}─── GoldML Dashboard · $(date '+%Y-%m-%d %H:%M:%S %Z') ───${RST}\n\n"
