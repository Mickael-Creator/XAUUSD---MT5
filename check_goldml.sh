#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# check_goldml.sh — Gold Intelligence v2.0 FTMO Dashboard
# Usage: bash ~/check_goldml.sh
# ═══════════════════════════════════════════════════════════════

# ── Colors ───────────────────────────────────────────────────
G='\033[0;32m'   R='\033[0;31m'   Y='\033[1;33m'
B='\033[0;34m'   C='\033[0;36m'   W='\033[1;37m'
D='\033[0;90m'   N='\033[0m'
BG_G='\033[42;30m'  BG_R='\033[41;37m'

API="http://127.0.0.1:5002"
NOW_UTC=$(date -u '+%Y-%m-%d %H:%M:%S')
H_UTC=$((10#$(date -u '+%H')))
M_UTC=$((10#$(date -u '+%M')))

# ── Fetch data once ──────────────────────────────────────────
SIG_JSON=$(curl -s --connect-timeout 3 "$API/news_trading_signal" 2>/dev/null)
HEALTH_JSON=$(curl -s --connect-timeout 3 "$API/v1/health" 2>/dev/null)

clear
echo -e "${B}+============================================================+${N}"
echo -e "${B}|${W}       GOLD INTELLIGENCE v2.0 -- FTMO DASHBOARD             ${B}|${N}"
echo -e "${B}|${D}       $NOW_UTC UTC                                ${B}|${N}"
echo -e "${B}+============================================================+${N}"
echo ""

# ══════════════════════════════════════════════════════════════
# 1. SERVICES VPS
# ══════════════════════════════════════════════════════════════
echo -e "${Y}=== 1. SERVICES VPS ============================================${N}"

ALL_SVC_OK=true
for svc in gold_intelligence gold-ml-monitor dxy_fetcher gold-automation-bridge; do
    case "$svc" in
        gold_intelligence)      desc="Gold Intelligence (API+Signal)" ;;
        gold-ml-monitor)        desc="Calendar Monitor              " ;;
        dxy_fetcher)            desc="DXY Fetcher                   " ;;
        gold-automation-bridge) desc="Automation Bridge              " ;;
    esac

    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        start_ts=$(systemctl show "$svc" --property=ActiveEnterTimestamp --value 2>/dev/null)
        if [ -n "$start_ts" ]; then
            s_epoch=$(date -d "$start_ts" +%s 2>/dev/null || echo 0)
            elapsed=$(( $(date +%s) - s_epoch ))
            printf -v up_str "%dh%02dm" $((elapsed/3600)) $(((elapsed%3600)/60))
        else
            up_str="?"
        fi
        extra=""
        if [ "$svc" = "gold_intelligence" ]; then
            pid=$(systemctl show "$svc" --property=MainPID --value 2>/dev/null)
            mem=$(systemctl show "$svc" --property=MemoryCurrent --value 2>/dev/null)
            if [ -n "$mem" ] && [ "$mem" != "[not set]" ] && [ "$mem" -gt 0 ] 2>/dev/null; then
                mem_mb=$(( mem / 1048576 ))
                extra=" | PID $pid | ${mem_mb}MB"
            fi
        fi
        echo -e "  ${G}OK${N} $desc ${G}RUNNING${N} ${D}($up_str$extra)${N}"
    else
        echo -e "  ${R}XX${N} $desc ${R}STOPPED${N}"
        ALL_SVC_OK=false
    fi
done
echo -e "  ${D}   Claude Engine: DESACTIVE (\$0/mois) | Python Sniper: DESACTIVE (ICT dans EA)${N}"
echo ""

# ══════════════════════════════════════════════════════════════
# 2. SIGNAL ACTUEL
# ══════════════════════════════════════════════════════════════
echo -e "${Y}=== 2. SIGNAL ACTUEL ============================================${N}"

S_DIR="?"; S_CONF="?"; S_BIAS="?"; S_TRADE="?"; S_GOLD="?"
S_TIMING="?"; S_TP="?"; S_SIZE="?"; S_TS="?"; S_AGE="?"; S_BBO=0

if [ -n "$SIG_JSON" ]; then
    eval "$(echo "$SIG_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
