#!/usr/bin/env python3
"""
Tests unitaires pour ClaudeDecisionEngine.
Utilise unittest.mock pour simuler l'API Claude — aucune vraie clé API requise.
"""

import json
import unittest
from unittest.mock import patch, MagicMock
from claude_decision_engine import ClaudeDecisionEngine, CLAUDE_CONFIG, STABLE_KEYS


# ═══════════════════════════════════════════════════════════════════════════════
# DONNÉES DE TEST
# ═══════════════════════════════════════════════════════════════════════════════

SAMPLE_SIGNAL = {
    "can_trade": True,
    "direction": "BULLISH",
    "bias": "BULLISH",
    "confidence": 72,
    "size_factor": 1.0,
    "wider_stops": False,
    "tp_mode": "NORMAL",
    "blackout_minutes": 0,
    "timing_mode": "CLEAR",
    "gold_price": 4425.50,
    "gold_source": "yahoo_v8",
    "timestamp": "2026-03-25T12:00:00Z",
    "error": None,
}

SAMPLE_CONTEXT = {
    "macro": {"us10y": 4.18, "real_rate": 1.75, "dxy": 95.8, "vix": 14.2},
    "cot": {"percentile": 68.0, "regime": "BULLISH", "net_positions": 245000},
    "sentiment": {"fear_greed_index": 62, "fear_greed_label": "Greed"},
    "geopolitics": {"tension_level": 6, "hot_zones_active": ["Ukraine", "Gaza"]},
}

MOCK_CLAUDE_RESPONSE = {
    "confidence_adjustment": 8,
    "risk_flags": ["DXY weakness may reverse", "VIX near floor"],
    "claude_commentary": "Signal cohérent avec macro dovish. DXY en baisse soutient l'or.",
    "signal_quality": "STRONG",
}


# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

