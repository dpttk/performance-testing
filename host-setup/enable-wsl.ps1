#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Enable WSL2 (Virtual Machine Platform + Windows Subsystem for Linux).

  Run in an elevated PowerShell, then REBOOT:
    powershell -ExecutionPolicy Bypass -File .\host-setup\enable-wsl.ps1

  After reboot:
    wsl -d Ubuntu
    cd /mnt/c/Users/plato/performance-evaluation
    sudo ./scripts/setup.sh
#>
$ErrorActionPreference = "Stop"

Write-Host "Enabling Windows features for WSL2..."
dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism /online /enable-feature /featurename:HypervisorPlatform /all /norestart

Write-Host "Setting WSL2 as default..."
wsl --set-default-version 2

Write-Host @"

Features enabled. A REBOOT is required before WSL2 will start.

After reboot:
  wsl -d Ubuntu
  cd /mnt/c/Users/plato/performance-evaluation
  sudo cp config.env.example config.env
  sudo ./scripts/setup.sh
  sudo ./scripts/prepare-profiles.sh
  sudo ./scripts/run.sh

"@

$reboot = Read-Host "Reboot now? (y/N)"
if ($reboot -eq 'y' -or $reboot -eq 'Y') {
    Restart-Computer -Force
}
