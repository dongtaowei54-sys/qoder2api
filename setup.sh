#!/usr/bin/env bash
# ============================================================
#  qoder2api - one-click setup for Codex (macOS / Linux)
#
#  What it does:
#    1. backs up your existing ~/.codex/config.toml
#    2. adds the [model_providers.qoder_local] block (skips if present)
#    3. registers the qfmodel catalog (skips if a catalog is already set)
#    4. creates the qoder profile file
#    5. appends the two required env vars to your shell rc
#
#  What it does NOT do:
#    - it never touches your default model / default provider
#    - it never overwrites an existing model_catalog_json setting
#
#  Safe to run more than once (idempotent).
#
#  Usage:
#    bash setup.sh
# ============================================================

set -euo pipefail

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; GRAY='\033[90m'; NC='\033[0m'
step() { printf "${CYAN}[*]${NC} %s\n" "$1"; }
ok()   { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
err()  { printf "${RED}[x]${NC} %s\n" "$1"; }

CODEX_DIR="$HOME/.codex"
CFG="$CODEX_DIR/config.toml"
PROF="$CODEX_DIR/qoder.config.toml"
CAT="$CODEX_DIR/qoder-models.json"

echo
printf "  qoder2api setup for Codex\n"
printf "${GRAY}  ------------------------------------------------${NC}\n"
echo

# ---------------------------------------------------------------
# 0. sanity checks
# ---------------------------------------------------------------
step "Checking prerequisites"

if ! command -v codex >/dev/null 2>&1; then
    warn "codex not found in PATH."
    warn "Install Codex CLI first: https://github.com/openai/codex"
    warn "Continuing anyway - config files will still be written."
fi

mkdir -p "$CODEX_DIR"
ok "Found $CODEX_DIR"

# ---------------------------------------------------------------
# 1. back up config.toml
# ---------------------------------------------------------------
if [ -f "$CFG" ]; then
    BAK="$CFG.bak-qoder-$(date +%Y%m%d-%H%M%S)"
    cp "$CFG" "$BAK"
    ok "Backed up config.toml -> $(basename "$BAK")"
else
    warn "config.toml not found - a new one will be created"
    : > "$CFG"
fi

# ---------------------------------------------------------------
# 2. add the provider block (idempotent)
# ---------------------------------------------------------------
if grep -q 'model_providers\.qoder_local' "$CFG" 2>/dev/null; then
    ok "Provider [model_providers.qoder_local] already present - skipped"
else
    # strip trailing blank lines, then append
    printf '\n\n# ---- Qoder local gateway (free Qwen3.8-Flash) ----\n' >> "$CFG"
    printf '# Added by setup.sh - serves OpenAI-compatible endpoints on 127.0.0.1:8963\n' >> "$CFG"
    printf '[model_providers.qoder_local]\n' >> "$CFG"
    printf 'name = "Qoder Local"\n' >> "$CFG"
    printf 'base_url = "http://127.0.0.1:8963/v1"\n' >> "$CFG"
    printf 'env_key = "QODER_LOCAL_KEY"\n' >> "$CFG"
    printf 'wire_api = "responses"\n' >> "$CFG"
    ok "Added provider [model_providers.qoder_local]"
fi

# ---------------------------------------------------------------
# 3. register the model catalog (never overwrite an existing one)
# ---------------------------------------------------------------
if grep -q 'model_catalog_json' "$CFG" 2>/dev/null; then
    warn "model_catalog_json is already set in config.toml - NOT touched."
    warn "To get qfmodel metadata, merge the entry from qoder-models.json manually."
else
    cat > "$CAT" <<'JSON'
{
  "models": [
    {
      "slug": "qfmodel",
      "display_name": "Qwen3.8-Flash",
      "description": "Qoder Qwen3.8-Flash via local gateway",
      "default_reasoning_level": "medium",
      "supported_reasoning_levels": [
        { "effort": "low", "description": "fast" },
        { "effort": "medium", "description": "balanced" },
        { "effort": "xhigh", "description": "deep" }
      ],
      "context_window": 200000,
      "effective_context_window_percent": 95,
      "supports_parallel_tool_calls": false,
      "input_modalities": ["text"],
      "shell_type": "default",
      "visibility": "list",
      "supported_in_api": true,
      "priority": 1,
      "base_instructions": "",
      "support_verbosity": false,
      "supports_reasoning_summaries": false,
      "experimental_supported_tools": [],
      "truncation_policy": { "mode": "bytes", "limit": 10000 }
    }
  ]
}
JSON

    # model_catalog_json is a TOP-LEVEL key: it must sit before the first [table]
    ENTRY="model_catalog_json = '$CAT'"
    FIRST_TABLE=$(grep -n '^\[' "$CFG" | head -1 | cut -d: -f1 || true)
    if [ -n "$FIRST_TABLE" ]; then
        { head -n $((FIRST_TABLE - 1)) "$CFG"; echo "$ENTRY"; echo; tail -n +"$FIRST_TABLE" "$CFG"; } > "$CFG.tmp"
        mv "$CFG.tmp" "$CFG"
    else
        printf '%s\n' "$ENTRY" >> "$CFG"
    fi
    ok "Registered model catalog (qoder-models.json)"
fi

# ---------------------------------------------------------------
# 4. create the profile file
# ---------------------------------------------------------------
if [ -f "$PROF" ]; then
    ok "Profile qoder.config.toml already exists - skipped"
else
    cat > "$PROF" <<'TOML'
model = "qfmodel"
model_provider = "qoder_local"
model_reasoning_effort = "medium"
TOML
    ok "Created profile qoder.config.toml"
fi

# ---------------------------------------------------------------
# 5. environment variables
# ---------------------------------------------------------------
step "Configuring shell environment"

SHELL_RC="$HOME/.zshrc"
case "${SHELL:-}" in
    *bash*) [ -f "$HOME/.bashrc" ] && SHELL_RC="$HOME/.bashrc" ;;
    *zsh*)  SHELL_RC="$HOME/.zshrc" ;;
