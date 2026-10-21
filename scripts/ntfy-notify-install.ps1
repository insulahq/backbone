# ==========================================================================
# ntfy Desktop Notifier — Windows installer
# ==========================================================================
# Installs a Scheduled Task (runs as the LOGGED-IN USER at logon) that keeps
# `ntfy subscribe` connected to the platform's self-hosted ntfy server and
# raises a native Windows toast for every message.
#
# Why not Web Push: the browser web app only delivers while a tab is open,
# and Brave/Chrome Web Push routes through Google FCM (Brave disables it by
# default). This path holds its own connection straight to your server —
# always on, no browser, no third party.
#
# Runs as the USER, not SYSTEM: a SYSTEM task lives in session 0 and cannot
# raise a toast on the interactive desktop. This is the one structural
# difference from netbird-selfheal-install.ps1, which is SYSTEM by design.
#
# Requirements: Windows 10/11, PowerShell 5.1+. No admin rights needed —
# the task is registered in the current user's context.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\ntfy-notify-install.ps1 `
#       -Server https://ntfy.example.net -Topic platform-alerts -Token tk_...
#
#   powershell -ExecutionPolicy Bypass -File .\ntfy-notify-install.ps1 -Uninstall
#
# Tunables:
#   -Topic        platform-alerts   topic to subscribe to
#   -MinPriority  1                 ignore messages below this priority (1-5)
#   -Version      2.27.0            ntfy release to install
#
# The token is stored DPAPI-encrypted (decryptable only by this user on this
# machine) and passed to ntfy via the environment, never on the command line
# where it would show up in the process list and the task definition.
#
# Use a READ-ONLY token, not the platform publish token. Provision one on the
# server via ntfy_extra_users / ntfy_extra_access / ntfy_extra_tokens.
#
# Project: https://github.com/insulahq/backbone
# ==========================================================================

param(
    [string]$Server,
    [string]$Topic = 'platform-alerts',
    [string]$Token,
    [string]$Version = '2.27.0',
    [ValidateRange(1, 5)][int]$MinPriority = 1,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$taskName = 'ntfy Desktop Notifier'
$stateDir = Join-Path $env:LOCALAPPDATA 'ntfy-notify'
$watcherPath = Join-Path $stateDir 'ntfy-notify.ps1'
$ntfyExe = Join-Path $stateDir 'ntfy.exe'
$tokenFile = Join-Path $stateDir 'token.dpapi'

# --- Uninstall -------------------------------------------------------------
if ($Uninstall) {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "OK: '$taskName' scheduled task removed."
    }
    else {
        Write-Host "Nothing to do: '$taskName' is not installed."
    }
    Get-Process -Name 'ntfy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "    State kept at $stateDir (delete it manually to remove the token and logs)."
    exit 0
}

# --- Validate --------------------------------------------------------------
if (-not $Server) { throw "-Server is required, e.g. -Server https://ntfy.example.net" }
if (-not $Token) { throw "-Token is required (a read-only ntfy access token, tk_...)" }

$Server = $Server.TrimEnd('/')
if ($Server -notmatch '^https://') {
    throw "-Server must be an https:// URL (the token is sent as a bearer header)"
}
# Same format ntfy itself generates. A malformed token is rejected by the
# server and would leave the watcher reconnecting forever with 401s.
if ($Token -notmatch '^tk_[a-z0-9]{29}$') {
    throw "-Token must be 'tk_' + 29 lowercase alphanumerics (32 chars), as produced by 'ntfy token generate'"
}
if ($Topic -notmatch '^[-_A-Za-z0-9]{1,64}$') {
    throw "-Topic '$Topic' is not a valid ntfy topic name"
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

# --- Fetch ntfy.exe (checksum-verified) ------------------------------------
$needDownload = $true
if (Test-Path $ntfyExe) {
    $installed = (& $ntfyExe --version 2>$null) -join ' '
    if ($installed -match [regex]::Escape($Version)) {
        Write-Host "ntfy $Version already present, skipping download."
        $needDownload = $false
    }
}

if ($needDownload) {
    $zipName = "ntfy_${Version}_windows_amd64.zip"
    $base = "https://github.com/binwiederhier/ntfy/releases/download/v$Version"
    $zipPath = Join-Path $env:TEMP $zipName
    $tmpDir = Join-Path $env:TEMP "ntfy-extract-$([guid]::NewGuid().ToString('N'))"

    # TLS 1.2 for Windows PowerShell 5.1, whose default is still SSL3/TLS1.0
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Host "Downloading ntfy $Version ..."
    Invoke-WebRequest -Uri "$base/$zipName" -OutFile $zipPath -UseBasicParsing

    # Verify against the release checksums rather than trusting the transport.
    Write-Host "Verifying checksum ..."
    $sums = (Invoke-WebRequest -Uri "$base/checksums.txt" -UseBasicParsing).Content
    $expected = ($sums -split "`n" | Where-Object { $_ -match [regex]::Escape($zipName) } |
        Select-Object -First 1) -split '\s+' | Select-Object -First 1
    if (-not $expected) { throw "No checksum for $zipName in checksums.txt — refusing to install." }
    $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected.ToLower()) {
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        throw "Checksum mismatch for $zipName (expected $expected, got $actual) — refusing to install."
    }

    # Archive layout is ntfy_<ver>_windows_amd64/ntfy.exe
    Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force
    $found = Get-ChildItem -Path $tmpDir -Filter 'ntfy.exe' -Recurse | Select-Object -First 1
    if (-not $found) { throw "ntfy.exe not found inside $zipName" }
    Copy-Item $found.FullName $ntfyExe -Force

    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Write-Host "Installed ntfy.exe to $ntfyExe"
}

