#!/usr/bin/env python3
"""
Claude Decision Engine — AI-Powered Signal Enrichment
======================================================
Utilise l'API Claude (Anthropic) pour enrichir les signaux de trading
avec une analyse contextuelle avancée.

Architecture :
  - Appel async-safe via timeout strict (10s max)
  - Fallback gracieux : si Claude est indisponible, le signal original est retourné intact
  - Cache des réponses Claude pour éviter les appels redondants
  - Rate limiting intégré (max 1 appel / 30s)
"""

import os
import json
import time
import logging
from threading import Lock
from datetime import datetime
from copy import deepcopy

logger = logging.getLogger(__name__)

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

CLAUDE_CONFIG = {
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 512,
    "timeout": 10,
    "min_interval_seconds": 30,
    "temperature": 0.2,
    "backoff_529": [60, 120, 300],  # Exponential backoff on 529 Overloaded
    # Cost optimization
    "trading_hours_start": 7,   # UTC
    "trading_hours_end": 22,    # UTC
    "min_confidence_for_claude": 58,
    "cache_ttl_seconds": 300,   # 5 minutes
    "cache_gold_threshold": 2.0,   # ±$2
    "cache_confidence_threshold": 3,  # ±3%
}

# Dedicated alert logger for 529 errors → /var/log/goldml_alerts.log
_alert_logger = logging.getLogger("goldml_alerts")
if not _alert_logger.handlers:
    try:
        _ah = logging.FileHandler("/var/log/goldml_alerts.log")
        _ah.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
        _alert_logger.addHandler(_ah)
        _alert_logger.setLevel(logging.WARNING)
    except Exception:
        pass  # Alert log not writable — non-blocking

SYSTEM_PROMPT = """Analyste quant XAUUSD. Signal brut + données macro/COT/sentiment/géo.
Rôle: 1)Cohérence signal↔macro 2)Risques cachés 3)Ajuster confiance(-20 à +20) 4)Commentaire court.
Les données contextuelles sont envoyées de façon incrémentale: seules les valeurs ayant changé significativement sont incluses. Les champs absents n'ont pas changé depuis le dernier appel.
JSON uniquement:{"confidence_adjustment":<int>,"risk_flags":[<max 3>],"claude_commentary":"<max 150c>","signal_quality":"<STRONG|MODERATE|WEAK>"}"""

# ═══════════════════════════════════════════════════════════════════════════════
# DYNAMIC PROMPT — Threshold-based context filtering
# ═══════════════════════════════════════════════════════════════════════════════

# Semi-stable: only include if change exceeds threshold
CHANGE_THRESHOLDS = {
    "macro.dxy": 0.5,
    "macro.vix": 1.0,
    "macro.us10y": 0.1,
    "macro.real_rate": 0.1,
    "sentiment.fear_greed_index": 5,
}

# Stable: include at most once per interval (seconds)
STABLE_INTERVAL = 3600  # 1 hour
STABLE_KEYS = {"cot", "geopolitics"}


# ═══════════════════════════════════════════════════════════════════════════════
# ENGINE
# ═══════════════════════════════════════════════════════════════════════════════

