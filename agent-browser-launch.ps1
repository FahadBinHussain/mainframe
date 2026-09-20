param([string]$Email = "", [string]$Url = "https://example.com", [string]$Log = "", [int]$TimeoutSec = 120)
# the ONLY way to launch agent-browser. syncs profile, spawns detached, verifies, returns.
$helper = "C:\Users\Admin\Downloads\mainframe\agent-browser-account.ps1"
$syncer = "C:\Users\Admin\Downloads\mainframe\edge-cdp-profile-sync.ps1"
if ([string]::IsNullOrWhiteSpace($Email)) { Write-Output "FAIL: -Email required"; exit 1 }
if ($Url -eq "about:blank") { Write-Output "FAIL: about:blank triggers the relaunched-browser bug, pass a real -Url"; exit 1 }
$user = ($Email -split '@')[0]
if ([string]::IsNullOrWhiteSpace($Log)) { $Log = "C:\tmp\ab-$user.log" }

function EdgePidsFor($mail) {
  @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$mail*" } |
    Select-Object -ExpandProperty ProcessId)
}

$already = EdgePidsFor $Email
if ($already.Count -gt 0) { Write-Output "READY-ALREADY-RUNNING email=$Email pids=$($already -join ',')"; exit 0 }

& $helper use $Email | Out-Null
$profileDir = Join-Path $env:APPDATA "mainframe\accounts\agent-browser\$Email"
$stale = $true
if (Test-Path -LiteralPath $profileDir) {
  $age = (Get-Date) - (Get-Item -LiteralPath $profileDir).LastWriteTime
  if ($age.TotalHours -lt 1) { $stale = $false }
}
if ($stale) { & $syncer -Email $Email | Select-Object -Last 2 | Out-Null } else { Write-Output "sync skipped (fresh within the hour)" }
if (Test-Path -LiteralPath $Log) { Remove-Item -LiteralPath $Log -Force }

$launcher = "C:\tmp\ab-launch-$user.ps1"
"& `"$helper`" run $Email -Url $Url > `"$Log`" 2>&1" | Set-Content -LiteralPath $launcher -Encoding utf8
Start-Process pwsh -ArgumentList "-NoProfile", "-File", $launcher | Out-Null

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
  $found = EdgePidsFor $Email
  if ((Test-Path -LiteralPath $Log) -and $found.Count -gt 0) {
    Write-Output "READY email=$Email url=$Url log=$Log pids=$($found -join ',')"
    exit 0
  }
}
Write-Output "FAIL: no browser with profile $Email after ${TimeoutSec}s"
if (Test-Path -LiteralPath $Log) { Get-Content -LiteralPath $Log | Select-Object -Last 10 }
exit 1