# --- Store the token, DPAPI-encrypted to this user -------------------------
# ConvertFrom-SecureString uses DPAPI: the blob is only decryptable by this
# user account on this machine, so a stolen file is useless elsewhere.
ConvertTo-SecureString -String $Token -AsPlainText -Force |
    ConvertFrom-SecureString |
    Set-Content -Path $tokenFile -Encoding ASCII
Write-Host "Token stored (DPAPI-encrypted) at $tokenFile"

# --- The watcher script ----------------------------------------------------
# Single-quoted here-string: no expansion here; values are injected on the
# placeholder lines below (same pattern as netbird-selfheal-install.ps1).
$watcher = @'
# ntfy Desktop Notifier — keeps a subscription open and toasts each message.
# Installed by ntfy-notify-install.ps1 (https://github.com/insulahq/backbone).

$Server      = '__SERVER__'
$Topic       = '__TOPIC__'
$MinPriority = __MIN_PRIORITY__

$stateDir  = Join-Path $env:LOCALAPPDATA 'ntfy-notify'
$ntfy      = Join-Path $stateDir 'ntfy.exe'
$logFile   = Join-Path $stateDir 'ntfy-notify.log'
$tokenFile = Join-Path $stateDir 'token.dpapi'
$stateFile = Join-Path $stateDir 'last-seen'

function Write-Log([string]$msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $msg"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    # Keep the log from growing unbounded
    $f = Get-Item $logFile -ErrorAction SilentlyContinue
    if ($f -and $f.Length -gt 1MB) { Get-Content $logFile -Tail 200 | Set-Content $logFile }
}

