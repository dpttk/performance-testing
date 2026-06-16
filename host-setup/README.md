# Host Setup (Windows)

This directory contains scripts to run the benchmark suite on a dedicated Linux
environment from a Windows 11 host.

## Environment constraints on this machine

| Item | Status |
|------|--------|
| Windows edition | Home (Hyper-V not available) |
| WSL2 Ubuntu | Installed but requires reboot after enabling Virtual Machine Platform |
| VirtualBox | Supported; use for a dedicated benchmark VM |

## Option A — VirtualBox VM (recommended on Windows Home)

**Automated install (recommended):**

```powershell
cd C:\Users\plato\performance-evaluation
powershell -ExecutionPolicy Bypass -File .\host-setup\create-vm-unattended.ps1
```

Downloads Ubuntu Server ISO (~2.5 GiB), installs headless (~30–45 min), forwards SSH to port 2222.

**After install completes:**

```powershell
ssh -p 2222 benchmark@127.0.0.1
git clone https://github.com/dpttk/performance-testing.git /opt/performance-evaluation
cd /opt/performance-evaluation
sudo cp config.env.example config.env
sudo ./scripts/setup.sh
sudo ./scripts/prepare-profiles.sh
sudo ./scripts/run.sh
```

Or from Windows:

```powershell
.\host-setup\run-benchmarks-remote.ps1 -SetupOnly
.\host-setup\run-benchmarks-remote.ps1
```

Guest password: `benchmark`

**Cloud-image path** (`create-vm.ps1`) is experimental on Windows due to ISO tooling limits; prefer unattended install.

## Option B — WSL2 (after reboot)

1. Run as Administrator:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\host-setup\enable-wsl.ps1
   ```

2. Reboot.

3. Inside WSL:

   ```bash
   cd /mnt/c/Users/plato/performance-evaluation
   sudo cp config.env.example config.env
   sudo ./scripts/setup.sh
   sudo ./scripts/prepare-profiles.sh
   sudo ./scripts/run.sh
   ```

## Credibility notes

- Use a dedicated VM or WSL instance with minimal background load.
- Ensure firmware virtualization is enabled (BIOS/UEFI).
- Full campaign (`REPS=50`) takes several hours.
- Copy `results/latest/` from the guest after completion.
