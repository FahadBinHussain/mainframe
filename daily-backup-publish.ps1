# daily-backup-publish.ps1 - daily machine-state backup + release publish
# meant to run from an S4U scheduled task (no UAC). skips loudly if a recent
# backup already ran today (idempotent for task retriggers).
$log = 'C:\tmp\daily-backup.log'
function Log($m) { "$(Get-Date -Format s) $m" | Add-Content -LiteralPath $log }
# S4U job has no desktop; hand visibility to the interactive MainframeBackupNotify task
$notifyTask = 'MainframeBackupNotify'
$notifyFile = 'C:\tmp\backup-notify.txt'
function Notify($state, $msg) {
    try {
        $line = if ($msg) { "$state|$msg" } else { $state }
        Set-Content -LiteralPath $notifyFile -Value $line -Encoding UTF8 -NoNewline
        Start-ScheduledTask -TaskName $notifyTask -ErrorAction Stop
    } catch { Log "notify($state) failed: $($_.Exception.Message)" }
}
try {
    Log 'daily backup+publish starting'
    Set-Location (Join-Path $env:USERPROFILE 'Downloads\mainframe')
    $marker = 'C:\tmp\daily-backup-lastdate.txt'
    $today = Get-Date -Format 'yyyy-MM-dd'
    if (Test-Path $marker) {
        if ((Get-Content $marker -Raw).Trim() -eq $today) { Log 'already published today - skip'; Notify 'skip'; exit 0 }
    }
    Notify 'start' 'zipping + publishing machine state'
    # vault must be unlocked so publish can read the GitHub token; the vault itself is
    # NOT backed up (bw-data + session.key excluded in backup.ps1 / tool-secrets manifest).
    if (-not (Test-Path "$env:APPDATA\mainframe\accounts\bitwarden\session.key")) { throw 'vault locked (no session.key) - unlock needed for publish' }
    & .\backup.ps1 -ExcludeSecrets -Publish 2>&1 | ForEach-Object { Log "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "backup.ps1 -Publish failed (exit $LASTEXITCODE)" }
    Set-Content -LiteralPath $marker -Value $today -Encoding UTF8
    Log 'daily backup+publish DONE'
    Notify 'done' 'release published to mainframe-production'
} catch {
    Log "FATAL: $($_.Exception.Message)"
    Notify 'fail' $_.Exception.Message
    exit 1
}
