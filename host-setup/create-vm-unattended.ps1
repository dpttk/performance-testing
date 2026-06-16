#Requires -Version 5.1
<#
.SYNOPSIS
  Create perf-bench VM via VirtualBox unattended Ubuntu install (Windows 11 Home).

  Usage:
    powershell -ExecutionPolicy Bypass -File .\host-setup\create-vm-unattended.ps1
#>
param(
    [string]$VmName = "perf-bench",
    [int]$MemoryMB = 8192,
    [int]$Cpus = 4,
    [int]$DiskGB = 40,
    [int]$SshHostPort = 2222,
    [string]$User = "benchmark",
    [string]$Password = "benchmark"
)

$ErrorActionPreference = "Stop"
$VBox = "${env:ProgramFiles}\Oracle\VirtualBox\VBoxManage.exe"
if (-not (Test-Path $VBox)) {
    throw "Install VirtualBox first: winget install Oracle.VirtualBox"
}

$VmDir = Join-Path $env:USERPROFILE "perf-bench-vm"
$Iso = Join-Path $VmDir "ubuntu-24.04.4-live-server-amd64.iso"
New-Item -ItemType Directory -Force -Path $VmDir | Out-Null

if (-not (Test-Path $Iso)) {
    $url = "https://releases.ubuntu.com/noble/ubuntu-24.04.4-live-server-amd64.iso"
    Write-Host "Downloading Ubuntu Server ISO (~2.5 GiB). This takes several minutes..."
    Invoke-WebRequest -Uri $url -OutFile $Iso -UseBasicParsing
}

$existing = & $VBox list vms 2>$null | Select-String "`"$VmName`""
if ($existing) {
    Write-Host "Removing existing VM..."
    $stateLine = & $VBox showvminfo $VmName --machinereadable 2>$null | Select-String '^VMState='
    if ($stateLine -match 'running') {
        & $VBox controlvm $VmName poweroff | Out-Null
        Start-Sleep -Seconds 4
    }
    & $VBox unregistervm $VmName --delete | Out-Null
}

Write-Host "Creating VM and starting unattended install (30-45 min)..."
& $VBox createvm --name $VmName --ostype "Ubuntu_64" --register
& $VBox modifyvm $VmName --memory $MemoryMB --cpus $Cpus --vram 16 --graphicscontroller vmsvga `
    --nic1 nat --natpf1 "ssh,tcp,,$SshHostPort,,22" --ioapic on --pae on --longmode on --chipset ich9
& $VBox createmedium disk --filename (Join-Path $VmDir "$VmName.vdi") --size ($DiskGB * 1024) --format VDI
& $VBox storagectl $VmName --name SATA --add sata --controller IntelAhci --portcount 2 --bootable on
& $VBox storageattach $VmName --storagectl SATA --port 0 --device 0 --type hdd `
    --medium (Join-Path $VmDir "$VmName.vdi")
& $VBox storageattach $VmName --storagectl SATA --port 1 --device 0 --type dvddrive --medium $Iso

& $VBox unattended install $VmName `
    --iso=$Iso `
    --user=$User `
    --password=$Password `
    --full-user-name="Benchmark User" `
    --hostname=perf-bench.local `
    --time-zone=UTC `
    --country=US `
    --install-additions `
    --start-vm=headless

Write-Host @"

Unattended install started for VM '$VmName'.
Monitor: VBoxManage showvminfo $VmName | findstr VMState

When install finishes (VM powers off), start again:
  VBoxManage startvm $VmName --type headless

Then SSH:
  ssh -p $SshHostPort ${User}@127.0.0.1

Provision benchmarks:
  git clone https://github.com/dpttk/performance-testing.git /opt/performance-evaluation
  cd /opt/performance-evaluation && cp config.env.example config.env
  sudo ./scripts/setup.sh && sudo ./scripts/prepare-profiles.sh && sudo ./scripts/run.sh

"@