sig_age = d.get('cache_status', {}).get('signal', {}).get('age_s', '?')
print(f'S_DIR={d.get(\"direction\", \"?\")!r}')
print(f'S_CONF={d.get(\"confidence\", \"?\")!r}')
print(f'S_BIAS={d.get(\"bias\", \"?\")!r}')
print(f'S_TRADE={d.get(\"can_trade\", \"?\")!r}')
print(f'S_GOLD={d.get(\"gold_price\", \"?\")!r}')
print(f'S_TIMING={d.get(\"timing_mode\", \"?\")!r}')
print(f'S_TP={d.get(\"tp_mode\", \"?\")!r}')
print(f'S_SIZE={d.get(\"size_factor\", \"?\")!r}')
print(f'S_WIDER={d.get(\"wider_stops\", \"?\")!r}')
print(f'S_TS={d.get(\"timestamp\", \"?\")!r}')
print(f'S_AGE={sig_age!r}')
print(f'S_BBO={d.get(\"blackout_minutes\", 0)!r}')
" 2>/dev/null)"

    # Direction color
    case "$S_DIR" in
        BUY)  dc="${G}" ;;
        SELL) dc="${R}" ;;
        *)    dc="${D}" ;;
    esac

    # Confidence color
    conf_int=${S_CONF%.*}
    if [ "${conf_int:-0}" -ge 70 ] 2>/dev/null; then cc="${G}"
    elif [ "${conf_int:-0}" -ge 50 ] 2>/dev/null; then cc="${Y}"
    else cc="${R}"; fi

    # Can trade
    if [ "$S_TRADE" = "True" ]; then ct_str="${G}YES${N}"
    else ct_str="${R}NO${N}"; fi

    echo -e "  Direction:   ${dc}${S_DIR}${N}"
    echo -e "  Confidence:  ${cc}${S_CONF}%${N}  ${D}(EA floor: 60%)${N}"
    echo -e "  Bias:        ${S_BIAS}"
    echo -e "  Can Trade:   $ct_str"
    echo -e "  Gold Price:  \$${S_GOLD}"
    echo -e "  Timing:      ${S_TIMING}  |  TP: ${S_TP}  |  Size: ${S_SIZE}x"
    echo -e "  Signal age:  ${S_AGE}s"
    echo -e "  ${D}Timestamp:   ${S_TS}${N}"
else
    echo -e "  ${R}XX API ne repond pas sur $API${N}"
fi
echo ""

# ══════════════════════════════════════════════════════════════
# 3. DONNEES MACRO + SCORING
# ══════════════════════════════════════════════════════════════
echo -e "${Y}=== 3. DONNEES MACRO + SCORING ===================================${N}"

if [ -n "$SIG_JSON" ]; then
    echo "$SIG_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
m = d.get('macro', {})
c = d.get('cot', {})
s = d.get('sentiment', {})
g = d.get('geopolitics', {})

total_bull = 0
total_bear = 0

# COT -- 30 pts (seuils: >=70 BULL, <=30 BEAR)
pct = c.get('percentile', 0) or 0
regime = c.get('regime', '?')
if pct >= 70:
    cot_bias, cot_pts, cot_side = 'BULLISH', 30, 'bull'
elif pct <= 30:
    cot_bias, cot_pts, cot_side = 'BEARISH', 30, 'bear'
else:
    cot_bias, cot_pts, cot_side = 'NEUTRAL', 0, None
if cot_side == 'bull': total_bull += cot_pts
elif cot_side == 'bear': total_bear += cot_pts
print(f'  COT:         {pct:>5.1f}% ({regime:15s}) {cot_bias:8s}  {cot_pts:2d}/30 pts')

# DXY -- 20 pts (seuils: <101 BULL, >104 BEAR)
dxy = m.get('dxy', 101.5) or 101.5
if dxy < 101:
    dxy_bias, dxy_pts, dxy_side = 'BULLISH', 20, 'bull'
elif dxy > 104:
    dxy_bias, dxy_pts, dxy_side = 'BEARISH', 20, 'bear'
else:
    dxy_bias, dxy_pts, dxy_side = 'NEUTRAL', 0, None
if dxy_side == 'bull': total_bull += dxy_pts
elif dxy_side == 'bear': total_bear += dxy_pts
print(f'  DXY:         {dxy:>7.2f}                  {dxy_bias:8s}  {dxy_pts:2d}/20 pts')

