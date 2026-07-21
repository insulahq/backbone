# ==========================================================================
# NetBird Self-Heal Guard — Windows installer
# ==========================================================================
# Installs a Scheduled Task (runs as SYSTEM every 2 minutes) that restarts
# the NetBird engine (netbird down && netbird up) when management/signal
# stay disconnected — so the peer recovers automatically after a NetBird
# server failover instead of dangling until someone restarts it by hand.
#
# Same state machine as the Linux guard (scripts/netbird-selfheal-install.sh):
# N consecutive failed checks -> engine restart, with a cooldown flap guard.
#
# Requirements: Windows with the NetBird client installed, admin shell.
# Usage (elevated PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\netbird-selfheal-install.ps1
#
# Tunables:
#   -IntervalMinutes 2   check cadence
#   -FailThreshold  3    consecutive failed checks before restart
#   -CooldownSecs   900  min seconds between restarts
#
# Project: https://github.com/insulahq/backbone
# ==========================================================================
#Requires -RunAsAdministrator

param(
    [int]$IntervalMinutes = 2,
    [int]$FailThreshold = 3,
    [int]$CooldownSecs = 900
)

$ErrorActionPreference = 'Stop'

$stateDir = Join-Path $env:ProgramData 'netbird-selfheal'
$guardPath = Join-Path $stateDir 'netbird-selfheal.ps1'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

# --- The guard script itself (single-quoted here-string: no expansion; the
# --- tunables are injected on the placeholder lines below) -----------------
$guard = @'
# NetBird Self-Heal Guard — restarts the engine when management/signal stay
# disconnected. Installed by netbird-selfheal-install.ps1
# (https://github.com/insulahq/backbone).

$FailThreshold = __FAIL_THRESHOLD__
$CooldownSecs = __COOLDOWN_SECS__

$stateDir = Join-Path $env:ProgramData 'netbird-selfheal'
$failFile = Join-Path $stateDir 'fails'
$lastRestartFile = Join-Path $stateDir 'last-restart'
$logFile = Join-Path $stateDir 'selfheal.log'

function Write-Log([string]$msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $msg"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    # Keep the log from growing unbounded
    if ((Get-Item $logFile -ErrorAction SilentlyContinue).Length -gt 1MB) {
        Get-Content $logFile -Tail 200 | Set-Content $logFile
    }
}

# Locate netbird.exe (PATH first, default install dir as fallback)
$netbird = (Get-Command netbird.exe -ErrorAction SilentlyContinue).Source
if (-not $netbird) {
    $candidate = Join-Path $env:ProgramFiles 'NetBird\netbird.exe'
    if (Test-Path $candidate) { $netbird = $candidate } else { exit 0 }
}

# Service not running — nothing to guard (netbird up cannot help either)
$svc = Get-Service -Name 'netbird' -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne 'Running') { exit 0 }

# Plain-text status parse — same criterion as the Linux guard. A hung
# daemon (no output) counts as unhealthy, which is exactly right.
$status = (& $netbird status 2>$null) -join "`n"
$healthy = ($status -match 'Management: Connected') -and ($status -match 'Signal: Connected')

if ($healthy) {
    Remove-Item $failFile -ErrorAction SilentlyContinue
    exit 0
}

$fails = 0
if (Test-Path $failFile) { $fails = [int](Get-Content $failFile -ErrorAction SilentlyContinue) }
$fails++
Set-Content -Path $failFile -Value $fails
Write-Log "management/signal disconnected (consecutive check $fails/$FailThreshold)"

if ($fails -lt $FailThreshold) { exit 0 }

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$lastRestart = 0
if (Test-Path $lastRestartFile) { $lastRestart = [long](Get-Content $lastRestartFile -ErrorAction SilentlyContinue) }
if (($now - $lastRestart) -lt $CooldownSecs) {
    Write-Log "still in cooldown ($($now - $lastRestart)s since last restart) - skipping"
    exit 0
}

Write-Log 'restarting NetBird engine (netbird down && netbird up)'
Set-Content -Path $lastRestartFile -Value $now
Remove-Item $failFile -ErrorAction SilentlyContinue

& $netbird down 2>$null
Start-Sleep -Seconds 2
& $netbird up 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Log 'engine restart failed - falling back to service restart'
    try { Restart-Service -Name 'netbird' -Force } catch { Write-Log "ERROR - service restart failed too: $_" }
}

Write-Log 'engine restart complete'
'@

$guard = $guard.Replace('__FAIL_THRESHOLD__', "$FailThreshold").Replace('__COOLDOWN_SECS__', "$CooldownSecs")
Set-Content -Path $guardPath -Value $guard -Encoding UTF8

# --- Scheduled Task: SYSTEM, every N minutes, single instance --------------
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$guardPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName 'NetBird Self-Heal Guard' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "OK: 'NetBird Self-Heal Guard' scheduled task installed (every $IntervalMinutes min,"
Write-Host "    restart after $FailThreshold failed checks, ${CooldownSecs}s cooldown)."
Write-Host "    Log: $stateDir\selfheal.log"
