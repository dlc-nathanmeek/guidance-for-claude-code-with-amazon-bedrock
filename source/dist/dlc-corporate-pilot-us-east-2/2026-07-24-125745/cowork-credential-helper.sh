#!/bin/bash
# ABOUTME: CoWork 3P credential helper — emits a Bedrock bearer token.
# Invoked by Claude Desktop as inferenceCredentialHelper (no arguments).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/credential-process" --desktop --profile dlc-corporate-pilot-us-east-2