# Fear & Greed -- 20 pts (seuils: <=30 BULL, >=70 BEAR)
fg = s.get('fear_greed_index', 50) or 50
fl = s.get('fear_greed_label', '?')
if fg <= 30:
    fg_bias, fg_pts, fg_side = 'BULLISH', 20, 'bull'
elif fg >= 70:
    fg_bias, fg_pts, fg_side = 'BEARISH', 20, 'bear'
else:
    fg_bias, fg_pts, fg_side = 'NEUTRAL', 0, None
if fg_side == 'bull': total_bull += fg_pts
elif fg_side == 'bear': total_bear += fg_pts
print(f'  Fear&Greed:  {fg:>3.0f} ({fl:15s})    {fg_bias:8s}  {fg_pts:2d}/20 pts')

# VIX -- 20 pts (high VIX = risk-off = bullish gold)
vix = m.get('vix', 18) or 18
if vix > 25:
    vix_bias, vix_pts, vix_side = 'BULLISH', 20, 'bull'
elif vix < 15:
    vix_bias, vix_pts, vix_side = 'BEARISH', 20, 'bear'
else:
    vix_bias, vix_pts, vix_side = 'NEUTRAL', 0, None
if vix_side == 'bull': total_bull += vix_pts
elif vix_side == 'bear': total_bear += vix_pts
print(f'  VIX:         {vix:>7.1f}                  {vix_bias:8s}  {vix_pts:2d}/20 pts')

# Real Rate -- 15 pts (negative = bullish gold)
rr = m.get('real_rate')
us10y = m.get('us10y', '?')
if rr is None:
    rr = (m.get('us10y', 4.0)) - 2.5
    src = 'fallback'
else:
    src = 'FRED DFII10'
if rr < 0:
    rr_bias, rr_pts, rr_side = 'BULLISH', 15, 'bull'
elif rr > 2.0:
    rr_bias, rr_pts, rr_side = 'BEARISH', 15, 'bear'
else:
    rr_bias, rr_pts, rr_side = 'NEUTRAL', 0, None
if rr_side == 'bull': total_bull += rr_pts
elif rr_side == 'bear': total_bear += rr_pts
print(f'  Real Rate:   {rr:>+6.2f}% (US10Y={us10y}%) {rr_bias:8s}  {rr_pts:2d}/15 pts  [{src}]')

# Geopolitique -- 15 pts (requires confirmation)
gt = g.get('tension_level', 5) or 5
zones = g.get('hot_zones_active', g.get('active_zones', []))
zones_str = ', '.join(zones[:3]) if zones else 'none'
if gt >= 8:
    geo_bias = 'BULLISH'
elif gt <= 3:
    geo_bias = 'BEARISH'
else:
    geo_bias = 'NEUTRAL'

geo_pts = 0
if geo_bias == 'BULLISH' and total_bull > 0:
    geo_pts = 15
    total_bull += 15
elif geo_bias == 'BEARISH' and total_bear > 0:
    geo_pts = 15
    total_bear += 15
confirmed = ' (confirmed)' if geo_pts > 0 else ' (no confirm)'
print(f'  Geopolitique:{gt:>3d}/10 ({zones_str[:20]:20s}) {geo_bias:8s}  {geo_pts:2d}/15 pts{confirmed}')

print(f'  --------------------------------------------------------')
winner = max(total_bull, total_bear)
side = 'BULL' if total_bull >= total_bear else 'BEAR'
print(f'  TOTAL:       BULL {total_bull} / BEAR {total_bear}  =>  {side} {winner} pts (max 120)')
" 2>/dev/null
else
    echo -e "  ${R}XX Pas de donnees macro${N}"
fi
echo ""

# ══════════════════════════════════════════════════════════════
# 4. REASONING (recalcule depuis les biais)
# ══════════════════════════════════════════════════════════════
echo -e "${Y}=== 4. REASONING ================================================${N}"

if [ -n "$SIG_JSON" ]; then
    echo "$SIG_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
m = d.get('macro', {})
c = d.get('cot', {})
s = d.get('sentiment', {})
g = d.get('geopolitics', {})
bias = d.get('bias', '?')
conf = d.get('confidence', 0)

reasons = []
pct = c.get('percentile', 0) or 0
regime = c.get('regime', '?')
if pct >= 70: reasons.append(f'COT: BULLISH (pct {pct:.0f}%, {regime})')
elif pct <= 30: reasons.append(f'COT: BEARISH (pct {pct:.0f}%, {regime})')
else: reasons.append(f'COT: NEUTRAL (pct {pct:.0f}%)')

