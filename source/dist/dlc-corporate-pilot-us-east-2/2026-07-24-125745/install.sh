#!/bin/bash
# Claude Code Authentication Installer
# Organization: login.microsoftonline.com/684fdbeb-a2a8-4079-a6e8-1fefe44f7477/v2.0
# Generated: 2026-07-24 12:57:47

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Resolve the real invoking user — safe whether or not run with sudo.
# If run as: sudo ./install.sh  →  SUDO_USER is set; use that for home-dir writes.
# If run as: ./install.sh       →  use $USER / $HOME directly.
if [ -n "$SUDO_USER" ]; then
    ACTUAL_USER="$SUDO_USER"
    ACTUAL_HOME=$(eval echo "~$SUDO_USER")
else
    ACTUAL_USER="$USER"
    ACTUAL_HOME="$HOME"
fi

echo "======================================"
echo "Claude Code Authentication Installer"
echo "======================================"
echo
echo "Organization: login.microsoftonline.com/684fdbeb-a2a8-4079-a6e8-1fefe44f7477/v2.0"
echo


# Check prerequisites
echo "Checking prerequisites..."
HAS_ERRORS=false

if command -v aws &> /dev/null; then
    echo "✓ AWS CLI found (optional)"
else
    echo "ℹ  AWS CLI not found — not required. The credential process binary handles authentication directly."
fi

if [ ! -f "config.json" ]; then
    echo "ERROR: config.json not found in current directory"
    echo "       Make sure you are running this from the extracted package folder"
    HAS_ERRORS=true
fi

# Find a Python interpreter (needed for config parsing)
PYTHON=""
if command -v python3 &> /dev/null; then
    PYTHON="python3"
elif command -v python &> /dev/null; then
    PYTHON="python"
else
    echo "ERROR: Python is not installed (python3 or python)"
    echo "       Python is needed to parse configuration files"
    HAS_ERRORS=true
fi

if [ "$HAS_ERRORS" = "true" ]; then
    exit 1
fi

if [ ! -f "claude-settings/settings.json" ] && [ ! -f "claude-settings/managed-settings.json" ]; then
    echo "WARNING: claude-settings/settings.json not found"
    echo "         Claude Code IDE settings will not be configured automatically"
    echo ""
fi

echo "OK Prerequisites validated"

# Detect platform and architecture
echo
echo "Detecting platform and architecture..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    PLATFORM="macos"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "arm64" ]]; then
        echo "✓ Detected macOS ARM64 (Apple Silicon)"
        BINARY_SUFFIX="macos-arm64"
    else
        echo "✓ Detected macOS Intel"
        BINARY_SUFFIX="macos-intel"
    fi
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    PLATFORM="linux"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "arm64" ]]; then
        echo "✓ Detected Linux ARM64"
        BINARY_SUFFIX="linux-arm64"
    else
        echo "✓ Detected Linux x64"
        BINARY_SUFFIX="linux-x64"
    fi
else
    echo "❌ Unsupported platform: $OSTYPE"
    echo "   This installer supports macOS and Linux only."
    exit 1
fi

# Check if binary for platform exists
CREDENTIAL_BINARY="credential-process-$BINARY_SUFFIX"
OTEL_BINARY="otel-helper-$BINARY_SUFFIX"

if [ ! -f "$CREDENTIAL_BINARY" ]; then
    echo "❌ Binary not found for your platform: $CREDENTIAL_BINARY"
    echo "   Please ensure you have the correct package for your architecture."
    exit 1
fi

# Create directory
echo
echo "Installing authentication tools..."
mkdir -p "$ACTUAL_HOME/claude-code-with-bedrock"

# Copy appropriate binary
cp "$CREDENTIAL_BINARY" "$ACTUAL_HOME/claude-code-with-bedrock/credential-process"

# Copy config
cp config.json "$ACTUAL_HOME/claude-code-with-bedrock/"
chmod +x "$ACTUAL_HOME/claude-code-with-bedrock/credential-process"

# Fix ownership when invoked via sudo so files belong to the real user, not root
if [ -n "$SUDO_USER" ]; then
    chown -R "$ACTUAL_USER" "$ACTUAL_HOME/claude-code-with-bedrock"
