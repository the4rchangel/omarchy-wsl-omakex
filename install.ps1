#Requires -Version 5.1
<#
.SYNOPSIS
  One-shot install of Omarchy WSL + omakex (Win-KeX-style Hyprland desktop).

.DESCRIPTION
  1. Ensures WSL2 is available
  2. Creates Arch WSL distro "omarchy" if missing (needs any existing distro as helper)
  3. Copies this repo into the distro and runs the full installer
  4. Optionally installs TigerVNC Viewer via winget

.EXAMPLE
  git clone https://github.com/the4rchangel/omarchy-wsl-omakex.git
  cd omarchy-wsl-omakex
  Set-ExecutionPolicy -Scope Process Bypass
  .\install.ps1
#>
param(
  [string]$DistroName = "omarchy",
  [string]$UserName = "omarchy",
  [string]$InstallDir = "$env:LOCALAPPDATA\WSL\$DistroName",
  [switch]$SkipTigerVNC,
  [switch]$SkipBootstrap
)

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

function Get-WslNames {
  $text = ((& wsl.exe -l -q 2>$null) | Out-String) -replace "\0", ""
  return @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-Distro([string]$Name) {
  return (Get-WslNames) -contains $Name
}

function Get-HelperDistro {
  $names = Get-WslNames | Where-Object { $_ -ne $DistroName }
  if ($names.Count -gt 0) { return $names[0] }
  return $null
}

function ConvertTo-WslPath([string]$WinPath, [string]$ViaDistro) {
  $p = (& wsl.exe -d $ViaDistro -- wslpath -a "$WinPath" 2>$null)
  if ($p) { return ($p | Select-Object -Last 1).ToString().Trim() }
  # Fallback /mnt/<drive>/...
  if ($WinPath -match '^([A-Za-z]):\\(.*)$') {
    $drive = $Matches[1].ToLower()
    $rest = ($Matches[2] -replace '\\', '/')
    return "/mnt/$drive/$rest"
  }
  throw "Cannot convert path to WSL: $WinPath"
}

Write-Host @"

  Omarchy WSL + omakex installer
  Distro: $DistroName   User: $UserName

"@ -ForegroundColor Green

Write-Step "Checking WSL"
try { $null = & wsl.exe --status 2>&1 } catch {
  Write-Host "WSL not found. In Admin PowerShell run:  wsl --install" -ForegroundColor Yellow
  Write-Host "Reboot, then re-run .\install.ps1"
  exit 1
}

$helper = Get-HelperDistro
if (-not $helper -and -not (Test-Distro $DistroName)) {
  Write-Host "Need at least one WSL distro to bootstrap from (e.g. Ubuntu)." -ForegroundColor Yellow
  Write-Host "  wsl --install -d Ubuntu"
  Write-Host "Then re-run .\install.ps1"
  exit 1
}
if (-not $helper) { $helper = $DistroName }

# --- Bootstrap ---
if (-not $SkipBootstrap) {
  if (Test-Distro $DistroName) {
    Write-Step "Distro '$DistroName' already exists — skipping bootstrap"
  } else {
    Write-Step "Bootstrapping Arch WSL distro '$DistroName' (via $helper)"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $repoWsl = ConvertTo-WslPath $RepoRoot $helper
    $installWsl = ConvertTo-WslPath $InstallDir $helper
    & wsl.exe -d $helper -- bash -lc @"
set -euo pipefail
chmod +x '$repoWsl'/scripts/*.sh '$repoWsl'/omakex/omakex
export OMAKEX_DISTRO='$DistroName'
export OMAKEX_INSTALL_DIR='$installWsl'
export OMAKEX_USER='$UserName'
'$repoWsl'/scripts/bootstrap-arch-wsl.sh
"@
    if (-not (Test-Distro $DistroName)) {
      Write-Host "Bootstrap failed — '$DistroName' not listed in wsl -l." -ForegroundColor Red
      exit 1
    }
  }
}

# --- Ensure Linux user ---
Write-Step "Ensuring Linux user '$UserName'"
& wsl.exe -d $DistroName -u root -- bash -lc @"
set -euo pipefail
if ! id '$UserName' &>/dev/null; then
  useradd -m -G wheel,video,render -s /bin/bash '$UserName'
  echo '$UserName ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/$UserName
  chmod 440 /etc/sudoers.d/$UserName
fi
mkdir -p /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' >/etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
usermod -aG wheel,video,render '$UserName' || true
"@

# --- Copy repo ---
Write-Step "Copying repo into $DistroName:/home/$UserName/omarchy-wsl-omakex"
$dest = "/home/$UserName/omarchy-wsl-omakex"
$repoWsl = ConvertTo-WslPath $RepoRoot $DistroName
& wsl.exe -d $DistroName -u root -- bash -lc @"
set -euo pipefail
rm -rf '$dest'
mkdir -p '$dest'
# Prefer rsync-like copy excluding heavy build artifacts
tar -C '$repoWsl' --exclude=build --exclude=.git -cf - . | tar -C '$dest' -xf -
chown -R $UserName:$UserName /home/$UserName
chmod +x '$dest'/scripts/*.sh '$dest'/omakex/omakex
"@

# --- Install ---
Write-Step "Installing Omarchy desktop + patched Aquamarine + omakex (several minutes)"
& wsl.exe -d $DistroName -u root --env "OMAKEX_USER=$UserName" -- bash -lc "bash $dest/scripts/install-omarchy-wsl.sh"
if ($LASTEXITCODE -ne 0) {
  Write-Host "Installer failed (exit $LASTEXITCODE). Check output above." -ForegroundColor Red
  exit $LASTEXITCODE
}

# --- TigerVNC ---
if (-not $SkipTigerVNC) {
  Write-Step "TigerVNC Viewer"
  $vnc = Join-Path ${env:ProgramFiles} "TigerVNC\vncviewer.exe"
  if (Test-Path $vnc) {
    Write-Host "Already installed: $vnc"
  } else {
    try {
      & winget install -e --id TigerVNC.TigerVNC --accept-package-agreements --accept-source-agreements
    } catch {
      Write-Host "Install TigerVNC manually: winget install TigerVNC.TigerVNC" -ForegroundColor Yellow
    }
  }
}

Write-Step "Restarting distro (applies default user + DRM boot fix)"
& wsl.exe --terminate $DistroName 2>$null
Start-Sleep -Seconds 2

Write-Host @"

Done. Launch like Kali KeX:

  wsl -d $DistroName
  omakex

Or one-liner from PowerShell:

  wsl -d $DistroName -- omakex

TigerVNC opens on localhost:5901. Stop with: omakex stop

"@ -ForegroundColor Green
