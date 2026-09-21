# ============================================================
#  qoder2api - one-click setup for Codex (Windows)
#
#  What it does:
#    1. backs up your existing ~/.codex/config.toml
#    2. adds the [model_providers.qoder_local] block (skips if present)
#    3. registers the qfmodel catalog (skips if a catalog is already set)
#    4. creates the qoder profile file
#    5. sets the two required user-level environment variables
#
#  What it does NOT do:
#    - it never touches your default model / default provider
#    - it never overwrites an existing model_catalog_json setting
#
#  Safe to run more than once (idempotent).
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File .\setup.ps1
# ============================================================

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok  ($msg) { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err ($msg) { Write-Host "[x] $msg" -ForegroundColor Red }

function Write-Utf8NoBom($path, $content) {
    # PowerShell 5.1's -Encoding UTF8 writes a BOM, which can break TOML parsers.
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $content, $enc)
}

Write-Host ""
Write-Host "  qoder2api setup for Codex" -ForegroundColor White
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------
# 0. sanity checks
# ---------------------------------------------------------------
$codexDir = Join-Path $env:USERPROFILE '.codex'
$cfgPath  = Join-Path $codexDir 'config.toml'
$profPath = Join-Path $codexDir 'qoder.config.toml'
$catPath  = Join-Path $codexDir 'qoder-models.json'

Write-Step "Checking prerequisites"

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    Write-Warn "codex not found in PATH."
    Write-Warn "Install Codex CLI first: https://github.com/openai/codex"
    Write-Warn "Continuing anyway - config files will still be written."
}

if (-not (Test-Path $codexDir)) {
    New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
    Write-Ok "Created $codexDir"
} else {
    Write-Ok "Found $codexDir"
}

# ---------------------------------------------------------------
# 1. back up config.toml
# ---------------------------------------------------------------
if (Test-Path $cfgPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = "$cfgPath.bak-qoder-$stamp"
    Copy-Item $cfgPath $bak -Force
    Write-Ok "Backed up config.toml -> $(Split-Path $bak -Leaf)"
    $cfg = Get-Content $cfgPath -Raw
} else {
    Write-Warn "config.toml not found - a new one will be created"
    $cfg = ''
}

# ---------------------------------------------------------------
# 2. add the provider block (idempotent)
# ---------------------------------------------------------------
$changed = $false

if ($cfg -match 'model_providers\.qoder_local') {
    Write-Ok "Provider [model_providers.qoder_local] already present - skipped"
} else {
    $cfg = $cfg.TrimEnd() + @'


# ---- Qoder local gateway (free Qwen3.8-Flash) ----
# Added by setup.ps1 - serves OpenAI-compatible endpoints on 127.0.0.1:8963
[model_providers.qoder_local]
name = "Qoder Local"
base_url = "http://127.0.0.1:8963/v1"
env_key = "QODER_LOCAL_KEY"
wire_api = "responses"
'@
    $changed = $true
    Write-Ok "Added provider [model_providers.qoder_local]"
}

# ---------------------------------------------------------------
# 3. register the model catalog (never overwrite an existing one)
# ---------------------------------------------------------------
if ($cfg -match 'model_catalog_json') {
    Write-Warn "model_catalog_json is already set in config.toml - NOT touched."
    Write-Warn "If you want qfmodel metadata, merge the entry from qoder-models.json manually."
} else {
    Write-Utf8NoBom $catPath (@'
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
'@)

    # model_catalog_json is a TOP-LEVEL key: it must sit before the first [table]
    $lines = $cfg -split "`r?`n"
    $firstTable = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimStart().StartsWith('[')) { $firstTable = $i; break }
    }
    $entry = "model_catalog_json = '$($catPath -replace '\\','/')'"
    if ($firstTable -ge 0) {
        $newLines = @()
        $newLines += $lines[0..($firstTable - 1)]
        $newLines += $entry
        $newLines += ''
        $newLines += $lines[$firstTable..($lines.Count - 1)]
        $cfg = $newLines -join "`r`n"
    } else {
        $cfg = $cfg.TrimEnd() + "`r`n" + $entry + "`r`n"
    }
    Write-Ok "Registered model catalog (qoder-models.json)"
    $changed = $true
}

# Only rewrite config.toml when something actually changed
if ($changed) {
    Write-Utf8NoBom $cfgPath $cfg
    Write-Ok "config.toml updated"
} else {
    Write-Ok "config.toml unchanged - not rewritten"
}

# ---------------------------------------------------------------
# 4. create the profile file
# ---------------------------------------------------------------
if (Test-Path $profPath) {
    Write-Ok "Profile qoder.config.toml already exists - skipped"
} else {
    Write-Utf8NoBom $profPath @'
model = "qfmodel"
model_provider = "qoder_local"
model_reasoning_effort = "medium"
'@
    Write-Ok "Created profile qoder.config.toml"
}

# ---------------------------------------------------------------
# 5. environment variables
# ---------------------------------------------------------------
Write-Step "Setting user-level environment variables"

# The gateway does not check auth, but Codex refuses to send a request
# when the provider's env_key is missing. Any non-empty value works.
[Environment]::SetEnvironmentVariable('QODER_LOCAL_KEY', 'qoder-local-gateway', 'User')
Write-Ok "QODER_LOCAL_KEY = qoder-local-gateway"

# Without this, a system HTTP proxy swallows requests to 127.0.0.1
# and Codex silently gets nothing back.
[Environment]::SetEnvironmentVariable('NO_PROXY', '127.0.0.1,localhost,::1', 'User')
[Environment]::SetEnvironmentVariable('no_proxy', '127.0.0.1,localhost,::1', 'User')
Write-Ok "NO_PROXY = 127.0.0.1,localhost,::1"

# ---------------------------------------------------------------
# done
# ---------------------------------------------------------------
Write-Host ""
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
Write-Ok "Setup complete."
Write-Host ""
Write-Host "  Next steps (open a NEW terminal so the env vars apply):" -ForegroundColor White
Write-Host ""
Write-Host "    1) Authorize with Qoder (once, opens your browser):" -ForegroundColor Gray
Write-Host "         .\qoder2api-login.exe" -ForegroundColor White
Write-Host ""
Write-Host "    2) Start the gateway - keep this window open:" -ForegroundColor Gray
Write-Host "         .\qoder2api.exe" -ForegroundColor White
Write-Host ""
Write-Host "    3) In another terminal, start Codex:" -ForegroundColor Gray
Write-Host "         codex --profile qoder" -ForegroundColor White
Write-Host ""
Write-Host "  Your default model is untouched - plain 'codex' still uses it." -ForegroundColor DarkGray
Write-Host ""