class ClaudeDecisionEngine:
    """
    Enrichit les signaux de trading via l'API Claude.
    Thread-safe, avec rate limiting et fallback gracieux.
    """

    def __init__(self):
        self._lock = Lock()
        self._last_call_time = 0
        self._client = None
        self._enabled = False
        self._consecutive_529 = 0
        self._backoff_until = 0  # timestamp until which we skip calls
        # Dynamic prompt state
        self._prev_context = {}       # last sent context values (flat keys)
        self._stable_last_sent = {}   # timestamp of last inclusion for stable keys
        # Cost optimization: cached Claude response
        self._last_claude_cache = None  # {response, gold_price, confidence, direction, timestamp}
        self._init_client()

    def _init_client(self):
        """Initialise le client Anthropic si la clé API est disponible."""
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if not api_key:
            logger.warning("⚠️ ANTHROPIC_API_KEY not set — Claude enrichment disabled")
            return

        try:
            import anthropic
            self._client = anthropic.Anthropic(api_key=api_key)
            self._enabled = True
            logger.info("🧠 Claude Decision Engine initialized successfully")
        except ImportError:
            logger.warning("⚠️ anthropic package not installed — Claude enrichment disabled")
        except Exception as e:
            logger.error(f"❌ Claude client init failed: {e}")

    @property
    def is_enabled(self) -> bool:
        return self._enabled and self._client is not None

    # ═══════════════════════════════════════════════════════════════════════════
    # COST OPTIMIZATION RULES
    # ═══════════════════════════════════════════════════════════════════════════

    def _is_trading_session(self) -> bool:
        """RÈGLE 1 — Vérifie si on est en session de trading (Lun-Ven 07:00-22:00 UTC)."""
        now = datetime.utcnow()
        if now.weekday() > 4:  # Samedi=5, Dimanche=6
            return False
        return CLAUDE_CONFIG["trading_hours_start"] <= now.hour < CLAUDE_CONFIG["trading_hours_end"]

    def _is_positive_signal(self, signal: dict) -> bool:
        """RÈGLE 2 — Vérifie si le signal justifie un appel Claude."""
        return (
            signal.get("can_trade") is True
            and signal.get("confidence", 0) >= CLAUDE_CONFIG["min_confidence_for_claude"]
        )

    def _is_cache_valid(self, signal: dict) -> bool:
        """RÈGLE 3 — Vérifie si le cache Claude est encore exploitable."""
        if not self._last_claude_cache:
            return False
        cache = self._last_claude_cache
        elapsed = time.time() - cache["timestamp"]
        if elapsed >= CLAUDE_CONFIG["cache_ttl_seconds"]:
            return False
        price_delta = abs(signal.get("gold_price", 0) - cache["gold_price"])
        conf_delta = abs(signal.get("confidence", 0) - cache["confidence"])
        dir_changed = signal.get("direction") != cache["direction"]
        if price_delta >= CLAUDE_CONFIG["cache_gold_threshold"]:
            return False
        if conf_delta >= CLAUDE_CONFIG["cache_confidence_threshold"]:
            return False
        if dir_changed:
            return False
        return True

    def _apply_cached_response(self, signal: dict) -> dict:
        """Applique la dernière réponse Claude en cache au signal courant."""
        cache = self._last_claude_cache
        enriched = dict(signal)
        adj = cache["claude_adj"]
        original_conf = signal.get("confidence", 0)
        new_conf = max(0, min(100, original_conf + adj))
        enriched["confidence"] = new_conf
        enriched["claude_confidence_adj"] = adj
        enriched["claude_risk_flags"] = cache["risk_flags"]
        enriched["claude_commentary"] = cache["commentary"]
        enriched["claude_signal_quality"] = cache["signal_quality"]
        enriched["claude_enriched"] = True
        enriched["claude_cached"] = True
        return enriched

    # ═══════════════════════════════════════════════════════════════════════════

    def enrich_signal(self, signal: dict, context: dict = None) -> dict:
        """
        Enrichit un signal de trading avec l'analyse Claude.

        Args:
            signal: Le signal brut issu de _calculate_signal()
            context: Données contextuelles optionnelles (macro, news, etc.)

        Returns:
            Signal enrichi avec les champs claude_* ajoutés.
            En cas d'erreur, retourne le signal original sans modification.
        """
        if not self.is_enabled:
            return signal

        # ── RÈGLE 1 : Session de trading uniquement ──
        if not self._is_trading_session():
            logger.info("⏰ Claude skipped - hors session trading (UTC)")
            if self._last_claude_cache:
                return self._apply_cached_response(signal)
            return signal

        # ── RÈGLE 2 : Signal positif requis ──
        if not self._is_positive_signal(signal):
            logger.info("⏭️ Claude skipped - signal négatif (can_trade=False ou conf<58%)")
            return signal

        # ── RÈGLE 3 : Cache intelligent 5 minutes ──
        if self._is_cache_valid(signal):
            logger.info("♻️ Claude cached - contexte stable")
            return self._apply_cached_response(signal)

        # Rate limiting + 529 backoff
        with self._lock:
            now = time.time()

            # 529 backoff: skip call if still in cooldown
            if now < self._backoff_until:
                remaining = int(self._backoff_until - now)
                logger.warning(
                    f"⏳ Claude 529 backoff active — skipping call ({remaining}s remaining, "
                    f"streak={self._consecutive_529})"
                )
                return signal

            elapsed = now - self._last_call_time
            if elapsed < CLAUDE_CONFIG["min_interval_seconds"]:
                logger.debug(f"Claude rate limited — {elapsed:.0f}s since last call")
                return signal
            self._last_call_time = now

        try:
            result = self._call_claude(signal, context or {})
            # Success — reset 529 backoff
            if self._consecutive_529 > 0:
                logger.info(f"✅ Claude recovered after {self._consecutive_529} consecutive 529 errors")
                self._consecutive_529 = 0
                self._backoff_until = 0
            return result
        except Exception as e:
            is_529 = "529" in str(e) or "overloaded" in str(e).lower()
            if is_529:
                self._handle_529_backoff()
            logger.error(f"❌ Claude enrichment failed (graceful fallback): {e}")
            return signal

    def _handle_529_backoff(self):
        """Apply exponential backoff on 529 Overloaded errors."""
        backoff_steps = CLAUDE_CONFIG["backoff_529"]
        self._consecutive_529 += 1
        idx = min(self._consecutive_529 - 1, len(backoff_steps) - 1)
        wait_seconds = backoff_steps[idx]
        self._backoff_until = time.time() + wait_seconds

        msg = (
            f"🔴 API 529 Overloaded — backoff {wait_seconds}s "
            f"(attempt #{self._consecutive_529})"
        )
        logger.warning(msg)

        # Dedicated alert in goldml_alerts.log (distinct from generic API errors)
        _alert_logger.warning(
            f"API_529_OVERLOADED | streak={self._consecutive_529} | "
            f"backoff={wait_seconds}s | next_retry_after={self._backoff_until:.0f}"
        )

    def _build_dynamic_context(self, context: dict) -> dict:
        """
        Build a minimal context payload using threshold-based filtering.

        - Volatile data (signal fields): always included by caller
        - Semi-stable (DXY, VIX, US10Y, etc.): included only if delta > threshold
        - Stable (COT, geopolitics): included at most once per STABLE_INTERVAL
        """
        now = time.time()
        filtered = {}
        included_tokens_saved = 0

        for section in ("macro", "sentiment"):
            section_data = context.get(section, {})
            section_out = {}
            for key, value in section_data.items():
                flat_key = f"{section}.{key}"
                threshold = CHANGE_THRESHOLDS.get(flat_key)

                if threshold is not None:
                    prev = self._prev_context.get(flat_key)
                    if prev is not None:
                        try:
                            if abs(float(value) - float(prev)) < threshold:
                                included_tokens_saved += 1
                                continue
                        except (TypeError, ValueError):
                            pass
                    section_out[key] = value
                    self._prev_context[flat_key] = value
                else:
                    # No threshold defined — always include (e.g. sentiment label)
                    flat_key_lbl = f"{section}.{key}"
                    prev_lbl = self._prev_context.get(flat_key_lbl)
                    if prev_lbl != value:
                        section_out[key] = value
                        self._prev_context[flat_key_lbl] = value

            if section_out:
                filtered[section] = section_out

        # Stable sections: COT, geopolitics — max once per hour
        for section in STABLE_KEYS:
            section_data = context.get(section, {})
            if not section_data:
                continue

            last_sent = self._stable_last_sent.get(section, 0)
            if now - last_sent >= STABLE_INTERVAL:
                filtered[section] = section_data
                self._stable_last_sent[section] = now
                # Update prev_context for stable data too
                for key, value in section_data.items():
                    self._prev_context[f"{section}.{key}"] = value
            else:
                # Check if any value actually changed (force include if so)
                changed = {}
                for key, value in section_data.items():
                    flat_key = f"{section}.{key}"
                    if self._prev_context.get(flat_key) != value:
                        changed[key] = value
                        self._prev_context[flat_key] = value
                if changed:
                    filtered[section] = changed

        if included_tokens_saved > 0:
            logger.debug(f"📉 Dynamic prompt: {included_tokens_saved} semi-stable fields omitted (unchanged)")

        return filtered

    @staticmethod
    def _extract_json(raw_text: str) -> dict:
        """
        Extract first valid JSON object from Claude's response,
        regardless of surrounding text, code blocks, or formatting.
        Covers: pure JSON, ```json blocks, preamble text, trailing text.
        """
        text = raw_text.strip()

        # Fast path — direct parse (~88% of responses)
        try:
            return json.loads(text)
        except (json.JSONDecodeError, ValueError):
            pass

        # Find first '{' and extract balanced JSON object
        start = text.find('{')
        if start == -1:
            raise ValueError(f"No JSON object found in response: {text[:200]}")

        depth = 0
        in_string = False
        escape = False
        for i in range(start, len(text)):
            c = text[i]
            if escape:
                escape = False
                continue
            if c == '\\' and in_string:
                escape = True
                continue
            if c == '"':
                in_string = not in_string
                continue
            if in_string:
                continue
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return json.loads(text[start:i + 1])

        raise ValueError(f"Unbalanced JSON in response: {text[:200]}")

    def _call_claude(self, signal: dict, context: dict) -> dict:
        """Appel effectif à l'API Claude avec prompt dynamique optimisé."""
        # Signal fields — always included (volatile)
        sig = {
            "d": signal.get("direction"),
            "c": signal.get("confidence"),
            "t": signal.get("can_trade"),
            "b": signal.get("bias"),
            "m": signal.get("timing_mode"),
            "p": signal.get("gold_price"),
        }

        # Context — dynamically filtered
        ctx = self._build_dynamic_context(context)

        payload = {"s": sig}
        if ctx:
            payload["x"] = ctx

        user_message = json.dumps(payload, separators=(",", ":"))

        response = self._client.messages.create(
            model=CLAUDE_CONFIG["model"],
            max_tokens=CLAUDE_CONFIG["max_tokens"],
            temperature=CLAUDE_CONFIG["temperature"],
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": user_message}],
        )

        # Log token usage and estimated cost
        usage = response.usage
        input_tokens = usage.input_tokens
        output_tokens = usage.output_tokens
        # Pricing for claude-sonnet: $3/M input, $15/M output
        cost_estimate = (input_tokens * 3.0 / 1_000_000) + (output_tokens * 15.0 / 1_000_000)
        prompt_len = len(user_message)
        logger.info(
            f"💰 Tokens: in={input_tokens} out={output_tokens} | ~${cost_estimate:.4f} | prompt_chars={prompt_len}"
        )

        # Guard: ensure response contains a text block
        if not response.content or not hasattr(response.content[0], 'text'):
            raise ValueError(f"Unexpected response format: stop_reason={response.stop_reason}")

        claude_result = self._extract_json(response.content[0].text)

        # Validation des bornes
        adj = claude_result.get("confidence_adjustment", 0)
        adj = max(-20, min(20, int(adj)))

        # Enrichir le signal
        enriched = dict(signal)
        original_conf = signal.get("confidence", 0)
        new_conf = max(0, min(100, original_conf + adj))

        enriched["confidence"] = new_conf
        enriched["claude_confidence_adj"] = adj
        enriched["claude_risk_flags"] = claude_result.get("risk_flags", [])[:3]
        enriched["claude_commentary"] = str(claude_result.get("claude_commentary", ""))[:150]
        enriched["claude_signal_quality"] = claude_result.get("signal_quality", "MODERATE")
        enriched["claude_enriched"] = True

        # Update cost optimization cache
        self._last_claude_cache = {
            "timestamp": time.time(),
            "gold_price": signal.get("gold_price", 0),
            "confidence": signal.get("confidence", 0),
            "direction": signal.get("direction"),
            "claude_adj": adj,
            "risk_flags": enriched["claude_risk_flags"],
            "commentary": enriched["claude_commentary"],
            "signal_quality": enriched["claude_signal_quality"],
        }

        logger.info(
            f"🧠 Claude: conf {original_conf}→{new_conf} ({adj:+d}) | "
            f"quality={enriched['claude_signal_quality']} | "
            f"flags={enriched['claude_risk_flags']}"
        )

        return enriched

    def health_check(self) -> dict:
        """Status de santé du moteur Claude."""
        now = time.time()
        backoff_remaining = max(0, int(self._backoff_until - now)) if self._backoff_until else 0
        cache_age = round(now - self._last_claude_cache["timestamp"], 1) if self._last_claude_cache else None
        return {
            "enabled": self._enabled,
            "client_ready": self._client is not None,
            "model": CLAUDE_CONFIG["model"],
            "last_call_age_s": round(now - self._last_call_time, 1) if self._last_call_time else None,
            "consecutive_529": self._consecutive_529,
            "backoff_remaining_s": backoff_remaining,
            "dynamic_prompt": {
                "cached_fields": len(self._prev_context),
                "stable_sections_cached": list(self._stable_last_sent.keys()),
            },
            "cost_optimization": {
                "trading_session": self._is_trading_session(),
                "cache_age_s": cache_age,
                "cache_active": self._last_claude_cache is not None,
            },
        }


# ═══════════════════════════════════════════════════════════════════════════════
# SINGLETON
# ═══════════════════════════════════════════════════════════════════════════════

claude_engine = ClaudeDecisionEngine()
