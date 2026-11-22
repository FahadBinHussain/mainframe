#Requires -Version 7
# Child-process harness for the bootstrap/rotate script tests. Mocks
# Invoke-RestMethod in this scope, then dot-sources the god script
# (windows/mainframe.ps1) and invokes the action function named by
# -Action (Invoke-NewBootstrapLink / Invoke-RotateNtfyTopic) with the
# args carried in $env:MF_HARNESS_ARGS (a JSON OBJECT, splatted as
# a hashtable - an array of strings cannot carry switches, because a
# splatted '-DryRun' binds as a positional string value, not a switch).
#
# The god script is dot-sourced, so the action functions' $PSScriptRoot
# is still windows/ and the mock stays visible through normal scope
# inheritance.
#
# CONTRACT: targets under this harness must fail with `throw`, never
# `exit 1` - measured 2026-11-15, an exit inside a script invoked with
# & from another script behaves like a return (the outer script keeps
# running and the process exits 0). a throw fails the run everywhere:
# the harness reports it as HARNESS-THREW and exits 1, and a direct run
# exits 1 too. (exit 0 is harmless here - it degrades to a return and
# the harness exits 0 anyway.)
#
# No network at all - not even a local listener: the Muse VM's egress
# proxy intercepts even localhost TCP, so a listener-based test cannot
# run there. The mock records every call (method + uri + body) as one
# JSON object per line in $env:MF_REST_CAPTURE, appends "REST <METHOD>
# <uri>" to the shared $env:MF_CALL_LOG, and answers per $env:MF_REST_MODE:
#
#   ok               PUT returns @{url = <uri>} (the relay echo), DELETE 204
#   put-fail         every PUT throws (mock relay refusal)
#   delete-fail      every DELETE throws
#   delete-fail-once the first DELETE throws, later ones succeed (the
#                    counter lives in $env:MF_REST_STATE/delete-count.txt)
param([string]$Target, [string]$Action)

$ErrorActionPreference = 'Stop'

function script:Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $Method, $Body, $ContentType, $TimeoutSec, $Headers)
    $mode = $env:MF_REST_MODE
    if (-not $mode) { $mode = 'ok' }
    if ($env:MF_CALL_LOG) {
        Add-Content -LiteralPath $env:MF_CALL_LOG -Value "REST $Method $Uri" -Encoding UTF8
    }
    if ($env:MF_REST_CAPTURE) {
        $record = [pscustomobject]@{ method = "$Method"; uri = "$Uri"; body = "$Body" } | ConvertTo-Json -Compress
        Add-Content -LiteralPath $env:MF_REST_CAPTURE -Value $record -Encoding UTF8
    }
    if ($Method -eq 'Put' -and $mode -eq 'put-fail') {
        throw [System.Exception]::new('HTTP 500 Internal Server Error (mock relay refusal)')
    }
    if ($Method -eq 'Delete' -and ($mode -eq 'delete-fail' -or $mode -eq 'delete-fail-once')) {
        if ($mode -eq 'delete-fail') {
            throw [System.Exception]::new('HTTP 500 Internal Server Error (mock relay refusal)')
        }
        $counterFile = Join-Path $env:MF_REST_STATE 'delete-count.txt'
        $count = 0
        if (Test-Path -LiteralPath $counterFile) {
            [int]::TryParse((Get-Content -LiteralPath $counterFile -Raw).Trim(), [ref]$count) | Out-Null
        }
        $count++
        Set-Content -LiteralPath $counterFile -Value "$count" -NoNewline
        if ($count -eq 1) {
            throw [System.Exception]::new('HTTP 500 Internal Server Error (mock relay refusal)')
        }
    }
    if ($Method -eq 'Put') {
        return [pscustomobject]@{ url = "$Uri" }
    }
    return $null
}

$targetArgs = @{}
if ($env:MF_HARNESS_ARGS -and $env:MF_HARNESS_ARGS.Trim() -ne '' -and $env:MF_HARNESS_ARGS.Trim() -ne '{}') {
    $parsed = $env:MF_HARNESS_ARGS | ConvertFrom-Json
    foreach ($prop in $parsed.PSObject.Properties) { $targetArgs[$prop.Name] = $prop.Value }
}
try {
    # capture the action name BEFORE dot-sourcing: mainframe.ps1 has a
    # top-level param block ($Group, $Action, $Rest) and dot-sourcing it
    # binds those params in THIS scope, clobbering $Action with $null.
    $harnessAction = $Action
    . $Target
    if (-not (Get-Command $harnessAction -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "harness: action '$harnessAction' not found after dot-sourcing $Target"
    }
    & $harnessAction @targetArgs
} catch {
    Write-Host "HARNESS-THREW: $($_.Exception.Message)"
    exit 1
}
exit 0