function Show-Toast([string]$title, [string]$body, [int]$priority) {
    $t = [System.Security.SecurityElement]::Escape($title)
    $b = [System.Security.SecurityElement]::Escape($body)
    try {
        # WinRT toast. Borrowing the built-in PowerShell AUMID means we do not
        # have to register a Start Menu shortcut just to be allowed to notify.
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType=WindowsRuntime]
        $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $duration = if ($priority -ge 4) { 'long' } else { 'short' }
        $xml = "<toast duration=`"$duration`"><visual><binding template=`"ToastGeneric`">" +
               "<text>$t</text><text>$b</text></binding></visual></toast>"
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
        return
    }
    catch {
        Write-Log "WinRT toast unavailable ($($_.Exception.Message)) - falling back to balloon"
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $icon.Icon = [System.Drawing.SystemIcons]::Information
        $icon.Visible = $true
        $icon.ShowBalloonTip(10000, $title, $body, [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Seconds 6
        $icon.Dispose()
    }
    catch {
        Write-Log "ERROR - could not raise a notification: $_"
    }
}

# Decrypt the token and hand it to ntfy via the environment, so it never
# appears in the process command line.
try {
    $sec = Get-Content $tokenFile | ConvertTo-SecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $env:NTFY_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
catch {
    Write-Log "FATAL - cannot decrypt $tokenFile (was it copied from another machine or user?): $_"
    exit 1
}

Write-Log "starting: $Server/$Topic (min priority $MinPriority)"
$backoff = 5
$lastId = ''
$lastTime = ''
if (Test-Path $stateFile) {
    $parts = (Get-Content $stateFile -ErrorAction SilentlyContinue) -split '\|'
    if ($parts.Count -ge 2) { $lastTime = $parts[0]; $lastId = $parts[1] }
}

while ($true) {
    # --since replays anything missed while asleep/offline, bounded by the
    # server's cache-duration. Skip the one message we already showed at that
    # exact timestamp so a reconnect does not duplicate it.
    $argv = @('subscribe')
    if ($lastTime) { $argv += @('--since', $lastTime) }
    $argv += "$Server/$Topic"

    try {
        & $ntfy @argv 2>&1 | ForEach-Object {
            $line = "$_"
            if ($line -notmatch '^\s*\{') { if ($line.Trim()) { Write-Log "ntfy: $line" }; return }
            try { $m = $line | ConvertFrom-Json } catch { return }
            if ($m.event -ne 'message') { return }      # open / keepalive / poll_request
            if ($m.id -eq $lastId) { return }           # already shown before the reconnect

            $backoff = 5                                # a real message means we are healthy
            $prio = if ($m.priority) { [int]$m.priority } else { 3 }
            if ($prio -lt $MinPriority) { return }

            $title = if ($m.title) { $m.title } else { "ntfy: $($m.topic)" }
            $body = "$($m.message)"
            if ($m.tags) { $body = "$body`n[$($m.tags -join ', ')]" }

            Show-Toast $title $body $prio
            $lastId = $m.id
            $lastTime = "$($m.time)"
            Set-Content -Path $stateFile -Value "$lastTime|$lastId" -ErrorAction SilentlyContinue
            Write-Log "notified: [$prio] $title"
        }
        Write-Log "subscription ended (exit $LASTEXITCODE) - reconnecting in ${backoff}s"
    }
    catch {
        Write-Log "subscription error: $_ - reconnecting in ${backoff}s"
    }

    Start-Sleep -Seconds $backoff
    # Exponential backoff to 5 min, so a server outage does not spin the CPU
    # or hammer Traefik with reconnects.
    $backoff = [Math]::Min($backoff * 2, 300)
}
'@

$watcher = $watcher.
    Replace('__SERVER__', $Server).
    Replace('__TOPIC__', $Topic).
    Replace('__MIN_PRIORITY__', "$MinPriority")
Set-Content -Path $watcherPath -Value $watcher -Encoding UTF8

# --- Scheduled Task: current user, at logon, runs forever ------------------
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcherPath`""

# Two triggers:
#   1. At logon — the reboot path. Task definitions survive a restart, so the
#      watcher comes back when the user signs in (and replays what it missed
#      via --since). Nothing runs before logon, which is correct: a toast has
#      no desktop to appear on at the lock screen.
#   2. A repeating trigger, first fire 30s after install (so installing needs
#      no reboot) then every 15 minutes forever. This is the self-heal: with
#      MultipleInstances=IgnoreNew below it is a no-op while the watcher is
#      alive, and restarts it if the process ever dies. Without it, a watcher
#      that exhausts RestartCount stays dead until the NEXT logon — which on a
#      machine that stays signed in for weeks means silently no alerts.
#      Same pattern as netbird-selfheal-install.ps1.
$triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30) `
        -RepetitionInterval (New-TimeSpan -Minutes 15) `
        -RepetitionDuration (New-TimeSpan -Days 3650))
)

# Interactive: the task must run in the user's session or the toast has no
# desktop to appear on. RunLevel Limited — no elevation required or wanted.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited

# ExecutionTimeLimit MUST be zero: this is a long-lived watcher, and the
# default 3-day limit would have the scheduler kill it silently.
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -Hidden

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings -Force | Out-Null

Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "OK: '$taskName' installed and started."
Write-Host "    Server      : $Server/$Topic"
Write-Host "    Runs as     : $env:USERDOMAIN\$env:USERNAME (interactive session, at logon)"
Write-Host "    Min priority: $MinPriority"
Write-Host "    Log         : $stateDir\ntfy-notify.log"
Write-Host ""
Write-Host "Test it from the server (or anywhere with a publish token):"
Write-Host "    curl -H `"Authorization: Bearer <publish-token>`" -d 'hello from ntfy' $Server/$Topic"
Write-Host ""
Write-Host "Remove with:  powershell -ExecutionPolicy Bypass -File .\ntfy-notify-install.ps1 -Uninstall"
