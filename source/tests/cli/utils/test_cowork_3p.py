# ABOUTME: Tests for cowork_3p.py add_monitoring_config endpoint resolution
# ABOUTME: and inferenceModels object-format generation (CRIS-ID resolution).

"""Tests for CoWork 3P monitoring configuration (endpoint resolution + auth headers)."""

from unittest.mock import MagicMock, patch

from claude_code_with_bedrock.cli.utils.cowork_3p import (
    add_monitoring_config,
    build_inference_models,
    build_inference_models_explicit,
    build_mdm_config,
)


class FakeProfile:
    """Minimal profile stub for testing add_monitoring_config."""

    def __init__(
        self,
        monitoring_enabled=True,
        monitoring_mode="central",
        otel_collector_endpoint=None,
        identity_pool_name="test-pool",
        aws_region="us-east-1",
    ):
        self.monitoring_enabled = monitoring_enabled
        self.monitoring_mode = monitoring_mode
        self.otel_collector_endpoint = otel_collector_endpoint
        self.identity_pool_name = identity_pool_name
        self.aws_region = aws_region
        self.stack_names = {}


class TestAddMonitoringConfig:
    """Tests for add_monitoring_config endpoint resolution logic."""

    def _make_console(self):
        return MagicMock()

    def test_monitoring_disabled_skips(self):
        """When monitoring_enabled=False, nothing is set."""
        profile = FakeProfile(monitoring_enabled=False)
        mdm = {}
        add_monitoring_config(mdm, profile, self._make_console())
        assert "otlpEndpoint" not in mdm

    def test_sidecar_mode_uses_local_proxy(self):
        """Sidecar mode configures CoWork to send to localhost otel-helper proxy."""
        profile = FakeProfile(monitoring_mode="sidecar")
        mdm = {}
        add_monitoring_config(mdm, profile, self._make_console())
        assert mdm["otlpEndpoint"] == "http://localhost:4318"
        assert mdm["otlpProtocol"] == "http/protobuf"

    def test_sidecar_mode_without_cowork_token(self):
        """Sidecar mode without cowork_service_token omits otlpHeaders."""
        profile = FakeProfile(monitoring_mode="sidecar")
        profile.cowork_service_token = None
        mdm = {}
        add_monitoring_config(mdm, profile, self._make_console())
        assert "otlpHeaders" not in mdm

    @patch("claude_code_with_bedrock.cli.utils.cowork_3p.get_stack_outputs")
    def test_stack_output_success(self, mock_get_outputs):
        """When stack outputs resolve, endpoint is set from CollectorEndpoint."""
        mock_get_outputs.return_value = {"CollectorEndpoint": "https://telemetry.example.com"}
        profile = FakeProfile()
        mdm = {}
        add_monitoring_config(mdm, profile, self._make_console())
        assert mdm["otlpEndpoint"] == "https://telemetry.example.com"
        assert mdm["otlpProtocol"] == "http/protobuf"

    @patch("claude_code_with_bedrock.cli.utils.cowork_3p.get_stack_outputs")
    def test_stack_failure_falls_back_to_profile(self, mock_get_outputs):
        """When stack query fails, falls back to profile.otel_collector_endpoint."""
        mock_get_outputs.side_effect = Exception("stack not found")
        profile = FakeProfile(otel_collector_endpoint="https://fallback.example.com")
        mdm = {}
        add_monitoring_config(mdm, profile, self._make_console())
        assert mdm["otlpEndpoint"] == "https://fallback.example.com"
        assert mdm["otlpProtocol"] == "http/protobuf"

    @patch("claude_code_with_bedrock.cli.utils.cowork_3p.get_stack_outputs")
    def test_stack_returns_no_endpoint_falls_back_to_profile(self, mock_get_outputs):
        """When stack outputs exist but CollectorEndpoint is missing, use profile fallback."""
        mock_get_outputs.return_value = {"SomeOtherOutput": "value"}
        profile = FakeProfile(otel_collector_endpoint="https://profile-endpoint.example.com")
        mdm = {}
        add_monitoring_config(mdm, profile, self._make_console())
        assert mdm["otlpEndpoint"] == "https://profile-endpoint.example.com"

    @patch("claude_code_with_bedrock.cli.utils.cowork_3p.get_stack_outputs")
    def test_both_missing_shows_warning(self, mock_get_outputs):
        """When stack query fails and no profile endpoint, no otlpEndpoint is set."""
        mock_get_outputs.side_effect = Exception("stack not found")
        profile = FakeProfile(otel_collector_endpoint=None)
        mdm = {}
        console = self._make_console()
        add_monitoring_config(mdm, profile, console)
        assert "otlpEndpoint" not in mdm
        # Should print a warning
        console.print.assert_called()
        warning_text = str(console.print.call_args_list[-1])
        assert "Could not resolve" in warning_text or "warning" in warning_text.lower()

    @patch("claude_code_with_bedrock.cli.utils.cowork_3p.get_stack_outputs")
    def test_custom_stack_name_from_profile(self, mock_get_outputs):
        """Uses stack name from profile.stack_names if configured."""
        mock_get_outputs.return_value = {"CollectorEndpoint": "https://custom-stack.example.com"}
        profile = FakeProfile()
        profile.stack_names = {"monitoring": "my-custom-monitoring-stack"}
        mdm = {}
        add_monitoring_config(mdm, profile, self._make_console())
        mock_get_outputs.assert_called_once_with("my-custom-monitoring-stack", "us-east-1")
        assert mdm["otlpEndpoint"] == "https://custom-stack.example.com"

    @patch("claude_code_with_bedrock.cli.utils.cowork_3p.get_stack_outputs")
    def test_cowork_service_token_adds_otlp_headers(self, mock_get_outputs):
        """When cowork_service_token is set, otlpHeaders includes X-Cowork-Token."""
        import json

        mock_get_outputs.return_value = {"CollectorEndpoint": "https://collector.example.com"}
        profile = FakeProfile()
        profile.cowork_service_token = "test-token-abc123"
        mdm = {}
        add_monitoring_config(mdm, profile, self._make_console())
        assert "otlpHeaders" in mdm
        headers = json.loads(mdm["otlpHeaders"])
        assert headers == {"X-Cowork-Token": "test-token-abc123"}

    @patch("claude_code_with_bedrock.cli.utils.cowork_3p.get_stack_outputs")
    def test_no_cowork_service_token_omits_otlp_headers(self, mock_get_outputs):
        """When cowork_service_token is not set, otlpHeaders is not added."""
        mock_get_outputs.return_value = {"CollectorEndpoint": "https://collector.example.com"}
        profile = FakeProfile()
        # No cowork_service_token attribute
        mdm = {}
        add_monitoring_config(mdm, profile, self._make_console())
        assert "otlpHeaders" not in mdm

    @patch("claude_code_with_bedrock.cli.utils.cowork_3p.get_stack_outputs")
    def test_empty_cowork_service_token_omits_otlp_headers(self, mock_get_outputs):
        """When cowork_service_token is empty string, otlpHeaders is not added."""
        mock_get_outputs.return_value = {"CollectorEndpoint": "https://collector.example.com"}
        profile = FakeProfile()
        profile.cowork_service_token = ""
        mdm = {}
        add_monitoring_config(mdm, profile, self._make_console())
        assert "otlpHeaders" not in mdm


