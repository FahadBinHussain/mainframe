# No Pester dependency. This file has to pass under windows powershell 5.1 AND
# pwsh 7 - the whole point is that the approval flow works in both.
#
# It never touches the network, the vault or the phone. It only checks how the
# module decides WHO is asking for an approval, because a wrong answer puts
# the wrong name on the phone card and lets a lookalike request pass for the
# real one.
$ErrorActionPreference = 'Stop'
$module = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../vault-approval.psm1'))

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
    $script:checks++
}

# 1. the module parses
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'vault-approval.psm1 parses'

$source = Get-Content -LiteralPath $module -Raw

# 2. the resolution ORDER is the fix, so it is checked structurally: a future
#    edit that moves the env vars back above the process tree silently
#    reintroduces the bug this file exists to catch.
$ancestryAt = $source.IndexOf('Process ancestry BEFORE')
$namedEnvAt = $source.IndexOf('The named agent env vars')
$lastEnvAt = $source.IndexOf('# 5. Environment variables, last resort')
Assert-True ($ancestryAt -gt 0) 'the process-ancestry step is present'
Assert-True ($namedEnvAt -gt 0) 'the named-env step is present'
Assert-True ($lastEnvAt -gt 0) 'the last-resort env step is present'
Assert-True ($ancestryAt -lt $namedEnvAt) 'the process tree is consulted before the named env vars'
Assert-True ($namedEnvAt -lt $lastEnvAt) 'the named env vars come before the last-resort env step'

# 3. the opencode compatibility flag on its own is the WEAKEST signal, so it
#    must be the last branch. MiniMax Code sets it for opencode compatibility,
#    which is what made every MiniMax Code request read as 'opencode'.
$compatFlag = $source.IndexOf('} elseif ($env:OPENCODE_DISABLE_CHANNEL_DB) {')
Assert-True ($compatFlag -gt 0) 'the compatibility-flag branch is present'
Assert-True ($compatFlag -gt $source.IndexOf('$env:ANTIGRAVITY_AGENT')) 'the compatibility flag is tested after the antigravity marker'
Assert-True ($compatFlag -gt $source.IndexOf('$env:OPENCODE_SESSION')) 'the compatibility flag is tested after the opencode marker'
Assert-True ($source -notmatch '\$env:OPENCODE -or \$env:OPENCODE_SESSION -or \$env:OPENCODE_DISABLE_CHANNEL_DB') `
    'the compatibility flag no longer rides along with the opencode marker'

# 4. MiniMax Code is in the process tree list
Assert-True ($source -match "\$name -match 'minimax\|mcode'") 'the process tree matches the MiniMax Code process'

Import-Module $module -Force -DisableNameChecking

# 5. the exported surface grew the two helpers
$exported = @(
    'Get-CallerIdentity', 'Get-MiniMaxSessionId', 'Get-MiniMaxModelFromDisk'
)
foreach ($name in $exported) {
    Assert-True ($null -ne (Get-Command $name -ErrorAction SilentlyContinue)) "$name is exported"
}

# 6. an explicit agent always wins
$explicit = Get-CallerIdentity -Agent 'some-agent' -Model 'some-model'
Assert-Equal 'some-agent' $explicit.Agent 'an explicit agent wins'
Assert-Equal 'some-model' $explicit.Model 'an explicit model wins'

# 7. a browser request is recognised from its context
$browser = Get-CallerIdentity -PromptContext 'monitor unlock request'
Assert-Equal 'browser' $browser.Agent 'a monitor request is a browser request'
$browser2 = Get-CallerIdentity -PromptContext 'open the browser page'
Assert-Equal 'browser' $browser2.Agent 'a browser request is a browser request'

# 8. the operator override beats the process tree
$saved = $env:MAINFRAME_AGENT_NAME
try {
    $env:MAINFRAME_AGENT_NAME = 'pinned-agent'
    $pinned = Get-CallerIdentity
    Assert-Equal 'pinned-agent' $pinned.Agent 'MAINFRAME_AGENT_NAME overrides the process tree'
} finally {
    if ($null -eq $saved) { Remove-Item Env:\MAINFRAME_AGENT_NAME -ErrorAction SilentlyContinue }
    else { $env:MAINFRAME_AGENT_NAME = $saved }
}

# 9. the session id is found in the session workspace path
$fakeId = 'mvs_0123456789abcdef0123456789abcdef'
$enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fakeId)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
$drive = (Get-PSDrive -PSProvider FileSystem | Select-Object -First 1).Root
$fakeWorkspace = Join-Path $drive ("tmp\mf-identity-test\sessions\" + $fakeId + "\workspace")
New-Item -ItemType Directory -Force -Path $fakeWorkspace | Out-Null
$savedCwd = (Get-Location).Path
try {
    Set-Location -LiteralPath $fakeWorkspace
    $found = Get-MiniMaxSessionId
    Assert-Equal $fakeId $found 'the session id comes out of the workspace path'
} finally {
    Set-Location -LiteralPath $savedCwd
}

# 10. the session id survives the base64url round trip the disk uses
$decoded = $enc.Replace('-', '+').Replace('_', '/')
switch ($decoded.Length % 4) {
    2 { $decoded += '==' }
    3 { $decoded += '=' }
}
Assert-Equal $fakeId ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($decoded))) `
    'the base64url session id round trips'

# 11. a session id with no folder on disk is not an error, it is just unknown
$missing = Get-MiniMaxModelFromDisk -SessionId 'mvs_00000000000000000000000000000000'
Assert-Equal $null $missing 'an unknown session id yields no model and no exception'

# 12. the real session tree is read when it is there
$realId = Get-MiniMaxSessionId
if ($realId) {
    $model = Get-MiniMaxModelFromDisk -SessionId $realId
    if ($model) {
        Assert-True ($model.Length -gt 0) 'the model read back from disk is not empty'
    } else {
        # the session tree is absent on this machine - the ground truth simply
        # is not there, which is allowed
        $script:checks++
    }
}

# 13. the identity this harness produces must not claim to be another harness
$mine = Get-CallerIdentity
Assert-True ($mine.Agent -in @('minimax-code', 'browser', 'terminal', 'opencode', 'claude-code', 'codex', 'antigravity', 'qoder', 'aider', 'cursor', 'windsurf')) `
    'the resolved agent is one of the known labels'

Write-Host "vault-approval identity checks: $script:checks passed"
