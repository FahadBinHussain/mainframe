<#
.SYNOPSIS
    rotate the ntfy approval topic on this machine.

.DESCRIPTION
    generates a new 32-char [a-z0-9] topic from a cryptographic rng and
    writes it as ntfyTopic in the profile config
    (~/.config/mainframe/mainframe.config.json on linux,
    %APPDATA%\mainframe\mainframe.config.json on windows). if the
    checkout-root mainframe.config.json carries an ntfyTopic it gets the
    same value; if it exists without one, a warning is printed.

    the topic is ONE value shared by every machine + the phone, so a
    rotation only works if all of them land on the SAME value: run this
    script plain (or with -ShowTopic) on the FIRST machine only, then
    apply that same value everywhere else with -Topic. a plain run on a
    second machine generates a DIFFERENT topic and splits the fleet.

    the new topic is NEVER printed by default - it would land in logs
    and transcripts, which is how the old one leaked (the runner printed
    it on every approval until 2026-11-15). -ShowTopic prints this run's
    value (your terminal only); -ShowCurrent prints the topic already in
    the config without changing anything - the recovery path if you
    rotated without showing it. never re-run plain to "see" the value:
    that rotates AGAIN.

    writes are atomic (temp file + move) and the config keeps mode 0600
    on non-windows. a missing or unparseable profile config refuses
    loudly and writes nothing.

    see docs/ntfy-topic-rotation.md for the full rollout order
    (machines first, phone LAST, then verify).
#>
param(
    [switch]$ShowTopic,
    [switch]$ShowCurrent,
    [string]$Topic
)

$ErrorActionPreference = 'Stop'

function New-NtfyTopic {
    # 32 chars of [a-z0-9] from a cryptographic rng, rejection-sampled
    # (252 = 7 * 36) so there is no modulo bias.
    $alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789'
    $chars = New-Object char[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $i = 0
        while ($i -lt 32) {
            $buf = New-Object byte[] 32
            $rng.GetBytes($buf)
            foreach ($b in $buf) {
                if ($i -ge 32) { break }
                if ($b -lt 252) {
                    $chars[$i] = $alphabet[$b % 36]
                    $i++
                }
            }
        }
    } finally {
        $rng.Dispose()
    }
    return -join $chars
}

function Test-NtfyTopicFormat {
    param([string]$Value)
    # -cmatch, not -match: -match is case-insensitive, so it would accept
    # uppercase (and a topic with uppercase is a different topic than its
    # lowercase form on the relay - it must not pass validation).
    return ($Value -cmatch '^[a-z0-9]{32}$')
}

