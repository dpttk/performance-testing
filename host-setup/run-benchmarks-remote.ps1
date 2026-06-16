#Requires -Version 5.1
<#
.SYNOPSIS
  SSH into the perf-bench VM and run (or monitor) the benchmark suite.
#>
param(
    [int]$Port = 2222,
    [string]$User = "benchmark",
    [string]$HostAddr = "127.0.0.1",
    [switch]$Quick,
    [switch]$SetupOnly
)

$ssh = Get-Command ssh -ErrorAction SilentlyContinue
if (-not $ssh) {
    throw "OpenSSH client not found."
}

$remoteCmd = if ($SetupOnly) {
    "cd /opt/performance-evaluation 2>/dev/null || git clone https://github.com/dpttk/performance-testing.git /opt/performance-evaluation; cd /opt/performance-evaluation && cp -n config.env.example config.env && sudo ./scripts/setup.sh"
} elseif ($Quick) {
    "sudo /opt/performance-evaluation/scripts/run.sh --quick"
} else {
    "sudo /usr/local/sbin/run-benchmark-suite.sh"
}

Write-Host "Connecting to ${User}@${HostAddr}:${Port} ..."
ssh -o StrictHostKeyChecking=no -p $Port "${User}@${HostAddr}" $remoteCmd