dxy = m.get('dxy', 101.5) or 101.5
if dxy < 101: reasons.append(f'DXY: BULLISH ({dxy:.1f} < 101 = weak dollar)')
elif dxy > 104: reasons.append(f'DXY: BEARISH ({dxy:.1f} > 104 = strong dollar)')

vix = m.get('vix', 18) or 18
if vix > 25: reasons.append(f'VIX: BULLISH ({vix:.1f} > 25 = risk-off)')
elif vix < 15: reasons.append(f'VIX: BEARISH ({vix:.1f} < 15 = risk-on)')

fg = s.get('fear_greed_index', 50) or 50
if fg <= 30: reasons.append(f'Fear&Greed: BULLISH ({fg:.0f} = extreme fear)')
elif fg >= 70: reasons.append(f'Fear&Greed: BEARISH ({fg:.0f} = extreme greed)')

rr = m.get('real_rate')
if rr is not None:
    if rr < 0: reasons.append(f'Real Rate: BULLISH ({rr:+.2f}% negative)')
    elif rr > 2.0: reasons.append(f'Real Rate: BEARISH ({rr:+.2f}% > 2%)')

gt = g.get('tension_level', 5) or 5
zones = g.get('hot_zones_active', g.get('active_zones', []))
zones_str = ', '.join(zones[:3]) if zones else ''
if gt >= 8: reasons.append(f'Geopolitique: BULLISH (tension {gt}/10 -- {zones_str})')
elif gt <= 3: reasons.append(f'Geopolitique: BEARISH (tension {gt}/10)')

if not reasons:
    reasons.append('Tous les indicateurs sont NEUTRAL')

for i, r in enumerate(reasons[:5], 1):
    print(f'  {i}. {r}')
print(f'  => Final: {bias} @ {conf}% confidence')
" 2>/dev/null
fi
echo ""

# ══════════════════════════════════════════════════════════════
# 5. SESSION GMT
# ══════════════════════════════════════════════════════════════
echo -e "${Y}=== 5. SESSION (GMT) ============================================${N}"
echo -e "  Heure GMT:   ${W}${H_UTC}:$(printf '%02d' $M_UTC)${N}"

LONDON=false; NY=false; OVERLAP=false; TRADING=false

if [ $H_UTC -ge 7 ] && [ $H_UTC -lt 16 ]; then
    LONDON=true; TRADING=true
    remain=$(( (16 - H_UTC) * 60 - M_UTC ))
    echo -e "  London:      ${G}OPEN${N}   07:00-16:00  ${D}(ferme dans ${remain}min)${N}"
else
    if [ $H_UTC -ge 16 ]; then
        opens_in=$(( (24 - H_UTC + 7) * 60 - M_UTC ))
    else
        opens_in=$(( (7 - H_UTC) * 60 - M_UTC ))
    fi
    echo -e "  London:      ${D}CLOSED${N} 07:00-16:00  ${D}(ouvre dans ${opens_in}min)${N}"
fi

if [ $H_UTC -ge 13 ] && [ $H_UTC -lt 21 ]; then
    NY=true; TRADING=true
    remain=$(( (21 - H_UTC) * 60 - M_UTC ))
    echo -e "  New York:    ${G}OPEN${N}   13:00-21:00  ${D}(ferme dans ${remain}min)${N}"
else
    if [ $H_UTC -ge 21 ]; then
        opens_in=$(( (24 - H_UTC + 13) * 60 - M_UTC ))
    else
        opens_in=$(( (13 - H_UTC) * 60 - M_UTC ))
    fi
    echo -e "  New York:    ${D}CLOSED${N} 13:00-21:00  ${D}(ouvre dans ${opens_in}min)${N}"
fi

if [ $H_UTC -ge 13 ] && [ $H_UTC -lt 16 ]; then
    OVERLAP=true
    echo -e "  ${C}** OVERLAP London/NY 13:00-16:00 -- MEILLEURE VOLATILITE **${N}"
fi

if $OVERLAP; then
    echo -e "  Session Boost EA: ${G}OVERLAP +10 pts${N}"
elif $LONDON; then
    echo -e "  Session Boost EA: ${G}LONDON +8 pts${N}"