esac
[ "${SHELL##*/}" = "bash" ] && SHELL_RC="$HOME/.bashrc"

if grep -q 'QODER_LOCAL_KEY' "$SHELL_RC" 2>/dev/null; then
    ok "Env vars already present in $(basename "$SHELL_RC") - skipped"
else
    {
        echo ''
        echo '# ---- qoder2api (Codex + Qoder local gateway) ----'
        echo '# The gateway does not check auth, but Codex refuses to send a'
        echo '# request when the provider env_key is missing.'
        echo 'export QODER_LOCAL_KEY="qoder-local-gateway"'
        echo '# Without this a system HTTP proxy swallows 127.0.0.1 requests.'
        echo 'export NO_PROXY="127.0.0.1,localhost,::1"'
        echo 'export no_proxy="127.0.0.1,localhost,::1"'
    } >> "$SHELL_RC"
    ok "Appended env vars to $(basename "$SHELL_RC")"
fi

# ---------------------------------------------------------------
# done
# ---------------------------------------------------------------
echo
printf "${GRAY}  ------------------------------------------------${NC}\n"
ok "Setup complete."
echo
printf "  Next steps (open a NEW terminal so the env vars apply):\n"
echo
printf "${GRAY}    1) Authorize with Qoder (once, opens your browser):${NC}\n"
printf "         ./qoder2api-login\n"
echo
printf "${GRAY}    2) Start the gateway - keep this terminal open:${NC}\n"
printf "         ./qoder2api\n"
echo
printf "${GRAY}    3) In another terminal, start Codex:${NC}\n"
printf "         codex --profile qoder\n"
echo
printf "${GRAY}  Your default model is untouched - plain 'codex' still uses it.${NC}\n"
echo
