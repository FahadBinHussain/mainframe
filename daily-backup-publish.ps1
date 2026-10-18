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
# autoclean: remove the artifacts the daily chain leaves behind. the zips are
# rebuildable intermediates (the release store holds the durable copy - a failed
# run's zips are rebuilt by the next run) and the temp trees are leftovers from
# crashed runs. called from a finally so every exit path sweeps. never throws.
function Remove-BackupArtifacts {
    $report = [pscustomobject]@{ Removed = 0; FreedBytes = 0L; Failed = @() }
    # tool-secrets.zip is the PLAINTEXT secrets archive (ssh keys, account profiles) -
    # publish encrypts it into mainframe-secrets.zip (which rides inside quick), the
    # next run rebuilds it from live state, so it must never linger after the run ends.
    $zipNames = 'mainframe-quick.zip', 'mainframe-persist.zip', 'mainframe-secrets.zip',
                'tool-secrets.zip', 'mainframe-core.zip', 'mainframe-backup.zip'
    foreach ($n in $zipNames) {
        $f = Join-Path $PSScriptRoot $n
        $item = Get-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        try {
            Remove-Item -LiteralPath $f -Force -ErrorAction Stop
            $report.Removed++; $report.FreedBytes += $item.Length
        } catch { $report.Failed += "$n ($($_.Exception.Message))" }
    }
    # temp leftovers: staging trees, strip-ditto dbs, stray blob, robocopy logs.
    # age guard - a live manual run may own anything younger than 2h.
    $cutoff = (Get-Date).AddHours(-2)
    $patterns = 'mainframe-backup-*', 'mainframe-zip-stage-*', 'mainframe-tool-secrets-*',
                'ditto-favorites-*.db', 'mainframe-secrets.zip', 'robocopy-log-*.txt'
    foreach ($pat in $patterns) {
        foreach ($item in @(Get-ChildItem -LiteralPath $env:TEMP -Filter $pat -Force -ErrorAction SilentlyContinue)) {
            if ($item.LastWriteTime -gt $cutoff) { continue }
            $size = if ($item.PSIsContainer) { (Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } else { $item.Length }
            if (-not $size) { $size = 0L }
            try {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                $report.Removed++; $report.FreedBytes += $size
            } catch { $report.Failed += "$($item.Name) ($($_.Exception.Message))" }
        }
    }
    $report
}
try {
    Log 'daily backup+publish starting'
    # metered-connection gate: if the link we would upload over is metered (or there is
    # no internet at all), skip BEFORE any backup work - no point burning metered data
    # on a backup that could never be uploaded. the check itself runs via Windows
    # PowerShell 5.1 because the WinRT NetworkInformation API is unavailable in pwsh 7
    # (see network-cost-check.ps1). a failed check is a loud fatal error, never a skip.
    $netRaw = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'network-cost-check.ps1') 2>&1
    if ($LASTEXITCODE -ne 0) { throw "network-cost-check failed (exit $LASTEXITCODE): $($netRaw -join ' ')" }
    try { $net = ($netRaw -join "`n") | ConvertFrom-Json } catch { throw "network-cost-check returned unparseable output: $($netRaw -join ' ')" }
    if ($net.skip) {
        $short = if (-not $net.connected) { 'no internet' } else { 'metered connection' }
        Log "skip: $($net.reasons -join '; ') - backup not run"
        Notify 'skip' "$short - backup skipped"
        exit 0
    }
    Log "upload link ok: $($net.interface) ($($net.costType))"
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
} finally {
    # autoclean artifacts (see Remove-BackupArtifacts) - logs only, never throws,
    # so it can never mask the real exit code or the FATAL above.
    try {
        $c = Remove-BackupArtifacts
        Log "cleanup: removed $($c.Removed) artifact(s), freed $([math]::Round($c.FreedBytes / 1MB, 1)) MB"
        foreach ($f in @($c.Failed)) { Log "cleanup WARNING: could not remove $f" }
    } catch { Log "cleanup WARNING: $($_.Exception.Message)" }
}