fi

# Resolve __CCWB_HOME__ to the real home in the CoWork MDM files. Claude Desktop
# on macOS does NOT expand ~ or env vars in MDM string values, and the
# .mobileconfig is generated centrally, so the absolute paths (headersHelper,
# inferenceCredentialHelper) must be substituted here on the user's machine.
for _ccwb_mdm in "cowork-3p.mobileconfig" "cowork-3p-config.json"; do
    if [ -f "$_ccwb_mdm" ] && grep -q "__CCWB_HOME__" "$_ccwb_mdm" 2>/dev/null; then
        sed -i.bak "s|__CCWB_HOME__|$ACTUAL_HOME|g" "$_ccwb_mdm" && rm -f "$_ccwb_mdm.bak"
        if [ -n "$SUDO_USER" ]; then chown "$ACTUAL_USER" "$_ccwb_mdm"; fi
        echo "OK Resolved home directory in $_ccwb_mdm"
    fi
done

# Install the CoWork credential-helper wrapper (helper-script mode). Claude
# Desktop runs inferenceCredentialHelper with no arguments, so the --desktop
# --profile flags live inside this wrapper, which execs the co-located binary.
if [ -f "cowork-credential-helper.sh" ]; then
    cp "cowork-credential-helper.sh" "$ACTUAL_HOME/claude-code-with-bedrock/cowork-credential-helper.sh"
    chmod +x "$ACTUAL_HOME/claude-code-with-bedrock/cowork-credential-helper.sh"
    if [ -n "$SUDO_USER" ]; then chown "$ACTUAL_USER" "$ACTUAL_HOME/claude-code-with-bedrock/cowork-credential-helper.sh"; fi
    echo "OK Installed cowork-credential-helper.sh"
fi

# macOS Gatekeeper + Keychain notices
if [[ "$OSTYPE" == "darwin"* ]]; then
    # Remove quarantine flag added by macOS when downloading unsigned binaries.
    # Without this, Gatekeeper blocks execution with "Apple could not verify..." dialog.
    xattr -d com.apple.quarantine "$ACTUAL_HOME/claude-code-with-bedrock/credential-process" 2>/dev/null || true
    echo
    echo "⚠️  macOS Keychain Access:"
    echo "   On first use, macOS will ask for permission to access the keychain."
    echo "   This is normal and required for secure credential storage."
    echo "   Click 'Always Allow' when prompted."
fi

# Copy Claude Code settings if present
if [ -d "claude-settings" ]; then
    echo
    echo "Installing Claude Code settings..."
    mkdir -p "$ACTUAL_HOME/.claude"
    if [ -n "$SUDO_USER" ]; then chown "$ACTUAL_USER" "$ACTUAL_HOME/.claude"; fi

    # Install managed-settings.json (OS-level enforcement) if present
    if [ -f "claude-settings/managed-settings.json" ]; then
        echo "Managed settings detected (organization-wide enforcement)..."

        # Determine OS-appropriate managed-settings path
        if [[ "$OSTYPE" == "darwin"* ]]; then
            MANAGED_DIR="/Library/Application Support/ClaudeCode"
        else
            MANAGED_DIR="/etc/claude-code"
        fi

        # Escalate only for the managed-settings write — don't require the whole script to run as root
        if [ "$(id -u)" -ne 0 ]; then
            echo "  Managed settings require root — running: sudo mkdir / sudo tee"
            sudo mkdir -p "$MANAGED_DIR"
            sed -e "s|__OTEL_HELPER_PATH__|$ACTUAL_HOME/claude-code-with-bedrock/otel-helper|g"                 -e "s|__CREDENTIAL_PROCESS_PATH__|$ACTUAL_HOME/claude-code-with-bedrock/credential-process|g"                 "claude-settings/managed-settings.json" | sudo tee "$MANAGED_DIR/managed-settings.json" > /dev/null
        else
            mkdir -p "$MANAGED_DIR"
            sed -e "s|__OTEL_HELPER_PATH__|$ACTUAL_HOME/claude-code-with-bedrock/otel-helper|g"                 -e "s|__CREDENTIAL_PROCESS_PATH__|$ACTUAL_HOME/claude-code-with-bedrock/credential-process|g"                 "claude-settings/managed-settings.json" > "$MANAGED_DIR/managed-settings.json"
        fi

        # Verify placeholders were replaced
        if grep -q '__CREDENTIAL_PROCESS_PATH__\|__OTEL_HELPER_PATH__' "$MANAGED_DIR/managed-settings.json" 2>/dev/null; then
            echo "WARNING: Some path placeholders were not replaced in managed-settings.json"
        else
            echo "OK Managed settings installed: $MANAGED_DIR/managed-settings.json"
            echo "   These settings have highest precedence and cannot be overridden by users."
        fi
    fi

    # Copy user-scope settings.json if present
    if [ -f "claude-settings/settings.json" ]; then
        # Check if settings file already exists
        if [ -f "$ACTUAL_HOME/.claude/settings.json" ]; then
            echo "Existing Claude Code settings found"
            # Backup existing settings
            BACKUP_NAME="settings.json.backup-$(date +%Y%m%d-%H%M%S)"
            cp "$ACTUAL_HOME/.claude/settings.json" "$ACTUAL_HOME/.claude/$BACKUP_NAME"
            if [ -n "$SUDO_USER" ]; then chown "$ACTUAL_USER" "$ACTUAL_HOME/.claude/$BACKUP_NAME"; fi
            echo "  Backed up to: $ACTUAL_HOME/.claude/$BACKUP_NAME"

            # Merge new settings into existing (preserves user customizations)
            $PYTHON -c "
