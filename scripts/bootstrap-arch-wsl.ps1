#Requires -Version 5.1
# Bootstrap only the Arch WSL distro. For the full Omarchy+omakex stack use ..\install.ps1
param(
  [string]$DistroName = "omarchy",
  [string]$InstallDir = "$env:LOCALAPPDATA\WSL\$DistroName"
)
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Get-WslNames {
  $text = ((& wsl.exe -l -q 2>$null) | Out-String) -replace "\0", ""
  @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$helper = @(Get-WslNames | Where-Object { $_ -ne $DistroName }) | Select-Object -First 1
if (-not $helper) {
  Write-Host "Need an existing WSL distro (e.g. Ubuntu) to run bootstrap." -ForegroundColor Yellow
  exit 1
}
$repoWsl = (& wsl.exe -d $helper -- wslpath -a $RepoRoot).ToString().Trim()
$installWsl = (& wsl.exe -d $helper -- wslpath -a $InstallDir).ToString().Trim()
Write-Host "Bootstrap via $helper → $DistroName"
& wsl.exe -d $helper -- bash -lc "chmod +x '$repoWsl'/scripts/*.sh; OMAKEX_DISTRO='$DistroName' OMAKEX_INSTALL_DIR='$installWsl' '$repoWsl'/scripts/bootstrap-arch-wsl.sh"