elif $NY; then
    echo -e "  Session Boost EA: ${G}NEW YORK +5 pts${N}"
else
    echo -e "  Session Boost EA: ${D}OFF (hors session)${N}"
fi

if $TRADING; then
    echo -e "  Fenetre trading: ${G}OUVERTE${N}"
else
    echo -e "  Fenetre trading: ${R}FERMEE${N}"
fi
echo ""

# ══════════════════════════════════════════════════════════════
# 6. PROCHAINE NEWS
# ══════════════════════════════════════════════════════════════
echo -e "${Y}=== 6. PROCHAINE NEWS ===========================================${N}"

if [ -n "$SIG_JSON" ]; then
    echo "$SIG_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
n = d.get('news', {})
nhi = n.get('next_high_impact')
hours = n.get('time_until_hours')
blackout = n.get('in_blackout', False)
timing = d.get('timing_mode', '?')
bbo = d.get('blackout_minutes', 0)

if nhi and isinstance(nhi, dict):
    event = nhi.get('event', nhi.get('title', '?'))
    time_gmt = nhi.get('time_gmt', nhi.get('datetime', '?'))
    print(f'  Event:     {event}')
    print(f'  Heure GMT: {time_gmt}')
    if hours is not None:
        print(f'  Dans:      {hours:.1f}h')
    else:
        print(f'  Dans:      ?')
elif nhi and isinstance(nhi, str):
    print(f'  Event:     {nhi}')
    if hours: print(f'  Dans:      {hours:.1f}h')
else:
    print('  Aucune news high impact a venir')

if blackout:
    print(f'  \033[0;31m!! BLACKOUT ACTIF ({bbo} min) -- PAS DE TRADING !!\033[0m')
else:
    print(f'  Timing mode: {timing}')
" 2>/dev/null
fi
echo ""

# ══════════════════════════════════════════════════════════════
# 7. CLAUDE ENGINE
# ══════════════════════════════════════════════════════════════
echo -e "${Y}=== 7. CLAUDE ENGINE ============================================${N}"
echo -e "  Status:  ${G}DESACTIVE${N}"
echo -e "  Cout:    \$0/mois ${D}(economie ~\$25/mois)${N}"
echo -e "  Raison:  Redondant avec EA Min_Confidence=60%"
echo -e "  ${D}Commit:  229b6fd (2026-04-06)${N}"
echo ""

# ══════════════════════════════════════════════════════════════
# 8. FTMO REMINDER
# ══════════════════════════════════════════════════════════════
echo -e "${C}=== 8. FTMO RULES ===============================================${N}"
echo -e "  Objectif:        ${W}+10%${N}"
echo -e "  Risk/trade:      ${W}1.0%${N} max"
echo -e "  DD journalier:   ${Y}4.5%${N} max  ${D}(FTMO limite: 5%)${N}"
echo -e "  DD total:        ${R}9.0%${N} max  ${D}(FTMO limite: 10%)${N}"
echo -e "  WR breakeven:    41.3%"
echo ""

# ══════════════════════════════════════════════════════════════
# 9. VERDICT FINAL
# ══════════════════════════════════════════════════════════════
echo -e "${B}=================================================================${N}"

READY=true
REASONS=""

if ! $ALL_SVC_OK; then
    READY=false
    REASONS="${REASONS}service down | "
fi

if [ -z "$SIG_JSON" ]; then
    READY=false
    REASONS="${REASONS}API muette | "
fi

if [ "$S_TRADE" != "True" ] 2>/dev/null; then
    READY=false
    REASONS="${REASONS}can_trade=false | "
fi

if ! $TRADING; then
    READY=false
    REASONS="${REASONS}hors session | "
fi

if [ "${S_BBO:-0}" -gt 0 ] 2>/dev/null; then
    READY=false
    REASONS="${REASONS}blackout ${S_BBO}min | "
fi

if $READY; then
    echo -e "  ${BG_G} PRET A TRADER ${N}  ${G}Tous les feux sont au vert${N}"
    echo -e "  ${G}${S_DIR} @ ${S_CONF}% conf | Gold \$${S_GOLD} | ${S_TIMING}${N}"
else
    REASONS="${REASONS% | }"
    echo -e "  ${BG_R} NON PRET ${N}  ${R}${REASONS}${N}"
fi

echo -e "${B}=================================================================${N}"
echo ""
