# Nova Fleet — Windows One-Liner Installer
# Entry point: WSL2 + delegate to bootstrap.sh
#
# Usage (PowerShell, run as Administrator):
#   irm https://raw.githubusercontent.com/novaainet2025/nova-fleet-config/main/install/install.ps1 | iex
#
# What this does:
#   1. Checks for WSL2 and installs Ubuntu if missing
#   2. Ensures git/curl inside WSL
#   3. Runs bootstrap.sh inside WSL (idempotent, re-run safe)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Colors ─────────────────────────────────────────────────────────────────
function Write-Ok   { param($m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Info { param($m) Write-Host " [INFO] $m" -ForegroundColor Cyan }
function Write-Warn { param($m) Write-Host " [WARN] $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "  [ERR] $m" -ForegroundColor Red }
function Write-Hdr  { param($m) Write-Host "`n==> $m" -ForegroundColor Blue }
function Write-Step { param($n,$t,$m) Write-Host "[$n/$t] $m" -ForegroundColor Magenta }

$TOTAL = 5
$BOOTSTRAP_URL = "https://raw.githubusercontent.com/novaainet2025/nova-fleet-config/main/install/bootstrap.sh"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     Nova Fleet — Universal Installer (Windows)       ║" -ForegroundColor Cyan
Write-Host "║     NCO · Nova-AX · All AI Providers · Claude Code  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── [1/5] Admin check ──────────────────────────────────────────────────────
Write-Step 1 $TOTAL "Checking Administrator privileges"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "This script must be run as Administrator."
    Write-Info "Right-click PowerShell → 'Run as administrator', then re-run:"
    Write-Host "  irm $BOOTSTRAP_URL/../install.ps1 | iex" -ForegroundColor Yellow
    exit 1
}
Write-Ok "Running as Administrator"

# ── [2/5] WSL2 ─────────────────────────────────────────────────────────────
Write-Step 2 $TOTAL "Checking WSL2"
$wslExe = Get-Command "wsl" -ErrorAction SilentlyContinue
if (-not $wslExe) {
    Write-Info "WSL not found — enabling WSL2 and installing Ubuntu..."
    wsl --install -d Ubuntu 2>&1
    Write-Warn "WSL2 installed. A REBOOT may be required."
    Write-Warn "After reboot, re-run this script to continue installation."
    $reboot = Read-Host "Reboot now? [y/N]"
    if ($reboot -match '^[Yy]') {
        Restart-Computer -Force
    }
    exit 0
}

# Check if Ubuntu distro is present
$distros = wsl --list --quiet 2>&1
$hasUbuntu = ($distros | Select-String -Pattern "Ubuntu" -Quiet)
if (-not $hasUbuntu) {
    Write-Info "Ubuntu not found — installing..."
    wsl --install -d Ubuntu 2>&1
    Write-Warn "Ubuntu installed. Please complete Ubuntu first-run setup, then re-run this script."
    Write-Info "  wsl -d Ubuntu"
    exit 0
}

# Check WSL version
$wslVersion = wsl --list --verbose 2>&1 | Select-String "Ubuntu"
if ($wslVersion -match "1\s*$") {
    Write-Info "Upgrading Ubuntu to WSL2..."
    wsl --set-version Ubuntu 2 2>&1
}
Write-Ok "WSL2 + Ubuntu ready"

# ── [3/5] WSL default distro ───────────────────────────────────────────────
Write-Step 3 $TOTAL "Setting Ubuntu as default WSL distro"
wsl --set-default Ubuntu 2>&1 | Out-Null
Write-Ok "Default distro: Ubuntu"

# ── [4/5] Ensure curl inside WSL ───────────────────────────────────────────
Write-Step 4 $TOTAL "Ensuring curl/bash in WSL"
wsl bash -c "command -v curl >/dev/null || (sudo apt-get update -qq && sudo apt-get install -y curl)" 2>&1
Write-Ok "curl available in WSL"

# ── [5/5] Run bootstrap.sh inside WSL ──────────────────────────────────────
Write-Step 5 $TOTAL "Running Nova Fleet bootstrap inside WSL"
Write-Info "Downloading and running: $BOOTSTRAP_URL"
Write-Host ""

# Pass through to WSL — bootstrap.sh handles everything from here
wsl bash -c "curl -fsSL '$BOOTSTRAP_URL' | bash"

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Ok "Bootstrap complete! Nova Fleet is installed in WSL Ubuntu."
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Open WSL:  wsl" -ForegroundColor White
    Write-Host "  2. Edit keys: nano ~/project/nco/.env" -ForegroundColor White
    Write-Host "  3. Auth:      claude   (Claude Code login)" -ForegroundColor White
    Write-Host "              gh auth login" -ForegroundColor White
    Write-Host "              tailscale up" -ForegroundColor White
    Write-Host "  4. Start NCO: pm2 start ~/project/nco/ecosystem.config.cjs" -ForegroundColor White
    Write-Host ""
    Write-Host "Verify: curl -s http://localhost:6200/health" -ForegroundColor Gray
} else {
    Write-Err "Bootstrap exited with code $LASTEXITCODE"
    Write-Info "Check output above for errors. Re-run to retry (idempotent)."
    exit $LASTEXITCODE
}
