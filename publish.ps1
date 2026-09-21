# ============================================================
#  qoder2api - one-shot GitHub publish
#
#  Prerequisite: you must have run `gh auth login` first.
#
#  What it does, in order:
#    1. verifies gh authentication
#    2. reads your GitHub username
#    3. sets a local git identity (GitHub noreply address)
#    4. commits all changes
#    5. forks jyao0708/qoder2api into your account (if not present)
#    6. repoints `origin` to YOUR fork
#    7. pushes the code
#    8. creates and pushes the tag v0.1.0-codex
#    9. creates the GitHub Release and uploads all dist/*.zip
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File .\publish.ps1
#
#  Add -DryRun to only print what would happen:
#    powershell -ExecutionPolicy Bypass -File .\publish.ps1 -DryRun
# ============================================================

param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------
#  Locate gh
#  GitHub CLI is not always on PATH (a plain PowerShell session
#  frequently misses it), so look in the usual install locations.
# ---------------------------------------------------------------
$GhPrefix = 'gh'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    $ghCandidates = @(
        'C:\Program Files\GitHub CLI\gh.exe',
        'C:\Program Files (x86)\GitHub CLI\gh.exe'
    )
    if ($env:ProgramFiles)         { $ghCandidates += (Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe') }
    if (${env:ProgramFiles(x86)})  { $ghCandidates += (Join-Path ${env:ProgramFiles(x86)} 'GitHub CLI\gh.exe') }
    if ($env:LOCALAPPDATA)         { $ghCandidates += (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe') }
    foreach ($c in $ghCandidates) {
        if ($c -and (Test-Path $c)) {
            # call operator + quotes so paths with spaces survive Invoke-Expression
            $GhPrefix = '& "' + $c + '"'
            break
        }
    }
}

# distinguish "gh not installed" from "gh installed but not logged in" -
# the latter is recoverable with `gh auth login`, the former is not
if ($GhPrefix -eq 'gh' -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "[x] gh (GitHub CLI) is not installed on this machine." -ForegroundColor Red
    Write-Host ""
    Write-Host "Install it first, then log in and re-run this script:" -ForegroundColor Red
    Write-Host ""
    Write-Host "    winget install GitHub.cli" -ForegroundColor Red
    Write-Host "    gh auth login" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------
#  Proxy
#  git does NOT read the Windows system proxy, so on a machine that
#  reaches GitHub through one, `git push` dies with
#  "Recv failure: Connection was reset". Detect it and export the
#  usual env vars so both git and gh use it.
# ---------------------------------------------------------------
if (-not $env:HTTPS_PROXY -and -not $env:https_proxy) {
    try {
        $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($reg.ProxyEnable -eq 1 -and $reg.ProxyServer) {
            $ps = $reg.ProxyServer
            if ($ps -notmatch '^https?://') { $ps = "http://$ps" }
            # set BOTH cases: libcurl prefers the lowercase variable
            $env:HTTPS_PROXY = $ps
            $env:HTTP_PROXY  = $ps
            $env:https_proxy = $ps
            $env:http_proxy  = $ps
            Write-Host "[*] Using Windows system proxy: $ps" -ForegroundColor Cyan
        }
    } catch { }
}

# never sit on an interactive credential prompt
$env:GIT_TERMINAL_PROMPT = '0'

# GitHub itself must not go through NO_PROXY
if (-not $env:NO_PROXY) { $env:NO_PROXY = '127.0.0.1,localhost,::1' }
if (-not $env:no_proxy) { $env:no_proxy = '127.0.0.1,localhost,::1' }

# surface which proxy is actually in effect - a silently-ignored proxy is
# the single most confusing failure mode here
if ($env:https_proxy -and $env:HTTPS_PROXY -and $env:https_proxy -ne $env:HTTPS_PROXY) {
    Write-Host "[!] https_proxy overrides HTTPS_PROXY - aligning them" -ForegroundColor Yellow
    $env:HTTPS_PROXY = $env:https_proxy
}

$Upstream  = 'jyao0708/qoder2api'
$RepoName  = 'qoder2api'
$Tag       = 'v0.1.0-codex'
$ReleaseTitle = 'v0.1.0-codex — Codex CLI 一键接入版'
$NotesFile = Join-Path $PSScriptRoot 'RELEASE-NOTES.md'

function Say($m)  { Write-Host "[*] $m" -ForegroundColor Cyan }
function Good($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

function Run($cmd, [switch]$AllowFail) {
    if ($DryRun) { Write-Host "      [dry-run] $cmd" -ForegroundColor DarkGray; return 0 }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # capture BOTH streams: merging stderr in and assigning to a variable keeps
    # the tool's real error message instead of losing it down the error stream
    $out = Invoke-Expression "$cmd 2>&1"
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($out) {
        $out | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    }
    if ($code -ne 0 -and -not $AllowFail) { Die "command failed: $cmd" }
    return $code
}

# retry a flaky network command (push / release upload)
function Retry($cmd, $times = 3) {
    for ($i = 1; $i -le $times; $i++) {
        $c = Run $cmd -AllowFail
        if ($c -eq 0) { return 0 }
        if ($i -lt $times) {
            Warn "attempt $i/$times failed - retrying in 6s"
            Start-Sleep -Seconds 6
        }
    }
    Die "command still failing after $times attempts: $cmd"
    return 1
}

# probe a gh/git command without ever throwing on a non-zero exit
function Probe($cmd) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $text = Invoke-Expression "$cmd 2>`$null" | Out-String
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return @{ Ok = ($code -eq 0); Text = $text }
}

Set-Location $PSScriptRoot

Write-Host ""
Write-Host "  qoder2api -> GitHub publish" -ForegroundColor White
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
if ($DryRun) { Warn "DRY RUN - nothing will actually be changed" }
Write-Host ""

# ---------------------------------------------------------------
# 1. auth
# ---------------------------------------------------------------
Say "Checking GitHub authentication"

$ghProbe = Probe "$GhPrefix auth status"
$ghStatus = $ghProbe.Text
if (-not $ghProbe.Ok) {
    Die @"
Not logged in to GitHub.

Run this first, then re-run this script:

    gh auth login

(then pick: GitHub.com -> HTTPS -> Login with a web browser)
"@
}
Good "gh is authenticated"

# ---------------------------------------------------------------
# 2. who am I
# ---------------------------------------------------------------
$userProbe = Probe "$GhPrefix api user --jq .login"
$user = $userProbe.Text.Trim()
if (-not $user) { Die "could not read your GitHub username via 'gh api user'" }
Good "GitHub user: $user"

# ---------------------------------------------------------------
# 3. git identity
# ---------------------------------------------------------------
Say "Configuring local git identity"

$curName  = (git config user.name 2>$null | Out-String).Trim()
$curEmail = (git config user.email 2>$null | Out-String).Trim()

if (-not $curName)  { Run "git config user.name `"$user`"";  Good "user.name = $user" }
else                { Good "user.name already set: $curName" }

if (-not $curEmail) {
    $uid = (Probe "$GhPrefix api user --jq .id").Text.Trim()
    if (-not $uid) { $uid = '0' }
    Run "git config user.email `"${uid}+${user}@users.noreply.github.com`""
    Good "user.email = ${uid}+${user}@users.noreply.github.com"
} else {
    Good "user.email already set: $curEmail"
}

# ---------------------------------------------------------------
# 4. commit
# ---------------------------------------------------------------
Say "Committing local changes"

$dirty = (git status --porcelain | Out-String).Trim()
if ($dirty) {
    Run "git add -A"
    $msg = "feat: Codex CLI compatibility patches + one-click installer`n`n- normalize role: developer -> system (Codex Responses API)`n- drop non-function tool types, wrap custom tools as function`n- add QUICKSTART-zh.md, PATCH.md, setup.ps1, setup.sh, build-all.ps1`n- README: note fork origin and upstream attribution"
    if ($DryRun) { Write-Host "      [dry-run] git commit -m <multi-line message>" -ForegroundColor DarkGray }
    else {
        [System.IO.File]::WriteAllText("$env:TEMP\qoder2api-commit-msg.txt", $msg, (New-Object System.Text.UTF8Encoding($false)))
        git commit -F "$env:TEMP\qoder2api-commit-msg.txt" | Out-Host
        Remove-Item "$env:TEMP\qoder2api-commit-msg.txt" -Force
        if ($LASTEXITCODE -ne 0) { Die "git commit failed" }
    }
    Good "changes committed"
} else {
    Good "nothing to commit - working tree clean"
}

# ---------------------------------------------------------------
# 5. fork
# ---------------------------------------------------------------
Say "Ensuring fork exists"

$forkProbe = Probe "$GhPrefix repo view `"$user/$RepoName`""
$forkCheck = $forkProbe.Text
if (-not $forkProbe.Ok -or $forkCheck -match 'not found|Could not resolve') {
    Warn "no fork found for $user/$RepoName"
    Run "$GhPrefix api repos/$Upstream/forks -X POST --jq .full_name"
    Start-Sleep -Seconds 5
    Good "forked $Upstream -> $user/$RepoName"
} else {
    Good "fork already exists: $user/$RepoName"
}

# ---------------------------------------------------------------
# 6. repoint origin
# ---------------------------------------------------------------
Say "Pointing origin at your fork"

$expected = "https://github.com/$user/$RepoName.git"
$curRemote = (git remote get-url origin 2>$null | Out-String).Trim()

if ($curRemote -ne $expected) {
    Run "git remote set-url origin `"$expected`""
    Good "origin -> $expected"
    if ($curRemote -match 'jyao0708') {
        Warn "upstream kept as a separate remote for future syncs"
        $hasUpstream = (git remote 2>$null | Out-String) -match 'upstream'
        if (-not $hasUpstream) { Run "git remote add upstream https://github.com/$Upstream.git" }
    }
} else {
    Good "origin already correct"
}

# ---------------------------------------------------------------
# 7. push code
# ---------------------------------------------------------------
# make git reuse the gh token - otherwise Windows pops the
# "CredentialHelperSelector" dialog and the push hangs forever
$ghelper = (Probe 'git config --global --get credential.https://github.com.helper').Text.Trim()
if (-not $ghelper) {
    Run "git config --global credential.https://github.com.helper `"!gh auth git-credential`""
    Good "git credentialed to use your existing gh login (no extra sign-in)"
} else {
    Good "git credential helper already configured: $ghelper"
}

Say "Pushing code"
Retry "git push -u origin HEAD"

# ---------------------------------------------------------------
# 8. tag
# ---------------------------------------------------------------
Say "Creating tag $Tag"

$tagExists = (git tag -l $Tag | Out-String).Trim()
if ($tagExists) {
    $tagCommit = (git rev-list -n 1 $Tag | Out-String).Trim()
    $headCommit = (git rev-parse HEAD | Out-String).Trim()
    if ($tagCommit -ne $headCommit) {
        Warn "tag $Tag points at an older commit - moving it to HEAD"
        Run "git tag -f -a $Tag -m `"Codex CLI one-click build`""
    } else {
        Good "tag $Tag already points at HEAD"
    }
} else {
    Run "git tag -a $Tag -m `"Codex CLI one-click build`""
}

# the remote tag may exist from an earlier publish and point elsewhere
if ((Run "git push origin $Tag" -AllowFail) -ne 0) {
    Warn "cannot push $Tag normally - force updating the remote tag"
    Retry "git push --force origin $Tag"
}

# ---------------------------------------------------------------
# 9. release + assets
# ---------------------------------------------------------------
Say "Creating GitHub Release and uploading assets"

$assets = Get-ChildItem (Join-Path $PSScriptRoot 'dist') -Filter '*.zip' -ErrorAction SilentlyContinue
if (-not $assets -or $assets.Count -eq 0) { Die "no dist/*.zip found - run build-all.ps1 first" }

$sumFile = Join-Path $PSScriptRoot 'dist\SHA256SUMS.txt'
$notesArg = ''
if (Test-Path $NotesFile) {
    $notesArg = "--notes-file `"$NotesFile`""
} else {
    $notesArg = "--notes `"Codex CLI one-click build. See QUICKSTART-zh.md`""
}

$assetList = ($assets | ForEach-Object { "`"$($_.FullName)`"" }) -join ' '
if (Test-Path $sumFile) { $assetList += " `"$sumFile`"" }

$relProbe = Probe "$GhPrefix release view $Tag -R `"$user/$RepoName`""
if ($relProbe.Ok) {
    Warn "release $Tag already exists - uploading assets to it"
    Retry "$GhPrefix release upload $Tag $assetList -R `"$user/$RepoName`" --clobber"
} else {
    Retry "$GhPrefix release create $Tag $assetList -R `"$user/$RepoName`" --title `"$ReleaseTitle`" $notesArg"
}

# ---------------------------------------------------------------
# done
# ---------------------------------------------------------------
Write-Host ""
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
Good "Published."
Write-Host ""
Write-Host "  Repo    : https://github.com/$user/$RepoName" -ForegroundColor White
Write-Host "  Release : https://github.com/$user/$RepoName/releases/tag/$Tag" -ForegroundColor White
Write-Host ""
Write-Host "  Uploaded assets:" -ForegroundColor Gray
$assets | ForEach-Object { Write-Host "    - $($_.Name)" -ForegroundColor Gray }
Write-Host ""