import json, sys
try:
    with open('$ACTUAL_HOME/.claude/$BACKUP_NAME') as f:
        existing = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    existing = {}

with open('claude-settings/settings.json') as f:
    incoming = json.load(f)

# Deep merge: incoming overwrites existing keys, but existing keys not in incoming are preserved
def deep_merge(base, override):
    result = base.copy()
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result

merged = deep_merge(existing, incoming)
with open('$ACTUAL_HOME/.claude/settings.json', 'w') as f:
    json.dump(merged, f, indent=2)
" 2>/dev/null

            if [ $? -eq 0 ]; then
                echo "OK Claude Code settings merged: $ACTUAL_HOME/.claude/settings.json"
                echo "   (existing user settings preserved, new Bedrock config added)"
            else
                # Fallback: overwrite if merge fails
                read -p "Merge failed. Overwrite with new settings? (Y/n): " -n 1 -r
                echo
                if [[ -z "$REPLY" ]]; then REPLY="y"; fi
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo "Skipping Claude Code settings..."
                    SKIP_SETTINGS=true
                fi
            fi
        fi

        if [ "$SKIP_SETTINGS" != "true" ] && [ ! -f "$ACTUAL_HOME/.claude/settings.json" ]; then
            # No existing settings — just write directly
            sed -e "s|__OTEL_HELPER_PATH__|$ACTUAL_HOME/claude-code-with-bedrock/otel-helper|g"                 -e "s|__CREDENTIAL_PROCESS_PATH__|$ACTUAL_HOME/claude-code-with-bedrock/credential-process|g"                 "claude-settings/settings.json" > "$ACTUAL_HOME/.claude/settings.json"
            echo "OK Claude Code settings configured: $ACTUAL_HOME/.claude/settings.json"
        fi

        # Replace placeholders in the final settings file
        if [ -f "$ACTUAL_HOME/.claude/settings.json" ] && [ "$SKIP_SETTINGS" != "true" ]; then
            sed -i.tmp -e "s|__OTEL_HELPER_PATH__|$ACTUAL_HOME/claude-code-with-bedrock/otel-helper|g"                        -e "s|__CREDENTIAL_PROCESS_PATH__|$ACTUAL_HOME/claude-code-with-bedrock/credential-process|g"                        "$ACTUAL_HOME/.claude/settings.json"
            rm -f "$ACTUAL_HOME/.claude/settings.json.tmp"

            # Verify placeholders were replaced
            if grep -q '__CREDENTIAL_PROCESS_PATH__\|__OTEL_HELPER_PATH__' "$ACTUAL_HOME/.claude/settings.json" 2>/dev/null; then
                echo "WARNING: Some path placeholders were not replaced in settings.json"
                echo "         You may need to edit the file manually: $ACTUAL_HOME/.claude/settings.json"
            fi
        fi

        if [ -n "$SUDO_USER" ] && [ -f "$ACTUAL_HOME/.claude/settings.json" ]; then
            chown "$ACTUAL_USER" "$ACTUAL_HOME/.claude/settings.json"
        fi
    fi
