#Requires -Version 5.1
<#
.SYNOPSIS
  Create a dedicated Ubuntu benchmark VM in VirtualBox (Windows 11 Home compatible).

.DESCRIPTION
  Downloads Ubuntu 24.04 cloud image, builds a cloud-init seed ISO, registers VM
  "perf-bench", and starts it headless. SSH is forwarded to localhost:2222.

  Prerequisites:
    - VirtualBox 7.x (winget install Oracle.VirtualBox)
    - ~12 GiB free disk, 8 GiB RAM available for the guest
    - Firmware virtualization enabled (BIOS/UEFI)

  After first boot (~3-5 min), connect:
    ssh -p 2222 benchmark@127.0.0.1   # password: benchmark

  Run the benchmark suite inside the guest:
    sudo /usr/local/sbin/run-benchmark-suite.sh

  Or from Windows (after guest is up):
    .\host-setup\run-benchmarks-remote.ps1
#>
param(
    [string]$VmName = "perf-bench",
    [int]$MemoryMB = 8192,
    [int]$Cpus = 4,
    [int]$DiskGB = 40,
    [int]$SshHostPort = 2222
)

$ErrorActionPreference = "Stop"
$VBox = "${env:ProgramFiles}\Oracle\VirtualBox\VBoxManage.exe"
if (-not (Test-Path $VBox)) {
    throw "VBoxManage not found. Install VirtualBox: winget install Oracle.VirtualBox"
}

$Root = Split-Path -Parent $PSScriptRoot
$VmDir = Join-Path $env:USERPROFILE "perf-bench-vm"
$CloudImg = Join-Path $VmDir "ubuntu-24.04-minimal-cloudimg-amd64.img"
$SeedIso = Join-Path $VmDir "cloud-init-seed.iso"
$DiskVdi = Join-Path $VmDir "$VmName.vdi"
$CloudInitDir = Join-Path $PSScriptRoot "cloud-init"

New-Item -ItemType Directory -Force -Path $VmDir | Out-Null

# --- Download Ubuntu minimal cloud image (~350 MiB) ---
if (-not (Test-Path $CloudImg)) {
    $url = "https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"
    Write-Host "Downloading Ubuntu cloud image..."
    Invoke-WebRequest -Uri $url -OutFile $CloudImg -UseBasicParsing
}

# --- Build cloud-init seed ISO (cidata volume label) ---
if (-not (Test-Path $SeedIso)) {
    Write-Host "Building cloud-init seed ISO..."
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $py) { $py = (Get-Command py -ErrorAction SilentlyContinue).Source }
    if (-not $py) { throw "Python not found. Install: winget install Python.Python.3.12" }
    & $py -m pip install pycdlib --quiet
    & $py (Join-Path $PSScriptRoot "make-seed-iso.py") $CloudInitDir $SeedIso
}

# --- Remove existing VM if present ---
$existing = & $VBox list vms 2>$null | Select-String "`"$VmName`""
if ($existing) {
    Write-Host "Removing existing VM '$VmName'..."
    & $VBox controlvm $VmName poweroff 2>$null | Out-Null
    Start-Sleep -Seconds 3
    & $VBox unregistervm $VmName --delete
}

# --- Create VM ---
Write-Host "Creating VM '$VmName'..."
& $VBox createvm --name $VmName --ostype "Ubuntu_64" --register
& $VBox modifyvm $VmName `
    --memory $MemoryMB `
    --cpus $Cpus `
    --vram 16 `
    --graphicscontroller vmsvga `
    --nic1 nat `
    --natpf1 "ssh,tcp,,$SshHostPort,,22" `
    --ioapic on `
    --pae on `
    --longmode on `
    --largepages on `
    --chipset ich9

& $VBox storagectl $VmName --name SATA --add sata --controller IntelAhci --portcount 4 --bootable on

# Convert cloud image to VDI if needed
if (-not (Test-Path $DiskVdi)) {
    Write-Host "Importing cloud image to VDI (may take a few minutes)..."
    & $VBox convertfromraw $CloudImg $DiskVdi --format VDI
    & $VBox modifymedium disk $DiskVdi --resize ($DiskGB * 1024)
}
& $VBox storageattach $VmName --storagectl SATA --port 0 --device 0 --type hdd --medium $DiskVdi

& $VBox storageattach $VmName --storagectl SATA --port 1 --device 0 --type dvddrive --medium $SeedIso

Write-Host "Starting VM headless..."
& $VBox startvm $VmName --type headless

Write-Host @"

VM '$VmName' is booting.
  SSH:  ssh -p $SshHostPort benchmark@127.0.0.1  (password: benchmark)
  Wait 3-5 minutes for cloud-init, then run:
        sudo /usr/local/sbin/run-benchmark-suite.sh

Shared repo on host: $Root
To copy results back after the run:
        scp -P $SshHostPort -r benchmark@127.0.0.1:/opt/performance-evaluation/results/latest ./results-from-vm/

"@
