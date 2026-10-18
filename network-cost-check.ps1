# network-cost-check.ps1 - is the current internet link metered / unusable for uploads?
#
# prints ONE JSON object and exits 0 when the check completed:
#   connected, interface, costType, roaming, overDataLimit, approachingDataLimit,
#   skip (true = do NOT run backup/upload on this link), reasons[]
# exit 1 = the check itself failed (loud - consumers must treat it as a real error,
# NOT as a skip).
#
# WHY powershell.exe AND NOT pwsh: this uses the WinRT Windows.Networking.Connectivity
# NetworkInformation API - the exact source the Windows UI "metered connection" toggle
# writes to. pwsh 7 cannot load WinRT projections (verified 2026-10-18: "Unable to
# find type [Windows.Networking.Connectivity.NetworkInformation,...]"), so the daily
# backup task invokes this file via Windows PowerShell 5.1. The guard below fails loud
# if someone runs it under pwsh instead of silently degrading.
#
# -Simulate <unrestricted|metered|offline> feeds synthetic values through the SAME
# classifier for testing (JSON carries "simulated": true). It never touches WinRT.

param(
    [ValidateSet('unrestricted', 'metered', 'offline')]
    [string]$Simulate
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -eq 'Core') {
    throw 'network-cost-check.ps1 must run under Windows PowerShell 5.1 (powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...) - the WinRT NetworkInformation API it depends on is not available in pwsh. The daily backup task invokes it correctly.'
}

$connected = $true
$profileName = $null
$costType = $null
$roaming = $false
$overDataLimit = $false
$approachingDataLimit = $false
$simulated = $false

if ($Simulate) {
    $simulated = $true
    switch ($Simulate) {
        'unrestricted' { $profileName = 'simulated'; $costType = 'Unrestricted' }
        'metered'      { $profileName = 'simulated'; $costType = 'Fixed' }
        'offline'      { $connected = $false }
    }
} else {
    [void][Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
    $pr = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if ($null -eq $pr) {
        $connected = $false
    } else {
        $profileName = $pr.ProfileName
        $cost = $pr.GetConnectionCost()
        $costType = $cost.NetworkCostType.ToString()
        $roaming = [bool]$cost.Roaming
        $overDataLimit = [bool]$cost.OverDataLimit
        $approachingDataLimit = [bool]$cost.ApproachingDataLimit
    }
}

$reasons = @()
if (-not $connected) { $reasons += 'no internet connection' }
if ($costType -eq 'Fixed' -or $costType -eq 'Variable') { $reasons += "metered connection (cost type: $costType)" }
if ($roaming) { $reasons += 'roaming' }
if ($overDataLimit) { $reasons += 'over data limit' }
if ($approachingDataLimit) { $reasons += 'approaching data limit' }

# utf8 (no bom) so a non-ascii ssid survives the stdout round-trip into pwsh
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

[ordered]@{
    checkedAt            = (Get-Date -Format s)
    simulated            = $simulated
    connected            = $connected
    interface            = $profileName
    costType             = $costType
    roaming              = $roaming
    overDataLimit        = $overDataLimit
    approachingDataLimit = $approachingDataLimit
    skip                 = ($reasons.Count -gt 0)
    reasons              = @($reasons)
} | ConvertTo-Json -Depth 4
