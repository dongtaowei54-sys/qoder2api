# ============================================================
#  qoder2api - cross-compile all release binaries
#
#  Produces zip archives in .\dist\ ready to upload to a
#  GitHub Release. Each archive contains:
#     qoder2api(.exe)         - the gateway
#     qoder2api-login(.exe)   - one-time OAuth helper
#     setup.ps1 / setup.sh    - one-click Codex configuration
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File .\build-all.ps1
# ============================================================

$ErrorActionPreference = 'Stop'

$DistDir = Join-Path $PSScriptRoot 'dist'
$BinDir  = Join-Path $PSScriptRoot 'bin'

# target list: name = GOOS/GOARCH
$Targets = [ordered]@{
    'windows-amd64' = @{ GOOS = 'windows'; GOARCH = 'amd64'; Ext = '.exe' }
    'windows-arm64' = @{ GOOS = 'windows'; GOARCH = 'arm64'; Ext = '.exe' }
    'darwin-amd64'  = @{ GOOS = 'darwin';  GOARCH = 'amd64'; Ext = ''     }
    'darwin-arm64'  = @{ GOOS = 'darwin';  GOARCH = 'arm64'; Ext = ''     }
    'linux-amd64'   = @{ GOOS = 'linux';   GOARCH = 'amd64'; Ext = ''     }
    'linux-arm64'   = @{ GOOS = 'linux';   GOARCH = 'arm64'; Ext = ''     }
}

Write-Host ""
Write-Host "  qoder2api cross-compile" -ForegroundColor White
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

if (Test-Path $DistDir) { Remove-Item $DistDir -Recurse -Force }
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
New-Item -ItemType Directory -Path $BinDir  -Force | Out-Null

# CGO off so the cross-compile needs no C toolchain
$env:CGO_ENABLED = '0'

foreach ($name in $Targets.Keys) {
    $t     = $Targets[$name]
    $ext   = $t.Ext
    $stage = Join-Path $DistDir "_stage_$name"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    Write-Host "[*] building $name ..." -ForegroundColor Cyan

    $env:GOOS   = $t.GOOS
    $env:GOARCH = $t.GOARCH

    $gwOut  = Join-Path $stage "qoder2api$ext"
    $lgOut  = Join-Path $stage "qoder2api-login$ext"

    & go build -trimpath -ldflags '-s -w' -o $gwOut ./cmd/qoder2api
    if ($LASTEXITCODE -ne 0) { throw "build failed: $name (gateway)" }

    & go build -trimpath -ldflags '-s -w' -o $lgOut ./cmd/qoder2api-login
    if ($LASTEXITCODE -ne 0) { throw "build failed: $name (login)" }

    Copy-Item (Join-Path $PSScriptRoot 'setup.ps1') $stage -Force
    Copy-Item (Join-Path $PSScriptRoot 'setup.sh')  $stage -Force
    Copy-Item (Join-Path $PSScriptRoot 'LICENSE')   $stage -Force

    if ($t.GOOS -eq 'windows') {
        Copy-Item (Join-Path $PSScriptRoot 'QUICKSTART-zh.md') $stage -Force -ErrorAction SilentlyContinue
    }

    $zip = Join-Path $DistDir "qoder2api-$name.zip"
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
    Remove-Item $stage -Recurse -Force

    $sizeMb = [math]::Round((Get-Item $zip).Length / 1MB, 2)
    Write-Host "[+] $name -> qoder2api-$name.zip ($sizeMb MB)" -ForegroundColor Green
}

Write-Host ""
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
Write-Host "[+] All targets built. Upload these to a GitHub Release:" -ForegroundColor Green
Get-ChildItem $DistDir -Filter '*.zip' | ForEach-Object {
    Write-Host "      $($_.Name)" -ForegroundColor White
}
Write-Host ""