class TestClaudeDecisionEngine(unittest.TestCase):

    def _make_engine_with_mock_client(self):
        """Crée un engine avec un client Anthropic mocké."""
        engine = ClaudeDecisionEngine.__new__(ClaudeDecisionEngine)
        engine._lock = __import__("threading").Lock()
        engine._last_call_time = 0
        engine._enabled = True
        engine._consecutive_529 = 0
        engine._backoff_until = 0
        engine._prev_context = {}
        engine._stable_last_sent = {}
        engine._last_claude_cache = None

        # Mock du client Anthropic
        mock_client = MagicMock()
        mock_response = MagicMock()
        mock_response.content = [MagicMock(text=json.dumps(MOCK_CLAUDE_RESPONSE))]
        mock_response.usage = MagicMock(input_tokens=300, output_tokens=80)
        mock_client.messages.create.return_value = mock_response
        engine._client = mock_client

        return engine

    def test_enrich_signal_adds_claude_fields(self):
        """enrich_signal() doit ajouter les champs claude_* au signal."""
        engine = self._make_engine_with_mock_client()
        result = engine.enrich_signal(SAMPLE_SIGNAL, SAMPLE_CONTEXT)

        self.assertTrue(result["claude_enriched"])
        self.assertEqual(result["claude_confidence_adj"], 8)
        self.assertEqual(result["confidence"], 80)  # 72 + 8
        self.assertEqual(result["claude_signal_quality"], "STRONG")
        self.assertEqual(len(result["claude_risk_flags"]), 2)
        self.assertIn("DXY weakness may reverse", result["claude_risk_flags"])
        self.assertIsInstance(result["claude_commentary"], str)

    def test_enrich_signal_preserves_original_fields(self):
        """enrich_signal() ne doit pas supprimer les champs originaux."""
        engine = self._make_engine_with_mock_client()
        result = engine.enrich_signal(SAMPLE_SIGNAL, SAMPLE_CONTEXT)

        self.assertEqual(result["direction"], "BULLISH")
        self.assertEqual(result["gold_price"], 4425.50)
        self.assertTrue(result["can_trade"])
        self.assertEqual(result["timing_mode"], "CLEAR")

    def test_confidence_bounded_0_100(self):
        """La confiance enrichie doit rester entre 0 et 100."""
        engine = self._make_engine_with_mock_client()

        # Test borne haute : 95 + 20 = 115 → capped à 100
        high_signal = dict(SAMPLE_SIGNAL, confidence=95)
        mock_high = dict(MOCK_CLAUDE_RESPONSE, confidence_adjustment=20)
        engine._client.messages.create.return_value.content[0].text = json.dumps(mock_high)
        engine._last_call_time = 0  # reset rate limit
        result = engine.enrich_signal(high_signal, SAMPLE_CONTEXT)
        self.assertLessEqual(result["confidence"], 100)

        # Test borne basse : 10 + (-20) = -10 → capped à 0
        low_signal = dict(SAMPLE_SIGNAL, confidence=10)
        mock_low = dict(MOCK_CLAUDE_RESPONSE, confidence_adjustment=-20)
        engine._client.messages.create.return_value.content[0].text = json.dumps(mock_low)
        engine._last_call_time = 0
        result = engine.enrich_signal(low_signal, SAMPLE_CONTEXT)
        self.assertGreaterEqual(result["confidence"], 0)

    def test_disabled_engine_returns_signal_unchanged(self):
        """Si le moteur est désactivé, le signal original est retourné tel quel."""
        engine = ClaudeDecisionEngine.__new__(ClaudeDecisionEngine)
        engine._lock = __import__("threading").Lock()
        engine._last_call_time = 0
        engine._enabled = False
        engine._client = None
        engine._consecutive_529 = 0
        engine._backoff_until = 0
        engine._prev_context = {}
        engine._stable_last_sent = {}

        result = engine.enrich_signal(SAMPLE_SIGNAL)
        self.assertEqual(result, SAMPLE_SIGNAL)
        self.assertNotIn("claude_enriched", result)

    def test_rate_limiting(self):
        """Les appels trop rapprochés doivent être ignorés."""
        engine = self._make_engine_with_mock_client()

        # Premier appel — passe
        result1 = engine.enrich_signal(SAMPLE_SIGNAL, SAMPLE_CONTEXT)
        self.assertTrue(result1.get("claude_enriched"))

        # Deuxième appel immédiat — invalidate cache to isolate rate limiting
        engine._last_claude_cache = None
        result2 = engine.enrich_signal(SAMPLE_SIGNAL, SAMPLE_CONTEXT)
        self.assertNotIn("claude_enriched", result2)

    def test_api_error_returns_original_signal(self):
        """En cas d'erreur API, le signal original est retourné intact."""
        engine = self._make_engine_with_mock_client()
        engine._client.messages.create.side_effect = Exception("API timeout")

        result = engine.enrich_signal(SAMPLE_SIGNAL, SAMPLE_CONTEXT)
        self.assertEqual(result, SAMPLE_SIGNAL)
        self.assertNotIn("claude_enriched", result)

    def test_malformed_json_response(self):
        """Si Claude retourne du JSON invalide, fallback gracieux."""
        engine = self._make_engine_with_mock_client()
        engine._client.messages.create.return_value.content[0].text = "Not valid JSON {{"

        result = engine.enrich_signal(SAMPLE_SIGNAL, SAMPLE_CONTEXT)
        self.assertEqual(result, SAMPLE_SIGNAL)

    def test_health_check(self):
        """health_check() retourne le bon status."""
        engine = self._make_engine_with_mock_client()
        health = engine.health_check()

        self.assertTrue(health["enabled"])
        self.assertTrue(health["client_ready"])
        self.assertEqual(health["model"], CLAUDE_CONFIG["model"])

    def test_risk_flags_capped_at_3(self):
        """Les risk_flags doivent être limités à 3 max."""
        engine = self._make_engine_with_mock_client()
        many_flags = dict(MOCK_CLAUDE_RESPONSE, risk_flags=["a", "b", "c", "d", "e"])
        engine._client.messages.create.return_value.content[0].text = json.dumps(many_flags)

        result = engine.enrich_signal(SAMPLE_SIGNAL, SAMPLE_CONTEXT)
        self.assertLessEqual(len(result["claude_risk_flags"]), 3)

    def test_adjustment_clamped_to_bounds(self):
        """L'ajustement de confiance est clampé à [-20, +20]."""
        engine = self._make_engine_with_mock_client()
        extreme = dict(MOCK_CLAUDE_RESPONSE, confidence_adjustment=50)
        engine._client.messages.create.return_value.content[0].text = json.dumps(extreme)

        result = engine.enrich_signal(SAMPLE_SIGNAL, SAMPLE_CONTEXT)
        self.assertEqual(result["claude_confidence_adj"], 20)  # Clamped


    def test_dynamic_prompt_omits_unchanged_semi_stable(self):
        """Semi-stable fields below threshold are omitted on subsequent calls."""
        engine = self._make_engine_with_mock_client()

        # First call — all context sent
        engine.enrich_signal(SAMPLE_SIGNAL, SAMPLE_CONTEXT)

        # Second call with tiny DXY change (0.1 < threshold 0.5)
        engine._last_call_time = 0
        engine._last_claude_cache = None  # bypass cache to test dynamic prompt
        ctx2 = {
            "macro": {"us10y": 4.18, "real_rate": 1.75, "dxy": 95.9, "vix": 14.2},
            "cot": SAMPLE_CONTEXT["cot"],
            "sentiment": SAMPLE_CONTEXT["sentiment"],
            "geopolitics": SAMPLE_CONTEXT["geopolitics"],
        }
        engine.enrich_signal(SAMPLE_SIGNAL, ctx2)

        # All changes are below threshold AND stable sections throttled
        # → filtered is empty → fallback sends full context to avoid blind judgement
        call_args = engine._client.messages.create.call_args
        user_msg = call_args.kwargs["messages"][0]["content"]
        payload = json.loads(user_msg)

        # Full context fallback: all sections present
        self.assertIn("x", payload)
        self.assertIn("macro", payload["x"])

    def test_dynamic_prompt_includes_significant_change(self):
        """Semi-stable fields above threshold ARE included."""
        engine = self._make_engine_with_mock_client()

        engine.enrich_signal(SAMPLE_SIGNAL, SAMPLE_CONTEXT)

        engine._last_call_time = 0
        engine._last_claude_cache = None  # bypass cache to test dynamic prompt
        ctx2 = {
            "macro": {"us10y": 4.18, "real_rate": 1.75, "dxy": 97.0, "vix": 14.2},
            "cot": SAMPLE_CONTEXT["cot"],
            "sentiment": SAMPLE_CONTEXT["sentiment"],
            "geopolitics": SAMPLE_CONTEXT["geopolitics"],
        }
        engine.enrich_signal(SAMPLE_SIGNAL, ctx2)

        call_args = engine._client.messages.create.call_args
        user_msg = call_args.kwargs["messages"][0]["content"]
        payload = json.loads(user_msg)

        # DXY change 1.2 > threshold 0.5 → must be included
        self.assertIn("macro", payload.get("x", {}))
        self.assertEqual(payload["x"]["macro"]["dxy"], 97.0)

    def test_dynamic_prompt_stable_throttled(self):
        """COT/geopolitics sent at most once per STABLE_INTERVAL."""
        engine = self._make_engine_with_mock_client()

        # First call — COT and geo included
        engine.enrich_signal(SAMPLE_SIGNAL, SAMPLE_CONTEXT)
        call_args = engine._client.messages.create.call_args
        payload = json.loads(call_args.kwargs["messages"][0]["content"])
        self.assertIn("cot", payload.get("x", {}))

        # Second call immediately — COT/geo should be omitted (unchanged + within interval)
        # Use a significant DXY change so filtered is non-empty (isolates stable throttling)
        engine._last_call_time = 0
        engine._last_claude_cache = None  # bypass cache to test dynamic prompt
        ctx2 = dict(SAMPLE_CONTEXT, macro={"us10y": 4.18, "real_rate": 1.75, "dxy": 97.0, "vix": 14.2})
        engine.enrich_signal(SAMPLE_SIGNAL, ctx2)
        call_args = engine._client.messages.create.call_args
        payload = json.loads(call_args.kwargs["messages"][0]["content"])
        # DXY changed significantly → macro is in filtered, but COT/geo unchanged → omitted
        self.assertIn("macro", payload.get("x", {}))
        self.assertNotIn("cot", payload.get("x", {}))
        self.assertNotIn("geopolitics", payload.get("x", {}))

    def test_compact_signal_keys(self):
        """Signal uses compact keys (d, c, t, b, m, p)."""
        engine = self._make_engine_with_mock_client()
        engine.enrich_signal(SAMPLE_SIGNAL, SAMPLE_CONTEXT)

        call_args = engine._client.messages.create.call_args
        payload = json.loads(call_args.kwargs["messages"][0]["content"])

        sig = payload["s"]
        self.assertEqual(sig["d"], "BULLISH")
        self.assertEqual(sig["c"], 72)
        self.assertTrue(sig["t"])
        self.assertEqual(sig["p"], 4425.50)

    def test_health_check_dynamic_prompt_info(self):
        """health_check() includes dynamic prompt stats."""
        engine = self._make_engine_with_mock_client()
        engine.enrich_signal(SAMPLE_SIGNAL, SAMPLE_CONTEXT)
        health = engine.health_check()

        self.assertIn("dynamic_prompt", health)
        self.assertGreater(health["dynamic_prompt"]["cached_fields"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