function Write-JsonAtomically {
    # write one config file: temp file in the same dir + move, so a
    # failure never leaves a half-written config behind. temp file is
    # removed on failure. no BOM (a BOM breaks some json readers).
    param([string]$Path, [object]$JsonObject)
    $content = ($JsonObject | ConvertTo-Json -Depth 10) + "`n"
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ('.' + (Split-Path -Leaf $Path) + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($tmp, $content, [System.Text.UTF8Encoding]::new($false))
        if ($env:OS -ne 'Windows_NT') {
            # the config holds the topic: keep it owner-only like the original.
            & chmod 600 $tmp
            if ($LASTEXITCODE -ne 0) { throw "chmod 600 failed on $tmp - refusing to install a config with loose permissions." }
        }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

# --- argument validation ----------------------------------------------------
if ($ShowTopic -and $ShowCurrent) {
    throw 'pick one: -ShowTopic rotates AND shows the new value, -ShowCurrent only shows the value already in the config. never both.'
}
if ($ShowCurrent -and $Topic) {
    throw '-ShowCurrent changes nothing, so -Topic has nothing to apply to. drop -Topic, or drop -ShowCurrent to rotate.'
}
if ($Topic -and -not (Test-NtfyTopicFormat -Value $Topic)) {
    throw '-Topic must be exactly 32 chars of [a-z0-9] - got something else, refusing to write it.'
}

# --- config paths -----------------------------------------------------------
# profile root via the repo's own helper when importable, else os-detect.
# MAINFRAME_PROFILE_ROOT wins in both branches - it is the repo's own
# override, and it is also how this script is tested against a temp config.
$profileRoot = $null
$pathsModule = Join-Path $PSScriptRoot 'mainframe-paths.psm1'
if (Test-Path -LiteralPath $pathsModule) {
    try {
        Import-Module $pathsModule -DisableNameChecking -ErrorAction Stop
        $profileRoot = Get-MainframeProfileRoot
    } catch {
        $profileRoot = $null
    }
}
if (-not $profileRoot) {
    if ($env:MAINFRAME_PROFILE_ROOT) {
        $profileRoot = $env:MAINFRAME_PROFILE_ROOT
    } elseif ($env:OS -eq 'Windows_NT') {
        $profileRoot = Join-Path $env:APPDATA 'mainframe'
    } else {
        $xdg = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
        $profileRoot = Join-Path $xdg 'mainframe'
    }
}
$profileConfig = Join-Path $profileRoot 'mainframe.config.json'
# checkout root is the parent of this script's folder.
$checkoutConfig = Join-Path (Split-Path -Parent $PSScriptRoot) 'mainframe.config.json'

# --- read the profile config (both modes need it) ---------------------------
if (-not (Test-Path -LiteralPath $profileConfig)) {
    throw "profile config not found: $profileConfig - refusing to rotate a machine that has no config. set the machine up first."
}
try {
    $profileJson = Get-Content -LiteralPath $profileConfig -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "profile config is not parseable json: $profileConfig - refusing to write anything. fix the file by hand first. ($($_.Exception.Message))"
}
$currentTopic = $profileJson.ntfyTopic

if ($ShowCurrent) {
    # read-only mode: show what is there, change nothing.
    if (-not $currentTopic) {
        throw "profile config has no ntfyTopic: $profileConfig - nothing to show."
    }
    Write-Host 'WARNING: the topic below will land in logs/transcripts if this output is captured. copy it, then clear scrollback if you care.'
    Write-Host "current ntfy topic: $currentTopic"
    Write-Host 'nothing changed - this was a read-only show.'
    exit 0
}

if (-not $currentTopic) {
    throw "profile config has no ntfyTopic: $profileConfig - refusing to invent one here. set the topic first, then rotate."
}

# --- determine the new topic ------------------------------------------------
if ($Topic) {
    $newTopic = $Topic
    if ($newTopic -eq $currentTopic) {
        throw '-Topic is the same value this machine already has - that is not a rotation. generate a fresh one (plain run) or pass a different value.'
    }
} else {
    do {
        $newTopic = New-NtfyTopic
    } while ($newTopic -eq $currentTopic)
}

# --- read the checkout config, if it exists ---------------------------------
# read BEFORE writing anything: an unparseable checkout config refuses
# loudly here, while nothing has been touched yet.
$checkoutJson = $null
$checkoutHasTopic = $false
if (Test-Path -LiteralPath $checkoutConfig) {
    try {
        $checkoutJson = Get-Content -LiteralPath $checkoutConfig -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "checkout config is not parseable json: $checkoutConfig - refusing to rotate with a half-readable fleet config. fix the file by hand first. ($($_.Exception.Message))"
    }
    $checkoutHasTopic = [bool]$checkoutJson.ntfyTopic
}

# --- write: profile first, then checkout ------------------------------------
$profileJson.ntfyTopic = $newTopic
Write-JsonAtomically -Path $profileConfig -JsonObject $profileJson
Write-Host "rotated: ntfyTopic in $profileConfig"
if ($checkoutJson) {
    if ($checkoutHasTopic) {
        $checkoutJson.ntfyTopic = $newTopic
        try {
            Write-JsonAtomically -Path $checkoutConfig -JsonObject $checkoutJson
            Write-Host "rotated: ntfyTopic in $checkoutConfig (checkout config carried a topic too)"
        } catch {
            throw "profile config was updated but the checkout config write failed: $checkoutConfig - the machine is half-rotated (checkout still has the OLD topic, and the checkout wins on reads). fix the file and re-run this script with -Topic to finish. ($($_.Exception.Message))"
        }
    } else {
        Write-Host "WARNING: checkout config exists but carries no ntfyTopic, left alone: $checkoutConfig"
    }
}

# --- next steps (the topic itself is never printed here by default) ---------
Write-Host ''
if ($ShowTopic) {
    Write-Host 'WARNING: the new topic is printed below because you asked with -ShowTopic. it will land in logs/transcripts if this output is captured - copy it, then clear scrollback if you care.'
    Write-Host "new ntfy topic: $newTopic"
    Write-Host ''
    Write-Host 'next steps (same value everywhere - the phone moves LAST):'
    Write-Host '  1. on every OTHER machine (A, B, laptop, desktop), apply this SAME topic:'
    Write-Host "     pwsh windows/rotate-ntfy-topic.ps1 -Topic $newTopic"
    Write-Host '     never run it plain on a second machine - each plain run generates a DIFFERENT topic.'
    Write-Host '  2. phone LAST: ntfy app -> subscription -> change the topic to the new value.'
    Write-Host '     (the topic must be typed into the phone by hand - there is no automation for that step.)'
    Write-Host '  3. verify: trigger one approval and confirm the phone shows it.'
} else {
    Write-Host 'the new topic is NOT printed here (it would land in logs/transcripts).'
    Write-Host 'next steps (same value everywhere - the phone moves LAST):'
    Write-Host '  1. on THIS machine, show the new topic (your terminal only):'
    Write-Host '     pwsh windows/rotate-ntfy-topic.ps1 -ShowCurrent'
    Write-Host '     (warning: the value will land in logs/transcripts - copy it, then clear scrollback if you care.)'
    Write-Host '     never re-run this script plain to "see" the value - that rotates AGAIN.'
    Write-Host '  2. on every OTHER machine (A, B, laptop, desktop), apply the SAME topic:'
    Write-Host '     pwsh windows/rotate-ntfy-topic.ps1 -Topic <new-topic>'
    Write-Host '     never run it plain on a second machine - each plain run generates a DIFFERENT topic.'
    Write-Host '  3. phone LAST: ntfy app -> subscription -> change the topic to the new value.'
    Write-Host '     (the topic must be typed into the phone by hand - there is no automation for that step.)'
    Write-Host '  4. verify: trigger one approval and confirm the phone shows it.'
}
Write-Host 'honest limit: the OLD topic stays usable - there is no relay-side deny list. rotation limits future exposure, it does not revoke the old topic.'
