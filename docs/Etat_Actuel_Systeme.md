# État Actuel du Système — Gold ML Trading Platform

> **Photographie de référence** — générée le **2026-04-22** depuis le VPS Linux `86.48.5.126` (vmi2828096).
> À n'utiliser que comme inventaire de départ pour la plateforme d'analyse quantitative.
> Ne modifie rien dans le code existant.
>
> **MAJ 2026-04-22 — v2.2 (EA Print label)** — intégration des garde-fous P2 (veto H4 structurel), P3 (DEAL-v2 reject threshold configurable) et des alertes SELL observationnelles. Voir [§4.9](#49--garde-fous-p2p3--alertes-sell-opportunity-ea-v22--2026-04-22).
>
> **MAJ 2026-04-23 — v2.3 (EA Print label)** — `EvaluateSellOpportunity` passe en mode **Sniper-gated** : un filtre LOCAL (H4+EMA) déclenche désormais **en plus** une validation Sniper M15 complète (sweep HIGH + BOS bearish + FVG/OB + score ≥ seuil) avant d'émettre une alerte. Motivé par l'analyse des 12 alertes du 23/04 (~85 % de signaux directionnels retardés non tradeables en mode LOCAL seul). Rollback via `SellAlert_Require_Sniper = false`. Voir [§4.9](#49--garde-fous-p2p3--alertes-sell-opportunity-ea-v22--2026-04-22).
>
> **MAJ 2026-04-25 — v2.4 (EA Print label)** — refonte directionnelle + 3 modules ICT additionnels. Le **filtre directionnel VPS est désactivé par défaut** (`Use_VPS_Direction = false`), libérant enfin les SELL après audit du biais BUY-only architectural (cf. mémoire phase 0). Ajout de 4 modules HTF en pipeline cumulatif : **Premium/Discount Filter** (binaire, étape 3), **FVG H1 bonus** (étape 4, +15 pts), **Breaker Block** (étape 5, +10 pts), **Mitigation Block** (étape 6, +5 pts). Magic_Number splitté en `Magic_Number_BUY` + `Magic_Number_SELL` pour stats par direction. Refactor scoring breakdown + WEEKLY-STATS log 7j. Tous les modules ICT v2.4 sont toggles (rollback non-destructif). Voir [§4.10](#410--v24--bypass-vps-direction--3-modules-ict-additionnels-2026-04-25).
>
> **MAJ 2026-04-25 — v2.4.1** — cleanup post-audit : 5 corrections audit v2.4 (P2-A à P2-E) appliquées sans changement de logique trading. Câblage `TradeThrottleSeconds`, `Log_Verbose`, `Use_Debug_Mode`, `Skip_Rollover` ; `Force_Direction_Override` respecte la protection news ; suppression de 5 weights orphelins (Option C). Voir [§4.10.1](#4101-v241--corrections-audit-2026-04-25).
>
> **MAJ 2026-04-25 — v2.4.2** — final cleanup avant démo : suppression `API_MarketData_URL` orphelin (C1), persistance throttle cross-jour (C2), `Force_Direction` skip si API stale + protection news active (C3), banner OnInit MAJ v2.4.2 (C4), documentation §4.10.2 (C5). **0 critical / 0 warnings post-cleanup**, code propre pour déploiement démo + multi-comptes futurs. Logique de trading identique à v2.4.1. Voir [§4.10.2](#4102-v242--final-cleanup-avant-démo-2026-04-25).

---

## Table des matières

1. [Inventaire VPS Linux (86.48.5.126)](#1--inventaire-vps-linux-86485126)
2. [Inventaire scripts Python](#2--inventaire-scripts-python)
3. [Architecture réseau](#3--architecture-réseau)
4. [Modules ICT et scoring](#4--modules-ict-et-scoring)
5. [Inventaire EA MQL5](#5--inventaire-ea-mql5)
6. [Configuration système](#6--configuration-système)
7. [Backups et versioning](#7--backups-et-versioning)
8. [Problèmes connus et TODO technique](#8--problèmes-connus-et-todo-technique)
9. [Monitoring et observabilité](#9--monitoring-et-observabilité)

---

## 1 — Inventaire VPS Linux (86.48.5.126)

### 1.1 Services systemd actifs

| Service | État | User | PID | Port | Exec | Description |
|---|---|---|---|---|---|---|
| `gold_intelligence.service` | **RUNNING** | `goldml` (systemd unit) mais process en `root` | 419493 | **5002** | `/root/gold_ml_phase4/venv/bin/python3 /root/gold_ml_phase4/gold_intelligence.py` | Signal Engine v2.0 institutional — cache, fallbacks, routes Flask |
| `gold-automation-bridge.service` | **RUNNING** | `root` | 419492 | — | `/usr/bin/python3 /root/gold_ml_phase4/automation_bridge.py` | Cycle macro toutes les 15 min (US10Y, DXY, VIX, Real Rate, Macro/Geo Score) |
| `gold-ml-monitor.service` | **RUNNING** | `root` | 419545 (+ workers) | **5000** | `gunicorn -w 2 -b 0.0.0.0:5000 --timeout 120 calendar_monitor:app` | Flask API calendar/FRED/COT/DXY/VIX/H4 signal |
| `dxy_fetcher.service` | **RUNNING** | `root` | 419465 | — | `/root/gold_ml_phase4/venv/bin/python /root/gold_ml_phase4/dxy_fetcher.py --daemon` | Fetch Yahoo DXY + TNX toutes les 5 min |
| `vps-api-secured.service` | **RUNNING** | `root` | 419512 | **5001** | `/opt/vps-api/venv/bin/python3 /opt/vps-api/server.py` | Flask API legacy v8.3.7 (404 par défaut, émet alertes email) |
| `goldml-datacollector.timer` | **DISABLED** | — | — | — | Déclencheur `goldml-datacollector.service` (oneshot, hourly) | Collecte horaire |
| `goldml-datacollector.service` | **DISABLED** | `root` | — | — | `/usr/bin/python3 /root/gold_ml_phase4/gold_data_collector_working.py` | Data collector (oneshot) |
| `goldml-api.service` | **DISABLED** | — | — | — | — | [À CLARIFIER AVEC MICKAËL] fichier unit probablement obsolète |
| `goldml-bridge.service` | **DISABLED** | — | — | — | — | [À CLARIFIER AVEC MICKAËL] legacy |
| `goldml-calendar-api.service` | **DISABLED** | — | — | — | — | [À CLARIFIER AVEC MICKAËL] legacy |

> Démarrage commun de tous les services actifs : **2026-04-09 06:03:44 CEST** (donc uptime ~1 sem 6 jours au snapshot).

### 1.2 Cron jobs (utilisateur `root`)

```cron
# Collecte macro (gold_data_collector_working.py) toutes les 30 min
*/30 * * * * cd /root/gold_ml_phases && /root/gold_ml_phases/venv/bin/python gold_data_collector_working.py >> /var/log/gold_collector.log 2>&1

# Optimization ML toutes les 2h
0 */2 * * * cd /root/gold_ml_phases && /root/gold_ml_phases/ml_venv/bin/python run_ml_optimization.py >> /root/gold_ml_phases/cron-ml.log 2>&1

# Check quotidien + cleanup logs à 08:00
0 8 * * * /root/gold_ml_phases/daily_check.sh >> /root/gold_ml_phases/logs/daily_check.log 2>&1

# Rotation des logs le dimanche à 03:00
0 3 * * 0 find /root/gold_ml_phases/logs -name "*.log" -mtime +7 -delete && find /var/log -name "*.log" -size +100M -delete

# Auto-restart gold-ml-monitor toutes les 10 min si down
*/10 * * * * systemctl is-active --quiet gold-ml-monitor || (systemctl restart gold-ml-monitor && echo "$(date): Service redémarré" >> /var/log/auto-restart.log)

# Backup des DBs à 04:00
0 4 * * * mkdir -p /root/backups/$(date +\%Y\%m\%d) && cp /root/gold_ml_phases/*.db /root/backups/$(date +\%Y\%m\%d)/ 2>/dev/null

# Alerte disque >80% à 09:00
0 9 * * * DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | sed 's/%//'); [ "$DISK_USAGE" -gt 80 ] && echo "$(date): WARNING - Disk usage at ${DISK_USAGE}%" >> /var/log/disk_alerts.log

# Maintenance gold_ml à 03:00
0 3 * * * /root/gold_ml_maintenance.sh

# VPS check quotidien à 08:05
5 8 * * * /root/gold_ml_phase4/vps_check_final.sh >> /root/gold_ml_phase4/vps_check_daily.log 2>&1

# Claude alert monitor toutes les 2 min
*/2 * * * * /root/gold_ml_phase4/goldml_alert_monitor.sh
```

> ⚠️ **[À CLARIFIER AVEC MICKAËL]** — plusieurs tâches cron pointent vers `/root/gold_ml_phases/` (pluriel) alors que le répertoire actif en production est `/root/gold_ml_phase4/` (singulier au pluriel inversé). À vérifier si `gold_ml_phases` existe ou si ces crons sont morts.

### 1.3 Ports ouverts et firewall UFW

```
Status: active

To                         Action      From
--                         ------      ----
22/tcp   (SSH)             ALLOW       Anywhere
5000/tcp (gold-ml-monitor) ALLOW       Anywhere
5001/tcp (vps-api-secured) ALLOW       Anywhere
5002/tcp (gold_intelligence) ALLOW     Anywhere
(IPv6 équivalents aussi ouverts)
```

Ports en `LISTEN` au moment du snapshot :

| Port | Process | Binding | Rôle |
|---|---|---|---|
| 22 | `sshd` | `0.0.0.0` | SSH |
| 53 | `systemd-resolved` | `127.0.0.53` + `127.0.0.54` | Résolveur DNS local |
| 5000 | `gunicorn` (calendar_monitor) | `0.0.0.0` | API calendar/FRED/COT/H4 |
| 5001 | `python3` (vps-api) | `0.0.0.0` | API legacy Flask |
| 5002 | `python3` (gold_intelligence) | `0.0.0.0` | Signal Engine (consommé par EA) |

> `nginx` n'est **pas installé** sur le VPS malgré la présence d'un `nginx_goldml.conf` dans `/root/gold_ml_phase4/`.
> `fail2ban` tourne (protection SSH).

### 1.4 Répertoires principaux

| Chemin | Taille | Rôle |
|---|---|---|
| `/root/gold_ml_phase4/` | **1.8 G** | Répertoire applicatif principal (code + DBs + logs) |
| `/root/gold_ml_phase4/logs/` | 171 M | Logs rotationnés (WatchedFileHandler + .gz) |
| `/root/gold_ml_phase4/venv/` | — | Venv Python principal |
| `/root/gold_ml_phase4/ml_venv/` | — | Venv Python pour `calendar_monitor` (gunicorn) |
| `/root/backups/` | 1.3 M | Backups horodatés (`YYYYMMDD`) issus du cron 04:00 |
| `/root/gold_ml_phase4/archive_obsolete/` | — | Archives de code legacy |
| `/opt/vps-api/` | — | Legacy API v8.3.7 |
| `/etc/goldml/.env` | — | Secrets (API_TOKEN, HMAC_SECRET, ANTHROPIC_API_KEY, FRED_API_KEY) |
| `/home/traderadmin/` | — | Copie de travail EA MQL5 + clone git `XAUUSD---MT5` |
| `/home/traderadmin/Turtle/` | — | Projet EA Turtle séparé (FTMO 100K) |

### 1.5 Bases de données SQLite

| Fichier | Taille | Contenu présumé |
|---|---|---|
| `/root/gold_ml_phase4/gold_intelligence.db` | **611 MB** | Cache signal + historique (init par `gold_intelligence.py`) |
| `/root/gold_ml_phase4/gold_ml_database.db` | 2.3 MB | Table `automation_data` (`automation_bridge.py`) + calendrier |
| `/root/gold_ml_phase4/cot_data.db` | 16 kB | Cache COT Legacy Futures Only |
| `/root/gold_ml_database.db` | 12 kB | [À CLARIFIER AVEC MICKAËL] doublon ? |

---

## 2 — Inventaire scripts Python

### 2.1 Scripts actifs en production (`/root/gold_ml_phase4/`)

| Script | Taille | Dernière modif | Rôle | I/O | Appelé par |
|---|---|---|---|---|---|
| `gold_intelligence.py` | 50 kB | 2026-04-06 | **Signal Engine v2.0** — Flask port 5002, cache TTL + refresh loop, fallback multi-niveaux, HMAC signing | IN : REST HTTP GET/POST | systemd `gold_intelligence.service` |
| `automation_bridge.py` | 10.8 kB | 2026-02-01 | Fetch Yahoo (DXY, VIX, US10Y, Fed target, Real Rate) toutes les 15 min → SQLite + webhook | IN : yfinance / OUT : `gold_ml_database.db`, webhook.site | systemd `gold-automation-bridge.service` |
| `calendar_monitor.py` | 38.5 kB | 2026-04-02 | Flask port 5000 — agrège calendar/FRED/COT/DXY/VIX + H4 signal + optimal thresholds | IN : HTTP GET / OUT : JSON | gunicorn (systemd `gold-ml-monitor.service`) |
| `dxy_fetcher.py` | 6.9 kB | 2026-01-28 | Daemon : pull DXY + TNX (Yahoo) toutes les 5 min | OUT : DB + log | systemd `dxy_fetcher.service` |
| `news_fetcher_v2.py` | 9.5 kB | 2026-03-30 | Fetch ForexFactory RSS | IN : ForexFactory / OUT : dict news | `gold_intelligence.py` (import) |
| `news_trading_signal.py` | 35.8 kB | 2026-04-06 | Classe `NewsTradingAnalyzer` (timing BLACKOUT/PRE/POST + fade spike) | dataclass → JSON | `gold_intelligence.py` (import) |
| `claude_decision_engine.py` | 24.3 kB | 2026-04-03 | Enrichissement signal via API Anthropic (modèle `claude-sonnet-4-20250514`) | IN : signal dict + Anthropic | **DÉSACTIVÉ** dans `gold_intelligence.py` depuis 2026-04-06 (« redondant avec Option D ») |
| `fred_service.py` | 8.8 kB | 2026-04-03 | Wrappers FRED : TIPS yield, breakeven, Fed funds, yield curve | IN : FRED API / OUT : float | `gold_intelligence.py`, `calendar_monitor.py` |
| `cot_service.py` | 18.5 kB | 2026-03-24 | Fetch COT Legacy Futures Only (hebdo) | IN : CFTC / OUT : DB | `calendar_monitor.py` |
| `cot_fetcher.py` | 3.8 kB | 2025-12-07 | Variante simple COT | — | legacy |
| `cot_advanced_fetcher.py` | 15.7 kB | 2025-12-07 | Variante avancée COT | — | legacy |
| `cot_endpoint.py` | 43.9 kB | 2025-12-07 | Endpoint COT | — | legacy |
| `backend_api.py` | 26.5 kB | 2026-03-23 | Flask API (routes /v1/api/macro, /dxy_data, /vix_data, etc.) | HTTP | **Non exposé** (pas de systemd unit actif) |
| `python_sniper.py` | 37.6 kB | 2026-04-03 | Ancienne logique sniper Python (ICT) | — | **DÉSACTIVÉ** (ICT migré dans EA local `CSniperM15`) |
| `gold_data_collector_working.py` | 5.3 kB | 2025-12-14 | Collecte horaire macro | OUT : DB | cron `*/30` ou timer systemd |
| `gold_ml_to_mt5_bridge_files.py` | 9.5 kB | 2025-11-01 | Bridge fichiers → MT5 | — | [À CLARIFIER] |
| `mt5_signal_sender.py` / `mt5_signal_sender_files.py` | 2-8.7 kB | 2025-10 | Envoi signal vers MT5 | — | legacy |
| `macro_data_endpoint.py` | 6.7 kB | 2025-10-11 | Endpoint macro | — | legacy |
| `ml_bridge.py` | 10.2 kB | 2025-10-12 | Bridge ML | — | legacy |
| `signal_api.py` | 2.0 kB | 2025-12-07 | — | — | legacy |
| `test_claude_decision_engine.py` | 13.2 kB | 2026-04-02 | Tests unitaires Claude engine | pytest | Manuel |
| `test_python_sniper.py` | 10.9 kB | 2026-03-26 | Tests sniper Python | pytest | Manuel |

### 2.2 Pipeline ML (legacy, dans `/root/gold_ml_phase4/`)

Scripts numérotés 1 à 6, exécutés séquentiellement par `RUN_ALL_PIPELINE.py` :

| # | Script | Rôle |
|---|---|---|
| 1 | `1_extract_vps_data.py` | Extraction données VPS |
| 2 | `2_download_yahoo_data.py` | Téléchargement Yahoo historique |
| 3 | `3_prepare_ml_dataset_ROBUST.py` (dernière version retenue) | Préparation dataset (3 variantes existent : original, FIXED, ROBUST) |
| 4 | `4_train_ml_model.py` | Entraînement scikit-learn |
| 5 | `5_optimize_thresholds.py` | Optimisation `optimal_thresholds.json` (scikit-optimize) |
| 6 | `6_update_pinescript_thresholds.py` | Export Pine Script |

> **État : PROBABLEMENT INACTIF** au jour du snapshot — pas de service actif qui l'appelle, seuls les crons `gold_ml_phases` (pluriel) le référencent et ce chemin n'existe pas.

### 2.3 Scripts shell de maintenance

| Script | Rôle |
|---|---|
| `/root/gold_ml_maintenance.sh` | Cron 03:00 quotidien |
| `/root/gold_ml_phase4/vps_check_final.sh` | Cron 08:05 — écrit `vps_check_daily.log` |
| `/root/gold_ml_phase4/goldml_alert_monitor.sh` | Cron */2 min — surveillance alertes |
| `/root/diagnostic.sh`, `/root/diagnostic_final.sh` | Diagnostic manuel |
| `/root/fix_vps_quick.sh` | Réparation manuelle |
| `/root/gml-full-check.sh`, `/root/gml-full-diagnostic.sh` | Audits complets |
| `/root/gold_ml_status.sh` | Statut express |
| `/root/test_backend_api_v4.sh` | Test API |
| `/home/traderadmin/check_goldml.sh` | Copie locale |

### 2.4 Dépendances Python principales

**Venv `/root/gold_ml_phase4/venv/`** (utilisé par `gold_intelligence` et `dxy_fetcher`) :

```
anthropic==0.86.0        APScheduler==3.11.1      beautifulsoup4==4.13.5
curl_cffi==0.13.0        feedparser==6.0.12       Flask==3.1.2
joblib==1.5.2            matplotlib==3.10.6       numpy==2.3.3
pandas==2.3.2            pydantic==2.12.5         python-dotenv==1.2.2
requests==2.32.5         scikit-learn==1.7.2      scipy==1.16.2
seaborn==0.13.2          ta==0.11.0               websockets==15.0.1
Werkzeug==3.1.3          yfinance==0.2.66
```

**Venv `/root/gold_ml_phase4/ml_venv/`** (utilisé par `calendar_monitor` gunicorn) :

```
Flask==3.1.2             gunicorn==23.0.0         numpy==2.3.3
pandas==2.3.3            pyaml==25.7.0            PyYAML==6.0.3
requests==2.32.5         schedule==1.2.2          scikit-learn==1.7.2
scikit-optimize==0.10.2  scipy==1.16.2            websockets==15.0.1
```

---

## 3 — Architecture réseau

### 3.1 Diagramme textuel des flux

```
                     ┌──────────────────────────────┐
                     │    VPS Windows (FTMO MT5)    │
                     │  Gold_News_Institutional_EA  │
                     │    (magic 888892)            │
                     └───────────────┬──────────────┘
                                     │  HTTP GET/POST
                    WebRequest       │  - Bearer API_Auth_Token
                    timeout 5000 ms  │  - Refresh 30 s
                                     ▼
    ┌──────────────────────────────────────────────────────────────┐
    │                  VPS Linux — 86.48.5.126                     │
    │                                                              │
    │ ┌────────────────────┐   ┌────────────────────────────┐      │
    │ │  Port 5002         │   │  Port 5000                 │      │
    │ │  gold_intelligence │   │  calendar_monitor          │      │
    │ │  (Flask raw)       │   │  (gunicorn x2 workers)     │      │
    │ │                    │   │                            │      │
    │ │  /v1/news_trading  │   │  /macro_data               │      │
    │ │    _signal/quick   │   │  /h4_signal                │      │
    │ │  /v1/market_data   │   │  /cot_data                 │      │
    │ │  /v1/health        │   │  /dxy_data                 │      │
    │ │  /gold_intelligence│   │  /vix_data                 │      │
    │ │    /quick /health  │   │  /optimal_thresholds       │      │
    │ │    /news /geo…     │   │  /market_context           │      │
    │ └─────────┬──────────┘   └────────────┬───────────────┘      │
    │           │ shared cache via SQLite   │                      │
    │           │                           │                      │
    │           ▼                           ▼                      │
    │ ┌──────────────────────────────────────────────────┐         │
    │ │  SQLite : gold_intelligence.db (611 MB)          │         │
    │ │  SQLite : gold_ml_database.db  (2.3 MB)          │         │
    │ └──────────────────────────────────────────────────┘         │
    │           ▲                           ▲                      │
    │           │                           │                      │
    │ ┌─────────┴──────────┐   ┌────────────┴────────────┐         │
    │ │ automation_bridge  │   │  dxy_fetcher (daemon)   │         │
    │ │ (cycle 15 min)     │   │  cycle 5 min            │         │
    │ └─────────┬──────────┘   └────────────┬────────────┘         │
    │           │ Yahoo Finance             │ Yahoo Finance        │
    │           │ + webhook.site            │                      │
    │           │                           │                      │
    │ ┌─────────┴───────────────────────────┴───────────┐          │
    │ │ Port 5001 — vps-api-secured.server (legacy)     │          │
    │ │ (Bearer API_KEY hardcodé, émet alertes email)   │          │
    │ └─────────────────────────────────────────────────┘          │
    └──────────────────┬───────────────────────────────────────────┘
                       │
                       ▼
         FRED, CFTC COT, ForexFactory RSS,
         alternative.me (Fear & Greed), Yahoo Finance,
         Anthropic API (désactivée côté runtime)
```

### 3.2 Endpoints HTTP (exposés à l'EA et outils externes)

#### `gold_intelligence` — port **5002** (endpoint principal consommé par l'EA)

| Méthode | Route | Rôle |
|---|---|---|
| GET  | `/news_trading_signal/quick` | Signal rapide News Trading (alias v0) |
| GET  | `/v1/news_trading_signal/quick` | Signal rapide News Trading (**consommé par l'EA** via `API_News_URL`) |
| POST | `/v1/market_data` | Ingestion market data (**consommé par l'EA** via `API_MarketData_URL`) |
| GET  | `/v1/health` | Healthcheck v1 |
| GET  | `/news_trading_signal` | Signal complet |
| GET  | `/gold_intelligence` | Vue complète du signal |
| GET  | `/gold_intelligence/quick` | Vue rapide |
| GET  | `/gold_intelligence/health` | Healthcheck détaillé |
| GET  | `/gold_intelligence/news` | News uniquement |
| GET  | `/gold_intelligence/geopolitics` | Géopolitique uniquement |
| GET  | `/tmp/ea_download` / `/tmp/bridge_download` | Téléchargement fichiers |

Sécurité : décorateur `_require_auth` basé sur `API_TOKEN` (`/etc/goldml/.env`) + réponses HMAC-signées via `HMAC_SECRET`.

#### `calendar_monitor` — port **5000**

| Méthode | Route | Rôle |
|---|---|---|
| GET | `/news_trading_signal/quick` | Healthcheck (EA safety) |
| GET | `/macro_data` | Macro aggregé |
| GET | `/news_status` | Statut news |
| GET | `/optimal_thresholds` | Seuils ML optimisés (JSON persistant) |
| GET | `/health` | Healthcheck |
| GET | `/dxy_data` / `/dxy_status` | DXY |
| GET | `/h4_signal` | Signal H4 (composite) |
| GET | `/server_time` | Heure serveur |
| GET | `/vix_data` | VIX |
| GET | `/market_context` | Contexte marché complet |
| GET | `/cot_data` | COT (Legacy Futures Only) |

#### `vps-api-secured` — port **5001** (legacy)

Répond `404` sur `/` par défaut (confirmé dans les logs). Accepte auth via `API_KEY` hardcodé dans `server.py`.
Bearer key : `Gold_ML_VPS_2025_SecretKey_LS_Mickael_ABC123` → **[À CLARIFIER AVEC MICKAËL]** encore utilisé ou peut-être désactivé.

### 3.3 Flux MT5 ↔ VPS Linux (synthèse côté EA)

```mql5
// Dans Gold_News_Institutional_EA.mq5 (lignes 47-52)
input string API_News_URL        = "http://86.48.5.126:5002/v1/news_trading_signal/quick";
input string API_MarketData_URL  = "http://86.48.5.126:5002/v1/market_data";
input int    API_Timeout         = 5000;
input int    API_Refresh_Seconds = 30;
input string API_Auth_Token      = "";   // À renseigner par l'utilisateur EA
```

L'EA n'appelle donc directement **que le port 5002**. Le port 5000 est consommé indirectement par `gold_intelligence` (qui lui-même lit les mêmes DBs).

---

## 4 — Modules ICT et scoring

> **Toute la logique ICT a été migrée de `python_sniper.py` (VPS) vers l'EA local `CSniperM15`** (commentaire explicite dans `gold_intelligence.py:29`).
> Le scoring documenté ici est celui implémenté dans `GoldML_SniperEntry_M15.mqh`.

### 4.1 Break of Structure (BOS)

- **Fichier** : `GoldML_SniperEntry_M15.mqh` — `CSniperM15::DetectBOS()` (ligne 921)
- Recherche un BOS M15 dans une fenêtre **`Sniper_Max_Bars_After_BOS = 60` bars** (15 h sur M15) après le sweep
- Cohérence `sweepBar` garantie via `DetectBOS(direction, sweepBar)`
- Struct `BreakOfStructure { found, barsSinceBOS, … }`

### 4.2 CHoCH (Change of Character)

- **Fichier** : `GoldML_ICT_Detector.mqh` — `DetectShiftM5()` (ligne 435)
- Fix P1 (2026-04-17) : CHoCH désormais valide **sur les 3 dernières bougies fermées** (au lieu de `close[1]` seul, qui manquait les CHoCH légèrement antérieurs)
- BOS considéré impulsif si `range > 1.2 * ATR`
- Retient toujours le **CHoCH le plus récent**

### 4.3 FVG (Fair Value Gap)

- **Fichier** : `GoldML_ICT_Detector.mqh` — `FindLatestFVG(direction, …)` (ligne 226)
- Minimum **5 bars** d'historique requis
- Bullish : `low[i-1] > high[i+1]` (gap up)
- Bearish : `high[i-1] < low[i+1]` (gap down)
- Struct `ICT_PDArray { type = ICT_PD_FVG, name = "FVG", … }`
- Tolérance d'alignement `0.1 × ATR` (fix P2 2026-04-17)

### 4.4 OB (Order Block)

- **Fichier** : `GoldML_ICT_Detector.mqh`
- Minimum **5 bars** (aligné avec le minimum FVG)
- Retourne `ICT_PDArray { type = ICT_PD_OB, name = "OB" }`
- Pullback OTE fallback si pas d'OB (commit `c427afc`)

### 4.5 Liquidity Sweeps

- **Fichier** : `GoldML_LiquidityLevels.mqh` (`CLiquidityLevels`)
- Paramètre EA : `Enable_ICT_Liquidity = true` (active la détection ICT, sinon fallback pivots 4/4)
- Niveaux détectés et leur **force** (0-100) :

| Type | Force | Description |
|---|---|---|
| `PWH` / `PWL` | 90 | Previous Week High/Low |
| `PDH` / `PDL` | 80 | Previous Day High/Low |
| `LONDON_H` / `LONDON_L` | 75 | London session High/Low |
| `ASIAN_H` / `ASIAN_L` | 70 | Asian session High/Low |
| `EQL_H` / `EQL_L` | 65 | Equal Highs / Equal Lows |

- Cap : **max 3 EQL_H + 3 EQL_L** (`MAX_EQL = 3`)
- Gap minimum **20 bougies M15** (~5 h) entre 2 EQL du même côté (fix 2026-04-17)
- Scan `i = 5..95` (soit ~15 h de lookback)
- Les niveaux sweepés sont marqués `active = false` + `sweptAt = GMT time` et ne sont plus réutilisés (fix `ea57b4d` — anti double-signal)

### 4.6 Formule de scoring Sniper (0-100)

Implémentée dans `CSniperM15::CalculateScore()` — `GoldML_SniperEntry_M15.mqh:1459` :

| Composant | Points | Condition |
|---|---|---|
| **Sweep détecté** | +20 | Base |
| Sweep virtuel (BOS Direct bypass) | +15 | Fix A1 2026-04-04 — demi-score sweep |
| **Niveau ICT balayé** | | Selon la force du niveau : |
| → `PWH`/`PWL` | +35 | |
| → `PDH`/`PDL` | +30 | |
| → `LONDON_H/L` | +25 | |
| → `ASIAN_H/L` | +22 | |
| → `EQL_H/L` | +20 | |
| → inconnu | +20 | |
| **BOS confirmé** | +20 | |
| BOS récent (≤ 5 bars) | +5 | |
| **Pullback dans PD array** | +15 | |
| → Type `FVG` | +5 | |
| → Type `OB` | +5 | |
| **CHoCH M5** | +10 | Confirmation timing |
| **BOS M5** | +5 | Confirmation timing |
| **Barres depuis sweep ≤ 5** | +5 | Fraîcheur sweep |
| **Confirmation candle M5** | +10 | `patternScore ≥ 75` accepté en remplacement de CHoCH |

Patterns M5 eux-mêmes scorés (`confirm.patternScore`) :
- 90 : configuration premium
- 85 / 75 / 60 / 50 / 40 : configurations progressivement plus faibles
- `+10` bonus si `candleConfirm = true`

**Score minimum par défaut (input EA) : `Sniper_Min_Score = 55`** (abaissé après recalibrage).

### 4.7 Seuils DEAL v2 (CONTRA-LIGHT, CONTRA-STRONG, ALIGNED)

Implémenté dans `CQualityFilters::GetH4ScoreContribution()` — `GoldML_QualityFilters.mqh:580-662`.

**Détection structure H4** (3 swings H/L) :
- `HH + HL`  → **BULLISH ALIGNED**
- `LH + LL`  → **BEARISH ALIGNED** (= CONTRA-STRONG pour un BUY)
- 1 seul critère cassé (`LH` xor `LL`) → **CONTRA-LIGHT**
- Sinon (HH+LL ou LH+HL) → **RANGING**

**Table des scores et sizeFactor** (pour une direction `BUY`, miroir symétrique en `SELL`) :

| État H4 | API confidence | Score | sizeFactor | Log |
|---|---|---|---|---|
| `ALIGNED` (HH+HL) | — | **+25** | **1.00** | `H4 BULLISH -> +25 pts \| size 100%` |
| `RANGING` | ≥ 70 % | +10 | 0.85 | `H4 RANGING + API>=70% -> +10 \| size 85%` |
| `RANGING` | 60-70 % | 0 | 0.70 | `H4 RANGING + API 60-70% -> 0 \| size 70%` |
| `RANGING` | < 60 % | −10 | 0.50 | `H4 RANGING + API<60% -> -10 \| size 50%` |
| `CONTRA-LIGHT` | ≥ 70 % | **−5** | **0.65** | `H4 CONTRA-LIGHT + API>=70% -> -5 \| size 65%` |
| `CONTRA-LIGHT` | 60-70 % | −15 | 0.50 | `H4 CONTRA-LIGHT + API 60-70% -> -15 \| size 50%` |
| `CONTRA-LIGHT` | < 60 % | −25 | **0.00 (BLOCKED)** | `H4 CONTRA-LIGHT + API<60% -> -25 \| BLOCKED` |
| `CONTRA-STRONG` (LH+LL) | ≥ 70 % | **−10** | **0.50** | `H4 BEARISH (LH+LL) + API>=70% -> -10 \| size 50%` |
| `CONTRA-STRONG` | 60-70 % | −20 | 0.35 | `H4 BEARISH (LH+LL) + API 60-70% -> -20 \| size 35%` |
| `CONTRA-STRONG` | < 60 % | −25 | **0.00 (BLOCKED)** | `H4 BEARISH (LH+LL) + API<60% -> -25 \| BLOCKED` |

**Règle de blocage historique** : `h4Score ≤ −25` (autrement dit : H4 contre-tendance avec API confidence < 60 %).

> **MAJ v2.2 (2026-04-22)** — le seuil est désormais configurable via l'input `DEAL_Reject_Threshold` (défaut **-20**, voir [§4.9](#49--garde-fous-p2p3--alertes-sell-opportunity-ea-v22--2026-04-22)) et un veto structurel H4 (`Enable_H4_Hard_Veto`, P2) s'exécute **avant** ce check. Avec défaut -20, la ligne `CONTRA-STRONG + API 60-70 %` (score -20) est désormais **bloquée** en plus des deux lignes `-25` historiques.

**Exception POST_NEWS_ENTRY** : fade trade par design → `trendOK = true` forcé, `m_h4SizeFactor = 1.0` réinitialisé (fix B3 2026-04-14).

**Combinaison avec ConflictFactor** : la formule finale est `MIN(conflictFactor, dealFactor)` (pas de cumul) — `Gold_News_Institutional_EA.mq5:1294`.

### 4.8 Seuils API confidence côté EA

| Paramètre | Valeur | Rôle |
|---|---|---|
| `Min_Confidence` | 60.0 | Confidence minimum pour trader (mode API) |
| `Local_Min_Confidence` | 55.0 | Fallback local quand l'API est silencieuse |

### 4.9 Garde-fous P2/P3 + Alertes SELL opportunity (EA v2.2 — 2026-04-22)

Trois couches additionnelles au-dessus du scoring DEAL v2 (§4.7), déployées le **2026-04-22** en réponse au biais BUY-only observé architecturalement (VPS → 0 SELL, Sniper → 0 HIGH sweep, DEAL-v2 → 0 reject sur la fenêtre d'observation pré-2026-04-22).

#### P2 — Veto structurel H4 (input `Enable_H4_Hard_Veto`, défaut `true`)

- **Fichier** : `GoldML_QualityFilters.mqh:767-774`
- S'exécute **avant** le calcul du `h4Score` — indépendant du scoring DEAL :
  - Bloque **BUY** si H4 confirmé BEARISH (Lower High **ET** Lower Low sur les 3 derniers swings H4)
  - Bloque **SELL** si H4 confirmé BULLISH (Higher High **ET** Higher Low)
- **Ne bloque pas** : `CONTRA-LIGHT` (1 seul critère cassé), `RANGING`, `ALIGNED`.
- **Rollback** : `Enable_H4_Hard_Veto = false` → comportement pré-P2 (DEAL-v2 seul).
- **Log émis** : `[H4-VETO] <DIR> bloque: H4 contre-structure forte (<BEARISH LH+LL|BULLISH HH+HL>) | score calcule=<h4Score> ignore (veto structurel independant du score DEAL)`
- **Tag motif** exposé à `CheckEntry` via `CQualityFilters::GetLastH4BlockReason()` = `"H4-VETO"` (réinitialisé à chaque évaluation).

#### P3 — DEAL-v2 reject threshold (input `DEAL_Reject_Threshold`, défaut `-20`)

- **Fichier** : `GoldML_QualityFilters.mqh:781-787`
- Remplace le seuil hardcodé `h4Score ≤ -25` (§4.7) par un input `int` configurable.
- **Défaut -20** bloque désormais aussi le cas `CONTRA-STRONG + API 60-70 %` (score -20). Les cas `-25` historiques (CONTRA-LIGHT + API<60 % et CONTRA-STRONG + API<60 %) restent bloqués.
- Scores `-5`, `-10`, `-15` conservent leur comportement de modulation via `sizeFactor` (ne bloquent pas à -20).
- **Rollback safety** : `DEAL_Reject_Threshold = -99` → seuil inaccessible, tous passent.
- **Interaction P2 → P3** : P2 retourne **avant** P3. Si veto structurel déclenché, ce seuil n'est pas évalué (comportement attendu).
- **Log émis** : `[DEAL-v2-REJECT] score=<h4Score> <= threshold=<threshold> | direction=<DIR> | sizeFactor=<X.XX> ignore, trade bloque`
- **Tag motif** exposé : `GetLastH4BlockReason() = "DEAL-v2-REJECT"`.

#### Alertes SELL opportunity (inputs `Enable_SellOpportunity_Alerts` + Sniper gating v2.3)

- **Fichiers** :
  - Évaluateur : `Gold_News_Institutional_EA.mq5::EvaluateSellOpportunity` (refactor 2026-04-23)
  - Hook dans `CheckEntry` : branche inchangée (direction==BUY && !fr.trendOK && H4-VETO|DEAL-v2-REJECT)
  - Validation Sniper dry-run : `GoldML_SniperEntry_M15.mqh::CSniperM15::ValidateSetup(direction)` — wrappe `AnalyzeEntry` avec save/restore de `m_lastResult`, confidence=0 (désactive le BOS_DIRECT_BYPASS SETUP-A), timingMode="CLEAR"
- **Condition de déclenchement** (dans `CheckEntry`, après `CQualityFilters::CheckAllFilters`) :
  ```
  Enable_SellOpportunity_Alerts
    && direction == "BUY"
    && !fr.trendOK
    && (GetLastH4BlockReason() == "H4-VETO" || "DEAL-v2-REJECT")
  ```
- **Logique interne v2.3 (pipeline deux étages)** :
  1. **Filtre directionnel LOCAL** : `GetLocalSignal()` doit retourner `direction == "SELL"` et `confidence ≥ Local_Min_Confidence` (55 %). Sinon → log `[SELL-SKIPPED-LOW-CONF]`, return.
  2. **Si `SellAlert_Require_Sniper = false`** (mode legacy PR #4) → émet `[SELL-OPPORTUNITY]` + push mobile et stop.
  3. **Si `SellAlert_Require_Sniper = true`** (défaut) → appel `g_sniper.ValidateSetup("SELL")` :
     - Retour valide && `score ≥ SellAlert_Sniper_Min_Score` (70) → émet `[SELL-OPPORTUNITY-ICT]` avec payload enrichi (sweep HIGH + level, BOS bearish + level, zone PD FVG/OB range, score) + push mobile.
     - Sinon → log `[SELL-SKIPPED-NO-SNIPER]` avec raison Sniper + détails sweep/BOS/score, pas de push.
- **AUCUN trade automatique** — pure observation. Les alertes v2.3 ICT-grade préparent par ailleurs l'architecture P4 (mode bidirectionnel AUTO) : si la fiabilité de ces alertes se confirme sur 2-4 semaines d'observation, P4 pourra remplacer `SendNotification()` par `ExecuteTrade()` sans redesign.
- **Throttle interne** : **1 h hardcodé** (`static datetime lastEvalTime` dans `EvaluateSellOpportunity`). H4 bar = 4 h mais 1 h laisse une fenêtre d'observation plus fine sans noyer le mobile sur un régime macro qui peut durer des jours. Le throttle s'applique à **toutes** les sorties (OPPORTUNITY-ICT, OPPORTUNITY legacy, SKIPPED-NO-SNIPER, SKIPPED-LOW-CONF) — le return early est avant la branche log.
- **Master switch rollback** : `Enable_SellOpportunity_Alerts = false` → aucun appel à `EvaluateSellOpportunity` depuis `CheckEntry`, comportement EA strictement identique au comportement pré-alertes.
- **Inputs** :
  - `SellAlert_Push_Notification` (défaut `true`) — active `SendNotification()` natif MT5 mobile.
  - `SellAlert_Logs_Only` (défaut `false`) — si `true`, n'émet **que** les logs (utile pour silencieux en test).
  - `SellAlert_Require_Sniper` (défaut `true` — **v2.3**) — `false` rollback comportement legacy PR #4 (LOCAL seul).
  - `SellAlert_Sniper_Min_Score` (défaut `70` — **v2.3**) — seuil score Sniper M15 pour déclencher l'alerte ICT. Monter à 75-80 si encore bruyant après observation ; descendre à 60-65 si trop restrictif.

#### Tags de logs SELL alertes (Journal EA MT5, à consulter sur VPS Windows)

| Tag | Émis par | Fréquence attendue | Sémantique |
|---|---|---|---|
| `[H4-VETO]` | `GoldML_QualityFilters.mqh` | À chaque tentative bloquée par P2 | Veto structurel — signal rejeté **avant** scoring DEAL |
| `[DEAL-v2-REJECT]` | `GoldML_QualityFilters.mqh` | À chaque tentative bloquée par P3 | Seuil `DEAL_Reject_Threshold` atteint — rejeté **après** scoring DEAL |
| `[SELL-OPPORTUNITY-ICT]` | `Gold_News_Institutional_EA.mq5::EvaluateSellOpportunity` (v2.3) | Max **1/h** | Sniper-gated : LOCAL SELL + setup ICT complet (sweep+BOS+PD) ≥ seuil — **push mobile émis** |
| `[SELL-OPPORTUNITY]` | idem (branche legacy `Require_Sniper=false`) | Max **1/h** | Mode legacy PR #4 : LOCAL SELL seul — **push mobile émis** |
| `[SELL-SKIPPED-LOW-CONF]` | idem | Max **1/h** | BUY bloqué mais LOCAL ne détecte pas de SELL ≥ 55 % (dir / conf reportés) |
| `[SELL-SKIPPED-NO-SNIPER]` | idem (v2.3) | Max **1/h** | LOCAL SELL OK mais Sniper M15 rejette (reason + sweep + BOS + score/seuil reportés) |
| `[DEAL-v2]` | `GoldML_QualityFilters.mqh` | À chaque passage autorisé | (Existant avant v2.2) Score calculé, passage autorisé |

> **Estimation post-refactor v2.3** : sur les 12 alertes `[SELL-OPPORTUNITY]` du 23/04/2026, le filtre Sniper aurait vraisemblablement validé **1-3 alertes** (celles correspondant à un vrai sweep HIGH + BOS bearish confirmé sur M15), les 9-11 autres tombant en `[SELL-SKIPPED-NO-SNIPER]`. Réduction attendue du bruit ≈ 75-90 %. À vérifier empiriquement sur 1 semaine post-déploiement.

### 4.10 v2.4 — Bypass VPS direction + 3 modules ICT additionnels (2026-04-25)

Branche `feat/v24-bypass-vps-add-ict-strategies` — 8 commits regroupant la libération SELL et 4 modules ICT/HTF en pipeline cumulatif.

#### Motivation

Audit phase 0 a confirmé un **biais BUY-only architectural** (VPS produit ~98 % de signaux BUY, 0 SELL en 14 jours, conflict detector pénalisait toute contre-direction LOCAL/ICT). v2.4 supprime cette contrainte par défaut tout en gardant la protection news FTMO, et compense la perte du veto VPS par 4 modules ICT/HTF qui re-qualifient les setups bidirectionnels.

#### Inventaire des changements (commits 1-8)

| # | Commit | Étape pipeline | Effet |
|---|---|---|---|
| 1 | `bf468a7` | — | Refonte 14 nouveaux inputs + renommages (Hard_Cap_Risk, SL_Cap_Pips, Trading_Session_*) + split `Magic_Number` → `Magic_Number_BUY=888892` + `Magic_Number_SELL=888893` |
| 2 | `c7a1af5` | Direction Gate | `Use_VPS_Direction=false` (default) bypasse le conflict detector ; `Use_VPS_News_Protection=true` (default) garde BLACKOUT/PRE/POST ; `Force_Direction_Override` debug |
| 3 | `ee61034` | **Étape 3** (filtre HTF) | Premium/Discount Array Filter binaire — BUY ⊆ Discount D1[1] (Bid ≤ médiane), SELL ⊆ Premium D1[1] (Bid ≥ médiane). Fail-open si D1 indispo. |
| 4 | `50ee98e` | **Étape 4** (HTF bonus) | FVG H1 detection (lookback 50 bars, mitigated rejected) → bonus `+Weight_FVG_H1` (15) |
| 5 | `45e6c49` | **Étape 5** (HTF bonus) | Breaker Block M15 (counter-direction violée + retest, lookback 80, body ≥ 0.3×ATR) → bonus `+Weight_Breaker` (10) |
| 6 | `27f0c5d` | **Étape 6** (HTF bonus) | Mitigation Block M15 (same-direction intacte + retest, distinction nette vs Breaker) → bonus `+Weight_Mitigation` (5) |
| 7 | `cca9edf` | scoring + telemetry | Refactor accumulation HTF explicite + log unifié `[SCORE-V24]` ; WEEKLY-STATS perf 7j toutes les 24h via OnTimer |
| 8 | (ce commit) | doc + tag | MAJ §4.10 + tag `v2.4` |

#### Pipeline `CheckEntry` après v2.4

```
1.  Force_Direction_Override (debug bypass)              ← v2.4 cmt 2
2.  Direction selection : API > Local > London Range
3.  Direction Gate (Use_VPS_Direction)                   ← v2.4 cmt 2
4.  Premium/Discount Filter (étape 3)                    ← v2.4 cmt 3
5.  Conflict Detector (gated par Use_VPS_Direction)
6.  Quality Filters (P2/P3, DEAL v2 H4)
7.  Sniper M15 AnalyzeEntry → score brut /100
8.  FVG H1 bonus  (étape 4, +15)                         ← v2.4 cmt 4
9.  Breaker bonus (étape 5, +10)                         ← v2.4 cmt 5
10. Mitigation bonus (étape 6, +5)                       ← v2.4 cmt 6
11. [SCORE-V24] log breakdown (cap 100)                  ← v2.4 cmt 7
12. Score threshold check
13. Hard gates (sweep / BOS / pullback)
14. DEAL v2 size factor (MIN avec conflict)
15. ExecuteTrade(direction, size)
```

#### Bonus HTF cumulatif

Score Sniper de base /100 + jusqu'à `+30` HTF (15+10+5), capé à 100. Un setup avec FVG H1 ouverte + Breaker en retest + Mitigation intacte gagne le bonus maximum. Le bonus est appliqué **avant** le `scoreThreshold` check : un setup limite peut être sauvé par un contexte HTF favorable (philosophie ICT — HTF context renforce LTF setup).

#### Logs structurés v2.4

| Tag | Origine |
|---|---|
| `[VPS-BYPASS]` | Direction VPS ignorée (commit 2) |
| `[FORCE-DIR]` | Override actif (commit 2) |
| `[PD-FILTER-PASS]` / `[PD-FILTER-REJECT]` / `[PD-FILTER-DECISION]` | Premium/Discount HTF (commit 3) |
| `[FVG-H1-PASS]` / `[FVG-H1-NONE]` / `[FVG-H1-MITIGATED]` | FVG H1 (commit 4) |
| `[BREAKER-DETAIL]` / `[BREAKER-PASS]` / `[BREAKER-NONE]` | Breaker M15 (commit 5) |
| `[MITIG-DETAIL]` / `[MITIG-PASS]` / `[MITIG-NONE]` | Mitigation M15 (commit 6) |
| `[SCORE-V24]` | Breakdown unifié (commit 7) |
| `[WEEKLY-STATS]` | Snapshot perf 7j (commit 7) |

#### Inputs v2.4 (defaults)

```
// BYPASS / DEBUG
Use_VPS_Direction              = false   // v2.3 implicite=true → biais BUY-only
Use_VPS_News_Protection        = true    // FTMO safety, BLACKOUT/PRE/POST gardés
Log_Verbose                    = false
Use_Debug_Mode                 = false
Force_Direction_Override       = false
Force_Direction_Value          = "BUY"

// ICT EXTENSIONS (toggles)
Enable_Premium_Discount_Filter = true
Enable_Breaker_Block           = true
Enable_Mitigation_Block        = true
Enable_FVG_H1                  = true

// SCORING WEIGHTS HTF (v2.4.1 — uniquement les 3 reellement consommes)
// Les 5 weights orphelins (Weight_Sweep / Weight_BOS / Weight_FVG_M5 /
// Weight_OB / Weight_Fib_OTE) ont ete supprimes en v2.4.1 — voir §4.10.1.
Weight_FVG_H1                  = 15      // ✅ actif commit 4
Weight_Breaker                 = 10      // ✅ actif commit 5
Weight_Mitigation              = 5       // ✅ actif commit 6

// RISK / SESSION
Hard_Cap_Risk                  = 1.5     // ex-Max_Risk_Percent (durci de 2.0)
SL_Cap_Pips                    = 50      // ex-Sniper_SL_Max_Pips
TradeThrottleSeconds           = 3600
Skip_Rollover                  = true
Trading_Session_Start          = "00:00" // ex-Session_Start
Trading_Session_End            = "23:59" // ex-Session_End

// MAGIC SPLIT
Magic_Number_BUY               = 888892
Magic_Number_SELL              = 888893
```

#### Rollback safety

| Toggle | `false` → comportement |
|---|---|
| `Enable_FVG_H1` | retire bonus HTF FVG H1 |
| `Enable_Breaker_Block` | retire bonus HTF Breaker |
| `Enable_Mitigation_Block` | retire bonus HTF Mitigation |
| `Enable_Premium_Discount_Filter` | retire le filtre HTF binaire (étape 3) |
| `Use_VPS_Direction = true` | revient au comportement v2.3 (conflict detector actif, bias BUY si VPS pousse BUY) |
| `Use_VPS_News_Protection = false` | retire BLACKOUT/PRE/POST (à utiliser uniquement en démo) |

Note : aucun changement runtime sans toggle utilisateur. Compilation v2.4 sur les 4 commits 1-3 vérifiée 0 erreur (checkpoint 2026-04-25).

#### Limites connues v2.4

- `Weight_Sweep` / `Weight_BOS` / `Weight_FVG_M5` / `Weight_OB` / `Weight_Fib_OTE` restent **hardcodés** dans `CSniperM15::CalculateScore` (`GoldML_SniperEntry_M15.mqh`). **Action v2.4.1** : ces 5 inputs orphelins ont été **supprimés** du `.mq5` (cf §4.10.1) — refactor propre + exposition via inputs reporté à **v2.5** avec backtest avant/après.
- WEEKLY-STATS premier log ~60 s après EA start (`g_LastWeeklyStatsTime=0`), ensuite throttle 24 h. Donne 0 trades en démo fraîche tant qu'aucun deal fermé sur les magics BUY/SELL n'est dans l'historique.

### 4.10.1 v2.4.1 — Corrections audit (2026-04-25)

PR de cleanup post-audit `audit_v24_coherence_performance.md` (verdict
"READY WITH WARNINGS"). 5 corrections, 1 commit chacune, push après
chaque commit. Aucun changement de logique de trading, uniquement
câblage d'inputs orphelins + hygiène de scoring.

#### Corrections appliquées

| # | Correction | Audit ref | Effet |
|---|-----------|-----------|-------|
| 1 | Câbler `TradeThrottleSeconds` | §6 + §11 P2-A | Throttle inter-trades effectif (default 1h). Persistance restart EA via `RecalcDailyStats`. |
| 2 | `Force_Direction_Override` respecte la protection news | §6 + §11 P2-B | `timingMode` n'est plus hardcodé `CLEAR` ; reprend `g_Signal.timing_mode` si API <300s. La gate `Use_VPS_News_Protection` redevient effective en mode debug. |
| 3 | Suppression de 5 weights orphelins (**Option C**) | §1 + §11 P2-D | `Weight_Sweep`, `Weight_BOS`, `Weight_FVG_M5`, `Weight_OB`, `Weight_Fib_OTE` retirés du `.mq5`. Conservés : `Weight_FVG_H1`, `Weight_Breaker`, `Weight_Mitigation` (les 3 réellement câblés). |
| 4 | Câbler 3 inputs cosmétiques | §1 + §11 P2-E | `Log_Verbose` guarde DIAGNOSTIC heartbeat 60s + breakdown `[SCORE-V24]`. `Use_Debug_Mode` ajoute trace `[DEBUG]` pré-signal. `Skip_Rollover` bloque trades 22:00-23:00 GMT. |
| 5 | Documentation §4.10 (ce paragraphe) | §10 + §11 P2-C | Note explicite sur les inputs orphelins supprimés + plan v2.5. |

#### Note Option C — pourquoi supprimer plutôt qu'exposer

Le scoring Sniper interne (`CSniperM15::CalculateScore` dans
`GoldML_SniperEntry_M15.mqh`) n'est **pas une simple combinaison
linéaire de 5 poids**. Il contient :

- plusieurs variantes par type de sweep (PWH/PWL/PDH/PDL/EQ-highs/EQ-lows
  + recent + displacement)
- un score OB conditionné par direction et par distance
- un fallback Fib OTE de +20 quand le pullback est dans la zone
- des bonus M5 (CHoCH-M5, BOS-M5, structure align M5, session)

Une exposition naïve de 5 weights aurait donné **l'illusion de contrôle**
sans correspondre à la réalité du calcul. Plutôt que créer un faux fix
(Option A) ou bloquer v2.4.1 sur un refactor lourd estimé 6-8h
+ backtest (Option B), v2.4.1 retire les 5 inputs orphelins et planifie
le travail propre :

> **v2.5** inclura un refactor de `CalculateScore` exposant des poids
> représentatifs du calcul réel, accompagné d'un **backtest avant/après**
> sur historique XAUUSD pour valider la nouvelle paramétrisation.

#### Comportement runtime des 4 nouveaux câblages

```
TradeThrottleSeconds=3600
  → REJECT "Throttle inter-trades Xs/3600s" si elapsed < 3600
  → 0 = throttle desactive

Skip_Rollover=true
  → REJECT "Skip_Rollover (fenetre 22:00-23:00 GMT, spread anormal)"
    si TimeCurrent().hour == 22

Log_Verbose=true
  → DIAGNOSTIC 60s + [SCORE-V24] breakdown actifs
Log_Verbose=false
  → DIAGNOSTIC + [SCORE-V24] supprimes (REJECT/TRADE OPENED restent)

Use_Debug_Mode=true
  → trace [DEBUG] CheckEntry pre-signal a chaque appel CheckEntry
Use_Debug_Mode=false (default)
  → aucune trace additionnelle
```

#### Rollback v2.4.1 → v2.4

| Toggle | Valeur | Effet rollback |
|---|---|---|
| `TradeThrottleSeconds` | `0` | Désactive le throttle (comportement v2.4) |
| `Skip_Rollover` | `false` | Désactive le check 22:00-23:00 GMT |
| `Log_Verbose` | `true` | DIAGNOSTIC + SCORE-V24 actifs (logs v2.4 identiques) |
| `Use_Debug_Mode` | `false` | Pas de trace [DEBUG] |

Note : `Force_Direction_Override` n'a pas de rollback — la correction du
bypass news est un correctif de sécurité.

---

### 4.10.2 v2.4.2 — Final cleanup avant démo (2026-04-25)

PR de cleanup final post-audit `audit_v241_coherence_performance.md`
(verdict "READY FOR DEMO"). 5 commits, 1 push après chaque.
**Aucun changement de logique de trading** : les 3 corrections code
adressent des cas-limites résiduels (un orphelin, un edge cross-jour,
un trou de sécurité news en mode debug). Les 2 corrections restantes
sont cosmétiques (banner) et documentaires (cette section).

#### Corrections appliquées

| # | Correction | Audit ref | Effet |
|---|-----------|-----------|-------|
| C1 | Suppression `API_MarketData_URL` orphelin | P2-A v2.4.2 | Input déclaré ligne 52 mais plus consommé depuis cleanup `PushMarketData()` du 2026-04-03. Cleanup conforme principe Option C. |
| C2 | Persistance throttle cross-jour | P2-B v2.4.2 | `RecalcDailyStats` étend la fenêtre `HistorySelect` à `[hier 00:00 ; demain 00:00]` pour restaurer `g_LastTradeTime` quand l'EA redémarre après minuit avec un trade exécuté la veille. Stats daily (`g_TradesToday`, `g_DailyPnL`) restent gates sur `dayStart`. |
| C3 | Force_Direction skip si API stale + protection news ON | P2-E v2.4.2 + concern §6 | Trou résiduel post-P2-B comblé (Option A). Si `Force_Direction_Override=true` + `Use_VPS_News_Protection=true` + API stale (panne ou >300s) → `REJECT` avec log `[FORCE-DIR-API-STALE-SKIP]` (throttle 60s). Plus aucun fallback `timingMode=CLEAR` possible sous protection news active. |
| C4 | MAJ banner OnInit v2.3 → v2.4.2 | P2-D v2.4.2 (P2-F audit v2.4) | Banner config ligne 533 affiche maintenant `v2.4.2 (2026-04-25) | AUDIT: 0 critical / 0 warnings post-cleanup`. Cohérence visuelle avec multi-comptes futurs. |
| C5 | Documentation §4.10.2 (ce paragraphe) | P2-C v2.4.2 + récap audit | Section dédiée v2.4.2 + tableau récapitulatif final ci-dessous. |

#### Détail technique C2 — fenêtre HistorySelect

```mql5
// Avant (v2.4.1):
datetime dayStart = today 00:00;
datetime dayEnd   = today 00:00 + 24h;
HistorySelect(dayStart, dayEnd);  // rate trade hier 23:45 si restart 00:15

// Après (v2.4.2):
datetime scanStart = dayStart - 86400;  // hier 00:00
HistorySelect(scanStart, dayEnd);       // capture trade hier
// Stats daily restent gates : if(dealTime >= dayStart) { tradesCount++; ... }
```

Edge cases vérifiés :
- **Restart 00:15 après trade 23:45 hier** : capture OK, throttle restauré, pas de double-trade.
- **Restart 23:59 après trade 23:30 today** : capture OK, comportement v2.4.1 préservé.
- **Trade hier > 1h ago** : `g_LastTradeTime` restauré mais throttle (3600s) déjà écoulé → pas de blocage abusif.

#### Détail technique C3 — diagramme de décision Force_Direction

```
Force_Direction_Override=true + Force_Direction_Value=BUY|SELL
   │
   ├─► apiFresh = (g_Signal.is_valid && age <= 300s)
   │
   ├─► Use_VPS_News_Protection=true  AND  !apiFresh
   │      → [FORCE-DIR-API-STALE-SKIP] log (throttle 60s)
   │      → REJECT "Force_Direction skipped: API stale + protection ON"
   │      → return (trade NON exécuté)
   │
   ├─► apiFresh=true
   │      → timingMode = g_Signal.timing_mode
   │      → gate news en aval bloque si BLACKOUT/PRE/POST + Use_VPS=true
   │
   └─► apiFresh=false  AND  Use_VPS_News_Protection=false
          → timingMode = CLEAR (responsabilité utilisateur explicite)
          → trade exécuté en aveugle (mode debug volontaire)
```

#### Tableau récapitulatif — audit v2.4 → v2.4.2 (8 items)

| Item | Origine audit | Statut | Fix |
|------|---------------|--------|-----|
| P2-A : `TradeThrottleSeconds` orphelin | v2.4 | ✅ **Résolu v2.4.1** | `b52cf3d` |
| P2-B : `Force_Direction` bypasse news | v2.4 | ✅ **Résolu v2.4.1** + trou résiduel résolu v2.4.2 (C3) | `1469824` + `0f2c6b5` |
| P2-C : Doc §4.10 inputs orphelins | v2.4 | ✅ **Résolu v2.4.1** (§4.10.1) | `611bc3c` |
| P2-D : 5 weights orphelins (Option C) | v2.4 | ✅ **Résolu v2.4.1** | `bb0caf9` |
| P2-E : 3 inputs cosmétiques | v2.4 | ✅ **Résolu v2.4.1** | `d1fcfcc` |
| P2-F : Banner OnInit "v2.3" | v2.4 | ✅ **Résolu v2.4.2** (C4) | `6f650ad` |
| P2-G : Refactor cache Breaker/Mitigation | v2.4 | ⏳ **Reporté v2.5** (perf marginale 10-50µs) | — |
| P2-D bis : Refactor scoring + exposition poids réels | v2.4 | ⏳ **Reporté v2.5** explicitement (backtest avant/après) | — |
| **API_MarketData_URL orphelin** | v2.4.1 | ✅ **Résolu v2.4.2** (C1) | `4c890c4` |
| **`RecalcDailyStats` cross-jour** | v2.4.1 | ✅ **Résolu v2.4.2** (C2) | `9750cce` |

**Bilan** : 8 items prioritaires audit v2.4 + 2 items audit v2.4.1 = **10 items**.
8 résolus (5 en v2.4.1 + 3 code + 1 banner + 1 doc en v2.4.2).
2 reportés en v2.5 (P2-G perf marginale, P2-D bis refactor scoring lourd avec backtest).

#### Plan v2.5 (inchangé)

> **v2.5** = refactor `CSniperM15::CalculateScore` :
> - exposition des poids réels du scoring (pas les 5 weights orphelins, mais les coefficients effectifs : variantes sweep, OB par direction, fallback Fib OTE, bonus M5)
> - backtest avant/après sur historique XAUUSD pour valider la nouvelle paramétrisation
> - refactor cache Breaker/Mitigation (P2-G) en parallèle
> - estimé 6-8h dev + backtest

#### Statut déploiement v2.4.2

> **v2.4.2 = code propre pour déploiement démo + multi-comptes futurs.**
> 0 critical / 0 warnings post-cleanup. Logique de trading **identique à v2.4.1**.
> Compile MetaEditor (F7) attendu **clean** (aucun nouveau warning).
>
> Workflow attendu Mickaël :
> 1. Pull `feat/v242-final-cleanup` sur VPS Windows
> 2. Compile MetaEditor (F7)
> 3. Si OK → re-audit minimal v2.4.2 (vérification)
> 4. Si re-audit OK → déploiement démo FTMO
>
> Si erreurs compile → corrections sur la même branche.

---

## 5 — Inventaire EA MQL5

### 5.1 Projet principal : `XAUUSD---MT5` (repo `/home/traderadmin`)

Fichiers trackés git :

| Fichier | Lignes | Rôle | Dernière modif |
|---|---|---|---|
| `Gold_News_Institutional_EA.mq5` | **2235** | Point d'entrée EA (OnInit/OnTick/OnTrade), magic `888892`, `#property version "2.10"`, Print label `v2.3` (MAJ 2026-04-23 — Sniper-gated SELL alerts) | 2026-04-23 |
| `GoldML_SniperEntry_M15.mqh` | **1874** | `CSniperM15` — détection sweep/BOS/CHoCH/pullback, scoring 0-100 ; expose `ValidateSetup(direction)` (dry-run v2.3) | 2026-04-23 |
| `GoldML_PositionManager_V2.mqh` | 901 | `CPositionManagerV2` — partial TP, BE, trailing ATR | 2026-04-15 20:05 |
| `GoldML_QualityFilters.mqh` | **1018** | `CQualityFilters` — cooldown, daily limit, range filter, **DEAL v2 H4**, **P2 veto H4 hard** + **P3 DEAL-v2 reject threshold** (MAJ 2026-04-22) | 2026-04-22 |
| `GoldML_ICT_Detector.mqh` | 527 | `CICT_Detector` — primitives CHoCH/BOS/FVG/OB, `DetectShiftM5` | 2026-04-17 14:07 |
| `GoldML_LiquidityLevels.mqh` | 515 | `CLiquidityLevels` — PDH/PDL, PWH/PWL, session, EQL, `MarkLevelSwept` | 2026-04-17 13:57 |
| `GoldML_JsonParser.mqh` | 221 | Parser JSON robuste (fix AUDIT-C1) | 2026-03-27 14:44 |
| `Gold_News_Institutional_EA.mq5.before_restore` | — | Backup avant restauration | 2026-04-02 18:01 |

Dépendances entre modules :

```
Gold_News_Institutional_EA.mq5
├── <Trade/Trade.mqh>, <Trade/PositionInfo.mqh>  (MQL5 stdlib)
├── GoldML_ICT_Detector.mqh
├── GoldML_SniperEntry_M15.mqh
│     └── GoldML_ICT_Detector.mqh
│     └── GoldML_LiquidityLevels.mqh
├── GoldML_PositionManager_V2.mqh
├── GoldML_QualityFilters.mqh
├── GoldML_JsonParser.mqh   (Audit-C1 : parser JSON robuste)
└── GoldML_LiquidityLevels.mqh
```

### 5.2 Inputs de l'EA (valeurs par défaut du snapshot)

#### API News Trading
```
API_News_URL        = "http://86.48.5.126:5002/v1/news_trading_signal/quick"
API_MarketData_URL  = "http://86.48.5.126:5002/v1/market_data"
API_Timeout         = 5000     (ms)
API_Refresh_Seconds = 30
API_Auth_Token      = ""       (à configurer)
```

#### Trading rules
```
Min_Confidence                = 60.0
Allow_PreNews_Trading         = true
Allow_PostNews_Fade           = true
Allow_Counter_Signal_Trading  = true
```

#### Sniper SMC (M15)
```
Sniper_Swing_Lookback    = 80         (= 20 h sur M15)
Sniper_Min_Swing_Bars    = 4
Sniper_Fib_Entry_Min     = 0.50
Sniper_Fib_Entry_Max     = 0.786      (ICT Golden Pocket)
Sniper_Fib_Optimal       = 0.618
Sniper_Max_Bars_After_BOS   = 60      (= 15 h)
Sniper_Max_Bars_After_Sweep = 60
Sniper_Require_Sweep     = true
Sniper_Require_BOS       = true
Sniper_Min_RR            = 2.0
Sniper_Min_Score         = 55
Sniper_Max_Spread        = 7.0 pips
Sniper_SL_Buffer_Pips    = 3.0
Sniper_SL_Min_Pips       = 25.0
Sniper_SL_Max_Pips       = 55.0
Use_M5_Confirmation      = true
```

#### Position management
```
Enable_Partial_TP        = true
Partial_Percent          = 40.0
Partial_At_RR            = 1.0
Move_To_BE_After_Partial = true
BE_Buffer_Pips           = 3.0
Enable_Trailing          = true
Trail_ATR_Mult           = 1.5
```

#### Risk management FTMO
```
Risk_Percent         = 1.0           (% equity per trade)
Max_Risk_Percent     = 2.0
Base_Lot_Size        = 0.10          (DEPRECATED)
Magic_Number         = 888892
Max_Daily_Loss_EUR   = 400.0
Max_Daily_Trades     = 6
FTMO_Daily_DD_Limit  = 4.5           (%)
FTMO_Initial_Balance = 10000.0
FTMO_Total_DD_Limit  = 9.0           (%)
```

#### Sessions, test mode, ICT, divers
```
Phase_Test_Force_Lot   = 0.01       (0.0 = désactivé)
Enable_Session_Filter  = true
Session_Start          = "00:00"
Session_End            = "21:00"
Enable_Local_Mode      = true
Local_Min_Confidence   = 55.0
Local_Size_Factor      = 0.7
Local_Max_Daily_Trades = 3
Enable_ICT_Liquidity   = true        (Phase 1)
Enable_Dashboard       = true
Enable_Alerts          = true
```

#### Garde-fous P2/P3 + Alertes SELL (EA v2.3 — 2026-04-23, voir §4.9)
```
Enable_H4_Hard_Veto            = true    (P2 : veto H4 structurel BEARISH LH+LL / BULLISH HH+HL)
DEAL_Reject_Threshold          = -20     (P3 : seuil configurable, remplace hardcode -25 ; -99 = rollback safety)
Enable_SellOpportunity_Alerts  = true    (Master switch : false = rollback total au comportement pré-alertes)
SellAlert_Push_Notification    = true    (SendNotification() push MT5 mobile natif)
SellAlert_Logs_Only            = false   (true = logs only, pas de push)
SellAlert_Require_Sniper       = true    (v2.3 : alertes ICT-grade Sniper M15 ; false = legacy LOCAL seul)
SellAlert_Sniper_Min_Score     = 70      (v2.3 : seuil score Sniper pour déclencher [SELL-OPPORTUNITY-ICT])
```

### 5.3 Projet secondaire : `Turtle` (FTMO 100K, indépendant)

Situé dans `/home/traderadmin/Turtle/` — dossier non présent dans le repo principal.

| Fichier | Rôle |
|---|---|
| `MQL5/Experts/Turtle/TURTLE_EA.mq5` | EA Turtle (Dennis 1983), Systems 1 & 2 |
| `MQL5/Include/Turtle/AtrCalculator.mqh` | Calcul ATR 20j |
| `MQL5/Include/Turtle/FtmoRules.mqh` | Garde-fous FTMO |
| `MQL5/Include/Turtle/Logger.mqh` | Logging |
| `MQL5/Include/Turtle/RiskManager.mqh` | Risk % dynamique |
| `MQL5/Include/Turtle/SymbolPresets.mqh` | Presets BTC/GOLD/US100/US30/OIL |
| `MQL5/Include/Turtle/TradeManager.mqh` | Gestion ordres |
| `MQL5/Include/Turtle/TurtleDetector.mqh` | Détection breakouts 20/55/10 |

Presets :

| Preset | Symbole | System | Entry/Exit (jours) | ATR Mult | Risk % |
|---|---|---|---|---|---|
| BTC   | BTCUSD     | S1 | 20/10 | 2.0 | **0.5** |
| GOLD  | XAUUSD     | S1 | 20/10 | 2.0 | 1.0 |
| US100 | US100.cash | S1 | 20/10 | 2.0 | 1.0 |
| US30  | US30.cash  | S1 | 20/10 | 2.0 | 1.0 |
| OIL   | USOIL      | **S2** | 55/20 | **3.0** | 1.0 |
| CUSTOM | *         | User | User | User | User |

Un backup flat existe dans `/home/traderadmin/Turtle_flat_backup/`.

---

## 6 — Configuration système

### 6.1 OS et runtime

| Élément | Valeur |
|---|---|
| Distribution | **Ubuntu 24.04.3 LTS (Noble Numbat)** |
| Kernel | `Linux 6.8.0-94-generic` (PREEMPT_DYNAMIC, Jan 2026) |
| Hostname | `vmi2828096` |
| Python système | **3.12.3** — `/usr/bin/python3` |
| Gestionnaire de paquets | `apt` / `dpkg` |
| Virtualenvs | `/root/gold_ml_phase4/venv/` + `/root/gold_ml_phase4/ml_venv/` + `/opt/vps-api/venv/` |
| Init system | `systemd` |
| Firewall | **UFW actif** (voir §1.3) |
| Intrusion | **fail2ban** actif |

### 6.2 MT5

- MT5 tourne sur un **VPS Windows séparé** (pas sur ce VPS Linux).
- Version MT5 : [À CLARIFIER AVEC MICKAËL] — probablement MT5 build récent compatible FTMO.

### 6.3 Variables d'environnement critiques

Fichier `/etc/goldml/.env` (chargé par `gold_intelligence.service` via `EnvironmentFile=`) :

| Variable | Rôle | Stocké |
|---|---|---|
| `API_TOKEN` | Auth Bearer pour les routes protégées | ✅ |
| `HMAC_SECRET` | Signature HMAC des réponses | ✅ |
| `ANTHROPIC_API_KEY` | Claude Decision Engine (actuellement désactivé) | ✅ |
| `FRED_API_KEY` | Accès à FRED (TIPS, Fed funds, yield curve) | ✅ |

> **Sécurité** : `vps-api-secured/server.py` contient encore en dur `API_KEY = "Gold_ML_VPS_2025_SecretKey_LS_Mickael_ABC123"` + `SENDER_PASSWORD` Gmail — **[À CORRIGER]** à migrer vers env file.

### 6.4 Sources de données externes utilisées

| Source | Usage | Fréquence |
|---|---|---|
| Yahoo Finance (`yfinance`) | DXY (`DX-Y.NYB`), ^TNX, VIX, Gold | 5 min / 15 min / 30 s |
| FRED API | TIPS yield, DFII10, Fed funds, yield curve 10Y2Y | 5 min |
| CFTC COT (Legacy Futures Only) | Positionnement institutionnel Gold | Hebdo |
| ForexFactory RSS | Calendar news Haute/Moyenne impact | 2 min |
| alternative.me | Fear & Greed Index | 5 min |
| Anthropic API | Claude Decision Engine (désactivé) | Paramétré (max 1 appel/30 s) |
| webhook.site (`692ce9b5-…`) | Notifications automation cycle | 15 min |

### 6.5 Rate limits / TTL configurés

```python
"ttl": {
    "gold_price":   30,
    "macro":        300,
    "cot":          3600,
    "news":         120,
    "sentiment":    300,
    "geopolitics":  600,
    "signal":        30,
},
"health_grace_s": 20,
```

---

## 7 — Backups et versioning

### 7.1 Repo Git — `Mickael-Creator/XAUUSD---MT5`

| Élément | Valeur |
|---|---|
| Remote | `https://github.com/Mickael-Creator/XAUUSD---MT5.git` |
| Branche active locale | `main` |
| Branches distantes | `main`, `claude/analyze-sell-trade-issue-nz5wD`, `claude/setup-gold-ml-system-GnRPn` |
| Worktree | `/home/traderadmin/` (monté comme repo root) |
| Synchronisation | `main` et `origin/main` sont alignés (aucun ahead/behind au snapshot) |

> ⚠️ **[À CORRIGER D'URGENCE]** — Le remote Git contient un **token GitHub en clair** dans son URL (`ghp_...`). Tout `git remote -v` l'expose. À régénérer côté GitHub (révoquer) et reconfigurer avec un credential helper ou en clean URL.

### 7.2 Derniers commits (20 derniers)

```
bbe9116 fix: log pullback après RefreshM5Data + throttle log 100->10
e618456 fix: throttle statics function-scope + swing lookback 24->80
2ccf7a7 fix: throttle direction only + reset TimeGMT vérifié
89f4be6 fix: Max Bars After BOS 12 -> 60 (15h)
3971b80 fix: throttle anti-répétition 30s→300s (1 bougie M5)
86351ba fix: SL points->pips + lot calc pipValue correct + garantie minLot
c427afc fix: anti-rep skip AVANT analyse + pullback OTE fallback + lookback M5 deja 80
0f45a30 fix: Max SL 45 -> 55 pips + anti-repetition OnTick + logs post-BOS pullback score
9476aee fix: desactiver Range Filter ATR — redondant avec pipeline ICT Sweep+BOS+CHoCH
981629c fix: P1 CHoCH 3 bougies + P2 tolerance FVG/OB 0.1xATR + P3 BOS scan +10 + MaxBarsAfterSweep 60 + MarkLevelSwept integre dans pipeline
ea57b4d fix: MarkLevelSwept post-trade (anti double-signal sur meme niveau ICT)
977d59a feat: logs diagnostic strategie A/B/C/D/E + audit coherence C1-C5 valide
0c09ba9 fix: scan 96 bougies (24h) + EQL réactivé + Asian Range ATR dynamique + Max_Spread défaut 7.0 pips FTMO + Session défaut 00:00-21:00 GMT
ff19188 fix: P4b lotStep alignement apres Phase_Test_Force_Lot override
38f5be6 fix: P4 re-clamp lots au minLot broker apres override Phase_Test
517d687 fix: P1 sizeFactor MIN au lieu de cumul + P2 validation blackout PM:591 + P3 détection mode HEDGE FTMO
1471867 feat: Allow bidirectional trading — pipeline ICT détermine direction, VPS = confidence+timing only
83da47d fix: B1 lot input Phase_Test + B2 confidence LOCAL/LONDON + B3 POST_NEWS sizeFactor + M1 reclaimBar>=1 + M2 refresh 07/12h GMT + M3 reset jour TimeGMT
52697ba fix: desactiver EqualHL temporaire + cap absolu 10 niveaux
59b7dab fix: Equal H/L strict max 3 chaque + cap global 20 niveaux
```

Aucun tag de version actif dans le repo au snapshot (`git tag -l` est vide).

### 7.3 Stratégie de backup existante

| Mécanisme | Fréquence | Source | Destination |
|---|---|---|---|
| Cron `0 4 * * *` | Daily 04:00 | `/root/gold_ml_phases/*.db` (⚠️ chemin probablement mort) | `/root/backups/YYYYMMDD/` |
| Rotation logs cron | Weekly Dim 03:00 | `/root/gold_ml_phases/logs/*.log` (> 7 jours) | Supprimés |
| Rotation logs cron | Weekly Dim 03:00 | `/var/log/*.log` (> 100 MB) | Supprimés |
| `RotatingFileHandler` calendar_monitor | À chaud (10 MB, 5 backups) | `calendar_monitor.log` | `.log.1` à `.log.5` |
| `WatchedFileHandler` gold_intelligence | À chaud | `/root/gold_ml_phase4/logs/gold_intelligence.log*` | 20+ fichiers gz |
| `.before_restore` EA | Manuel | `Gold_News_Institutional_EA.mq5` | `.before_restore` dans `/home/traderadmin/` |
| `.backup`, `.bak_*`, `.save` Python | Manuel | Plusieurs scripts | Dans `/root/gold_ml_phase4/` |

Dossiers de backup historique :

- `/root/backups/` — 109 sous-dossiers `YYYYMMDD` depuis 2026-01-08, total **1.3 MB**
- `/root/gold_ml_phase4/archive_obsolete/` + `/archives/` + `/_archive_old/` — code legacy
- `/root/gold_ml_phase4/logs/archives_YYYYMM/` — logs archivés mensuel

---

## 8 — Problèmes connus et TODO technique

### 8.1 Bugs identifiés mais pas encore corrigés

| Sévérité | Problème | Localisation | Note |
|---|---|---|---|
| 🟥 Critique | Token GitHub exposé dans `git remote -v` | `/home/traderadmin/.git/config` | À régénérer + cleanup |
| 🟥 Critique | `API_KEY` + mot de passe Gmail en dur dans `vps-api-secured/server.py` | `/opt/vps-api/server.py` | À migrer vers env file |
| 🟧 Élevé | Crons référencent `/root/gold_ml_phases/` (inexistant) | crontab `root` | 5+ tâches probablement mortes (data collector 30 min, ML optimization 2h, daily check, backup DBs, log rotation) |
| 🟧 Élevé | `gold_intelligence.db` fait **611 MB** | `/root/gold_ml_phase4/` | Pas de VACUUM/compaction — va grossir indéfiniment |
| 🟨 Modéré | Webhook automation pointe vers webhook.site (endpoint de test) | `automation_bridge.py:15` | Log : `⚠️ Webhook error (ignored): 404` |
| 🟨 Modéré | Unit `gold_intelligence.service` déclare `User=goldml` mais process tourne en `root` | `/etc/systemd/system/gold_intelligence.service` | Inconsistance à résoudre |
| 🟨 Modéré | `calendar_monitor.py` contient `CALENDAR_API_KEY = 'votre_cle_api_si_necessaire'` | ligne 43 | Placeholder jamais complété |
| 🟩 Mineur | 3 variantes `3_prepare_ml_dataset*.py` cohabitent | `/root/gold_ml_phase4/` | Nettoyer |
| 🟩 Mineur | `claude_decision_engine.py` toujours présent mais désactivé dans `gold_intelligence.py:29` | — | Retirer ou réactiver selon décision |

### 8.2 Limitations actuelles

- **Pas de HTTPS** : toutes les API (5000/5001/5002) sont en HTTP clair — tokens Bearer circulent en clair sur Internet.
- **Pas de reverse proxy** : nginx n'est pas installé malgré la présence de `nginx_goldml.conf`.
- **Pas de monitoring externe** : pas de Grafana / Prometheus / Sentry — tout repose sur les logs locaux + cron alert shell.
- **Pas de CI/CD** : pas de workflow GitHub Actions visible dans le repo.
- **Pas de tests automatiques** : présence de `test_*.py` mais exécution manuelle uniquement.
- **Pas de tag de version** Git — traçabilité reposant sur les hashes de commits.
- **Legacy multi-versions** : beaucoup de fichiers `.backup`, `.bak_*`, `.before_restore`, `.save`, `.PROD_OK_*` qui alourdissent l'arborescence.
- **Biais BUY-only architectural** (observé pré-2026-04-22) : sur la fenêtre d'observation disponible avant cette MAJ, le VPS a émis **0 SELL**, le Sniper a détecté **0 HIGH sweep**, et le filtre DEAL-v2 n'a produit **0 reject**. Le système était donc structurellement incapable de prendre un SELL. **Partiellement contenu depuis 2026-04-22** par P2 (veto H4 structurel, bloque BUY sur H4 BEARISH LH+LL) + P3 (seuil DEAL-v2 configurable à -20, capture `CONTRA-STRONG + API 60-70 %`) — voir [§4.9](#49--garde-fous-p2p3--alertes-sell-opportunity-ea-v22--2026-04-22). Les alertes `[SELL-OPPORTUNITY]` permettent d'**observer** les SELL setups sans intervenir. **Décision finale pendante** après 5-7 jours de collecte data pour trancher sur une bascule éventuelle (réactivation SELL côté VPS, review Sniper, ajustement seuils).

### 8.3 Technical debt

1. Deux chemins applicatifs coexistent : `/root/gold_ml_phase4/` (actif) vs `/root/gold_ml_phases/` (référencé dans cron, inexistant).
2. Deux venvs Python séparés (`venv/` et `ml_venv/`) avec des versions divergentes de `pandas` (2.3.2 vs 2.3.3).
3. Pas de gestion dépendances en `requirements.txt` — `pip freeze` brut.
4. Plusieurs modules Python désactivés mais conservés (`python_sniper.py`, `claude_decision_engine.py`).
5. Plusieurs scripts `cot_*` redondants (`cot_fetcher.py`, `cot_advanced_fetcher.py`, `cot_endpoint.py`, `cot_service.py`).
6. `backend_api.py` définit des routes mais n'est plus exposé par aucun service actif.
7. Pas de schéma DB documenté — SQLite accédé ad-hoc.

### 8.4 Tâches en attente (inférées des commentaires code)

- **Phase 1 Liquidité ICT** (approche A) : niveaux ICT calculés (`CLiquidityLevels`) mais **pas encore branchés dans le sweep principal** (commentaire `GoldML_LiquidityLevels.mqh:15`).
- **Phase 2** : réécriture du sweep pour consommer les niveaux ICT — en attente.
- Normaliser unit systemd pour forcer `User=goldml`.
- Migration `claude_decision_engine` : décision retrait définitif ou réactivation.

---

## 9 — Monitoring et observabilité

### 9.1 Logs applicatifs

| Source | Chemin | Taille au snapshot | Rotation |
|---|---|---|---|
| `gold_intelligence` (Flask 5002) | `/root/gold_ml_phase4/logs/gold_intelligence.log` | 564 kB (courant) + 20+ archives `.gz` | `WatchedFileHandler` + cron hebdo |
| `calendar_monitor` (gunicorn 5000) | `/root/gold_ml_phase4/calendar_monitor.log` | — | `RotatingFileHandler` (10 MB × 5) |
| `automation_bridge` | systemd journal | — | `journalctl` natif |
| `dxy_fetcher` | systemd journal + `dxy_fetcher.log` racine `/root/` | 2.4 MB | — |
| `data_collector` | `/root/gold_ml_phase4/logs/data_collector.log` + archives `.gz` | 16 kB (courant) | Hebdo cron |
| `vps-api-secured` | `/var/log/vps-api-secured.log` + systemd journal | — | — |
| Logs EA (côté VPS Windows) | [À CLARIFIER AVEC MICKAËL] — probablement MT5 `Experts/` | — | — |
| `bridge.log`, `bridge_service_error.log.1` | `/root/gold_ml_phase4/logs/` | — | — |
| `20260420_filtered.log` | `/home/traderadmin/` | **43 MB** | — |

### 9.2 Rotation et cleanup

- Cron hebdo (Dim 03:00) supprime logs > 7 jours dans `/root/gold_ml_phases/logs/` (⚠️ chemin inexistant) et logs > 100 MB dans `/var/log/`.
- `RotatingFileHandler` pour `calendar_monitor.py` : `maxBytes=10 MB`, `backupCount=5`.
- `WatchedFileHandler` pour `gold_intelligence.py` : pas de rotation interne, dépend du cron.

### 9.3 Alertes configurées

| Type | Déclencheur | Destination |
|---|---|---|
| Alerte disque > 80 % | Cron 09:00 quotidien | `/var/log/disk_alerts.log` |
| Auto-restart `gold-ml-monitor` | Cron */10 min si service down | `/var/log/auto-restart.log` |
| Alert monitor `goldml` | Cron */2 min (`goldml_alert_monitor.sh`) | [À CLARIFIER] contenu du script |
| Alerte email (`vps-api-secured`) | Déclenché par code Flask | Destinataire `ls.mickaell@gmail.com` (via Gmail SMTP) |
| Webhook automation | Cycle 15 min (auto) | `webhook.site/692ce9b5-…` (test endpoint, retourne 404) |

### 9.4 Dashboards de supervision

Aucun dashboard de supervision externe détecté au snapshot (ni Grafana, ni Kibana, ni Datadog, ni Prometheus).
Le "dashboard" évoqué dans l'EA (`Enable_Dashboard = true`) est un affichage graphique **sur le chart MT5 uniquement** (Objects MQL5), pas un outil web.

---

## Appendices

### A — Mapping des composants par rôle

| Rôle fonctionnel | Composant principal | Port | Statut |
|---|---|---|---|
| Signal temps réel pour EA | `gold_intelligence.py` | 5002 | RUNNING |
| Agrégation macro/calendar | `calendar_monitor.py` | 5000 | RUNNING |
| Fetch DXY/TNX | `dxy_fetcher.py` | — | RUNNING |
| Cycle automation macro | `automation_bridge.py` | — | RUNNING |
| API legacy | `vps-api-secured/server.py` | 5001 | RUNNING (mais répond 404 par défaut) |
| Détection ICT (BOS/CHoCH/FVG/OB) | `GoldML_ICT_Detector.mqh` | — | EA local |
| Niveaux de liquidité (PDH/PDL/EQL/…) | `GoldML_LiquidityLevels.mqh` | — | EA local (Phase 1) |
| Scoring sniper (0-100) | `GoldML_SniperEntry_M15.mqh` | — | EA local |
| Filtres qualité + DEAL v2 | `GoldML_QualityFilters.mqh` | — | EA local |
| Gestion positions | `GoldML_PositionManager_V2.mqh` | — | EA local |
| Parser JSON robuste | `GoldML_JsonParser.mqh` | — | EA local |

### B — Checklist « ce qui est à clarifier avec Mickaël »

- [ ] Chemin `/root/gold_ml_phases/` référencé dans cron : existe-t-il sur un autre mount/VPS ou crons morts ?
- [ ] Version exacte MT5 utilisée (build + broker FTMO).
- [ ] Statut de `vps-api-secured` port 5001 : encore consommé ou à décommissionner ?
- [ ] Statut de `backend_api.py` et des 3 services systemd `DISABLED` (`goldml-api`, `goldml-bridge`, `goldml-calendar-api`) : peut-on les supprimer ?
- [ ] Contenu / finalité de `goldml_alert_monitor.sh`.
- [ ] Webhook.site : endpoint de test volontaire ou à remplacer par Discord/Slack ?
- [ ] MT5 `Experts/` logs : accessibles depuis le VPS Windows ?
- [ ] `/home/traderadmin/20260420_filtered.log` (43 MB) : log de debug à archiver ou supprimer ?
- [ ] Unit `gold_intelligence.service` : utilisateur `goldml` volontaire ou bug (process tourne en root) ?
- [ ] Claude Decision Engine : retirer définitivement ou réactiver sous conditions ?

### C — Informations de connexion

- **VPS Linux** : `86.48.5.126` (hostname `vmi2828096`)
- **Ports publics** : 22 (SSH), 5000 (calendar), 5001 (legacy), 5002 (signal engine)
- **VPS Windows** : [À CLARIFIER — non observable depuis ce VPS]
- **Repo GitHub** : `https://github.com/Mickael-Creator/XAUUSD---MT5`

---

*Document généré automatiquement — 2026-04-22. Aucun fichier du système n'a été modifié lors de sa production.*