fi

# Copy OTEL helper executable if present
if [ -f "$OTEL_BINARY" ]; then
    echo
    echo "Installing OTEL helper..."
    cp "$OTEL_BINARY" "$ACTUAL_HOME/claude-code-with-bedrock/otel-helper"
    chmod +x "$ACTUAL_HOME/claude-code-with-bedrock/otel-helper"
    if [ -n "$SUDO_USER" ]; then chown "$ACTUAL_USER" "$ACTUAL_HOME/claude-code-with-bedrock/otel-helper"; fi
    xattr -d com.apple.quarantine "$ACTUAL_HOME/claude-code-with-bedrock/otel-helper" 2>/dev/null || true
    echo "✓ OTEL helper installed"
fi

# Add debug info if OTEL helper was installed
if [ -f "$ACTUAL_HOME/claude-code-with-bedrock/otel-helper" ]; then
    echo "The OTEL helper will extract user attributes from authentication tokens"
    echo "and include them in metrics. To test the helper, run:"
    echo "  $ACTUAL_HOME/claude-code-with-bedrock/otel-helper --test"
fi

# Install otelcol sidecar collector (present only in sidecar-mode packages).
# The collector binary is built via OCB and SHIPPED in the package as
# otelcol-$BINARY_SUFFIX, the same model as credential-process and otel-helper —
# end users never download it. It receives OTLP from Claude Code on localhost:4318,
# injects the user-attribution headers written by otel-helper, and forwards to
# CloudWatch with SigV4.
OTELCOL_BINARY="otelcol-$BINARY_SUFFIX"
if [ -f "collector-config.yaml" ] && [ -f "$OTELCOL_BINARY" ]; then
    echo
    echo "Installing OTEL Collector sidecar..."

    OTELCOL_DEST="$ACTUAL_HOME/claude-code-with-bedrock/otelcol"
    cp "$OTELCOL_BINARY" "$OTELCOL_DEST"
    chmod +x "$OTELCOL_DEST"
    if [ -n "$SUDO_USER" ]; then chown "$ACTUAL_USER" "$OTELCOL_DEST"; fi
    xattr -d com.apple.quarantine "$OTELCOL_DEST" 2>/dev/null || true
    echo "✓ otelcol installed: $OTELCOL_DEST"

    # Install collector config alongside the binary
    cp "collector-config.yaml" "$ACTUAL_HOME/claude-code-with-bedrock/collector-config.yaml"
    if [ -n "$SUDO_USER" ]; then chown "$ACTUAL_USER" "$ACTUAL_HOME/claude-code-with-bedrock/collector-config.yaml"; fi
    echo "✓ Collector config installed"

    # A dedicated <profile>-collector AWS profile is registered in the AWS profiles
    # section below. otelcol resolves CloudWatch credentials through it via
    # credential_process. The separate profile is needed because a user's static
    # ~/.aws/credentials would otherwise shadow credential_process and cannot
    # auto-refresh (see otel-helper.sh).
elif [ -f "collector-config.yaml" ] && [ ! -f "$OTELCOL_BINARY" ]; then
    echo
    echo "⚠️  Sidecar config present but collector binary '$OTELCOL_BINARY' is missing."
    echo "   The admin must run 'ccwb package' with Go 1.23+ installed to build the collector."
    echo "   Telemetry will not be forwarded until the collector is installed."
fi

# Update AWS config
echo
echo "Configuring AWS profiles..."
mkdir -p "$ACTUAL_HOME/.aws"
if [ -n "$SUDO_USER" ]; then chown "$ACTUAL_USER" "$ACTUAL_HOME/.aws"; fi

# Read all profiles from config.json
PROFILES=$($PYTHON -c "import json; profiles = list(json.load(open('config.json')).keys()); print(' '.join(profiles))")

