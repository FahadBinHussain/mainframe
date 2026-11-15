<#
    new-bootstrap-link.ps1 - mint a one-link bootstrap for a new machine

    reads the local mainframe.config.json and posts it to the relay, which
    stores it under an unguessable single-use token for 1 h. prints ONE
    link and nothing else - never the config, never the topic.

    the link goes to the new machine, where bootstrap.sh / bootstrap.ps1
    downloads the bundle once, places the config, clones mainframe and
    runs the restore. no file copying between machines, ever.

    no vault session is needed: the config is a local file. the bundle is
    mainframe.config.json ONLY (topic + server + pagesBase + email) - no
    signing key, it self-heals from the vault after the first unlock.

    usage:
        pwsh windows/new-bootstrap-link.ps1 [-DryRun]

    -DryRun validates the config and prints the relay base + topic
    fingerprint without creating a link.
#>
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'

function Get-BootstrapRelayBase {
    param([string]$NtfyServer)
    if ([string]::IsNullOrWhiteSpace($NtfyServer)) {
        throw 'no ntfyServer in the local config - the bootstrap endpoint lives on the worker relay, not on ntfy.sh. set ntfyServer to the worker relay url (ending in /ntfy) and re-run.'
    }
    $server = $NtfyServer.TrimEnd('/')
    if (-not $server.EndsWith('/ntfy')) {
        throw "ntfyServer '$server' does not end in /ntfy - the bootstrap endpoint lives next to the relay's /ntfy mount. refusing to post the config anywhere else (posting it to plain ntfy.sh would publish it to a public topic)."
    }
    $base = $server.Substring(0, $server.Length - 5)
    if (-not $base.StartsWith('https://')) {
        throw "relay base '$base' is not https - refusing to send the config over plain http."
    }
    return $base
}

$pathsModule = Join-Path $PSScriptRoot 'mainframe-paths.psm1'
if (-not (Test-Path -LiteralPath $pathsModule -PathType Leaf)) {
    throw "mainframe-paths.psm1 not found next to this script ($pathsModule) - run it from the mainframe repo."
}
Import-Module $pathsModule -DisableNameChecking -ErrorAction Stop

$profileRoot = Get-MainframeProfileRoot
$configPath = Join-Path $profileRoot 'mainframe.config.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "no local config at $configPath - nothing to bootstrap from. this machine has no mainframe config yet."
}
$rawConfig = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
try {
    $config = $rawConfig | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "the local config at $configPath is not valid JSON: $($_.Exception.Message)"
}
if (-not $config.ntfyTopic -or ($config.ntfyTopic -notmatch '^[a-z0-9]{32}$')) {
    throw 'the local config has no valid ntfyTopic (32 lowercase letters/digits) - refusing to bootstrap from a broken config.'
}
$relayBase = Get-BootstrapRelayBase -NtfyServer $config.ntfyServer
$fingerprint = $config.ntfyTopic.Substring(0, 4)

if ($DryRun) {
    Write-Host "config valid (topic fingerprint $fingerprint). would POST it to $relayBase/bootstrap - no link created."
    return
}

try {
    $response = Invoke-RestMethod -Uri "$relayBase/bootstrap" -Method Post -Body $rawConfig -ContentType 'application/json' -TimeoutSec 15 -ErrorAction Stop
} catch {
    $detail = $_.Exception.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        try {
            $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).error
        } catch {
            $detail = $_.ErrorDetails.Message
        }
    }
    throw "the relay refused the bootstrap bundle: $detail"
}
$url = $response.url
if (-not $url -or ($url -notmatch '^https://[^/]+/bootstrap/[A-Za-z0-9_-]{22}$')) {
    throw 'the relay answered without a valid bootstrap link - no link created. re-run, and if it persists the relay is misbehaving.'
}
Write-Host 'bootstrap link (single-use, expires in 1h - send it to the new machine, then run the bootstrap there):'
Write-Host $url
