# No Pester dependency. This file has to pass under windows powershell 5.1 AND
# pwsh 7 - the whole point is that the approval flow works in both.
#
# No network at all - not even a local listener: the Muse VM's egress proxy
# intercepts even localhost TCP, so a listener-based test cannot run there.
# Instead Invoke-RestMethod is mocked inside the module's own scope (the
# same technique tests/vault-approval-lock.Tests.ps1 uses), which captures
# the exact headers the push hands over - a header that is built and then
# sent anyway is still caught, because the mock sees what leaves.
#
# What it pins: topic-only auth - the topic name in mainframe.config.json
# is the only credential, no header or token is ever sent, and a refused
# push must say so instead of dying quietly.
$ErrorActionPreference = 'Stop'
$module = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../vault-approval.psm1'))

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
}

# 1. the module parses
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'vault-approval.psm1 parses'

$source = Get-Content -LiteralPath $module -Raw

# 2. there is NO credential in the design any more - no resolver, no config
#    key, no environment variable. a regression here is how a new machine
#    ends up blocked asking for a credential again.
Assert-True ($source -notmatch 'function Get-VaultNtfyToken') 'there is no ntfy token resolver'
Assert-True ($source -notmatch 'function Get-VaultNtfyCredential') 'there is no ntfy credential resolver'
Assert-True ($source -notmatch 'MAINFRAME_NTFY_TOKEN') 'there is no ntfy token environment variable'
Assert-True ($source -notmatch 'MAINFRAME_NTFY_AUTH') 'there is no ntfy auth environment variable'
Assert-True ($source -notmatch "'ntfyToken'") 'the config carries no ntfy token key'
Assert-True ($source -notmatch "'ntfyAuth'") 'the config carries no ntfy auth key'

Import-Module $module -Force -DisableNameChecking

# 3. mock Invoke-RestMethod inside the module's own scope. the mock records
#    the uri + headers of every call in a capture file, and throws a
#    403-shaped exception when MF_REFUSE=1. env vars carry the control in
#    because the mock runs in the module's session state, not this script's.
$captureFile = [IO.Path]::GetTempFileName()
Set-Content -LiteralPath $captureFile -Value '' -Encoding UTF8
$env:MF_CAPTURE = $captureFile
$env:MF_REFUSE = '0'
try {
    & (Get-Module vault-approval) {
        function script:Invoke-RestMethod {
            [CmdletBinding()]
            param($Uri, $Method, $Headers, $Body, $TimeoutSec)
            $capture = [PSCustomObject]@{ uri = "$Uri"; headers = $Headers } | ConvertTo-Json -Compress
            Add-Content -LiteralPath $env:MF_CAPTURE -Encoding UTF8 -Value $capture
            if ($env:MF_REFUSE -eq '1') {
                $resp = [PSCustomObject]@{ StatusCode = 403 }
                $ex = New-Object System.Exception('403 Forbidden')
                $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $ex
            }
            return $null
        }
    }

    function Read-LastCapture {
        $lines = @(Get-Content -LiteralPath $captureFile -Encoding UTF8 | Where-Object { $_.Trim() })
        if ($lines.Count -eq 0) { throw 'the mock captured nothing' }
        return ($lines[-1] | ConvertFrom-Json)
    }

    # 3a. a push succeeds and carries NO Authorization header - that is the
    #     only mode there is now
    $sent = Send-VaultApprovalNotification -Topic 'sometopic' -Url 'https://example.invalid/#k=x' `
        -HostName 'TESTHOST' -Code '42' -Server 'https://relay.example.test/ntfy'
    Assert-True $sent 'the push succeeds'
    $capture = Read-LastCapture
    Assert-True ($capture.uri -like '*sometopic*') 'the push really went to the topic'
    Assert-Equal $null $capture.headers.'authorization' 'a push carries no authorization header'
    Assert-Equal 'Vault Unlock: Code [42] (TESTHOST)' $capture.headers.'title' 'the title still travels'

    # 3b. a second push, another topic - still no header anywhere
    $sent = Send-VaultApprovalNotification -Topic 'anothertopic' -Url 'https://example.invalid/#k=x' `
        -HostName 'TESTHOST' -Code '42' -Server 'https://relay.example.test/ntfy'
    Assert-True $sent 'the second push succeeds'
    $capture = Read-LastCapture
    Assert-True ($capture.uri -like '*anothertopic*') 'the second push really went to its topic'
    Assert-Equal $null $capture.headers.'authorization' 'the second push carries no authorization header either'

    # 4. a refused push says WHY. the relay answers 403 when the topic or
    #    server is wrong, and drops the message - so without this the only
    #    symptom is a phone that never buzzes. the warning must NOT send
    #    anyone hunting for a credential that does not exist.
    # TextWriter's Stream constructors are all PROTECTED - the public way to
    # capture text is a StringWriter over a StringBuilder.
    $env:MF_REFUSE = '1'
    $sb = New-Object Text.StringBuilder
    $writer = [IO.StringWriter]::new($sb)
    $oldError = [Console]::Error
    [Console]::SetError($writer)
    try {
        $sent = Send-VaultApprovalNotification -Topic 'refusetopic' -Url 'https://example.invalid/#k=x' `
            -HostName 'TESTHOST' -Code '42' -Server 'https://relay.example.test/ntfy'
    } finally {
        $writer.Flush()
        [Console]::SetError($oldError)
    }
    $stderr = $sb.ToString()

    Assert-True (-not $sent) 'a refused push reports failure'
    Assert-True ($stderr -match '403') 'the refusal names the http status'
    Assert-True ($stderr -match 'no credential to set') 'the refusal says there is no credential to set'
    Assert-True ($stderr -match 'ntfyTopic') 'the refusal names the topic setting to check'
    Assert-True ($stderr -notmatch 'ntfyToken') 'the refusal must not name a credential setting'
} finally {
    Remove-Item Env:\MF_CAPTURE -ErrorAction SilentlyContinue
    Remove-Item Env:\MF_REFUSE -ErrorAction SilentlyContinue
}

Write-Host "vault-approval topic checks: $script:checks passed"
