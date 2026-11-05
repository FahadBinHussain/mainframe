# No Pester dependency. This file has to pass under windows powershell 5.1 AND
# pwsh 7 - the whole point is that the approval flow works in both.
#
# It talks to a LOCAL listener only - no ntfy.sh, no network, no phone, no
# vault. What it pins: a PROTECTED topic needs the credential, and a refused
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

# 2. the credential has a documented resolver, and it is exported
Assert-True ($source -match 'function Get-VaultNtfyToken') 'there is a resolver for the ntfy credential'
Assert-True ($source -match 'Get-VaultNtfyToken, `') 'the resolver is exported'
Assert-True ($source -match 'MAINFRAME_NTFY_TOKEN') 'the environment variable overrides the config'
Assert-True ($source -match "Get-VaultConfigValue -Key 'ntfyToken'") 'the config carries the credential'

Import-Module $module -Force -DisableNameChecking

# 3. an explicit credential wins over the environment
$savedToken = $env:MAINFRAME_NTFY_TOKEN
try {
    $env:MAINFRAME_NTFY_TOKEN = 'tk_from_env'
    Assert-Equal 'tk_from_env' (Get-VaultNtfyToken) 'the environment variable is used'
    Assert-Equal 'tk_explicit' (Get-VaultNtfyToken -Token 'tk_explicit') 'an explicit credential wins'
} finally {
    if ($null -eq $savedToken) { Remove-Item Env:\MAINFRAME_NTFY_TOKEN -ErrorAction SilentlyContinue }
    else { $env:MAINFRAME_NTFY_TOKEN = $savedToken }
}

# 4. a local listener that records what the push actually sent
#
# a real round trip, because the point of the change is a header that LEAVES
# the process. a static check of the source would not catch a header that is
# built and then dropped.
#
# a raw TcpListener, not HttpListener: HttpListener hands the socket to
# HTTP.sys, which is a SHARED service - two processes can register the same
# prefix and the requests are split between them, which makes the capture
# file a lottery. a tcp socket belongs to this process alone.
$port = 18700 + (Get-Random -Minimum 0 -Maximum 400)
$prefix = "http://127.0.0.1:$port/"
$readyFile = [IO.Path]::GetTempFileName()
$captureFile = [IO.Path]::GetTempFileName()
Set-Content -LiteralPath $readyFile -Value '' -Encoding UTF8
Set-Content -LiteralPath $captureFile -Value '' -Encoding UTF8

$listener = Start-Job -ScriptBlock {
    param($Port, $ReadyFile, $CaptureFile, $Count)
    $tcp = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    $tcp.Start()
    Set-Content -LiteralPath $ReadyFile -Value 'ready' -Encoding UTF8
    try {
        for ($i = 0; $i -lt $Count; $i++) {
            $client = $tcp.AcceptTcpClient()
            $stream = $client.GetStream()
            $reader = New-Object IO.StreamReader($stream)

            $requestLine = $reader.ReadLine()
            $headers = @{}
            while ($true) {
                $line = $reader.ReadLine()
                if ([string]::IsNullOrEmpty($line)) { break }
                if ($line -match '^([^:]+):\s*(.*)$') { $headers[$matches[1].ToLower().Trim()] = $matches[2] }
            }
            $body = ''
            if ($headers['content-length'] -and [int]$headers['content-length'] -gt 0) {
                $buffer = New-Object char[] ([int]$headers['content-length'])
                $null = $reader.ReadBlock($buffer, 0, $buffer.Length)
                $body = -join $buffer
            }

            # a request for a topic named *refuse* is answered with a
            # rejection, the way ntfy answers a protected topic when the
            # credential is missing.
            $status = 200
            if ($requestLine -like '*refuse*') { $status = 403 }

            # the capture is written BEFORE the answer goes out. the other way
            # round the client can return before the file is written, and the
            # test would read the PREVIOUS request's headers.
            Add-Content -LiteralPath $CaptureFile -Encoding UTF8 -Value (
                ([PSCustomObject]@{ request = $requestLine; headers = $headers; body = $body }) | ConvertTo-Json -Compress)

            $response = "HTTP/1.1 $status OK`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
            $bytes = [Text.Encoding]::ASCII.GetBytes($response)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $client.Close()
        }
    } finally {
        $tcp.Stop()
    }
} -ArgumentList $port, $readyFile, $captureFile, 3

try {
    # wait for the listener to bind before the first push
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ((Get-Item -LiteralPath $readyFile).Length -gt 2) { break }
        Start-Sleep -Milliseconds 200
    }
    Assert-True ((Get-Item -LiteralPath $readyFile).Length -gt 2) 'the local listener came up'

    function Read-LastCapture {
        $lines = @(Get-Content -LiteralPath $captureFile -Encoding UTF8 | Where-Object { $_.Trim() })
        if ($lines.Count -eq 0) { throw 'the local listener captured nothing' }
        return ($lines[-1] | ConvertFrom-Json)
    }

    # 4a. a push WITH a credential carries the Authorization header
    $sent = Send-VaultApprovalNotification -Topic 'protectedtopic' -Url 'https://example.invalid/#k=x' `
        -HostName 'TESTHOST' -Code '42' -Server $prefix -Token 'tk_testvalue'
    Assert-True $sent 'the push with a credential succeeds'
    $capture = Read-LastCapture
    Assert-Equal 'Bearer tk_testvalue' $capture.headers.'authorization' 'the credential is sent as a bearer token'
    Assert-Equal 'Vault Unlock: Code [42] (TESTHOST)' $capture.headers.'title' 'the title still travels'

    # 4b. a push WITHOUT a credential carries no Authorization header
    $sent = Send-VaultApprovalNotification -Topic 'publictopic' -Url 'https://example.invalid/#k=x' `
        -HostName 'TESTHOST' -Code '42' -Server $prefix -NoToken
    Assert-True $sent 'the anonymous push succeeds'
    $capture = Read-LastCapture
    Assert-True ($capture.request -like '*publictopic*') 'the anonymous push really reached the listener'
    Assert-Equal $null $capture.headers.'authorization' 'an anonymous push carries no credential'


    # 5. a refused push says WHY. ntfy answers 403 to a protected topic when
    #    the credential is missing, and drops the message - so without this the
    #    only symptom is a phone that never buzzes.
    # TextWriter's Stream constructors are all PROTECTED - the public way to
    # capture text is a StringWriter over a StringBuilder.
    $sb = New-Object Text.StringBuilder
    $writer = [IO.StringWriter]::new($sb)
    $oldError = [Console]::Error
    [Console]::SetError($writer)
    try {
        $sent = Send-VaultApprovalNotification -Topic 'refusetopic' -Url 'https://example.invalid/#k=x' `
            -HostName 'TESTHOST' -Code '42' -Server $prefix -NoToken
    } finally {
        $writer.Flush()
        [Console]::SetError($oldError)
    }
    $stderr = $sb.ToString()

    Assert-True (-not $sent) 'a refused push reports failure'
    Assert-True ($stderr -match '403') 'the refusal names the http status'
    Assert-True ($stderr -match 'ntfyToken') 'the refusal says which setting to fix'
    Assert-True ($stderr -match 'MAINFRAME_NTFY_TOKEN') 'the refusal names the environment variable too'
} finally {
    # the listener ends on its own after the last request; nothing to stop.
    Wait-Job -Job $listener -Timeout 15 | Out-Null
}

Write-Host "vault-approval token checks: $script:checks passed"