if [ -z "$PROFILES" ]; then
    echo "❌ No profiles found in config.json"
    exit 1
fi

echo "Found profiles: $PROFILES"
echo

# Get region from package settings (for Bedrock calls, not infrastructure)
if [ -f "claude-settings/settings.json" ]; then
    DEFAULT_REGION=$($PYTHON -c "
import json
print(json.load(open('claude-settings/settings.json'))['env']['AWS_REGION'])
" 2>/dev/null || echo "us-east-2")
elif [ -f "claude-settings/managed-settings.json" ]; then
    DEFAULT_REGION=$($PYTHON -c "
import json
print(json.load(open('claude-settings/managed-settings.json'))['env']['AWS_REGION'])
" 2>/dev/null || echo "us-east-2")
else
    DEFAULT_REGION="us-east-2"
fi

# Configure each profile
for PROFILE_NAME in $PROFILES; do
    echo "Configuring AWS profile: $PROFILE_NAME"

    # Remove old profile if exists
    sed -i.bak "/\[profile $PROFILE_NAME\]/,/^$/d" "$ACTUAL_HOME/.aws/config" 2>/dev/null || true

    # Get profile-specific region from config.json
    PROFILE_REGION=$($PYTHON -c "
import json
print(json.load(open('config.json')).get('$PROFILE_NAME', {}).get('aws_region', '$DEFAULT_REGION'))
")

    # Add new profile with --profile flag (cross-platform, no shell required)
    cat >> "$ACTUAL_HOME/.aws/config" << EOF
[profile $PROFILE_NAME]
credential_process = $ACTUAL_HOME/claude-code-with-bedrock/credential-process --profile $PROFILE_NAME
region = $PROFILE_REGION
EOF
    if [ -n "$SUDO_USER" ]; then chown "$ACTUAL_USER" "$ACTUAL_HOME/.aws/config"; fi
    echo "  ✓ Created AWS profile '$PROFILE_NAME'"

    # Create a <profile>-collector profile for the otelcol sidecar (sidecar packages only).
    # otelcol needs CloudWatch write access and resolves it via credential_process. A
    # dedicated profile is used because a user's static ~/.aws/credentials would shadow
    # credential_process on the main profile and cannot auto-refresh (see otel-helper.sh).
    if [ -f "$ACTUAL_HOME/claude-code-with-bedrock/collector-config.yaml" ]; then
        sed -i.bak "/\[profile ${PROFILE_NAME}-collector\]/,/^$/d" "$ACTUAL_HOME/.aws/config" 2>/dev/null || true
        cat >> "$ACTUAL_HOME/.aws/config" << EOF
[profile ${PROFILE_NAME}-collector]
credential_process = $ACTUAL_HOME/claude-code-with-bedrock/credential-process --profile $PROFILE_NAME
region = $PROFILE_REGION
EOF
        echo "  ✓ Created AWS profile '${PROFILE_NAME}-collector' (otelcol SigV4 auth)"
    fi
done

# Post-install validation
echo
echo "Validating installation..."
if [ -f "$ACTUAL_HOME/claude-code-with-bedrock/credential-process" ]; then
    echo "  OK credential-process: $ACTUAL_HOME/claude-code-with-bedrock/credential-process"
else
    echo "  FAIL credential-process not found at: $ACTUAL_HOME/claude-code-with-bedrock/credential-process"
fi
if [ -f "$ACTUAL_HOME/.claude/settings.json" ]; then
    echo "  OK settings.json: $ACTUAL_HOME/.claude/settings.json"
else
    echo "  WARN settings.json not found at: $ACTUAL_HOME/.claude/settings.json"
fi

echo
echo "======================================"
echo "Installation complete!"
echo "======================================"
echo
echo "Available profiles:"
for PROFILE_NAME in $PROFILES; do
    echo "  - $PROFILE_NAME"
done
echo
echo ">>> Start Claude Code:"
echo "      claude"
echo
echo "    Authentication is handled automatically via your configured credential"
echo "    process. Simply run 'claude' to start."
echo
echo "To use a non-default profile, set AWS_PROFILE before launching:"
echo "  AWS_PROFILE=<profile-name> claude"
echo