class TestBuildInferenceModels:
    """Regression tests for inferenceModels generation.

    Guards issue #8 / issue_3: with a cris_prefix, bare tier aliases MUST resolve
    to concrete CRIS model IDs in object format so Claude Desktop never resolves a
    bare alias to an invalid model identifier (the /model/haiku/invoke 403 class).
    Without a prefix, the legacy string passthrough is preserved.
    """

    def test_prefix_resolves_bare_aliases_to_object_format(self):
        """Bare tiers + us prefix → object entries with real CRIS IDs + tags + labels."""
        models = build_inference_models(["opus", "sonnet", "haiku"], "us")

        # No bare strings survive — every entry is a tagged object.
        assert all(isinstance(m, dict) for m in models), models
        for m in models:
            assert m["name"].startswith("us.anthropic.claude-"), m
            # bare alias must NOT leak through as the name
            assert m["name"] not in ("opus", "sonnet", "haiku")
            assert m["anthropicFamilyTier"] in ("opus", "sonnet", "haiku")
            assert m["isFamilyDefault"] is True
            assert m["labelOverride"]  # non-empty display label

        tiers = [m["anthropicFamilyTier"] for m in models]
        assert tiers == ["opus", "sonnet", "haiku"]

    def test_no_prefix_preserves_bare_strings(self):
        """Back-compat: no prefix + all-simple aliases → unchanged string list."""
        assert build_inference_models(["opus", "sonnet", "haiku"]) == ["opus", "sonnet", "haiku"]

    def test_explicit_cris_ids_are_tier_tagged(self):
        """Full CRIS IDs (no prefix) are tagged with tier inferred from the ID."""
        models = build_inference_models(["us.anthropic.claude-opus-4-8"])
        assert models == [
            {"name": "us.anthropic.claude-opus-4-8", "anthropicFamilyTier": "opus", "isFamilyDefault": True}
        ]

    def test_eu_prefix_resolves_eu_cris_ids(self):
        """A non-US prefix resolves to that geography's CRIS IDs."""
        models = build_inference_models_explicit(["opus", "sonnet", "haiku"], "eu")
        assert all(m["name"].startswith("eu.anthropic.claude-") for m in models), models

    def test_only_first_model_per_tier_is_family_default(self):
        """When two models share a tier, only the first is the family default."""
        models = build_inference_models_explicit(["us.anthropic.claude-opus-4-8", "us.anthropic.claude-opus-4-7"], "us")
        opus_defaults = [m for m in models if m.get("anthropicFamilyTier") == "opus" and m.get("isFamilyDefault")]
        assert len(opus_defaults) == 1
        assert opus_defaults[0]["name"] == "us.anthropic.claude-opus-4-8"

    def test_build_mdm_config_emits_object_models_with_prefix(self):
        """build_mdm_config threads cris_prefix through to object-format models."""
        cfg = build_mdm_config(
            bedrock_region="us-east-2",
            model_aliases=["opus", "sonnet", "haiku"],
            profile_name="test-profile",
            cris_prefix="us",
        )
        models = cfg["inferenceModels"]
        assert all(isinstance(m, dict) and m["name"].startswith("us.anthropic.") for m in models), models
